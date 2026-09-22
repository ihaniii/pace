//
//  QMemoryEvidenceCollector.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 3 (Verified Response Path), third slice: the Memory Evidence
//  Collector. Turns already-retrieved memory (`QProvenanceAwareMemoryProvider.queryContextItems`,
//  Phase 3 slice 1) into bounded, deterministic Evidence Pool drafts — without ever re-reading, re-
//  interpreting, or upgrading what memory already said about itself.
//
//  What this collector does NOT do:
//   - it never upgrades trust. Every draft goes through `QMemoryContextItem.asEvidenceDraft(taskId:)`
//     (slice 1, unmodified), which ALWAYS produces `.retrievedExternal` evidence under untrusted
//     `.untrustedTool(toolName: "memory")` provenance — regardless of what the record's own stored
//     label said, and regardless of whether the item was `.priorVerifiedProposition`. A fact that was
//     independently verified in an EARLIER task must be independently verified again in THIS one
//     before it counts as more than "observed" (Phase 2C's pool, unchanged, enforces this);
//   - it never writes memory. `queryContextItems` is read-only; nothing here ever calls `insert`,
//     `update`, or the verified-proposition writer;
//   - it never fabricates an evidence ID. Every draft's identity is the deterministic, content-hash
//     based one `asEvidenceDraft` already derives — the same memory content always yields the same
//     evidence ID, which is also how the Evidence Pool's own `addEvidence` naturally deduplicates two
//     records that happen to say the same thing;
//   - the query text (typically the task's own intent) is used ONLY to call `queryContextItems` and is
//     never persisted, logged, or placed in any evidence draft or its metadata.
//

import Foundation

extension QMemoryContextItem {
    /// The Phase-3-slice-3 draft: identical security posture to `asEvidenceDraft(taskId:)` (same
    /// kind, same untrusted provenance, same content, same deterministic identity) with ADDITIONAL
    /// bounded, non-sensitive metadata describing what this item's *original* standing was — for
    /// legacy memory (no structured provenance) explicitly marked `legacy`, so a caller/auditor can
    /// see that this evidence started life untrusted rather than inferring it.
    func asAnnotatedEvidenceDraft(taskId: String) -> QEvidenceDraft {
        let base = asEvidenceDraft(taskId: taskId)
        var metadata = base.metadata
        metadata["originalTrust"] = trust.rawValue
        if let verifiedProvenance {
            metadata["originalVerification"] = verifiedProvenance.verification
            metadata["originalTrustLabel"] = verifiedProvenance.trust
            metadata["originalSourceKind"] = verifiedProvenance.sourceKind
        } else {
            metadata["legacy"] = "true"
        }
        return QEvidenceDraft(
            taskId: base.taskId,
            sourceId: base.sourceId,
            kind: base.kind,
            provenance: base.provenance,
            origin: base.origin,
            content: base.content,
            metadata: metadata,
            initialVerification: base.initialVerification
        )
    }
}

/// Collects memory relevant to the current task, bounded and deterministic. Conforms to the
/// existing Phase 2C `QEvidenceCollector` seam — the Evidence Pool remains entirely unaware this
/// collector exists as anything other than "a source of drafts".
public struct QMemoryEvidenceCollector: QEvidenceCollector {
    private let store: any QProvenanceAwareMemoryProvider
    /// Transient: held only for the lifetime of this value, used once to call `queryContextItems`,
    /// never persisted, never placed in any evidence draft.
    private let queryText: String

    public init(store: any QProvenanceAwareMemoryProvider, queryText: String) {
        self.store = store
        self.queryText = queryText
    }

    public func collect(taskId: String, limit: Int) async throws -> [QEvidenceDraft] {
        try Task.checkCancellation()
        let boundedLimit = min(limit, QLocalEvidenceLimits.maxMemoryEvidenceRecords)
        guard boundedLimit > 0 else { return [] }

        let items = try await store.queryContextItems(for: queryText, limit: boundedLimit)
        try Task.checkCancellation()

        // Deterministic de-dup: the store's own retrieval order is already deterministic for a
        // given snapshot (SQL ORDER BY); this keeps the FIRST occurrence of identical content,
        // preserving that order (`Array.sorted`-free — nothing here reorders anything).
        var seenContent: Set<String> = []
        var drafts: [QEvidenceDraft] = []
        for item in items {
            guard drafts.count < boundedLimit else { break }
            guard seenContent.insert(item.text).inserted else { continue }
            drafts.append(item.asAnnotatedEvidenceDraft(taskId: taskId))
        }
        return drafts
    }
}
