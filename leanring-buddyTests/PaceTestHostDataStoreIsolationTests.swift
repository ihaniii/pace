//
//  PaceTestHostDataStoreIsolationTests.swift
//  leanring-buddyTests
//
//  Proves the unit-test host never loads, overwrites, or deletes the user's
//  real Pace data: memory-index.json, thread-memory.json,
//  activity-goal-model.json, retrieval-index.json, the QMemory SQLite
//  database, and the q-data capability store — and never mirrors test
//  memories into the system Spotlight index.
//
//  Before this, a full regression replaced the user's real thread memory and
//  activity-goal model with test fixtures, rewrote the memory and retrieval
//  indexes, and wrote hundreds of test rows into QMemory.
//
//  Directory-level validation (markers, temp roots, symlinks into
//  production) is covered in QAuditLoggerTestProcessIsolationTests; this
//  suite covers nested store paths and every data store's default path.
//

import CoreSpotlight
import Foundation
import Testing
@testable import Pace

@Suite("Test-host data store isolation")
struct PaceTestHostDataStoreIsolationTests {

    // MARK: - Fixtures

    private static let validXCTestMarkerEnvironment = [
        PaceTestHostDataIsolation.xcTestSessionIdentifierEnvironmentMarkerKey: UUID().uuidString
    ]

    /// The real files these stores used to write during tests. Only ever
    /// read (size + modification date), never opened for writing.
    private static let realProductionStoreRelativePaths = [
        "memory-index.json",
        "thread-memory.json",
        "activity-goal-model.json",
        "retrieval-index.json",
        "QMemory/q_memory_wal.sqlite",
        "QMemory/q_memory_wal.sqlite-wal",
        "QMemory/q_memory_wal.sqlite-shm",
        "q-data/q_durable_tasks.sqlite",
        "q-data/q_durable_tasks.sqlite-wal",
        "q-data/q_durable_tasks.sqlite-shm"
    ]

    private static var realProductionDataDirectoryURL: URL {
        PaceTestHostDataIsolation.productionDataDirectoryURL(
            applicationSupportDirectoryURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        )
    }

    private static func snapshotOfRealProductionStores() -> [String: String] {
        var snapshot: [String: String] = [:]
        for relativePath in realProductionStoreRelativePaths {
            let filePath = realProductionDataDirectoryURL.appendingPathComponent(relativePath).path
            let attributes = (try? FileManager.default.attributesOfItem(atPath: filePath)) ?? [:]
            let size = attributes[.size] as? Int ?? -1
            let modificationDate = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            snapshot[relativePath] = "\(size)|\(modificationDate)"
        }
        return snapshot
    }

    /// The per-process isolated directory every store in this test host shares.
    private static func sharedIsolatedDirectoryURL() throws -> URL {
        guard case .isolatedDirectory(let isolatedDirectoryURL) = PaceTestHostDataIsolation.currentProcessDataDirectory else {
            throw IsolationFixtureError.testHostIsolationUnavailable(PaceTestHostDataIsolation.currentProcessDataDirectory)
        }
        return isolatedDirectoryURL
    }

    private enum IsolationFixtureError: Error {
        case testHostIsolationUnavailable(PaceTestHostDataDirectory)
    }

    private static func expectIsolated(_ storeFileURL: URL?, relativePath: String) throws {
        let isolatedDirectoryURL = try sharedIsolatedDirectoryURL()
        let resolvedStoreFileURL = try #require(storeFileURL, "\(relativePath) has no persistence URL in the test host")
        #expect(resolvedStoreFileURL.pathComponents
            == isolatedDirectoryURL.pathComponents + relativePath.split(separator: "/").map(String.init))
        #expect(resolvedStoreFileURL.path != realProductionDataDirectoryURL.appendingPathComponent(relativePath).path)
        #expect(!resolvedStoreFileURL.path.contains("/Application Support/"))
    }

    /// A fresh, test-owned sandbox holding a fake temp root, a fake
    /// Application Support, and a fake home.
    private struct FakeFilesystemRoots {
        let sandboxURL: URL
        let temporaryRootURL: URL
        let applicationSupportURL: URL
        let homeURL: URL

        init() throws {
            sandboxURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("data-store-isolation-fixture-\(UUID().uuidString)", isDirectory: true)
            temporaryRootURL = sandboxURL.appendingPathComponent("tmp-root", isDirectory: true)
            homeURL = sandboxURL.appendingPathComponent("home", isDirectory: true)
            applicationSupportURL = homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: applicationSupportURL.appendingPathComponent("Pace", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        func resolveDirectory() -> PaceTestHostDataDirectory {
            PaceTestHostDataIsolation.resolveTestHostDataDirectory(
                environment: PaceTestHostDataStoreIsolationTests.validXCTestMarkerEnvironment,
                isXCTestRuntimeLoaded: true,
                temporaryRootDirectoryURL: temporaryRootURL,
                applicationSupportDirectoryURL: applicationSupportURL,
                homeDirectoryURL: homeURL,
                processIdentifier: 4242,
                uniqueToken: UUID().uuidString
            )
        }

        func resolveFile(relativePath: String, in directoryDecision: PaceTestHostDataDirectory) -> PaceTestHostFileDestination {
            PaceTestHostDataIsolation.resolveFile(
                relativePath: relativePath,
                in: directoryDecision,
                applicationSupportDirectoryURL: applicationSupportURL
            )
        }

        func removeSandbox() {
            try? FileManager.default.removeItem(at: sandboxURL)
        }
    }

    private static func isIsolationUnavailable(_ destination: PaceTestHostFileDestination) -> Bool {
        if case .isolationUnavailable = destination { return true }
        return false
    }

    // MARK: - Nested store paths

    @Test("A nested store path gets an owner-only subdirectory inside the isolated directory")
    func nestedStorePathIsCreatedInsideIsolatedDirectory() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let directoryDecision = roots.resolveDirectory()
        guard case .isolatedDirectory(let isolatedDirectoryURL) = directoryDecision else {
            Issue.record("expected an isolated directory, got \(directoryDecision)")
            return
        }
        guard case .isolatedTemporaryFile(let databaseURL) = roots.resolveFile(relativePath: "QMemory/q_memory_wal.sqlite", in: directoryDecision) else {
            Issue.record("expected an isolated nested file")
            return
        }

        #expect(databaseURL.pathComponents == isolatedDirectoryURL.pathComponents + ["QMemory", "q_memory_wal.sqlite"])
        let subdirectoryPermissions = try FileManager.default
            .attributesOfItem(atPath: isolatedDirectoryURL.appendingPathComponent("QMemory").path)[.posixPermissions] as? Int
        #expect(subdirectoryPermissions == 0o700)
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    }

    @Test("A subdirectory swapped for a symlink into production is refused")
    func symlinkedSubdirectoryIsRefused() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let directoryDecision = roots.resolveDirectory()
        guard case .isolatedDirectory(let isolatedDirectoryURL) = directoryDecision else {
            Issue.record("expected an isolated directory, got \(directoryDecision)")
            return
        }
        let fakeProductionQMemoryURL = roots.applicationSupportURL.appendingPathComponent("Pace/QMemory", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeProductionQMemoryURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: isolatedDirectoryURL.appendingPathComponent("QMemory"),
            withDestinationURL: fakeProductionQMemoryURL
        )

        #expect(Self.isIsolationUnavailable(roots.resolveFile(relativePath: "QMemory/q_memory_wal.sqlite", in: directoryDecision)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fakeProductionQMemoryURL.path).isEmpty)
    }

    @Test("Unsafe nested store paths are refused")
    func unsafeNestedStorePathsAreRefused() throws {
        let roots = try FakeFilesystemRoots()
        defer { roots.removeSandbox() }

        let directoryDecision = roots.resolveDirectory()
        for unsafeRelativePath in ["QMemory/../x.sqlite", "QMemory//x.sqlite", "/QMemory/x.sqlite", "QMemory/", "Q Memory/x.sqlite", "QMemory/./x.sqlite"] {
            #expect(
                Self.isIsolationUnavailable(roots.resolveFile(relativePath: unsafeRelativePath, in: directoryDecision)),
                "store path \(unsafeRelativePath) must be refused"
            )
        }
    }

    // MARK: - Every data store's default path in this test host

    @Test("Every JSON store's default path resolves into the shared isolated directory")
    @MainActor
    func jsonStoreDefaultsAreIsolated() throws {
        try Self.expectIsolated(PaceMemoryStore().persistedFileURL, relativePath: "memory-index.json")
        try Self.expectIsolated(PaceThreadMemoryStore().persistedFileURL, relativePath: "thread-memory.json")
        try Self.expectIsolated(PaceActivityGoalPersistenceStore.defaultFileURL(), relativePath: "activity-goal-model.json")
        try Self.expectIsolated(PaceActivityGoalPersistenceStore().persistedFileURL, relativePath: "activity-goal-model.json")
        try Self.expectIsolated(PaceLocalRetriever.defaultPersistenceURL(), relativePath: "retrieval-index.json")

        // The audit logs share the very same directory.
        let isolatedDirectoryURL = try Self.sharedIsolatedDirectoryURL()
        #expect(QAuditLogger.shared.persistedLogFileURL?.deletingLastPathComponent().pathComponents == isolatedDirectoryURL.pathComponents)
        print("🧪 test-host isolated data directory: \(isolatedDirectoryURL.path)")
    }

    @Test("A bare CompanionManager in a test never points at real stores or Spotlight")
    @MainActor
    func companionManagerStoresAreIsolated() throws {
        let productionSnapshotBefore = Self.snapshotOfRealProductionStores()

        let companionManager = CompanionManager()
        try Self.expectIsolated(companionManager.memoryStore.persistedFileURL, relativePath: "memory-index.json")
        try Self.expectIsolated(companionManager.threadMemoryStore.persistedFileURL, relativePath: "thread-memory.json")
        try Self.expectIsolated(companionManager.activityGoalPersistenceStore.persistedFileURL, relativePath: "activity-goal-model.json")
        #expect(!companionManager.spotlightMemoryIndexer.isMirroringEnabled)

        #expect(Self.snapshotOfRealProductionStores() == productionSnapshotBefore)
    }

    @Test("Bootstrapping with no path uses an isolated QMemory database and never the real stores")
    func bootstrapWithoutPathIsIsolated() async throws {
        let productionSnapshotBefore = Self.snapshotOfRealProductionStores()

        let bootstrap = QRuntimeBootstrap()
        let report = await bootstrap.bootstrap()
        let isolatedDirectoryURL = try Self.sharedIsolatedDirectoryURL()
        let isolatedDatabaseURL = isolatedDirectoryURL.appendingPathComponent("QMemory/q_memory_wal.sqlite")
        #expect(report.defaultMemoryPath == isolatedDatabaseURL.path)
        #expect(FileManager.default.fileExists(atPath: isolatedDatabaseURL.path))

        // A write through the bootstrapped store lands in the isolated file.
        let memoryStore = try #require(bootstrap.getMemoryStore())
        let markerRecord = QMemoryRecord(
            sessionId: "isolation-\(UUID().uuidString)",
            key: "isolation-marker",
            content: "isolation marker",
            provenanceSource: "isolation_test"
        )
        try memoryStore.insert(record: markerRecord)
        let independentReader = try QSQLiteMemoryStore(databasePath: isolatedDatabaseURL.path)
        #expect(try independentReader.get(recordId: markerRecord.recordId)?.content == "isolation marker")

        #expect(Self.snapshotOfRealProductionStores() == productionSnapshotBefore)
    }

    @Test("A no-signal process still resolves to the production default for every store")
    func productionDefaultIsUnchanged() {
        for relativePath in ["memory-index.json", "QMemory/q_memory_wal.sqlite"] {
            let destination = PaceTestHostDataIsolation.resolveTestHostFileDestination(
                relativePath: relativePath,
                environment: ["HOME": "/Users/someone"],
                isXCTestRuntimeLoaded: false,
                temporaryRootDirectoryURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
                applicationSupportDirectoryURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
                processIdentifier: 1,
                uniqueToken: "unused"
            )
            #expect(destination == .notRunningUnderTestHost)
        }
        #expect(Self.realProductionDataDirectoryURL.path.hasSuffix("/Library/Application Support/Pace"))
    }

    // MARK: - Spotlight

    @Test("The default Spotlight mirror is disabled in a test host; an explicit index is honored")
    @MainActor
    func spotlightMirrorIsDisabledInTestHost() {
        #expect(PaceTestHostDataIsolation.isRunningUnderTestHost)
        #expect(PaceSpotlightMemoryIndexer.defaultSpotlightIndexForCurrentProcess() == nil)
        #expect(!PaceSpotlightMemoryIndexer().isMirroringEnabled)
        // Constructing a named index writes nothing; it only proves the
        // injection seam still works for tests that need one.
        #expect(PaceSpotlightMemoryIndexer(spotlightIndex: CSSearchableIndex(name: "pace-isolation-test-\(UUID().uuidString)")).isMirroringEnabled)
    }
}
