//
//  QVerifiedMemoryStore.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 3 (Verified Response Path), first slice: durable verified
//  propositions and provenance-preserving retrieval, as an extension of the EXISTING
//  `QSQLiteMemoryStore` (same SQLite file, same WAL connection, same lock) — deliberately not a
//  second database.
//
//  Guarantees (each covered by tests):
//   - atomic + idempotent: validate → dedupe → insert → prune in ONE `BEGIN IMMEDIATE` transaction;
//     identity is a deterministic hash of the proposition, so re-writing the same verified
//     proposition is a `.duplicate` and can never accumulate;
//   - bounded: per-subject and global caps prune the oldest rows inside the same transaction;
//   - fail-safe reads: a row that cannot be decoded, or that fails `QVerifiedPropositionValidator`
//     (tampered id, an "unverified" row claiming verification, malformed evidence IDs, unknown schema
//     version), is SKIPPED and counted — never trusted, never deleted, never upgraded;
//   - schema-versioned: a newer or unreadable on-disk schema is left completely untouched;
//   - conservative legacy handling: pre-existing `memory_records` rows are never migrated into
//     trusted status. Retrieval reports them as `.unverified` (or `.userStatement` for the user's own
//     recorded intent); a bare `trusted:system`/`trusted:local` label is not evidence;
//   - existing tables and the existing `QMemoryProvider` API are untouched.
//

import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
    sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
}

private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    sqlite3_column_text(statement, index).map { String(cString: $0) }
}

private let propositionTable = "verified_propositions"
private let propositionMetaTable = "verified_proposition_meta"

private let propositionColumns = """
proposition_id, subject_key, value, origin_task_id, claim_id, evidence_ids, verification, trust, verified_basis, \
source_kind, requirement, write_back_eligible, written_at, schema_version
"""

extension QSQLiteMemoryStore: QVerifiedPropositionStoring, QProvenanceAwareMemoryProvider {

    // MARK: Schema

    /// Creates (or validates) the verified-proposition schema. Never drops, truncates, or rewrites anything.
    func ensureVerifiedPropositionSchema() {
        lock.lock()
        defer { lock.unlock() }

        guard verifiedExec("CREATE TABLE IF NOT EXISTS \(propositionMetaTable) (key TEXT PRIMARY KEY, value TEXT NOT NULL);") else {
            verifiedPropositionSchemaSupported = false
            return
        }
        var versionStatement: OpaquePointer?
        var onDiskVersion: Int?
        guard sqlite3_prepare_v2(db, "SELECT value FROM \(propositionMetaTable) WHERE key = 'schema_version' LIMIT 1;", -1, &versionStatement, nil) == SQLITE_OK else {
            verifiedPropositionSchemaSupported = false
            return
        }
        let versionStep = sqlite3_step(versionStatement)
        if versionStep == SQLITE_ROW {
            guard let text = columnText(versionStatement, 0), let parsed = Int(text) else {
                sqlite3_finalize(versionStatement)
                verifiedPropositionSchemaSupported = false   // unreadable marker: leave everything alone
                return
            }
            onDiskVersion = parsed
        } else if versionStep != SQLITE_DONE {
            sqlite3_finalize(versionStatement)
            verifiedPropositionSchemaSupported = false
            return
        }
        sqlite3_finalize(versionStatement)
        if let onDiskVersion, onDiskVersion > QVerifiedMemoryLimits.schemaVersion {
            verifiedPropositionSchemaSupported = false
            return
        }

        let created = verifiedExec("""
        CREATE TABLE IF NOT EXISTS \(propositionTable) (
            proposition_id TEXT PRIMARY KEY,
            subject_key TEXT NOT NULL,
            value TEXT NOT NULL,
            origin_task_id TEXT NOT NULL,
            claim_id TEXT NOT NULL,
            evidence_ids TEXT NOT NULL,
            verification TEXT NOT NULL,
            trust TEXT NOT NULL,
            verified_basis TEXT NOT NULL,
            source_kind TEXT NOT NULL,
            requirement TEXT NOT NULL,
            write_back_eligible INTEGER NOT NULL,
            written_at REAL NOT NULL,
            schema_version INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_vprop_subject ON \(propositionTable)(subject_key, written_at);
        """)
        guard created else {
            verifiedPropositionSchemaSupported = false
            return
        }
        verifiedExec("INSERT OR REPLACE INTO \(propositionMetaTable) (key, value) VALUES ('schema_version', '\(QVerifiedMemoryLimits.schemaVersion)');")
    }

    @discardableResult
    private func verifiedExec(_ sql: String) -> Bool {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if let errorMessage { sqlite3_free(errorMessage) }
        return status == SQLITE_OK
    }

    // MARK: Write

    public func writeVerifiedProposition(_ proposition: QVerifiedProposition, now: Date = Date()) -> QVerifiedWriteResult {
        lock.lock()
        defer { lock.unlock() }

        guard verifiedPropositionSchemaSupported else { return .rejected(.schemaVersionUnsupported) }
        if let rejection = QVerifiedPropositionValidator.rejection(for: proposition, now: now) { return .rejected(rejection) }
        guard verifiedExec("BEGIN IMMEDIATE;") else { return .storeUnavailable }

        let (result, shouldCommit) = writeWithinTransaction(proposition)
        if shouldCommit {
            guard verifiedExec("COMMIT;") else {
                verifiedExec("ROLLBACK;")
                return .storeUnavailable
            }
        } else {
            verifiedExec("ROLLBACK;")
        }
        return result
    }

    private func writeWithinTransaction(_ proposition: QVerifiedProposition) -> (QVerifiedWriteResult, Bool) {
        if rowExists(id: proposition.provenance.propositionId) { return (.duplicate, false) }

        let sql = """
        INSERT INTO \(propositionTable)
        (proposition_id, subject_key, value, origin_task_id, claim_id, evidence_ids, verification, trust, verified_basis,
         source_kind, requirement, write_back_eligible, written_at, schema_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return (.storeUnavailable, false) }
        let provenance = proposition.provenance
        bindText(statement, 1, provenance.propositionId)
        bindText(statement, 2, proposition.subjectKey)
        bindText(statement, 3, proposition.value)
        bindText(statement, 4, provenance.originTaskId)
        bindText(statement, 5, provenance.claimId)
        bindText(statement, 6, provenance.evidenceIds.joined(separator: ","))
        bindText(statement, 7, provenance.verification)
        bindText(statement, 8, provenance.trust)
        bindText(statement, 9, provenance.verifiedBasis)
        bindText(statement, 10, provenance.sourceKind)
        bindText(statement, 11, provenance.requirement)
        sqlite3_bind_int64(statement, 12, provenance.writeBackEligible ? 1 : 0)
        sqlite3_bind_double(statement, 13, provenance.writtenAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 14, Int64(provenance.schemaVersion))
        let inserted = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        guard inserted else { return (.storeUnavailable, false) }

        guard pruneVerifiedPropositions(subjectKey: proposition.subjectKey) else { return (.storeUnavailable, false) }
        return (.written, true)
    }

    private func rowExists(id: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM \(propositionTable) WHERE proposition_id = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, id)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Per-subject and global caps, inside the caller's transaction.
    private func pruneVerifiedPropositions(subjectKey: String) -> Bool {
        var statement: OpaquePointer?
        let perSubject = """
        DELETE FROM \(propositionTable) WHERE proposition_id IN (
            SELECT proposition_id FROM \(propositionTable) WHERE subject_key = ?
            ORDER BY written_at DESC, proposition_id DESC LIMIT -1 OFFSET \(QVerifiedMemoryLimits.maxPerSubject)
        );
        """
        guard sqlite3_prepare_v2(db, perSubject, -1, &statement, nil) == SQLITE_OK else { return false }
        bindText(statement, 1, subjectKey)
        let status = sqlite3_step(statement)
        sqlite3_finalize(statement)
        guard status == SQLITE_DONE else { return false }

        return verifiedExec("""
        DELETE FROM \(propositionTable) WHERE proposition_id IN (
            SELECT proposition_id FROM \(propositionTable)
            ORDER BY written_at DESC, proposition_id DESC LIMIT -1 OFFSET \(QVerifiedMemoryLimits.maxPropositions)
        );
        """)
    }

    // MARK: Read

    private func decodeProposition(from statement: OpaquePointer?) -> QVerifiedProposition? {
        guard let propositionId = columnText(statement, 0),
              let subjectKey = columnText(statement, 1),
              let value = columnText(statement, 2),
              let originTaskId = columnText(statement, 3),
              let claimId = columnText(statement, 4),
              let evidenceIdsText = columnText(statement, 5),
              let verification = columnText(statement, 6),
              let trust = columnText(statement, 7),
              let verifiedBasis = columnText(statement, 8),
              let sourceKind = columnText(statement, 9),
              let requirement = columnText(statement, 10)
        else { return nil }
        let eligible = sqlite3_column_int64(statement, 11) == 1
        return QVerifiedProposition(
            provenance: QVerifiedPropositionProvenance(
                propositionId: propositionId, originTaskId: originTaskId, claimId: claimId,
                evidenceIds: evidenceIdsText.isEmpty ? [] : evidenceIdsText.components(separatedBy: ","),
                verification: verification, trust: trust, verifiedBasis: verifiedBasis, sourceKind: sourceKind,
                requirement: requirement, writeBackEligible: eligible,
                writtenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
                schemaVersion: Int(sqlite3_column_int64(statement, 13))
            ),
            subjectKey: subjectKey,
            value: value
        )
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    public func verifiedPropositions(matching text: String, limit: Int) -> QVerifiedPropositionReadResult {
        lock.lock()
        defer { lock.unlock() }
        guard verifiedPropositionSchemaSupported else { return QVerifiedPropositionReadResult(propositions: [], skippedRowCount: 0) }

        let boundedLimit = max(0, min(limit, QVerifiedMemoryLimits.maxRetrievalLimit))
        let sql = """
        SELECT \(propositionColumns) FROM \(propositionTable)
        WHERE subject_key LIKE ? ESCAPE '\\' OR value LIKE ? ESCAPE '\\'
        ORDER BY written_at DESC, proposition_id DESC LIMIT \(boundedLimit);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return QVerifiedPropositionReadResult(propositions: [], skippedRowCount: 0)
        }
        defer { sqlite3_finalize(statement) }
        let pattern = "%" + Self.escapeLike(text) + "%"
        bindText(statement, 1, pattern)
        bindText(statement, 2, pattern)

        var usable: [QVerifiedProposition] = []
        var skipped = 0
        // A stored row is re-validated on every read against the reader's clock, so a tampered row
        // (forged id, an unverified row claiming verification, a future write time) is skipped.
        let readTime = Date()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let proposition = decodeProposition(from: statement),
                  QVerifiedPropositionValidator.rejection(for: proposition, now: readTime) == nil else {
                skipped += 1
                continue
            }
            usable.append(proposition)
        }
        return QVerifiedPropositionReadResult(propositions: usable, skippedRowCount: skipped)
    }

    public func verifiedPropositionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard verifiedPropositionSchemaSupported else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(propositionTable);", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    // MARK: Provenance-preserving context retrieval (additive; `queryContext` is unchanged)

    /// Legacy `memory_records` rows plus structured verified propositions, each labelled with what it
    /// actually is. Retrieval NEVER upgrades: a bare `trusted:system` (or any other) label is not
    /// evidence, so legacy rows are `.unverified` — except the user's own recorded intent
    /// (`trusted:user`, not a completion record), which is `.userStatement`.
    public func queryContextItems(for query: String, limit: Int) async throws -> [QMemoryContextItem] {
        let boundedLimit = max(0, min(limit, QVerifiedMemoryLimits.maxRetrievalLimit))
        var items: [QMemoryContextItem] = []

        for proposition in verifiedPropositions(matching: query, limit: boundedLimit).propositions {
            items.append(
                QMemoryContextItem(
                    text: proposition.renderedText, trust: .priorVerifiedProposition,
                    recordedProvenanceLabel: "verified_proposition", verifiedProvenance: proposition.provenance
                )
            )
        }
        for record in try self.query(text: query, sessionId: nil, limit: boundedLimit) {
            let isUserStatement = record.provenanceKind == "trusted:user" && !record.key.hasPrefix("task_completion:")
            items.append(
                QMemoryContextItem(
                    text: record.content, trust: isUserStatement ? .userStatement : .unverified,
                    recordedProvenanceLabel: record.provenanceKind
                )
            )
        }
        return Array(items.prefix(boundedLimit))
    }
}
