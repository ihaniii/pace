//
//  QAuditLoggerTestProcessIsolationTests.swift
//  leanring-buddyTests
//
//  Proves the unit-test host never writes to (or rotates) the user's real
//  ~/Library/Application Support/Pace/q-audit.log: the default logger inside a
//  test host resolves to a validated per-process temporary log, and every
//  failure to establish that isolation falls back to memory-only — never to
//  the production path.
//
//  Every branch that could create a directory is driven with test-owned fake
//  roots under a fresh temporary directory; the real production directory is
//  only ever READ (to prove nothing was written there).
//

import Foundation
import Testing
@testable import Pace

@Suite("QAuditLogger test-process isolation")
struct QAuditLoggerTestProcessIsolationTests {

    // MARK: - Fixtures

    private static let validXCTestMarkerEnvironment = [
        PaceTestHostDataIsolation.xcTestConfigurationEnvironmentMarkerKey: "/private/var/folders/fake/pace.xctestconfiguration"
    ]

    /// A fresh, test-owned sandbox holding a fake temp root, a fake
    /// Application Support, and a fake home — so no branch of the resolver
    /// ever touches the real user directories.
    private struct FakeFilesystemRoots {
        let sandboxURL: URL
        let temporaryRootURL: URL
        let applicationSupportURL: URL
        let homeURL: URL

        init() throws {
            sandboxURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("q-audit-isolation-fixture-\(UUID().uuidString)", isDirectory: true)
            temporaryRootURL = sandboxURL.appendingPathComponent("tmp-root", isDirectory: true)
            applicationSupportURL = sandboxURL.appendingPathComponent("home/Library/Application Support", isDirectory: true)
            homeURL = sandboxURL.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: applicationSupportURL.appendingPathComponent("Pace", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        func resolve(
            environment: [String: String] = QAuditLoggerTestProcessIsolationTests.validXCTestMarkerEnvironment,
            isXCTestRuntimeLoaded: Bool = true,
            temporaryRootURL overridingTemporaryRootURL: URL? = nil,
            processIdentifier: Int32 = 4242,
            uniqueToken: String = UUID().uuidString
        ) -> PaceTestHostFileDestination {
            PaceTestHostDataIsolation.resolveTestHostFileDestination(
                relativePath: QAuditLogger.auditLogFileName,
                environment: environment,
                isXCTestRuntimeLoaded: isXCTestRuntimeLoaded,
                temporaryRootDirectoryURL: overridingTemporaryRootURL ?? temporaryRootURL,
                applicationSupportDirectoryURL: applicationSupportURL,
                homeDirectoryURL: homeURL,
                processIdentifier: processIdentifier,
                uniqueToken: uniqueToken
            )
        }

        func removeSandbox() {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    private static var realProductionLogFileURL: URL {
        let realApplicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return QAuditLogger.productionDefaultLogFileURL(applicationSupportDirectoryURL: realApplicationSupportURL)
    }

    private static func isolatedLogURL(from destination: PaceTestHostFileDestination) -> URL? {
        if case .isolatedTemporaryFile(let isolatedLogFileURL) = destination { return isolatedLogFileURL }
        return nil
    }

    private static func isMemoryOnly(_ destination: PaceTestHostFileDestination) -> Bool {
        if case .isolationUnavailable = destination { return true }
        return false
    }

    /// Size + modification date + contents of every real production
    /// q-audit.log* file. Read-only.
    private static func snapshotOfRealProductionLogFiles() -> [String: String] {
        let productionDirectoryURL = realProductionLogFileURL.deletingLastPathComponent()
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: productionDirectoryURL.path)) ?? []
        var snapshot: [String: String] = [:]
        for fileName in fileNames where fileName.hasPrefix("q-audit.log") {
            let filePath = productionDirectoryURL.appendingPathComponent(fileName).path
            let attributes = (try? FileManager.default.attributesOfItem(atPath: filePath)) ?? [:]
            let size = attributes[.size] as? Int ?? -1
            let modificationDate = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            snapshot[fileName] = "\(size)|\(modificationDate)"
        }
        return snapshot
    }

    private static func makeRecord(sessionId: String) -> QAuditRecord {
        QAuditRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            sessionId: sessionId,
            taskId: "isolation-task",
            tool: "isolation.test",
            riskLevel: .level0ReadOnly,
            rawArguments: "isolation-arguments",
            authorizationResult: "allow",
            provenance: "trusted:system",
            executionSummary: "isolation summary"
        )
    }

    // MARK: - Production path

    @Test("Production default path is unchanged and chosen when no test-host signal exists")
    func productionDefaultPathIsUnchanged() {
        let realApplicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #expect(Self.realProductionLogFileURL == realApplicationSupportURL
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("q-audit.log"))
        #expect(Self.realProductionLogFileURL.path.hasSuffix("/Library/Application Support/Pace/q-audit.log"))

        // No marker, no secondary signal, no XCTest runtime → the resolver
        // defers to init's unchanged production branch.
        let destination = PaceTestHostDataIsolation.resolveTestHostFileDestination(
            relativePath: QAuditLogger.auditLogFileName,
            environment: ["HOME": "/Users/someone", "PATH": "/usr/bin"],
            isXCTestRuntimeLoaded: false,
            temporaryRootDirectoryURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
            applicationSupportDirectoryURL: realApplicationSupportURL,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            processIdentifier: 1,
            uniqueToken: "unused"
        )
        #expect(destination == .notRunningUnderTestHost)
    }

    // MARK: - Isolated path

    @Test("A valid XCTest marker produces a fresh isolated log inside the temp root")
    func validMarkerProducesIsolatedPath() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let isolatedLogFileURL = try #require(Self.isolatedLogURL(from: roots.resolve(processIdentifier: 777, uniqueToken: "token-a")))
        let isolatedDirectoryURL = isolatedLogFileURL.deletingLastPathComponent()
        let resolvedTemporaryRootURL = roots.temporaryRootURL.resolvingSymlinksInPath()

        #expect(isolatedLogFileURL.lastPathComponent == "q-audit.log")
        #expect(isolatedDirectoryURL.lastPathComponent == "pace-test-data-777-token-a")
        #expect(isolatedDirectoryURL.deletingLastPathComponent().pathComponents == resolvedTemporaryRootURL.pathComponents)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: isolatedDirectoryURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let permissions = try FileManager.default.attributesOfItem(atPath: isolatedDirectoryURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        #expect(!FileManager.default.fileExists(atPath: isolatedLogFileURL.path))
    }

    @Test("Current Xcode's marker shape (empty config path + session UUID) produces an isolated path")
    func sessionIdentifierMarkerProducesIsolatedPath() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let currentXcodeEnvironment = [
            PaceTestHostDataIsolation.xcTestConfigurationEnvironmentMarkerKey: "",
            PaceTestHostDataIsolation.xcTestSessionIdentifierEnvironmentMarkerKey: UUID().uuidString,
            "XCTestBundlePath": "Contents/PlugIns/leanring-buddyTests.xctest",
            "XCInjectBundleInto": "unused"
        ]
        let isolatedLogFileURL = try #require(Self.isolatedLogURL(from: roots.resolve(environment: currentXcodeEnvironment, isXCTestRuntimeLoaded: false)))
        #expect(isolatedLogFileURL.deletingLastPathComponent().deletingLastPathComponent().pathComponents
            == roots.temporaryRootURL.resolvingSymlinksInPath().pathComponents)
    }

    @Test("The isolated path never equals or sits inside the production location")
    func isolatedPathDiffersFromProductionPath() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let isolatedLogFileURL = try #require(Self.isolatedLogURL(from: roots.resolve()))
        let fakeProductionLogFileURL = QAuditLogger.productionDefaultLogFileURL(applicationSupportDirectoryURL: roots.applicationSupportURL)
        #expect(isolatedLogFileURL.path != fakeProductionLogFileURL.path)
        #expect(isolatedLogFileURL.path != Self.realProductionLogFileURL.path)
        #expect(!isolatedLogFileURL.path.contains("/Application Support/"))
    }

    @Test("Different process/token identities produce different directories; a reused identity fails safely")
    func differentIdentitiesProduceDifferentDirectories() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let firstLogURL = try #require(Self.isolatedLogURL(from: roots.resolve(processIdentifier: 100, uniqueToken: "same-token")))
        let otherProcessLogURL = try #require(Self.isolatedLogURL(from: roots.resolve(processIdentifier: 101, uniqueToken: "same-token")))
        let otherTokenLogURL = try #require(Self.isolatedLogURL(from: roots.resolve(processIdentifier: 100, uniqueToken: "other-token")))

        #expect(Set([firstLogURL, otherProcessLogURL, otherTokenLogURL].map(\.path)).count == 3)

        // Exact same identity again: the directory already exists, so the
        // resolver refuses to share it rather than reuse another process's log.
        #expect(Self.isMemoryOnly(roots.resolve(processIdentifier: 100, uniqueToken: "same-token")))
    }

    // MARK: - The real shared logger in this test process

    @Test("QAuditLogger.shared in this test host is isolated under the real temp directory")
    func sharedLoggerInTestHostIsIsolated() throws {
        let sharedLogFileURL = try #require(
            QAuditLogger.shared.persistedLogFileURL,
            "shared logger is memory-only — test-host isolation marker was not recognized"
        )
        let resolvedRealTemporaryRootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let sharedDirectoryURL = sharedLogFileURL.deletingLastPathComponent()

        #expect(sharedLogFileURL.path != Self.realProductionLogFileURL.path)
        #expect(sharedDirectoryURL.deletingLastPathComponent().pathComponents == resolvedRealTemporaryRootURL.pathComponents)
        #expect(sharedDirectoryURL.lastPathComponent.hasPrefix("pace-test-data-\(ProcessInfo.processInfo.processIdentifier)-"))
        print("🧪 QAuditLogger.shared isolated test log: \(sharedLogFileURL.path)")
    }

    @Test("Writes through QAuditLogger.shared reach the isolated log and never the production log")
    func sharedWritesReachIsolatedLogNotProduction() throws {
        let sharedLogFileURL = try #require(QAuditLogger.shared.persistedLogFileURL)
        let productionSnapshotBefore = Self.snapshotOfRealProductionLogFiles()

        let uniqueMarkerSessionId = "isolation-marker-\(UUID().uuidString)"
        QAuditLogger.shared.record(Self.makeRecord(sessionId: uniqueMarkerSessionId))

        let isolatedContents = try String(contentsOf: sharedLogFileURL, encoding: .utf8)
        #expect(isolatedContents.contains(uniqueMarkerSessionId))
        #expect(QAuditLogger.shared.getRecentRecords(limit: 1000).contains { $0.sessionId == uniqueMarkerSessionId })

        if let productionContents = try? String(contentsOf: Self.realProductionLogFileURL, encoding: .utf8) {
            #expect(!productionContents.contains(uniqueMarkerSessionId))
        }
        #expect(Self.snapshotOfRealProductionLogFiles() == productionSnapshotBefore)
    }

    // MARK: - Fail-safe branches

    @Test("A test-host signal without a valid marker is memory-only, never production")
    func missingOrInvalidMarkerNeverFallsBackToProduction() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let signalledButUnmarkedEnvironments: [[String: String]] = [
            ["XCTestBundlePath": "/tmp/Pace.xctest"],
            ["XCTestSessionIdentifier": "ABC"],
            ["XCInjectBundleInto": "/tmp/Pace"],
            ["DYLD_INSERT_LIBRARIES": "/Applications/Xcode.app/usr/lib/libXCTestBundleInject.dylib"],
            [PaceTestHostDataIsolation.xcTestConfigurationEnvironmentMarkerKey: ""],
            [PaceTestHostDataIsolation.xcTestConfigurationEnvironmentMarkerKey: "   "],
            [PaceTestHostDataIsolation.xcTestConfigurationEnvironmentMarkerKey: "relative/path.xctestconfiguration"],
            [
                PaceTestHostDataIsolation.xcTestConfigurationEnvironmentMarkerKey: "",
                PaceTestHostDataIsolation.xcTestSessionIdentifierEnvironmentMarkerKey: "not-a-uuid",
                "XCTestBundlePath": "Contents/PlugIns/leanring-buddyTests.xctest"
            ],
            [PaceTestHostDataIsolation.xcTestSessionIdentifierEnvironmentMarkerKey: ""]
        ]
        for environment in signalledButUnmarkedEnvironments {
            let destination = roots.resolve(environment: environment, isXCTestRuntimeLoaded: false)
            #expect(Self.isMemoryOnly(destination), "environment \(environment) must be memory-only")
        }

        // XCTest runtime loaded, but no environment marker at all.
        #expect(Self.isMemoryOnly(roots.resolve(environment: [:], isXCTestRuntimeLoaded: true)))

        // Nothing was created in the fake production directory by any branch.
        let fakeProductionDirectoryPath = roots.applicationSupportURL.appendingPathComponent("Pace").path
        #expect(try FileManager.default.contentsOfDirectory(atPath: fakeProductionDirectoryPath).isEmpty)
    }

    @Test("Invalid temp roots, identities, or a missing Application Support fail safely")
    func invalidTemporaryRootFailsSafely() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let regularFileURL = roots.sandboxURL.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: regularFileURL)

        #expect(Self.isMemoryOnly(roots.resolve(temporaryRootURL: regularFileURL.appendingPathComponent("child"))))
        #expect(Self.isMemoryOnly(roots.resolve(temporaryRootURL: regularFileURL)))
        #expect(Self.isMemoryOnly(roots.resolve(temporaryRootURL: roots.sandboxURL.appendingPathComponent("missing-\(UUID().uuidString)"))))
        #expect(Self.isMemoryOnly(roots.resolve(temporaryRootURL: URL(fileURLWithPath: "/", isDirectory: true))))
        #expect(Self.isMemoryOnly(roots.resolve(temporaryRootURL: roots.homeURL)))
        #expect(Self.isMemoryOnly(roots.resolve(processIdentifier: 0)))
        #expect(Self.isMemoryOnly(roots.resolve(uniqueToken: "")))
        #expect(Self.isMemoryOnly(roots.resolve(uniqueToken: "../escape")))
        #expect(Self.isMemoryOnly(roots.resolve(uniqueToken: "a/b")))

        let destinationWithoutApplicationSupport = PaceTestHostDataIsolation.resolveTestHostFileDestination(
            relativePath: QAuditLogger.auditLogFileName,
            environment: Self.validXCTestMarkerEnvironment,
            isXCTestRuntimeLoaded: true,
            temporaryRootDirectoryURL: roots.temporaryRootURL,
            applicationSupportDirectoryURL: nil,
            homeDirectoryURL: roots.homeURL,
            processIdentifier: 1,
            uniqueToken: "token"
        )
        #expect(Self.isMemoryOnly(destinationWithoutApplicationSupport))
    }

    @Test("A temp root that is a symlink into the production location fails safely")
    func symlinkToProductionFailsSafely() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let fakeProductionDirectoryURL = roots.applicationSupportURL.appendingPathComponent("Pace", isDirectory: true)
        let symlinkToProductionDirectoryURL = roots.sandboxURL.appendingPathComponent("tmp-link-to-production")
        let symlinkToApplicationSupportURL = roots.sandboxURL.appendingPathComponent("tmp-link-to-app-support")
        try FileManager.default.createSymbolicLink(at: symlinkToProductionDirectoryURL, withDestinationURL: fakeProductionDirectoryURL)
        try FileManager.default.createSymbolicLink(at: symlinkToApplicationSupportURL, withDestinationURL: roots.applicationSupportURL)

        #expect(Self.isMemoryOnly(roots.resolve(temporaryRootURL: symlinkToProductionDirectoryURL)))
        #expect(Self.isMemoryOnly(roots.resolve(temporaryRootURL: symlinkToApplicationSupportURL)))
        #expect(Self.isMemoryOnly(roots.resolve(temporaryRootURL: fakeProductionDirectoryURL)))

        // Nothing was created inside the fake production tree.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fakeProductionDirectoryURL.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: roots.applicationSupportURL.path) == ["Pace"])
    }

    // MARK: - Format and retention unchanged

    @Test("Records written to the isolated log are byte-identical to a custom-URL logger's")
    func recordStructureIsUnchanged() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let isolatedLogFileURL = try #require(Self.isolatedLogURL(from: roots.resolve()))
        let referenceLogFileURL = roots.sandboxURL.appendingPathComponent("reference-q-audit.log")
        let record = Self.makeRecord(sessionId: "structure-check")

        QAuditLogger(customLogURL: isolatedLogFileURL).record(record)
        QAuditLogger(customLogURL: referenceLogFileURL).record(record)

        let isolatedBytes = try Data(contentsOf: isolatedLogFileURL)
        #expect(isolatedBytes == (try Data(contentsOf: referenceLogFileURL)))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedLine = try #require(String(data: isolatedBytes, encoding: .utf8)?.split(separator: "\n").first)
        #expect(try decoder.decode(QAuditRecord.self, from: Data(decodedLine.utf8)) == record)

        let permissions = try FileManager.default.attributesOfItem(atPath: isolatedLogFileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test("Rotation of an isolated log stays inside its temp directory")
    func rotationRemainsIsolated() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let isolatedLogFileURL = try #require(Self.isolatedLogURL(from: roots.resolve()))
        let productionSnapshotBefore = Self.snapshotOfRealProductionLogFiles()

        // Pre-fill to exactly the 25 MB rotation cap so the next write rotates.
        try Data(repeating: 0x61, count: 25 * 1024 * 1024).write(to: isolatedLogFileURL)
        QAuditLogger(customLogURL: isolatedLogFileURL).record(Self.makeRecord(sessionId: "rotation-check"))

        let isolatedDirectoryURL = isolatedLogFileURL.deletingLastPathComponent()
        let rotatedFileNames = try FileManager.default.contentsOfDirectory(atPath: isolatedDirectoryURL.path).sorted()
        #expect(rotatedFileNames == ["q-audit.log", "q-audit.log.1"])
        let freshLogSize = try FileManager.default.attributesOfItem(atPath: isolatedLogFileURL.path)[.size] as? Int ?? 0
        #expect(freshLogSize < 4096)

        #expect(Self.snapshotOfRealProductionLogFiles() == productionSnapshotBefore)
    }
}
