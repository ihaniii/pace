//
//  PaceAPIAuditLogTestProcessIsolationTests.swift
//  leanring-buddyTests
//
//  Proves the unit-test host never writes to (or rotates) the user's real
//  ~/Library/Application Support/Pace/api-audit.jsonl — the file the Privacy
//  dashboard reads to show when the planner, TTS, and actions last ran.
//  Before this, a full regression appended ~45 genuine-looking entries there.
//
//  `PaceAPIAuditLog.shared` in a test host resolves into the same validated
//  per-process temp directory as `QAuditLogger.shared`; if isolation cannot
//  be proven safe, entries are discarded — never written to production.
//
//  Directory-level validation (markers, temp roots, symlinks into production)
//  is covered in QAuditLoggerTestProcessIsolationTests; this suite covers the
//  API log itself and the per-file step.
//

import Foundation
import Testing
@testable import Pace

@Suite("PaceAPIAuditLog test-process isolation")
struct PaceAPIAuditLogTestProcessIsolationTests {

    // MARK: - Fixtures

    private static let apiAuditLogFileName = "api-audit.jsonl"

    private static let validXCTestMarkerEnvironment = [
        PaceTestHostDataIsolation.xcTestSessionIdentifierEnvironmentMarkerKey: UUID().uuidString
    ]

    /// A fresh, test-owned sandbox holding a fake temp root, a fake
    /// Application Support, and a fake home.
    private struct FakeFilesystemRoots {
        let sandboxURL: URL
        let temporaryRootURL: URL
        let applicationSupportURL: URL
        let homeURL: URL

        init() throws {
            sandboxURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("api-audit-isolation-fixture-\(UUID().uuidString)", isDirectory: true)
            temporaryRootURL = sandboxURL.appendingPathComponent("tmp-root", isDirectory: true)
            homeURL = sandboxURL.appendingPathComponent("home", isDirectory: true)
            applicationSupportURL = homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: applicationSupportURL.appendingPathComponent("Pace", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        func resolveDirectory(uniqueToken: String = UUID().uuidString) -> PaceTestHostDataDirectory {
            PaceTestHostDataIsolation.resolveTestHostDataDirectory(
                environment: PaceAPIAuditLogTestProcessIsolationTests.validXCTestMarkerEnvironment,
                isXCTestRuntimeLoaded: true,
                temporaryRootDirectoryURL: temporaryRootURL,
                applicationSupportDirectoryURL: applicationSupportURL,
                homeDirectoryURL: homeURL,
                processIdentifier: 4242,
                uniqueToken: uniqueToken
            )
        }

        func resolveLogFile(named logFileName: String, in directoryDecision: PaceTestHostDataDirectory) -> PaceTestHostFileDestination {
            PaceTestHostDataIsolation.resolveFile(
                relativePath: logFileName,
                in: directoryDecision,
                applicationSupportDirectoryURL: applicationSupportURL
            )
        }

        func removeSandbox() {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    private static var realProductionAPIAuditLogFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent(apiAuditLogFileName)
    }

    private static func isolatedLogURL(from destination: PaceTestHostFileDestination) -> URL? {
        if case .isolatedTemporaryFile(let isolatedLogFileURL) = destination { return isolatedLogFileURL }
        return nil
    }

    private static func isIsolationUnavailable(_ destination: PaceTestHostFileDestination) -> Bool {
        if case .isolationUnavailable = destination { return true }
        return false
    }

    /// Size + modification date of every real production api-audit.jsonl*
    /// file. Read-only.
    private static func snapshotOfRealProductionAPIAuditLogFiles() -> [String: String] {
        let productionDirectoryURL = realProductionAPIAuditLogFileURL.deletingLastPathComponent()
        let fileNames = (try? FileManager.default.contentsOfDirectory(atPath: productionDirectoryURL.path)) ?? []
        var snapshot: [String: String] = [:]
        for fileName in fileNames where fileName.hasPrefix(apiAuditLogFileName) {
            let filePath = productionDirectoryURL.appendingPathComponent(fileName).path
            let attributes = (try? FileManager.default.attributesOfItem(atPath: filePath)) ?? [:]
            let size = attributes[.size] as? Int ?? -1
            let modificationDate = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            snapshot[fileName] = "\(size)|\(modificationDate)"
        }
        return snapshot
    }

    private static func recordFixedEntry(into auditLog: PaceAPIAuditLog, detail: String) {
        auditLog.record(
            subsystem: "isolation.test",
            operation: "isolation.operation",
            target: "isolation-target",
            durationMilliseconds: 12,
            outcome: "ok",
            inputCharacterCount: 3,
            outputCharacterCount: 4,
            detail: detail,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        auditLog.waitForPendingWrites()
    }

    // MARK: - Production path

    @Test("No test-host signal leaves the API log on its unchanged production path")
    func productionDefaultPathIsUnchanged() {
        #expect(Self.realProductionAPIAuditLogFileURL.path.hasSuffix("/Library/Application Support/Pace/api-audit.jsonl"))

        let destination = PaceTestHostDataIsolation.resolveTestHostFileDestination(
            relativePath: Self.apiAuditLogFileName,
            environment: ["HOME": "/Users/someone", "PATH": "/usr/bin"],
            isXCTestRuntimeLoaded: false,
            temporaryRootDirectoryURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
            applicationSupportDirectoryURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            processIdentifier: 1,
            uniqueToken: "unused"
        )
        #expect(destination == .notRunningUnderTestHost)

        // A caller-supplied URL is used exactly as given — the test-host
        // decision only ever applies to the default initializer.
        let explicitURL = URL(fileURLWithPath: "/tmp/explicit-\(UUID().uuidString).jsonl")
        #expect(PaceAPIAuditLog(logFileURL: explicitURL).persistedLogFileURL == explicitURL)
    }

    // MARK: - The real shared log in this test host

    @Test("PaceAPIAuditLog.shared is isolated in the same per-process directory as QAuditLogger.shared")
    func sharedAPIAuditLogInTestHostIsIsolated() throws {
        let sharedAPILogFileURL = try #require(
            PaceAPIAuditLog.shared.persistedLogFileURL,
            "shared API audit log is discarding — test-host isolation marker was not recognized"
        )
        let resolvedRealTemporaryRootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let sharedDirectoryURL = sharedAPILogFileURL.deletingLastPathComponent()

        #expect(sharedAPILogFileURL.lastPathComponent == Self.apiAuditLogFileName)
        #expect(sharedAPILogFileURL.path != Self.realProductionAPIAuditLogFileURL.path)
        #expect(sharedDirectoryURL.deletingLastPathComponent().pathComponents == resolvedRealTemporaryRootURL.pathComponents)
        #expect(sharedDirectoryURL.lastPathComponent.hasPrefix("pace-test-data-\(ProcessInfo.processInfo.processIdentifier)-"))

        let sharedQAuditLogFileURL = try #require(QAuditLogger.shared.persistedLogFileURL)
        #expect(sharedQAuditLogFileURL.deletingLastPathComponent() == sharedDirectoryURL)
        print("🧪 PaceAPIAuditLog.shared isolated test log: \(sharedAPILogFileURL.path)")
    }

    @Test("Writes through PaceAPIAuditLog.shared reach the isolated log and never the production log")
    func sharedWritesReachIsolatedLogNotProduction() throws {
        let sharedAPILogFileURL = try #require(PaceAPIAuditLog.shared.persistedLogFileURL)
        let productionSnapshotBefore = Self.snapshotOfRealProductionAPIAuditLogFiles()

        let uniqueMarkerDetail = "isolation-marker-\(UUID().uuidString)"
        Self.recordFixedEntry(into: PaceAPIAuditLog.shared, detail: uniqueMarkerDetail)

        let isolatedContents = try String(contentsOf: sharedAPILogFileURL, encoding: .utf8)
        #expect(isolatedContents.contains(uniqueMarkerDetail))
        #expect(PaceAPIAuditLog.shared.readAllEntries().contains { $0.detail == uniqueMarkerDetail })

        if let productionContents = try? String(contentsOf: Self.realProductionAPIAuditLogFileURL, encoding: .utf8) {
            #expect(!productionContents.contains(uniqueMarkerDetail))
        }
        #expect(Self.snapshotOfRealProductionAPIAuditLogFiles() == productionSnapshotBefore)
    }

    // MARK: - Discard mode (isolation unavailable)

    @Test("With no resolved URL the API log discards entries and reads back nothing")
    func discardModeWritesNothing() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }
        let productionSnapshotBefore = Self.snapshotOfRealProductionAPIAuditLogFiles()

        let discardingAuditLog = PaceAPIAuditLog(resolvedLogFileURL: nil)
        #expect(discardingAuditLog.persistedLogFileURL == nil)
        Self.recordFixedEntry(into: discardingAuditLog, detail: "discard-\(UUID().uuidString)")

        #expect(discardingAuditLog.readAllEntries().isEmpty)
        #expect(discardingAuditLog.lastEntryTimestamp(forSubsystem: "isolation.test") == nil)
        #expect(Self.snapshotOfRealProductionAPIAuditLogFiles() == productionSnapshotBefore)
    }

    // MARK: - Per-file step

    @Test("Both audit logs resolve into one shared directory with distinct files")
    func bothLogsShareOneDirectory() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let directoryDecision = roots.resolveDirectory()
        let apiLogFileURL = try #require(Self.isolatedLogURL(from: roots.resolveLogFile(named: Self.apiAuditLogFileName, in: directoryDecision)))
        let qAuditLogFileURL = try #require(Self.isolatedLogURL(from: roots.resolveLogFile(named: QAuditLogger.auditLogFileName, in: directoryDecision)))

        #expect(apiLogFileURL.deletingLastPathComponent() == qAuditLogFileURL.deletingLastPathComponent())
        #expect(apiLogFileURL != qAuditLogFileURL)
        #expect(apiLogFileURL.deletingLastPathComponent().deletingLastPathComponent().pathComponents
            == roots.temporaryRootURL.resolvingSymlinksInPath().pathComponents)
    }

    @Test("Non-test and unavailable directory decisions map straight through")
    func directoryDecisionsMapThrough() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        #expect(roots.resolveLogFile(named: Self.apiAuditLogFileName, in: .notRunningUnderTestHost) == .notRunningUnderTestHost)
        #expect(Self.isIsolationUnavailable(roots.resolveLogFile(named: Self.apiAuditLogFileName, in: .unavailable(reason: "fixture"))))
    }

    @Test("Unsafe log file names are refused")
    func unsafeLogFileNamesAreRefused() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let directoryDecision = roots.resolveDirectory()
        for unsafeLogFileName in ["", ".", "..", "a/../b", "a//b", "a/", "../api-audit.jsonl", "/etc/passwd", "api audit.jsonl"] {
            #expect(
                Self.isIsolationUnavailable(roots.resolveLogFile(named: unsafeLogFileName, in: directoryDecision)),
                "log file name \(unsafeLogFileName) must be refused"
            )
        }
    }

    @Test("A symlink at the log path is refused; an existing regular file is reused")
    func symlinkAtLogPathIsRefused() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let directoryDecision = roots.resolveDirectory()
        guard case .isolatedDirectory(let isolatedDirectoryURL) = directoryDecision else {
            Issue.record("expected an isolated directory, got \(directoryDecision)")
            return
        }

        let fakeProductionLogURL = roots.applicationSupportURL.appendingPathComponent("Pace/api-audit.jsonl")
        try Data("real history\n".utf8).write(to: fakeProductionLogURL)
        try FileManager.default.createSymbolicLink(
            at: isolatedDirectoryURL.appendingPathComponent(Self.apiAuditLogFileName),
            withDestinationURL: fakeProductionLogURL
        )
        #expect(Self.isIsolationUnavailable(roots.resolveLogFile(named: Self.apiAuditLogFileName, in: directoryDecision)))
        #expect(try String(contentsOf: fakeProductionLogURL, encoding: .utf8) == "real history\n")

        // A second instance of the same log in one process legitimately
        // finds the file the first instance already wrote.
        try Data("earlier line\n".utf8).write(to: isolatedDirectoryURL.appendingPathComponent(QAuditLogger.auditLogFileName))
        #expect(Self.isolatedLogURL(from: roots.resolveLogFile(named: QAuditLogger.auditLogFileName, in: directoryDecision)) != nil)
    }

    // MARK: - Format and retention unchanged

    @Test("Entries written to the isolated log are byte-identical to a custom-URL log's")
    func entryFormatIsUnchanged() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let isolatedLogFileURL = try #require(Self.isolatedLogURL(from: roots.resolveLogFile(named: Self.apiAuditLogFileName, in: roots.resolveDirectory())))
        let referenceLogFileURL = roots.sandboxURL.appendingPathComponent("reference-api-audit.jsonl")

        Self.recordFixedEntry(into: PaceAPIAuditLog(logFileURL: isolatedLogFileURL), detail: "structure-check")
        Self.recordFixedEntry(into: PaceAPIAuditLog(logFileURL: referenceLogFileURL), detail: "structure-check")

        let isolatedBytes = try Data(contentsOf: isolatedLogFileURL)
        #expect(!isolatedBytes.isEmpty)
        #expect(isolatedBytes == (try Data(contentsOf: referenceLogFileURL)))

        let decodedEntry = try #require(PaceAPIAuditLog(logFileURL: isolatedLogFileURL).readAllEntries().first)
        #expect(decodedEntry.subsystem == "isolation.test")
        #expect(decodedEntry.detail == "structure-check")
        #expect(decodedEntry.at == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Rotation of an isolated API log stays inside its temp directory")
    func rotationRemainsIsolated() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let isolatedLogFileURL = try #require(Self.isolatedLogURL(from: roots.resolveLogFile(named: Self.apiAuditLogFileName, in: roots.resolveDirectory())))
        let productionSnapshotBefore = Self.snapshotOfRealProductionAPIAuditLogFiles()

        // Pre-fill to exactly the rotation threshold so the next write rotates.
        try Data(repeating: 0x61, count: PaceAPIAuditLog.rotationByteThreshold).write(to: isolatedLogFileURL)
        Self.recordFixedEntry(into: PaceAPIAuditLog(logFileURL: isolatedLogFileURL), detail: "rotation-check")

        let isolatedDirectoryURL = isolatedLogFileURL.deletingLastPathComponent()
        let fileNamesAfterRotation = try FileManager.default.contentsOfDirectory(atPath: isolatedDirectoryURL.path).sorted()
        #expect(fileNamesAfterRotation == ["api-audit.jsonl", "api-audit.jsonl.1"])
        let freshLogSize = try FileManager.default.attributesOfItem(atPath: isolatedLogFileURL.path)[.size] as? Int ?? 0
        #expect(freshLogSize < 4096)

        #expect(Self.snapshotOfRealProductionAPIAuditLogFiles() == productionSnapshotBefore)
    }
}
