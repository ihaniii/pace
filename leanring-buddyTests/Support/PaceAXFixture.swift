//
//  PaceAXFixture.swift
//  leanring-buddyTests
//
//  Test-side client for PaceAXFixtureHost, the separate helper app that hosts real AppKit
//  controls so QBridgeAccessibility tests exercise genuine cross-process Accessibility
//  instead of AX calls back into this XCTest host's own process (which crash in AppKit's
//  main-queue assertions, return inconsistent trees, or hang).
//
//  Three layers:
//    - PaceAXFixtureLease: a process-wide lease so at most ONE fixture runs at a time, across
//      every suite. Swift Testing runs suites in parallel inside this process, and a second
//      live fixture would both make bundle-identifier resolution ambiguous (QBridge fails
//      closed on that) and be force-terminated by the next launch's stale-instance cleanup.
//    - PaceAXFixtureHostProcess: launches one fixture process (only while holding the lease)
//      and exchanges newline-delimited JSON requests over its stdin/stdout.
//    - PaceAXFixture: a registered, handshaken fixture with typed scene commands.
//

import AppKit
import Foundation

enum PaceAXFixtureError: Error, CustomStringConvertible {
    case fixtureAppMissing(String)
    case launchFailed(String)
    case requestFailed(String)
    case responseTimedOut(String)
    case leaseTimedOut(TimeInterval)
    case fixtureNeverRegistered(pid_t)
    case unexpectedValueType(identifier: String, key: String, value: String)

    var description: String {
        switch self {
        case .fixtureAppMissing(let path): return "fixture app not built at \(path)"
        case .launchFailed(let reason): return "fixture launch failed: \(reason)"
        case .requestFailed(let reason): return "fixture request failed: \(reason)"
        case .responseTimedOut(let command): return "fixture did not answer '\(command)' in time"
        case .leaseTimedOut(let seconds):
            return "waited \(Int(seconds))s for the fixture lease — a previous fixture user never released it (a leaked fixture, not a slow test)"
        case .fixtureNeverRegistered(let pid): return "fixture pid \(pid) never appeared in NSWorkspace.runningApplications under its bundle identifier"
        case .unexpectedValueType(let identifier, let key, let value): return "fixture '\(identifier)'.\(key) returned unexpected value \(value)"
        }
    }
}

// MARK: - Lease

/// Grants the single fixture slot to one holder at a time, in request order.
actor PaceAXFixtureLease {
    static let shared = PaceAXFixtureLease()

    /// How long a would-be holder waits before failing. This is not a tuning knob: tests only
    /// hold the lease for their own short duration, so reaching it means a holder leaked the
    /// lease, and the right outcome is a loud failure naming that, not an indefinite hang.
    static let acquisitionTimeoutSeconds: TimeInterval = 300

    private var isHeld = false
    private var waitingHolders: [(waiterId: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        guard isHeld else {
            isHeld = true
            return
        }
        let waiterId = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waitingHolders.append((waiterId, continuation))
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.acquisitionTimeoutSeconds * 1_000_000_000))
                self.failWaiterIfStillWaiting(waiterId)
            }
        }
    }

    /// Hands the lease straight to the next waiter (it stays held) or frees it.
    func release() {
        if waitingHolders.isEmpty {
            isHeld = false
        } else {
            waitingHolders.removeFirst().continuation.resume()
        }
    }

    private func failWaiterIfStillWaiting(_ waiterId: UUID) {
        guard let waiterIndex = waitingHolders.firstIndex(where: { $0.waiterId == waiterId }) else { return }
        waitingHolders.remove(at: waiterIndex).continuation.resume(throwing: PaceAXFixtureError.leaseTimedOut(Self.acquisitionTimeoutSeconds))
    }
}

// MARK: - Process

/// Launches and talks to one PaceAXFixtureHost process over its stdin/stdout pipes.
final class PaceAXFixtureHostProcess: @unchecked Sendable {
    static let bundleIdentifier = "test.qbridge.axfixturehost"

    /// The fixture is built next to Pace.app (the test host) in the same products directory.
    static var fixtureExecutableURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("PaceAXFixtureHost.app/Contents/MacOS/PaceAXFixtureHost")
    }

    let process: Process
    private let requestPipe = Pipe()
    private let responsePipe = Pipe()
    private let ioQueue = DispatchQueue(label: "PaceAXFixtureHostProcess.io")
    private var pendingResponseBytes = Data()
    private var nextRequestId = 0
    private let leaseReleaseLock = NSLock()
    private var hasReleasedLease = false

    /// The ONLY way to start a fixture: waits for the lease, clears any stale instance, then
    /// launches. The lease is released by `forceStop()` (or, as a backstop, on deinit).
    ///
    /// - Parameter viaIntermediateShell: launch through `/bin/sh` so the fixture's parent is a
    ///   process a test can kill independently (parent-death teardown test).
    static func launch(viaIntermediateShell: Bool = false) async throws -> PaceAXFixtureHostProcess {
        try await PaceAXFixtureLease.shared.acquire()
        do {
            await terminateStaleInstances()
            return try PaceAXFixtureHostProcess(viaIntermediateShell: viaIntermediateShell)
        } catch {
            await PaceAXFixtureLease.shared.release()
            throw error
        }
    }

    private init(viaIntermediateShell: Bool) throws {
        let executableURL = Self.fixtureExecutableURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw PaceAXFixtureError.fixtureAppMissing(executableURL.path)
        }
        process = Process()
        if viaIntermediateShell {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // "$0" is the fixture path; the shell stays alive as the fixture's parent. The explicit
            // `0<&0` keeps our stdin pipe — a non-interactive shell otherwise gives a background
            // job /dev/null, which would read as an immediate EOF.
            process.arguments = ["-c", "\"$0\" 0<&0 & wait", executableURL.path]
        } else {
            process.executableURL = executableURL
        }
        process.standardInput = requestPipe
        process.standardOutput = responsePipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw PaceAXFixtureError.launchFailed(error.localizedDescription)
        }
    }

    deinit {
        // Backstop only: a test that forgot forceStop() (or threw before its defer ran) must
        // neither leave a fixture running nor hold the lease forever.
        if process.isRunning { process.terminate() }
        releaseLeaseOnce()
    }

    /// Sends one JSON request line and waits (off the main actor) for the matching response.
    func request(_ command: String, _ parameters: [String: Any] = [:], timeout: TimeInterval = 5) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    continuation.resume(returning: try self.blockingRequest(command, parameters, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func blockingRequest(_ command: String, _ parameters: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        nextRequestId += 1
        let requestId = nextRequestId
        var requestObject = parameters
        requestObject["id"] = requestId
        requestObject["command"] = command
        var requestLine = try JSONSerialization.data(withJSONObject: requestObject)
        requestLine.append(0x0A)
        try requestPipe.fileHandleForWriting.write(contentsOf: requestLine)

        let responseFileDescriptor = responsePipe.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newlineIndex = pendingResponseBytes.firstIndex(of: 0x0A) {
                let lineBytes = pendingResponseBytes[pendingResponseBytes.startIndex..<newlineIndex]
                pendingResponseBytes.removeSubrange(pendingResponseBytes.startIndex...newlineIndex)
                guard let response = (try? JSONSerialization.jsonObject(with: Data(lineBytes))) as? [String: Any] else {
                    throw PaceAXFixtureError.requestFailed("unparseable response to \(command)")
                }
                guard response["id"] as? Int == requestId else { continue }
                guard response["ok"] as? Bool == true else {
                    throw PaceAXFixtureError.requestFailed("\(command): \(response["error"] ?? "unknown")")
                }
                return response
            }
            let remainingMilliseconds = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard remainingMilliseconds > 0 else { throw PaceAXFixtureError.responseTimedOut(command) }
            var pollDescriptor = pollfd(fd: responseFileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, remainingMilliseconds) > 0 else { continue }
            var readBuffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(responseFileDescriptor, &readBuffer, readBuffer.count)
            guard bytesRead > 0 else { throw PaceAXFixtureError.requestFailed("fixture closed stdout during \(command)") }
            pendingResponseBytes.append(contentsOf: readBuffer[0..<bytesRead])
        }
    }

    /// Teardown path under test: close our end of stdin; the fixture must exit on EOF.
    func closeStdin() {
        try? requestPipe.fileHandleForWriting.close()
    }

    /// Stops the fixture and releases the lease. Safe to call more than once.
    func forceStop() {
        closeStdin()
        if process.isRunning { process.terminate() }
        releaseLeaseOnce()
    }

    private func releaseLeaseOnce() {
        leaseReleaseLock.lock()
        let shouldRelease = !hasReleasedLease
        hasReleasedLease = true
        leaseReleaseLock.unlock()
        guard shouldRelease else { return }
        Task { await PaceAXFixtureLease.shared.release() }
    }

    /// Terminates any stale fixture instance left behind by a crashed run, matched ONLY by the
    /// fixture's exact bundle identifier, so launch-time resolution is never ambiguous. Only
    /// ever called while holding the lease, so it can never kill another test's live fixture.
    @MainActor
    private static func terminateStaleInstances() async {
        let staleInstances = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleIdentifier }
        for staleInstance in staleInstances { staleInstance.forceTerminate() }
        for _ in 0..<50 where NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

// MARK: - Typed fixture

/// A launched, handshaken fixture that the system has registered under its bundle identifier
/// (which is what QBridgeAccessibility resolves against).
final class PaceAXFixture: @unchecked Sendable {
    let hostProcess: PaceAXFixtureHostProcess
    let processIdentifier: pid_t

    /// The application name tests pass to QBridge in place of the test host's own name.
    var applicationName: String { PaceAXFixtureHostProcess.bundleIdentifier }

    private init(hostProcess: PaceAXFixtureHostProcess, processIdentifier: pid_t) {
        self.hostProcess = hostProcess
        self.processIdentifier = processIdentifier
    }

    static func launch() async throws -> PaceAXFixture {
        let hostProcess = try await PaceAXFixtureHostProcess.launch()
        do {
            let handshake = try await hostProcess.request("ping")
            guard let fixturePid = (handshake["pid"] as? Int).map({ pid_t($0) }) else {
                throw PaceAXFixtureError.requestFailed("ping response carried no pid")
            }
            let registered = await Self.waitUntilRegistered(fixturePid)
            guard registered else { throw PaceAXFixtureError.fixtureNeverRegistered(fixturePid) }
            return PaceAXFixture(hostProcess: hostProcess, processIdentifier: fixturePid)
        } catch {
            hostProcess.forceStop()
            throw error
        }
    }

    /// Runs `body` with a fresh fixture and always stops it afterwards, even if `body` throws.
    static func withFixture<Result>(_ body: (PaceAXFixture) async throws -> Result) async throws -> Result {
        let fixture = try await launch()
        defer { fixture.stop() }
        return try await body(fixture)
    }

    func stop() {
        hostProcess.forceStop()
    }

    @MainActor
    private static func waitUntilRegistered(_ fixturePid: pid_t) async -> Bool {
        for _ in 0..<50 {
            let isRegistered = NSWorkspace.shared.runningApplications.contains {
                $0.processIdentifier == fixturePid && $0.bundleIdentifier == PaceAXFixtureHostProcess.bundleIdentifier
            }
            if isRegistered { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    // MARK: Scene building

    /// Creates a window and returns its token. `styles` defaults (in the fixture) to
    /// titled, closable, miniaturizable, resizable.
    @discardableResult
    func createWindow(
        identifier: String? = nil,
        title: String? = nil,
        width: Double = 480,
        height: Double = 360,
        styles: [String]? = nil,
        kind: String = "window"
    ) async throws -> String {
        var parameters: [String: Any] = ["width": width, "height": height, "kind": kind]
        if let identifier { parameters["identifier"] = identifier }
        if let title { parameters["title"] = title }
        if let styles { parameters["styles"] = styles }
        let response = try await hostProcess.request("createWindow", parameters)
        return try requireString(response["windowToken"], identifier: identifier ?? "window", key: "windowToken")
    }

    /// Adds a control into a window (`windowToken`) or into a container control
    /// (`parentIdentifier`). `frame` is optional; the fixture stacks controls when omitted.
    func addControl(
        kind: String,
        identifier: String,
        windowToken: String? = nil,
        parentIdentifier: String? = nil,
        frame: NSRect? = nil,
        properties: [String: Any] = [:]
    ) async throws {
        var parameters: [String: Any] = ["kind": kind, "identifier": identifier, "properties": properties]
        if let windowToken { parameters["windowToken"] = windowToken }
        if let parentIdentifier { parameters["parentIdentifier"] = parentIdentifier }
        if let frame { parameters["frame"] = [frame.origin.x, frame.origin.y, frame.width, frame.height] }
        _ = try await hostProcess.request("addControl", parameters)
    }

    func presentSheet(parentIdentifier: String, identifier: String, title: String? = nil) async throws {
        var parameters: [String: Any] = ["parent": parentIdentifier, "identifier": identifier]
        if let title { parameters["title"] = title }
        _ = try await hostProcess.request("presentSheet", parameters)
    }

    func endSheet(identifier: String) async throws {
        _ = try await hostProcess.request("endSheet", ["identifier": identifier])
    }

    func startModalSession(identifier: String) async throws {
        _ = try await hostProcess.request("startModal", ["identifier": identifier])
    }

    func stopModalSession() async throws {
        _ = try await hostProcess.request("stopModal")
    }

    func isModalSessionRunning() async throws -> Bool {
        let response = try await hostProcess.request("isModalSessionRunning")
        return try requireBool(response["value"], identifier: "application", key: "isModalSessionRunning")
    }

    // MARK: Ground truth (read from the fixture's own AppKit objects, never through AX)

    func value(_ identifier: String, _ key: String) async throws -> Any {
        let response = try await hostProcess.request("get", ["identifier": identifier, "key": key])
        guard let value = response["value"] else { throw PaceAXFixtureError.unexpectedValueType(identifier: identifier, key: key, value: "nil") }
        return value
    }

    func string(_ identifier: String, _ key: String) async throws -> String {
        try requireString(try await value(identifier, key), identifier: identifier, key: key)
    }

    func double(_ identifier: String, _ key: String) async throws -> Double {
        let rawValue = try await value(identifier, key)
        guard let number = rawValue as? NSNumber else { throw PaceAXFixtureError.unexpectedValueType(identifier: identifier, key: key, value: "\(rawValue)") }
        return number.doubleValue
    }

    func int(_ identifier: String, _ key: String) async throws -> Int {
        let rawValue = try await value(identifier, key)
        guard let number = rawValue as? NSNumber else { throw PaceAXFixtureError.unexpectedValueType(identifier: identifier, key: key, value: "\(rawValue)") }
        return number.intValue
    }

    /// A Double that the fixture reports as null when the underlying AppKit object is absent.
    func optionalDouble(_ identifier: String, _ key: String) async throws -> Double? {
        let rawValue = try await value(identifier, key)
        if rawValue is NSNull { return nil }
        guard let number = rawValue as? NSNumber else { throw PaceAXFixtureError.unexpectedValueType(identifier: identifier, key: key, value: "\(rawValue)") }
        return number.doubleValue
    }

    /// Optional-identifier overloads: a nil handle (e.g. `inputField` when none was created, or
    /// `buttons.first` of an empty list) reads as nil, mirroring optional chaining on the old
    /// AppKit object.
    func stringIfPresent(_ identifier: String?, _ key: String) async throws -> String? {
        guard let identifier else { return nil }
        return try await string(identifier, key)
    }

    func optionalString(_ identifier: String, _ key: String) async throws -> String? {
        let rawValue = try await value(identifier, key)
        if rawValue is NSNull { return nil }
        return try requireString(rawValue, identifier: identifier, key: key)
    }

    func intIfPresent(_ identifier: String?, _ key: String) async throws -> Int? {
        guard let identifier else { return nil }
        let rawValue = try await value(identifier, key)
        if rawValue is NSNull { return nil }
        guard let number = rawValue as? NSNumber else { throw PaceAXFixtureError.unexpectedValueType(identifier: identifier, key: key, value: "\(rawValue)") }
        return number.intValue
    }

    func optionalDoubles(_ identifier: String, _ key: String) async throws -> [Double]? {
        let rawValue = try await value(identifier, key)
        if rawValue is NSNull { return nil }
        guard let numbers = rawValue as? [NSNumber] else { throw PaceAXFixtureError.unexpectedValueType(identifier: identifier, key: key, value: "\(rawValue)") }
        return numbers.map(\.doubleValue)
    }

    /// Fixture handles of the AppKit objects an accessibility accessor returned (nil if it returned nil).
    func handles(_ identifier: String, _ key: String) async throws -> [String]? {
        let rawValue = try await value(identifier, key)
        if rawValue is NSNull { return nil }
        guard let handles = rawValue as? [String] else { throw PaceAXFixtureError.unexpectedValueType(identifier: identifier, key: key, value: "\(rawValue)") }
        return handles
    }

    func fieldEditorSelectedRange(_ identifier: String) async throws -> NSRange? {
        let rawValue = try await value(identifier, "fieldEditorSelectedRange")
        if rawValue is NSNull { return nil }
        guard let parts = rawValue as? [Int], parts.count == 2 else { throw PaceAXFixtureError.unexpectedValueType(identifier: identifier, key: "fieldEditorSelectedRange", value: "\(rawValue)") }
        return NSRange(location: parts[0], length: parts[1])
    }

    func bool(_ identifier: String, _ key: String) async throws -> Bool {
        try requireBool(try await value(identifier, key), identifier: identifier, key: key)
    }

    // MARK: Mutations performed by the fixture itself (test setup, not the code under test)

    func set(_ identifier: String, _ key: String, _ value: Any) async throws {
        _ = try await hostProcess.request("set", ["identifier": identifier, "key": key, "value": value])
    }

    func perform(_ identifier: String, _ action: String) async throws {
        _ = try await hostProcess.request("perform", ["identifier": identifier, "action": action])
    }

    /// Sets one allowlisted NSAccessibility override. For element-reference attributes pass the
    /// referenced control identifier (or an array of them) as `value`.
    func setAccessibility(_ identifier: String, _ attribute: String, _ value: Any) async throws {
        _ = try await hostProcess.request("setAccessibility", ["identifier": identifier, "attribute": attribute, "value": value])
    }

    /// Runs an application-level operation ("activate", "hide", "unhide", "state") in the
    /// fixture and reports the fixture's own resulting state.
    @discardableResult
    func applicationOperation(_ operation: String) async throws -> (isActive: Bool, isHidden: Bool) {
        let response = try await hostProcess.request("application", ["operation": operation])
        return (
            try requireBool(response["isActive"], identifier: "application", key: "isActive"),
            try requireBool(response["isHidden"], identifier: "application", key: "isHidden")
        )
    }

    // MARK: Menus (built by the fixture's own AppKit menu code)

    func installMenu(menuBarTitle: String, itemTitle: String, itemEnabled: Bool, countsSelections: Bool) async throws {
        _ = try await hostProcess.request("installMenu", [
            "menuBarTitle": menuBarTitle, "itemTitle": itemTitle, "itemEnabled": itemEnabled, "countsSelections": countsSelections
        ])
    }

    func appendMenuItem(menuBarTitle: String, itemTitle: String) async throws {
        _ = try await hostProcess.request("appendMenuItem", ["menuBarTitle": menuBarTitle, "itemTitle": itemTitle])
    }

    func insertRootMenu(title: String, itemTitle: String) async throws {
        _ = try await hostProcess.request("insertRootMenu", ["title": title, "itemTitle": itemTitle])
    }

    func menuSelectionCount(menuBarTitle: String) async throws -> Int {
        let response = try await hostProcess.request("menuSelectionCount", ["menuBarTitle": menuBarTitle])
        guard let count = response["value"] as? Int else { throw PaceAXFixtureError.unexpectedValueType(identifier: menuBarTitle, key: "menuSelectionCount", value: "\(response["value"] ?? "nil")") }
        return count
    }

    /// Makes the fixture the ACTIVE application (what `NSApp.activate(ignoringOtherApps: true)` did
    /// for the in-process windows it replaces), then waits — bounded — until the fixture itself
    /// reports being active. Never skips: if activation never lands, the caller's own assertions
    /// decide the outcome.
    func activateApplication() async throws {
        try await applicationOperation("activate")
        NSRunningApplication(processIdentifier: processIdentifier)?.activate()
        for _ in 0..<30 {
            if try await applicationOperation("state").isActive { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func events() async throws -> [[String: Any]] {
        let response = try await hostProcess.request("events")
        return response["events"] as? [[String: Any]] ?? []
    }

    func clearEvents() async throws {
        _ = try await hostProcess.request("clearEvents")
    }

    private func requireString(_ rawValue: Any?, identifier: String, key: String) throws -> String {
        guard let stringValue = rawValue as? String else { throw PaceAXFixtureError.unexpectedValueType(identifier: identifier, key: key, value: "\(rawValue ?? "nil")") }
        return stringValue
    }

    private func requireBool(_ rawValue: Any?, identifier: String, key: String) throws -> Bool {
        guard let boolValue = rawValue as? Bool else { throw PaceAXFixtureError.unexpectedValueType(identifier: identifier, key: key, value: "\(rawValue ?? "nil")") }
        return boolValue
    }
}
