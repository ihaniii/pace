//
//  QModelCapabilityMemoryTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2D capability-memory tests: observation model, validation,
//  identity, dedup, aggregation, retention/pruning, persistence, WAL recovery, corruption/schema
//  handling, atomicity, concurrency, and the (advisory) recommendation rule.
//

import Testing
import Foundation
import SQLite3
@testable import Pace

// MARK: - Fixtures

enum CapabilityFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func temporaryDatabasePath() -> String {
        NSTemporaryDirectory() + "q-capability-\(UUID().uuidString).sqlite"
    }

    static func removeDatabase(at path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    static func observation(
        taskId: String = "task-1",
        attemptId: String = "attempt-1",
        source: QObservationSource = .taskOutcome,
        taskType: QTaskType = .research,
        complexity: QTaskComplexity = .moderate,
        backend: QModelBackendType = .ollama,
        strategy: QModelStrategy = .singleLocalModel,
        attemptOutcome: QObservedAttemptOutcome = .accepted,
        verification: QObservedVerification = .verified,
        completeness: QEvidenceCompleteness = .complete,
        contradiction: QObservedContradiction = .none,
        resource: QObservedResource = .completed,
        execution: QObservedExecution = .succeeded,
        latency: Int? = 120,
        feedback: QExplicitUserFeedback? = nil,
        observedAt: Date = now
    ) -> QModelCapabilityObservation {
        QModelCapabilityObservation(
            taskId: taskId, attemptId: attemptId, source: source, taskType: taskType, complexity: complexity,
            backend: backend, strategy: strategy, attemptOutcome: attemptOutcome, verification: verification,
            evidenceCompleteness: completeness, contradiction: contradiction, resource: resource, execution: execution,
            latencyMilliseconds: latency, feedback: feedback, observedAt: observedAt
        )
    }

    /// Records `count` successful, distinct-task observations for `backend`.
    @discardableResult
    static func seed(
        _ store: QDurableTaskStore, backend: QModelBackendType, count: Int, successful: Bool,
        taskType: QTaskType = .research, complexity: QTaskComplexity = .moderate, prefix: String = "seed"
    ) -> Int {
        var recorded = 0
        for index in 0..<count {
            let result = store.record(
                observation(
                    taskId: "\(prefix)-\(backend.rawValue)-\(index)", attemptId: "a-\(index)", taskType: taskType, complexity: complexity, backend: backend,
                    verification: successful ? .verified : .contradicted, execution: successful ? .succeeded : .failed,
                    observedAt: now.addingTimeInterval(TimeInterval(index))
                ),
                now: now.addingTimeInterval(TimeInterval(index))
            )
            if result == .recorded { recorded += 1 }
        }
        return recorded
    }

    /// Runs `body` with a raw sqlite3 connection to the same file (for corruption/tamper tests).
    static func withRawConnection(_ path: String, _ body: (OpaquePointer) -> Void) {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let connection else {
            Issue.record("could not open raw connection to \(path)")
            return
        }
        sqlite3_busy_timeout(connection, 5000)
        body(connection)
        sqlite3_close(connection)
    }

    @discardableResult
    static func rawExec(_ connection: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK
    }

    static func rawCount(_ connection: OpaquePointer, _ sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
    }
}

// MARK: - Observation, validation, identity

@Suite("QModelCapabilityMemoryTests")
struct QModelCapabilityMemoryTests {

    private let now = CapabilityFixtures.now

    private func memoryStore() throws -> QDurableTaskStore { try QDurableTaskStore(inMemory: true) }

    // 1. creation
    @Test("1. An observation is created from real, typed facts and derives (never accepts) its outcome")
    func observationCreation() {
        let success = CapabilityFixtures.observation()
        #expect(success.outcome == .success)
        #expect(success.observationId.hasPrefix("obs-"))

        let failed = CapabilityFixtures.observation(verification: .contradicted)
        #expect(failed.outcome == .verificationFailed)
    }

    // 2/11/12/13. validation
    @Test("2/11/12/13. Validation rejects malformed identifiers, impossible latency, and future/expired timestamps")
    func validationRejections() throws {
        let store = try memoryStore()
        #expect(store.record(CapabilityFixtures.observation(taskId: ""), now: now) == .rejected(.malformedIdentifier))
        #expect(store.record(CapabilityFixtures.observation(taskId: "bad\u{0007}id"), now: now) == .rejected(.malformedIdentifier))
        #expect(store.record(CapabilityFixtures.observation(attemptId: String(repeating: "x", count: 500)), now: now) == .rejected(.malformedIdentifier))
        #expect(store.record(CapabilityFixtures.observation(latency: -1), now: now) == .rejected(.impossibleLatency))
        #expect(store.record(CapabilityFixtures.observation(latency: QModelCapabilityLimits.maxLatencyMilliseconds + 1), now: now) == .rejected(.impossibleLatency))
        #expect(store.record(CapabilityFixtures.observation(observedAt: now.addingTimeInterval(QModelCapabilityLimits.maxFutureSkewSeconds + 60)), now: now) == .rejected(.futureTimestamp))
        #expect(store.record(CapabilityFixtures.observation(observedAt: now.addingTimeInterval(-QModelCapabilityLimits.retentionSeconds - 60)), now: now) == .rejected(.expired))
        #expect(store.observationCount() == 0)
        // Small clock skew and a boundary latency are tolerated.
        #expect(store.record(CapabilityFixtures.observation(latency: QModelCapabilityLimits.maxLatencyMilliseconds, observedAt: now.addingTimeInterval(30)), now: now) == .recorded)
    }

    @Test("Validation catches a forged identity, a forged outcome, an unsupported schema version, and inconsistent feedback")
    func validationCatchesForgery() throws {
        let store = try memoryStore()
        let genuine = CapabilityFixtures.observation()

        func stored(id: String? = nil, outcome: QLearnedOutcome? = nil, source: QObservationSource = .taskOutcome, feedback: QExplicitUserFeedback? = nil, version: Int = 1, verification: QObservedVerification = .verified) -> QModelCapabilityObservation {
            QModelCapabilityObservation(
                storedObservationId: id ?? genuine.observationId, storedOutcome: outcome ?? .success,
                taskId: "task-1", attemptId: "attempt-1", source: source, taskType: .research, complexity: .moderate,
                backend: .ollama, strategy: .singleLocalModel, attemptOutcome: .accepted, verification: verification,
                evidenceCompleteness: .complete, contradiction: .none, resource: .completed, execution: .succeeded,
                latencyMilliseconds: 10, feedback: feedback, observedAt: now, schemaVersion: version
            )
        }
        #expect(store.record(stored(id: "obs-forged"), now: now) == .rejected(.identityMismatch))
        // "Model claims success although verification failed."
        #expect(store.record(stored(outcome: .success, verification: .contradicted), now: now) == .rejected(.inconsistentOutcome))
        #expect(store.record(stored(version: 7), now: now) == .rejected(.schemaVersionUnsupported))
        let feedbackSourceWithoutFeedback = stored(id: QModelCapabilityObservation.deterministicId(taskId: "task-1", attemptId: "attempt-1", backend: .ollama, source: .userFeedback), outcome: .unresolved, source: .userFeedback, feedback: nil)
        #expect(store.record(feedbackSourceWithoutFeedback, now: now) == .rejected(.inconsistentFeedback))
        #expect(store.observationCount() == 0)
    }

    // 3. identity
    @Test("3. Identity is deterministic; feedback identity ignores the attempt so it cannot be replayed into extra weight")
    func deterministicIdentity() {
        let first = CapabilityFixtures.observation()
        let second = CapabilityFixtures.observation()
        #expect(first.observationId == second.observationId)
        #expect(CapabilityFixtures.observation(attemptId: "attempt-2").observationId != first.observationId)
        #expect(CapabilityFixtures.observation(backend: .llamaCpp).observationId != first.observationId)
        #expect(CapabilityFixtures.observation(source: .modelAttempt).observationId != first.observationId)

        let feedbackA = CapabilityFixtures.observation(attemptId: "one", source: .userFeedback, feedback: .correction)
        let feedbackB = CapabilityFixtures.observation(attemptId: "two", source: .userFeedback, feedback: .correction)
        #expect(feedbackA.observationId == feedbackB.observationId)
    }

    // 4/5. duplicates and conflicts
    @Test("4. A duplicate observation is recognised (even re-reported later) and adds no weight")
    func duplicatePrevention() throws {
        let store = try memoryStore()
        #expect(store.record(CapabilityFixtures.observation(), now: now) == .recorded)
        #expect(store.record(CapabilityFixtures.observation(), now: now) == .duplicate)
        #expect(store.record(CapabilityFixtures.observation(observedAt: now.addingTimeInterval(60)), now: now.addingTimeInterval(60)) == .duplicate)
        #expect(store.observationCount() == 1)
    }

    @Test("44. Conflicting outcomes for the same identity: the FIRST stands, the later one is refused")
    func conflictingOutcomeFirstWins() throws {
        let store = try memoryStore()
        #expect(store.record(CapabilityFixtures.observation(verification: .verified), now: now) == .recorded)
        #expect(store.record(CapabilityFixtures.observation(verification: .contradicted), now: now) == .conflictingDuplicate)
        let profile = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now)
        #expect(profile.verifiedSuccessCount == 1)
        #expect(profile.verifiedFailureCount == 0)
    }

    // 6. aggregation
    @Test("6. Aggregation is deterministic typed counts: successes, failures, timeouts, cancellations, denials, unresolved, latency")
    func aggregation() throws {
        let store = try memoryStore()
        func record(_ index: Int, _ configure: (Int) -> QModelCapabilityObservation) {
            #expect(store.record(configure(index), now: now.addingTimeInterval(TimeInterval(index))) == .recorded)
        }
        record(0) { CapabilityFixtures.observation(taskId: "t\($0)", latency: 100, observedAt: now.addingTimeInterval(TimeInterval($0))) }
        record(1) { CapabilityFixtures.observation(taskId: "t\($0)", verification: .contradicted, latency: 300, observedAt: now.addingTimeInterval(TimeInterval($0))) }
        record(2) { CapabilityFixtures.observation(taskId: "t\($0)", execution: .failed, latency: nil, observedAt: now.addingTimeInterval(TimeInterval($0))) }
        record(3) { CapabilityFixtures.observation(taskId: "t\($0)", attemptOutcome: .timedOut, resource: .timedOut, latency: 200, observedAt: now.addingTimeInterval(TimeInterval($0))) }
        record(4) { CapabilityFixtures.observation(taskId: "t\($0)", attemptOutcome: .cancelled, resource: .cancelled, latency: nil, observedAt: now.addingTimeInterval(TimeInterval($0))) }
        record(5) { CapabilityFixtures.observation(taskId: "t\($0)", execution: .blocked, latency: nil, observedAt: now.addingTimeInterval(TimeInterval($0))) }
        record(6) { CapabilityFixtures.observation(taskId: "t\($0)", verification: .unavailable, latency: nil, observedAt: now.addingTimeInterval(TimeInterval($0))) }
        record(7) { CapabilityFixtures.observation(taskId: "t\($0)", execution: .partial, latency: nil, observedAt: now.addingTimeInterval(TimeInterval($0))) }

        let profile = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now.addingTimeInterval(10))
        #expect(profile.sampleCount == 8)
        #expect(profile.distinctTaskCount == 8)
        #expect(profile.verifiedSuccessCount == 1)
        #expect(profile.verifiedFailureCount == 1)
        #expect(profile.failureCount == 1)
        #expect(profile.timeoutCount == 1)
        #expect(profile.cancellationCount == 1)
        #expect(profile.deniedCount == 1)
        #expect(profile.unresolvedCount == 1)
        #expect(profile.partialCount == 1)
        #expect(profile.verificationUnavailableCount == 1)
        #expect(profile.latencySampleCount == 3)
        #expect(profile.meanLatencyMilliseconds == 200)   // (100 + 300 + 200) / 3, exact
        #expect(profile.adverseCount == 3)                // failure + verificationFailed + timeout; cancel/deny/unresolved are not adverse
        #expect(profile.lastObserved == now.addingTimeInterval(7))
    }

    @Test("Profiles are per (task type, complexity, backend): one model's or category's history never leaks into another's")
    func profilesAreIsolatedPerKey() throws {
        let store = try memoryStore()
        CapabilityFixtures.seed(store, backend: .ollama, count: 3, successful: true)
        CapabilityFixtures.seed(store, backend: .llamaCpp, count: 2, successful: false)
        CapabilityFixtures.seed(store, backend: .ollama, count: 4, successful: true, taskType: .coding)

        let research = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now.addingTimeInterval(10))
        let other = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .llamaCpp), now: now.addingTimeInterval(10))
        #expect(research.sampleCount == 3 && research.verifiedSuccessCount == 3)
        #expect(other.sampleCount == 2 && other.verifiedFailureCount == 2)
        #expect(store.profiles(now: now.addingTimeInterval(10)).count == 3)
    }

    // 6/10 (bounded retention)
    @Test("Bounded retention: per-key cap keeps only the newest observations")
    func perKeyRetentionBound() throws {
        let store = try memoryStore()
        let total = QModelCapabilityLimits.maxObservationsPerKey + 15
        for index in 0..<total {
            let timestamp = now.addingTimeInterval(TimeInterval(index))
            #expect(store.record(CapabilityFixtures.observation(taskId: "t\(index)", observedAt: timestamp), now: timestamp) == .recorded)
        }
        #expect(store.observationCount() == QModelCapabilityLimits.maxObservationsPerKey)
        let retained = store.observations(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now.addingTimeInterval(TimeInterval(total))).observations
        #expect(retained.count == QModelCapabilityLimits.maxObservationsPerKey)
        #expect(!retained.contains { $0.taskId == "t0" })                       // oldest pruned
        #expect(retained.contains { $0.taskId == "t\(total - 1)" })             // newest kept
    }

    @Test("Bounded retention: the global cap holds across many keys")
    func globalRetentionBound() throws {
        let store = try memoryStore()
        let keys: [(QTaskType, QTaskComplexity, QModelBackendType)] = QTaskType.allCases.flatMap { taskType in
            QModelBackendType.allCases.map { (taskType, QTaskComplexity.moderate, $0) }
        }
        var index = 0
        let target = QModelCapabilityLimits.maxTotalObservations + 60
        while index < target {
            let key = keys[index % keys.count]
            let timestamp = now.addingTimeInterval(TimeInterval(index))
            store.record(CapabilityFixtures.observation(taskId: "g\(index)", taskType: key.0, complexity: key.1, backend: key.2, observedAt: timestamp), now: timestamp)
            index += 1
        }
        #expect(store.observationCount() == QModelCapabilityLimits.maxTotalObservations)
    }

    // 6. expiry & pruning
    @Test("Retention window: expired observations are ignored on read and physically pruned on the next write")
    func retentionExpiryAndPruning() throws {
        let store = try memoryStore()
        let old = now.addingTimeInterval(-80 * 24 * 60 * 60)
        #expect(store.record(CapabilityFixtures.observation(taskId: "old", observedAt: old), now: now) == .recorded)
        let key = QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama)
        #expect(store.profile(for: key, now: now).sampleCount == 1)

        let later = now.addingTimeInterval(20 * 24 * 60 * 60)   // the old row is now 100 days old
        #expect(store.profile(for: key, now: later).sampleCount == 0)   // stale data ignored
        #expect(store.observationCount() == 1)                          // ...but not yet deleted by a READ

        #expect(store.record(CapabilityFixtures.observation(taskId: "fresh", observedAt: later), now: later) == .recorded)
        #expect(store.observationCount() == 1)                          // pruned by the next write
        #expect(store.profile(for: key, now: later).sampleCount == 1)
    }

    @Test("Per-(task, backend) cap: one task cannot flood a model's history; other backends are unaffected")
    func perTaskCap() throws {
        let store = try memoryStore()
        for attempt in 0..<QModelCapabilityLimits.maxObservationsPerTaskPerBackend {
            #expect(store.record(CapabilityFixtures.observation(attemptId: "a\(attempt)"), now: now) == .recorded)
        }
        #expect(store.record(CapabilityFixtures.observation(attemptId: "a-extra"), now: now) == .rejected(.perTaskLimitReached))
        #expect(store.record(CapabilityFixtures.observation(attemptId: "a0", backend: .llamaCpp), now: now) == .recorded)
        #expect(store.observationCount() == QModelCapabilityLimits.maxObservationsPerTaskPerBackend + 1)
    }

    // 8. restart recovery
    @Test("8. Restart recovery: observations persist across a store restart, dedup still holds, and learning continues")
    func restartRecovery() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let key = QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama)

        var store: QDurableTaskStore? = try QDurableTaskStore(databasePath: path)
        CapabilityFixtures.seed(store!, backend: .ollama, count: 4, successful: true)
        let before = store!.profile(for: key, now: now.addingTimeInterval(10))
        store = nil   // "crash": connection dropped without any explicit checkpoint

        let reopened = try QDurableTaskStore(databasePath: path)
        #expect(reopened.profile(for: key, now: now.addingTimeInterval(10)) == before)
        #expect(reopened.record(CapabilityFixtures.observation(taskId: "seed-local.ollama-0", attemptId: "a-0", observedAt: now), now: now) == .duplicate)
        #expect(reopened.record(CapabilityFixtures.observation(taskId: "after-restart", observedAt: now.addingTimeInterval(20)), now: now.addingTimeInterval(20)) == .recorded)
        #expect(reopened.profile(for: key, now: now.addingTimeInterval(30)).sampleCount == 5)
    }

    // 9. WAL recovery
    @Test("9. WAL recovery: a copy of the database + its un-checkpointed WAL (a crash image) recovers every committed observation")
    func walRecovery() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        let crashImage = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path); CapabilityFixtures.removeDatabase(at: crashImage) }

        let liveStore = try QDurableTaskStore(databasePath: path)
        CapabilityFixtures.seed(liveStore, backend: .ollama, count: 6, successful: true)
        #expect(FileManager.default.fileExists(atPath: path + "-wal"))

        // Snapshot the files while the writer is still open — exactly what a crash leaves behind.
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.copyItem(atPath: path + suffix, toPath: crashImage + suffix)
        }
        let recovered = try QDurableTaskStore(databasePath: crashImage)
        #expect(recovered.observationCount() == 6)
        let key = QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama)
        #expect(recovered.profile(for: key, now: now.addingTimeInterval(10)).verifiedSuccessCount == 6)
        withExtendedLifetime(liveStore) {}
    }

    @Test("Crash mid-write: an uncommitted transaction leaves no trace, and the database stays healthy")
    func uncommittedWriteLeavesNothing() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let store = try QDurableTaskStore(databasePath: path)
        CapabilityFixtures.seed(store, backend: .ollama, count: 2, successful: true)

        CapabilityFixtures.withRawConnection(path) { connection in
            CapabilityFixtures.rawExec(connection, "BEGIN IMMEDIATE;")
            CapabilityFixtures.rawExec(connection, "DELETE FROM q_model_capability_observations;")
            // connection closes here without COMMIT → SQLite rolls back
        }
        let reopened = try QDurableTaskStore(databasePath: path)
        #expect(reopened.observationCount() == 2)
        #expect(reopened.record(CapabilityFixtures.observation(taskId: "next"), now: now) == .recorded)
    }

    // 14. malformed rows
    @Test("14. Malformed, tampered, future, and incomplete rows are skipped and counted — never trusted, never deleted")
    func corruptRowsAreSkipped() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let store = try QDurableTaskStore(databasePath: path)
        CapabilityFixtures.seed(store, backend: .ollama, count: 2, successful: true)

        let genuineId = CapabilityFixtures.observation(taskId: "forged", attemptId: "a").observationId
        let futureSeconds = now.addingTimeInterval(3600).timeIntervalSince1970
        CapabilityFixtures.withRawConnection(path) { connection in
            func insert(id: String, task: String = "raw", attempt: String = "a", taskType: String = "research", backend: String = "local.ollama",
                        verification: String = "verified", outcome: String = "success", feedback: String? = nil,
                        observedAt: Double = CapabilityFixtures.now.timeIntervalSince1970, version: Int = 1) {
                let feedbackSQL = feedback.map { "'\($0)'" } ?? "NULL"
                CapabilityFixtures.rawExec(connection, """
                INSERT INTO q_model_capability_observations VALUES
                ('\(id)','\(task)','\(attempt)','taskOutcome','\(taskType)','moderate','\(backend)','singleLocalModel','accepted',
                 '\(verification)','complete','none','completed','succeeded',10,'\(outcome)',\(feedbackSQL),\(observedAt),\(observedAt),\(version));
                """)
            }
            insert(id: "obs-unknown-backend", backend: "cloud.gpt")                                   // model name is not a capability
            insert(id: "obs-bad-tasktype", taskType: "bogus")
            insert(id: genuineId, task: "forged", verification: "contradicted", outcome: "success")   // tampered outcome (id is "genuine")
            insert(id: "obs-future", observedAt: futureSeconds + 100_000)
            insert(id: "obs-empty-attempt", attempt: "")                                              // missing metadata
            insert(id: "obs-bad-feedback", feedback: "nonsense")
            insert(id: "obs-future-version", version: 9)
        }

        let key = QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama)
        let read = store.observations(for: key, now: now.addingTimeInterval(10))
        #expect(read.observations.count == 2)          // only the two genuine rows
        #expect(read.skippedRowCount >= 5)
        #expect(store.profile(for: key, now: now.addingTimeInterval(10)).sampleCount == 2)
        #expect(store.observationCount() == 9)          // nothing was deleted by reading
    }

    // 15. schema
    @Test("15. A NEWER on-disk schema version is left completely untouched: reads are empty, writes refused, data intact")
    func newerSchemaIsUntouched() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        do {
            let store = try QDurableTaskStore(databasePath: path)
            CapabilityFixtures.seed(store, backend: .ollama, count: 3, successful: true)
        }
        CapabilityFixtures.withRawConnection(path) { connection in
            CapabilityFixtures.rawExec(connection, "UPDATE q_model_capability_meta SET value = '99' WHERE key = 'schema_version';")
        }
        let reopened = try QDurableTaskStore(databasePath: path)
        #expect(reopened.record(CapabilityFixtures.observation(taskId: "new"), now: now) == .rejected(.schemaVersionUnsupported))
        #expect(reopened.observationCount() == 0)
        #expect(reopened.profiles(now: now).isEmpty)
        CapabilityFixtures.withRawConnection(path) { connection in
            #expect(CapabilityFixtures.rawCount(connection, "SELECT COUNT(*) FROM q_model_capability_observations;") == 3)
            #expect(CapabilityFixtures.rawCount(connection, "SELECT value FROM q_model_capability_meta WHERE key = 'schema_version';") == 99)
        }
    }

    @Test("An unreadable schema marker also fails safe (no guess, no rewrite)")
    func unreadableSchemaMarkerFailsSafe() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        do { _ = try QDurableTaskStore(databasePath: path) }
        CapabilityFixtures.withRawConnection(path) { connection in
            CapabilityFixtures.rawExec(connection, "UPDATE q_model_capability_meta SET value = 'garbage' WHERE key = 'schema_version';")
        }
        let reopened = try QDurableTaskStore(databasePath: path)
        #expect(reopened.record(CapabilityFixtures.observation(), now: now) == .rejected(.schemaVersionUnsupported))
    }

    @Test("A database with existing capability rows but no schema marker (pre-marker/older) opens, keeps its rows, and gains the marker")
    func missingSchemaMarkerIsMigrated() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        do {
            let store = try QDurableTaskStore(databasePath: path)
            CapabilityFixtures.seed(store, backend: .ollama, count: 2, successful: true)
        }
        CapabilityFixtures.withRawConnection(path) { connection in
            CapabilityFixtures.rawExec(connection, "DELETE FROM q_model_capability_meta;")
        }
        let reopened = try QDurableTaskStore(databasePath: path)
        #expect(reopened.observationCount() == 2)
        #expect(reopened.record(CapabilityFixtures.observation(taskId: "more"), now: now) == .recorded)
        CapabilityFixtures.withRawConnection(path) { connection in
            #expect(CapabilityFixtures.rawCount(connection, "SELECT value FROM q_model_capability_meta WHERE key = 'schema_version';") == 1)
        }
    }

    @Test("Existing durable task state is never destroyed by capability memory: tasks, plans, and events survive alongside it")
    func existingDurableStateSurvives() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let store = try QDurableTaskStore(databasePath: path)
        let task = QTask(intent: "durable state marker")
        try store.saveTask(QDurableTaskState(from: task, budget: QAgentBudget()))
        try store.recordEvent(QTaskLifecycleEvent(taskId: task.taskId, sessionId: "s", eventType: .taskCreated))

        CapabilityFixtures.seed(store, backend: .ollama, count: 3, successful: true)
        let reopened = try QDurableTaskStore(databasePath: path)
        #expect(try reopened.getTask(taskId: task.taskId) != nil)
        #expect(try reopened.listEvents(taskId: task.taskId).count == 1)
        #expect(reopened.observationCount() == 3)
    }

    // 16. atomicity
    @Test("Partial failure is atomic: if pruning fails, the whole write rolls back and the store reports unavailable")
    func partialFailureRollsBack() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let store = try QDurableTaskStore(databasePath: path)
        CapabilityFixtures.seed(store, backend: .ollama, count: 2, successful: true)

        let staleSeconds = now.addingTimeInterval(-QModelCapabilityLimits.retentionSeconds - 3600).timeIntervalSince1970
        CapabilityFixtures.withRawConnection(path) { connection in
            // A physically-present expired row + a trigger that forbids deleting it → the prune
            // step inside the write transaction must fail.
            CapabilityFixtures.rawExec(connection, """
            INSERT INTO q_model_capability_observations VALUES
            ('obs-stale','stale','a','taskOutcome','research','moderate','local.ollama','singleLocalModel','accepted','verified','complete','none','completed','succeeded',1,'success',NULL,\(staleSeconds),\(staleSeconds),1);
            CREATE TRIGGER forbid_delete BEFORE DELETE ON q_model_capability_observations BEGIN SELECT RAISE(ABORT, 'no deletes'); END;
            """)
        }
        let countBefore = store.observationCount()
        #expect(store.record(CapabilityFixtures.observation(taskId: "should-roll-back"), now: now.addingTimeInterval(100)) == .storeUnavailable)
        #expect(store.observationCount() == countBefore)   // the insert was rolled back with the failed prune
        #expect(store.observations(forTask: "should-roll-back", now: now.addingTimeInterval(100)).observations.isEmpty)
    }

    // 10/12. concurrency
    @Test("10/12. Concurrent writers across two connections to the same file lose nothing and duplicate nothing")
    func concurrentWritesAcrossConnections() async throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let storeA = try QDurableTaskStore(databasePath: path)
        let storeB = try QDurableTaskStore(databasePath: path)
        let stores = [storeA, storeB]
        let referenceTime = now

        let results = await withTaskGroup(of: QObservationRecordResult.self, returning: [QObservationRecordResult].self) { group in
            for writer in 0..<2 {
                for index in 0..<40 {
                    group.addTask {
                        stores[writer].record(
                            CapabilityFixtures.observation(taskId: "c-\(writer)-\(index)", observedAt: referenceTime.addingTimeInterval(TimeInterval(index))),
                            now: referenceTime.addingTimeInterval(100)
                        )
                    }
                }
            }
            var collected: [QObservationRecordResult] = []
            for await result in group { collected.append(result) }
            return collected
        }
        #expect(results.allSatisfy { $0 == .recorded })
        #expect(storeA.observationCount() == 80)
        #expect(storeB.observationCount() == 80)
    }

    @Test("12. Concurrent reports of the SAME observation (same task, same attempt) record exactly once")
    func concurrentDuplicateReports() async throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let stores = [try QDurableTaskStore(databasePath: path), try QDurableTaskStore(databasePath: path)]
        let referenceTime = now

        let results = await withTaskGroup(of: QObservationRecordResult.self, returning: [QObservationRecordResult].self) { group in
            for index in 0..<24 {
                group.addTask { stores[index % 2].record(CapabilityFixtures.observation(), now: referenceTime) }
            }
            var collected: [QObservationRecordResult] = []
            for await result in group { collected.append(result) }
            return collected
        }
        #expect(results.filter { $0 == .recorded }.count == 1)
        #expect(results.filter { $0 == .duplicate }.count == 23)
        #expect(stores[0].observationCount() == 1)
    }

    @Test("Two models reporting the same task/attempt ID are separate observations: neither can overwrite the other")
    func twoModelsSameAttemptIdentifier() throws {
        let store = try memoryStore()
        #expect(store.record(CapabilityFixtures.observation(backend: .ollama), now: now) == .recorded)
        #expect(store.record(CapabilityFixtures.observation(backend: .llamaCpp, verification: .contradicted), now: now) == .recorded)
        let ollama = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now)
        let llama = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .llamaCpp), now: now)
        #expect(ollama.verifiedSuccessCount == 1 && ollama.verifiedFailureCount == 0)
        #expect(llama.verifiedFailureCount == 1 && llama.verifiedSuccessCount == 0)
    }

    // 42/43. poisoning
    @Test("42/43. Poisoning: a flood of repeated/near-identical reports from one task adds bounded weight and never enables ranking")
    func repeatedObservationsHaveBoundedInfluence() throws {
        let store = try memoryStore()
        var recorded = 0
        for index in 0..<500 {
            // 500 distinct attempt IDs, all for the SAME task and backend (a replay/flood).
            if store.record(CapabilityFixtures.observation(taskId: "flood", attemptId: "a\(index)"), now: now) == .recorded { recorded += 1 }
        }
        // Then 500 exact duplicates of the same observation.
        for _ in 0..<500 { _ = store.record(CapabilityFixtures.observation(taskId: "flood", attemptId: "a0"), now: now) }

        #expect(recorded == QModelCapabilityLimits.maxObservationsPerTaskPerBackend)
        let profile = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now)
        #expect(profile.sampleCount == QModelCapabilityLimits.maxObservationsPerTaskPerBackend)
        #expect(profile.distinctTaskCount == 1)
        // One task is not enough evidence to rank a candidate, however many times it was reported.
        let recommendation = QModelRoutingRecommender.recommend(candidates: [.llamaCpp, .ollama], profiles: [.ollama: profile])
        #expect(!recommendation.reordered)
        #expect(recommendation.basis[.ollama] == .insufficientObservations(distinctTasks: 1))
    }

    @Test("A bad model poisons only its own profile: another backend's history and the ranking rule are unaffected")
    func badModelCannotPoisonOthers() throws {
        let store = try memoryStore()
        CapabilityFixtures.seed(store, backend: .ollama, count: 6, successful: true)
        CapabilityFixtures.seed(store, backend: .llamaCpp, count: 200, successful: false, prefix: "attack")   // hammered
        let ollama = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now.addingTimeInterval(500))
        #expect(ollama.sampleCount == 6)
        #expect(ollama.verifiedSuccessCount == 6)
        #expect(ollama.adverseCount == 0)
    }

    // MARK: - Recommendation rule (28)

    private func profile(_ backend: QModelBackendType, successes: Int, failures: Int) -> QModelCapabilityProfile {
        var rows: [QModelCapabilityObservation] = []
        for index in 0..<successes { rows.append(CapabilityFixtures.observation(taskId: "s\(index)", backend: backend)) }
        for index in 0..<failures { rows.append(CapabilityFixtures.observation(taskId: "f\(index)", backend: backend, verification: .contradicted)) }
        return QModelCapabilityProfile(observations: rows, key: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: backend))
    }

    @Test("28. Recommendation: ranks by exact verified-success fraction only when enough distinct tasks were observed")
    func recommendationRanking() {
        let strong = profile(.llamaCpp, successes: 6, failures: 0)
        let weak = profile(.ollama, successes: 1, failures: 5)
        let recommendation = QModelRoutingRecommender.recommend(candidates: [.ollama, .llamaCpp], profiles: [.ollama: weak, .llamaCpp: strong])
        #expect(recommendation.orderedBackends == [.llamaCpp, .ollama])
        #expect(recommendation.reordered)
        #expect(recommendation.basis[.llamaCpp] == .observedOutcomes(samples: 6, verifiedSuccesses: 6, adverse: 0))
    }

    @Test("Recommendation: too little evidence (fewer than the minimum distinct tasks) never reorders")
    func recommendationNeedsMinimumEvidence() {
        let few = profile(.llamaCpp, successes: QModelCapabilityLimits.minimumDistinctTasksForRecommendation - 1, failures: 0)
        let recommendation = QModelRoutingRecommender.recommend(candidates: [.ollama, .llamaCpp], profiles: [.llamaCpp: few])
        #expect(!recommendation.reordered)
        #expect(recommendation.orderedBackends == [.ollama, .llamaCpp])
    }

    @Test("Recommendation: candidates with no evidence keep their slot; only evidence-backed candidates reorder among themselves")
    func recommendationKeepsUnrankedSlots() {
        let strong = profile(.llamaCpp, successes: 6, failures: 0)
        let weak = profile(.mlx, successes: 0, failures: 6)
        let recommendation = QModelRoutingRecommender.recommend(candidates: [.ollama, .mlx, .llamaCpp], profiles: [.mlx: weak, .llamaCpp: strong])
        #expect(recommendation.orderedBackends == [.ollama, .llamaCpp, .mlx])   // ollama untouched at slot 0
    }

    @Test("Recommendation: fractions are compared exactly (8/10 ties 4/5); ties keep the original order; result is deterministic")
    func recommendationExactAndDeterministic() {
        let fourOfFive = profile(.ollama, successes: 4, failures: 1)
        let eightOfTen = profile(.llamaCpp, successes: 8, failures: 2)
        let first = QModelRoutingRecommender.recommend(candidates: [.ollama, .llamaCpp], profiles: [.ollama: fourOfFive, .llamaCpp: eightOfTen])
        #expect(!first.reordered)
        for _ in 0..<5 {
            #expect(QModelRoutingRecommender.recommend(candidates: [.ollama, .llamaCpp], profiles: [.ollama: fourOfFive, .llamaCpp: eightOfTen]) == first)
        }
        let better = profile(.llamaCpp, successes: 9, failures: 1)
        #expect(QModelRoutingRecommender.recommend(candidates: [.ollama, .llamaCpp], profiles: [.ollama: fourOfFive, .llamaCpp: better]).orderedBackends == [.llamaCpp, .ollama])
    }

    @Test("Recommendation is always a permutation of the given candidates, including duplicate/empty inputs")
    func recommendationIsAPermutation() {
        let strong = profile(.llamaCpp, successes: 6, failures: 0)
        let weak = profile(.ollama, successes: 0, failures: 6)
        for candidates in [[QModelBackendType](), [.ollama], [.ollama, .ollama, .llamaCpp], [.llamaCpp, .ollama, .mlx, .appleFoundation]] {
            let recommendation = QModelRoutingRecommender.recommend(candidates: candidates, profiles: [.llamaCpp: strong, .ollama: weak])
            #expect(recommendation.orderedBackends.sorted { $0.rawValue < $1.rawValue } == candidates.sorted { $0.rawValue < $1.rawValue })
        }
    }

    @Test("Memory facade: advice reads real persisted history and fails safe to 'unchanged' with a single candidate or no data")
    func memoryAdvice() throws {
        let store = try memoryStore()
        let memory = QModelCapabilityMemory(store: store)
        #expect(memory.advise(taskType: .research, complexity: .moderate, candidates: [.ollama, .llamaCpp], now: now) == QModelRoutingRecommender.recommend(candidates: [.ollama, .llamaCpp], profiles: [:]))
        CapabilityFixtures.seed(store, backend: .ollama, count: 6, successful: false)
        CapabilityFixtures.seed(store, backend: .llamaCpp, count: 6, successful: true)
        let advice = memory.advise(taskType: .research, complexity: .moderate, candidates: [.ollama, .llamaCpp], now: now.addingTimeInterval(100))
        #expect(advice.orderedBackends == [.llamaCpp, .ollama])
        #expect(memory.advise(taskType: .research, complexity: .moderate, candidates: [.ollama], now: now).orderedBackends == [.ollama])
        // A different category has no history → unchanged.
        #expect(!memory.advise(taskType: .coding, complexity: .moderate, candidates: [.ollama, .llamaCpp], now: now.addingTimeInterval(100)).reordered)
    }

    // MARK: - Bounded storage & performance (39, 21)

    @Test("39/21. Storage is bounded and cheap: file size stays small at the global cap, and read/write latency is measured")
    func boundedStorageAndPerformance() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let store = try QDurableTaskStore(databasePath: path)
        let writes = QModelCapabilityLimits.maxTotalObservations + 500
        let keys: [(QTaskType, QModelBackendType)] = QTaskType.allCases.flatMap { taskType in QModelBackendType.allCases.map { (taskType, $0) } }

        let writeStart = Date()
        for index in 0..<writes {
            let key = keys[index % keys.count]
            let timestamp = now.addingTimeInterval(TimeInterval(index))
            store.record(CapabilityFixtures.observation(taskId: "p\(index)", taskType: key.0, backend: key.1, observedAt: timestamp), now: timestamp)
        }
        let writeMilliseconds = Date().timeIntervalSince(writeStart) * 1000 / Double(writes)

        let readStart = Date()
        let readRounds = 50
        for round in 0..<readRounds {
            let key = keys[round % keys.count]
            _ = store.profile(for: QModelCapabilityProfileKey(taskType: key.0, complexity: .moderate, backend: key.1), now: now.addingTimeInterval(TimeInterval(writes)))
        }
        let readMilliseconds = Date().timeIntervalSince(readStart) * 1000 / Double(readRounds)

        let fileBytes = ["", "-wal"].reduce(0) { total, suffix in
            total + ((try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? Int) ?? 0)
        }
        print("PERF capability-memory: writes=\(writes) avgWrite=\(String(format: "%.3f", writeMilliseconds))ms avgProfileRead=\(String(format: "%.3f", readMilliseconds))ms rows=\(store.observationCount()) diskBytes=\(fileBytes)")

        #expect(store.observationCount() == QModelCapabilityLimits.maxTotalObservations)
        #expect(fileBytes < 8 * 1024 * 1024)         // bounded: a few MB at the 5,000-row cap
        #expect(writeMilliseconds < 25)              // sanity ceiling, ~2 orders above the measured cost
        #expect(readMilliseconds < 25)
    }
}
