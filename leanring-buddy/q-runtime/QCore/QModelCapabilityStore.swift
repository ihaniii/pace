//
//  QModelCapabilityStore.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2D/2E durable capability-observation persistence.
//  Adds the capability-observation tables to the EXISTING `QDurableTaskStore` (same SQLite file,
//  same WAL connection, same lock) — deliberately not a second database and not a second
//  concurrency authority. SQLite's own WAL semantics provide atomicity, crash recovery, and
//  cross-connection serialisation (`BEGIN IMMEDIATE` + the store's `busy_timeout`).
//
//  Guarantees:
//   - atomic: validate → dedupe → cap → insert → prune all run in ONE transaction; any failure
//     rolls back and returns `.storeUnavailable`, changing nothing;
//   - idempotent: identity is deterministic (`QModelCapabilityObservation.deterministicId`), so a
//     replayed observation is a `.duplicate` and cannot add weight; a same-identity observation
//     with different facts is `.conflictingDuplicate` and the FIRST one stands;
//   - bounded: per-(task, backend) cap, per-key cap, global cap, and a retention window, all
//     enforced inside the same transaction (`QModelCapabilityLimits`);
//   - fail-safe reads: rows that cannot be decoded, or that fail `QObservationValidator` (tampered
//     id/outcome, unknown enum, bad timestamp, unknown schema version), are SKIPPED and counted —
//     never trusted, never deleted (existing durable state is never destroyed by a read);
//   - schema-versioned: a database whose capability schema is NEWER than this build is left
//     completely untouched (reads empty, writes refused);
//   - content-free: every column is an enum raw value, a deterministic identifier, a measured
//     integer, or a timestamp. There is no free-text column, so there is nowhere to persist a
//     prompt, response, screen text, OCR, credential, URL, or document body.
//

import Foundation
import SQLite3

// MARK: - Storage contract

public struct QCapabilityReadResult: Sendable, Equatable {
    public let observations: [QModelCapabilityObservation]
    /// Rows that were present but unusable (corrupt, tampered, unknown version) and were skipped.
    public let skippedRowCount: Int
}

public protocol QModelCapabilityObservationStoring: Sendable {
    func record(_ observation: QModelCapabilityObservation, now: Date) -> QObservationRecordResult
    func observations(for key: QModelCapabilityProfileKey, now: Date) -> QCapabilityReadResult
    func observations(forTask taskId: String, now: Date) -> QCapabilityReadResult
    func profile(for key: QModelCapabilityProfileKey, now: Date) -> QModelCapabilityProfile
    func profiles(now: Date) -> [QModelCapabilityProfile]
    func observationCount() -> Int
}

// MARK: - SQLite helpers (file-private)

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
    sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
}

private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    sqlite3_column_text(statement, index).map { String(cString: $0) }
}

private let observationTable = "q_model_capability_observations"
private let metaTable = "q_model_capability_meta"

private let observationColumns = """
observation_id, task_id, attempt_id, source, task_type, complexity, backend, strategy, attempt_outcome, \
verification, completeness, contradiction, resource, execution, latency_ms, outcome, feedback, observed_at, schema_version
"""

// MARK: - QDurableTaskStore + capability observations

extension QDurableTaskStore: QModelCapabilityObservationStoring {

    // MARK: Schema

    /// Creates (or validates) the capability schema. Never drops, truncates, or rewrites anything.
    func ensureCapabilitySchema() {
        lock.lock()
        defer { lock.unlock() }

        guard capabilityExec("CREATE TABLE IF NOT EXISTS \(metaTable) (key TEXT PRIMARY KEY, value TEXT NOT NULL);") else {
            capabilitySchemaSupported = false
            return
        }

        switch readCapabilitySchemaVersion() {
        case .unreadable:
            // A meta row we cannot interpret: leave EVERYTHING alone rather than guess.
            capabilitySchemaSupported = false
            return
        case .version(let onDiskVersion) where onDiskVersion > QModelCapabilityLimits.currentSchemaVersion:
            capabilitySchemaSupported = false
            return
        case .version, .absent:
            break
        }

        let created = capabilityExec("""
        CREATE TABLE IF NOT EXISTS \(observationTable) (
            observation_id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            attempt_id TEXT NOT NULL,
            source TEXT NOT NULL,
            task_type TEXT NOT NULL,
            complexity TEXT NOT NULL,
            backend TEXT NOT NULL,
            strategy TEXT NOT NULL,
            attempt_outcome TEXT NOT NULL,
            verification TEXT NOT NULL,
            completeness TEXT NOT NULL,
            contradiction TEXT NOT NULL,
            resource TEXT NOT NULL,
            execution TEXT NOT NULL,
            latency_ms INTEGER,
            outcome TEXT NOT NULL,
            feedback TEXT,
            observed_at REAL NOT NULL,
            recorded_at REAL NOT NULL,
            schema_version INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_qmco_key ON \(observationTable)(task_type, complexity, backend, observed_at);
        CREATE INDEX IF NOT EXISTS idx_qmco_task ON \(observationTable)(task_id, backend);
        """)
        guard created else {
            capabilitySchemaSupported = false
            return
        }
        // Migration hook: v1 is the first version, so "absent" and "1" both need only the tables
        // above. A future version N+1 adds its ALTERs here, gated on the on-disk version.
        capabilityExec("INSERT OR REPLACE INTO \(metaTable) (key, value) VALUES ('schema_version', '\(QModelCapabilityLimits.currentSchemaVersion)');")
    }

    private enum CapabilitySchemaVersion {
        case absent
        case version(Int)
        case unreadable
    }

    private func readCapabilitySchemaVersion() -> CapabilitySchemaVersion {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM \(metaTable) WHERE key = 'schema_version' LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            return .unreadable
        }
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let text = columnText(statement, 0), let version = Int(text) else { return .unreadable }
            return .version(version)
        case SQLITE_DONE:
            return .absent
        default:
            return .unreadable
        }
    }

    @discardableResult
    private func capabilityExec(_ sql: String) -> Bool {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if let errorMessage { sqlite3_free(errorMessage) }
        return status == SQLITE_OK
    }

    // MARK: Write

    public func record(_ observation: QModelCapabilityObservation, now: Date = Date()) -> QObservationRecordResult {
        lock.lock()
        defer { lock.unlock() }

        guard capabilitySchemaSupported else { return .rejected(.schemaVersionUnsupported) }
        if let rejection = QObservationValidator.rejection(for: observation, now: now) { return .rejected(rejection) }
        guard capabilityExec("BEGIN IMMEDIATE;") else { return .storeUnavailable }

        let (result, shouldCommit) = recordWithinTransaction(observation, now: now)
        if shouldCommit {
            guard capabilityExec("COMMIT;") else {
                capabilityExec("ROLLBACK;")
                return .storeUnavailable
            }
        } else {
            capabilityExec("ROLLBACK;")
        }
        return result
    }

    private func recordWithinTransaction(_ observation: QModelCapabilityObservation, now: Date) -> (QObservationRecordResult, Bool) {
        // 1. Identity: replay / conflict / explicit-feedback upgrade.
        if let existing = fetchObservation(id: observation.observationId) {
            if observation.source == .userFeedback, existing.feedback == .confirmation, observation.feedback == .correction {
                let updated = executeUpdateFeedback(observation, now: now)
                return updated ? (.upgraded, true) : (.storeUnavailable, false)
            }
            return (Self.hasSameFacts(existing, observation) ? .duplicate : .conflictingDuplicate, false)
        }

        // 2. Feedback must attach to a task the store has actually observed, with the same key.
        if observation.source == .userFeedback {
            guard let taskRow = fetchTaskRow(taskId: observation.taskId, backend: observation.backend) else {
                return (.rejected(.noMatchingTaskObservation), false)
            }
            guard taskRow.taskType == observation.taskType, taskRow.complexity == observation.complexity else {
                return (.rejected(.inconsistentFeedback), false)
            }
        } else {
            // 3. Influence bound: one task cannot flood a model's history.
            guard countNonFeedbackRows(taskId: observation.taskId, backend: observation.backend) < QModelCapabilityLimits.maxObservationsPerTaskPerBackend else {
                return (.rejected(.perTaskLimitReached), false)
            }
        }

        // 4. Insert.
        guard executeInsert(observation, now: now) else { return (.storeUnavailable, false) }

        // 5. Prune, in the same transaction.
        guard pruneWithinTransaction(after: observation, now: now) else { return (.storeUnavailable, false) }
        return (.recorded, true)
    }

    /// All facts except the timestamp: a re-report seconds later is still the same observation.
    private static func hasSameFacts(_ lhs: QModelCapabilityObservation, _ rhs: QModelCapabilityObservation) -> Bool {
        lhs.observationId == rhs.observationId && lhs.taskId == rhs.taskId && lhs.attemptId == rhs.attemptId
            && lhs.source == rhs.source && lhs.taskType == rhs.taskType && lhs.complexity == rhs.complexity
            && lhs.backend == rhs.backend && lhs.strategy == rhs.strategy && lhs.attemptOutcome == rhs.attemptOutcome
            && lhs.verification == rhs.verification && lhs.evidenceCompleteness == rhs.evidenceCompleteness
            && lhs.contradiction == rhs.contradiction && lhs.resource == rhs.resource && lhs.execution == rhs.execution
            && lhs.latencyMilliseconds == rhs.latencyMilliseconds && lhs.outcome == rhs.outcome && lhs.feedback == rhs.feedback
    }

    private func executeInsert(_ observation: QModelCapabilityObservation, now: Date) -> Bool {
        let sql = """
        INSERT INTO \(observationTable)
        (observation_id, task_id, attempt_id, source, task_type, complexity, backend, strategy, attempt_outcome,
         verification, completeness, contradiction, resource, execution, latency_ms, outcome, feedback,
         observed_at, recorded_at, schema_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, observation.observationId)
        bindText(statement, 2, observation.taskId)
        bindText(statement, 3, observation.attemptId)
        bindText(statement, 4, observation.source.rawValue)
        bindText(statement, 5, observation.taskType.rawValue)
        bindText(statement, 6, observation.complexity.rawValue)
        bindText(statement, 7, observation.backend.rawValue)
        bindText(statement, 8, observation.strategy.rawValue)
        bindText(statement, 9, observation.attemptOutcome.rawValue)
        bindText(statement, 10, observation.verification.rawValue)
        bindText(statement, 11, observation.evidenceCompleteness.rawValue)
        bindText(statement, 12, observation.contradiction.rawValue)
        bindText(statement, 13, observation.resource.rawValue)
        bindText(statement, 14, observation.execution.rawValue)
        if let latency = observation.latencyMilliseconds {
            sqlite3_bind_int64(statement, 15, Int64(latency))
        } else {
            sqlite3_bind_null(statement, 15)
        }
        bindText(statement, 16, observation.outcome.rawValue)
        if let feedback = observation.feedback {
            bindText(statement, 17, feedback.rawValue)
        } else {
            sqlite3_bind_null(statement, 17)
        }
        sqlite3_bind_double(statement, 18, observation.observedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 19, now.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 20, Int64(observation.schemaVersion))
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func executeUpdateFeedback(_ observation: QModelCapabilityObservation, now: Date) -> Bool {
        let sql = "UPDATE \(observationTable) SET feedback = ?, outcome = ?, observed_at = ?, recorded_at = ? WHERE observation_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, observation.feedback?.rawValue ?? "")
        bindText(statement, 2, observation.outcome.rawValue)
        sqlite3_bind_double(statement, 3, observation.observedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
        bindText(statement, 5, observation.observationId)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func countNonFeedbackRows(taskId: String, backend: QModelBackendType) -> Int {
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \(observationTable) WHERE task_id = ? AND backend = ? AND source != 'userFeedback';"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return Int.max }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, taskId)
        bindText(statement, 2, backend.rawValue)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : Int.max
    }

    /// Retention, per-key cap, and global cap — all inside the caller's transaction.
    private func pruneWithinTransaction(after observation: QModelCapabilityObservation, now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-QModelCapabilityLimits.retentionSeconds).timeIntervalSince1970
        guard capabilityExec("DELETE FROM \(observationTable) WHERE observed_at < \(cutoff);") else { return false }

        let perKeyPrune = """
        DELETE FROM \(observationTable) WHERE observation_id IN (
            SELECT observation_id FROM \(observationTable)
            WHERE task_type = ? AND complexity = ? AND backend = ?
            ORDER BY observed_at DESC, observation_id DESC LIMIT -1 OFFSET \(QModelCapabilityLimits.maxObservationsPerKey)
        );
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, perKeyPrune, -1, &statement, nil) == SQLITE_OK else { return false }
        bindText(statement, 1, observation.taskType.rawValue)
        bindText(statement, 2, observation.complexity.rawValue)
        bindText(statement, 3, observation.backend.rawValue)
        let perKeyStatus = sqlite3_step(statement)
        sqlite3_finalize(statement)
        guard perKeyStatus == SQLITE_DONE else { return false }

        // Global cap: only pay for the ordered delete when the table is actually over the bound.
        guard totalRowCount() > QModelCapabilityLimits.maxTotalObservations else { return true }
        return capabilityExec("""
        DELETE FROM \(observationTable) WHERE observation_id IN (
            SELECT observation_id FROM \(observationTable)
            ORDER BY observed_at DESC, observation_id DESC LIMIT -1 OFFSET \(QModelCapabilityLimits.maxTotalObservations)
        );
        """)
    }

    private func totalRowCount() -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(observationTable);", -1, &statement, nil) == SQLITE_OK else { return Int.max }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : Int.max
    }

    // MARK: Read

    private func decodeObservation(from statement: OpaquePointer?) -> QModelCapabilityObservation? {
        guard let observationId = columnText(statement, 0),
              let taskId = columnText(statement, 1),
              let attemptId = columnText(statement, 2),
              let source = columnText(statement, 3).flatMap(QObservationSource.init(rawValue:)),
              let taskType = columnText(statement, 4).flatMap(QTaskType.init(rawValue:)),
              let complexity = columnText(statement, 5).flatMap(QTaskComplexity.init(rawValue:)),
              let backend = columnText(statement, 6).flatMap(QModelBackendType.init(rawValue:)),
              let strategy = columnText(statement, 7).flatMap(QModelStrategy.init(rawValue:)),
              let attemptOutcome = columnText(statement, 8).flatMap(QObservedAttemptOutcome.init(rawValue:)),
              let verification = columnText(statement, 9).flatMap(QObservedVerification.init(rawValue:)),
              let completeness = columnText(statement, 10).flatMap(QEvidenceCompleteness.init(rawValue:)),
              let contradiction = columnText(statement, 11).flatMap(QObservedContradiction.init(rawValue:)),
              let resource = columnText(statement, 12).flatMap(QObservedResource.init(rawValue:)),
              let execution = columnText(statement, 13).flatMap(QObservedExecution.init(rawValue:)),
              let outcome = columnText(statement, 15).flatMap(QLearnedOutcome.init(rawValue:))
        else { return nil }

        let latency: Int? = sqlite3_column_type(statement, 14) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 14))
        var feedback: QExplicitUserFeedback?
        if sqlite3_column_type(statement, 16) != SQLITE_NULL {
            // A non-null but unrecognised feedback value is corruption, not "no feedback".
            guard let decoded = columnText(statement, 16).flatMap(QExplicitUserFeedback.init(rawValue:)) else { return nil }
            feedback = decoded
        }
        return QModelCapabilityObservation(
            storedObservationId: observationId, storedOutcome: outcome,
            taskId: taskId, attemptId: attemptId, source: source, taskType: taskType, complexity: complexity,
            backend: backend, strategy: strategy, attemptOutcome: attemptOutcome, verification: verification,
            evidenceCompleteness: completeness, contradiction: contradiction, resource: resource, execution: execution,
            latencyMilliseconds: latency, feedback: feedback,
            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 17)),
            schemaVersion: Int(sqlite3_column_int64(statement, 18))
        )
    }

    private func fetchObservation(id: String) -> QModelCapabilityObservation? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(observationColumns) FROM \(observationTable) WHERE observation_id = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, id)
        return sqlite3_step(statement) == SQLITE_ROW ? decodeObservation(from: statement) : nil
    }

    private func fetchTaskRow(taskId: String, backend: QModelBackendType) -> QModelCapabilityObservation? {
        var statement: OpaquePointer?
        let sql = "SELECT \(observationColumns) FROM \(observationTable) WHERE task_id = ? AND backend = ? AND source != 'userFeedback' ORDER BY observed_at ASC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, taskId)
        bindText(statement, 2, backend.rawValue)
        return sqlite3_step(statement) == SQLITE_ROW ? decodeObservation(from: statement) : nil
    }

    /// Runs `sql` (already bound by `bind`) and returns every row that decodes AND validates.
    private func readObservations(sql: String, now: Date, bind: (OpaquePointer?) -> Void) -> QCapabilityReadResult {
        guard capabilitySchemaSupported else { return QCapabilityReadResult(observations: [], skippedRowCount: 0) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return QCapabilityReadResult(observations: [], skippedRowCount: 0)
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)

        var usable: [QModelCapabilityObservation] = []
        var skipped = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let observation = decodeObservation(from: statement),
                  QObservationValidator.rejection(for: observation, now: now) == nil else {
                skipped += 1
                continue
            }
            usable.append(observation)
        }
        return QCapabilityReadResult(observations: usable, skippedRowCount: skipped)
    }

    public func observations(for key: QModelCapabilityProfileKey, now: Date = Date()) -> QCapabilityReadResult {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-QModelCapabilityLimits.retentionSeconds).timeIntervalSince1970
        let sql = """
        SELECT \(observationColumns) FROM \(observationTable)
        WHERE task_type = ? AND complexity = ? AND backend = ? AND observed_at >= \(cutoff)
        ORDER BY observed_at DESC, observation_id DESC LIMIT \(QModelCapabilityLimits.maxObservationsPerKey);
        """
        return readObservations(sql: sql, now: now) { statement in
            bindText(statement, 1, key.taskType.rawValue)
            bindText(statement, 2, key.complexity.rawValue)
            bindText(statement, 3, key.backend.rawValue)
        }
    }

    public func observations(forTask taskId: String, now: Date = Date()) -> QCapabilityReadResult {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-QModelCapabilityLimits.retentionSeconds).timeIntervalSince1970
        let sql = """
        SELECT \(observationColumns) FROM \(observationTable)
        WHERE task_id = ? AND observed_at >= \(cutoff)
        ORDER BY observed_at ASC, observation_id ASC LIMIT \(QModelCapabilityLimits.maxObservationsPerKey);
        """
        return readObservations(sql: sql, now: now) { statement in bindText(statement, 1, taskId) }
    }

    public func profile(for key: QModelCapabilityProfileKey, now: Date = Date()) -> QModelCapabilityProfile {
        QModelCapabilityProfile(observations: observations(for: key, now: now).observations, key: key)
    }

    public func profiles(now: Date = Date()) -> [QModelCapabilityProfile] {
        lock.lock()
        defer { lock.unlock() }
        guard capabilitySchemaSupported else { return [] }
        let cutoff = now.addingTimeInterval(-QModelCapabilityLimits.retentionSeconds).timeIntervalSince1970
        var statement: OpaquePointer?
        let sql = "SELECT DISTINCT task_type, complexity, backend FROM \(observationTable) WHERE observed_at >= \(cutoff) ORDER BY task_type, complexity, backend;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var keys: [QModelCapabilityProfileKey] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let taskType = columnText(statement, 0).flatMap(QTaskType.init(rawValue:)),
               let complexity = columnText(statement, 1).flatMap(QTaskComplexity.init(rawValue:)),
               let backend = columnText(statement, 2).flatMap(QModelBackendType.init(rawValue:)) {
                keys.append(QModelCapabilityProfileKey(taskType: taskType, complexity: complexity, backend: backend))
            }
        }
        sqlite3_finalize(statement)
        return keys.map { profile(for: $0, now: now) }
    }

    public func observationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard capabilitySchemaSupported else { return 0 }
        let count = totalRowCount()
        return count == Int.max ? 0 : count
    }
}
