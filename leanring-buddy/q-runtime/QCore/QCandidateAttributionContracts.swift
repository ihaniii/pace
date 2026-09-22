//
//  QCandidateAttributionContracts.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 3 (Verified Response Path), fourth slice: candidate-level
//  outcome attribution. Extends Evidence → Verification → Outcome Learning so a verified,
//  contradicted, or unresolved model-generated CLAIM can be attributed to the specific model
//  candidate/backend that produced it — additively, alongside the existing task-level learning
//  (Phase 2E), which this file does not touch.
//
//      QEvidencePool (post-verification)
//        → QCandidateAttributionResolver.resolve   (pure; claim → evidence → attempt → candidate → backend)
//        → [QCandidateAttributionRecord]            (provenance metadata; no authority, no truth)
//        → QOutcomeLearningService.learnCandidateAttribution (QOutcomeLearning.swift)
//        → QModelCapabilityMemory                   (existing, bounded, idempotent — unchanged rules)
//
//  What attribution is NOT:
//   - it is not truth. `outcome` is read directly from `QEvidenceClaim.verification`/`.contradiction`
//     (Phase 2C, unchanged) and never fed back into them — the resolver takes the pool BY VALUE and
//     cannot mutate it, so attribution can never raise, lower, or otherwise influence trust;
//   - it is not a guess. Candidate identity comes ONLY from the origin evidence item's
//     `QEvidenceOrigin` (`attemptId`/`candidateId`/`backend`), set exclusively by the existing,
//     authoritative Phase 2B/3 ingestion paths (`QEvidencePipeline.ingestLocalInputs`,
//     `QEvidenceIngestion.draft(for:taskId:)`). Nothing here reconstructs identity from a model-name
//     string, response text, timing, ordering, or lexical similarity — a claim whose origin item
//     carries no such identity is `.attributionUnavailable`, never a best-effort guess;
//   - it is not a ranking. There is no numeric score, no percentage, no "winner" — a claim's outcome
//     is one of five fixed, conservative labels, and two candidates that produced conflicting claims
//     are recorded independently, exactly as the pool already keeps them (Phase 2C never merges
//     conflicting claims, and this resolver inherits that by resolving per-CLAIM, never per-text);
//   - it is not a new authority. `QCandidateAttributionResolver` performs no I/O, no model call, no
//     network, and touches no execution/permission/egress type; it is a pure function from one
//     value type to another.
//

import Foundation

// MARK: - Outcome

/// The five fixed, conservative standings a candidate-attributed claim can have. Never a numeric
/// score; never a rank.
public enum QCandidateAttributionOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    /// The Evidence Pool independently verified this claim.
    case verified
    /// The Evidence Pool found this claim contradicted by independent evidence.
    case contradicted
    /// Verification was attempted (or a real conflict exists) but produced no verdict either way.
    case unresolved
    /// Verification never ran for this claim (still `.pending`) or was not required (`.notRequired`)
    /// — there is no verdict yet to attribute.
    case notEvaluated
    /// The claim's origin evidence item carries no candidate/attempt/backend identity. Attribution
    /// is refused rather than guessed; this case NEVER carries a candidate, attempt, or backend.
    case attributionUnavailable
}

// MARK: - Record (provenance metadata only — no raw text)

/// One claim's candidate attribution. Codable/Equatable, and deliberately carries no claim/evidence
/// TEXT — only deterministic identifiers and enum raw values, so it can be persisted (via
/// `QModelCapabilityObservation`, see `QOutcomeLearning.swift`) without ever risking raw content.
public struct QCandidateAttributionRecord: Codable, Sendable, Equatable {
    public let taskId: String
    public let claimId: String
    /// The claim's extracting evidence item — the one whose `QEvidenceOrigin` this record's identity
    /// was resolved from.
    public let evidenceId: String
    /// Present if and only if `outcome != .attributionUnavailable`. At least one of
    /// `attemptId`/`candidateId`/`backend` is non-nil whenever this triple is present.
    public let attemptId: String?
    public let candidateId: String?
    public let backend: QModelBackendType?
    /// Raw value of `QEvidenceVerificationState` at resolution time — reported as observed, never
    /// altered by attribution.
    public let verification: String
    /// Raw value of `QContradictionState` at resolution time — reported as observed, never altered.
    public let contradiction: String
    public let outcome: QCandidateAttributionOutcome
    public let observedAt: Date

    public var isAttributionAvailable: Bool { outcome != .attributionUnavailable }
}

// MARK: - Resolver (pure)

public enum QCandidateAttributionResolver {

    /// Resolves every model-generated claim currently in `pool` to its producing candidate, if the
    /// pool's own evidence provenance can establish one. Read-only: `pool` is a value type and this
    /// function never mutates it, calls a model, or performs any I/O. Bounded by the pool's own
    /// existing claim cap (`QEvidenceLimits.maxClaims`) — nothing here can grow unbounded.
    public static func resolve(pool: QEvidencePool, now: Date) -> [QCandidateAttributionRecord] {
        pool.claims
            .filter { $0.originKind == .modelGenerated }
            .prefix(QEvidenceLimits.maxClaims)
            .map { claim in
                guard let originEvidenceId = claim.sourceEvidenceIds.first,
                      let originItem = pool.item(originEvidenceId),
                      let origin = originItem.source.origin,
                      origin.attemptId != nil || origin.candidateId != nil || origin.backend != nil
                else {
                    // No authoritative identity to report — never guessed, never omitted silently.
                    return unavailable(claim: claim, evidenceId: claim.sourceEvidenceIds.first?.rawValue ?? "", now: now)
                }
                return QCandidateAttributionRecord(
                    taskId: claim.taskId,
                    claimId: claim.claimId.rawValue,
                    evidenceId: originItem.evidenceId.rawValue,
                    attemptId: origin.attemptId?.rawValue,
                    candidateId: origin.candidateId?.rawValue,
                    backend: origin.backend,
                    verification: claim.verification.rawValue,
                    contradiction: claim.contradiction.rawValue,
                    outcome: outcome(for: claim.verification),
                    observedAt: now
                )
            }
    }

    private static func outcome(for verification: QEvidenceVerificationState) -> QCandidateAttributionOutcome {
        switch verification {
        case .verified: return .verified
        case .contradicted: return .contradicted
        case .unresolved, .unavailable: return .unresolved
        case .pending, .notRequired: return .notEvaluated
        }
    }

    private static func unavailable(claim: QEvidenceClaim, evidenceId: String, now: Date) -> QCandidateAttributionRecord {
        QCandidateAttributionRecord(
            taskId: claim.taskId, claimId: claim.claimId.rawValue, evidenceId: evidenceId,
            attemptId: nil, candidateId: nil, backend: nil,
            verification: claim.verification.rawValue, contradiction: claim.contradiction.rawValue,
            outcome: .attributionUnavailable, observedAt: now
        )
    }
}
