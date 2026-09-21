//
//  QEvidenceCritic.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2C Critic.
//  A bounded, ADVISORY reviewer of the evidence pool. It identifies unsupported claims, missing
//  evidence, contradictions, reasoning gaps, verification failures, and unsupported certainty.
//
//  What the critic cannot do — by type, not by policy:
//   - `QCriticFinding` has no action, permission, egress, capability, risk, approval, or
//     verification-override field, and `QCriticFindingKind` has no "approved"/"verified"/"safe"
//     case. The worst a finding can do is add a caveat to the synthesis;
//   - the critic receives a read-only value-type pool snapshot and returns findings; it cannot
//     mutate the pool, so it cannot change any claim's trust, status, or verification;
//   - critic output is UNTRUSTED until `QCriticValidator` accepts it: unknown claim/evidence IDs
//     are dropped, detail text is credential-redacted and length-capped (and is display-only —
//     never parsed, never executed), duplicates are collapsed, and the count is capped;
//   - exactly one critic pass runs (`QEvidenceLimits.maxCriticPasses`); there is no critic loop and
//     no numeric "quality score".
//

import Foundation

// MARK: - Finding

public enum QCriticFindingKind: String, Sendable, Equatable, CaseIterable {
    /// A model asserted this and nothing non-model backs it.
    case unsupportedClaim
    /// Verification is required but has not been attempted, or the pool is empty.
    case missingEvidence
    /// Claims about the same subject disagree.
    case contradiction
    /// A claim cites evidence that does not actually assert it — the conclusion does not follow
    /// from what it cites.
    case reasoningGap
    /// Verification was attempted and failed / was unavailable / was inconclusive / contradicted.
    case verificationFailure
    /// Certainty language on a claim that is not independently verified.
    case unsupportedCertainty
    /// An evidence item contained instruction-shaped text (flagged and ignored).
    case instructionLikeEvidence

    /// Kinds that must reference at least one real claim or evidence ID to be accepted.
    var requiresReference: Bool { self != .missingEvidence }

    /// Fixed, content-free description. Deterministic critics use ONLY these strings.
    public var templateDetail: String {
        switch self {
        case .unsupportedClaim: return "Claim is asserted only by a model; no independent source supports it."
        case .missingEvidence: return "Required verification evidence has not been gathered."
        case .contradiction: return "Claims about the same subject disagree; both are preserved."
        case .reasoningGap: return "Claim cites evidence that does not assert it."
        case .verificationFailure: return "Verification did not confirm this claim."
        case .unsupportedCertainty: return "Certainty is expressed without independent verification."
        case .instructionLikeEvidence: return "Evidence contained instruction-like text, which was ignored."
        }
    }
}

public struct QCriticFinding: Sendable, Equatable {
    public let findingId: String
    public let kind: QCriticFindingKind
    public let claimIds: [QClaimID]
    public let evidenceIds: [QEvidenceID]
    /// Bounded, credential-redacted, DISPLAY-ONLY text.
    public let detail: String

    public init(kind: QCriticFindingKind, claimIds: [QClaimID] = [], evidenceIds: [QEvidenceID] = [], detail: String? = nil) {
        self.kind = kind
        self.claimIds = claimIds
        self.evidenceIds = evidenceIds
        self.detail = QEvidenceText.boundedSafe(detail ?? kind.templateDetail, maxCharacters: QEvidenceLimits.maxCriticDetailCharacters)
        self.findingId = "cf-" + QEvidenceText.shortHash([kind.rawValue] + claimIds.map { $0.rawValue }.sorted() + evidenceIds.map { $0.rawValue }.sorted())
    }
}

// MARK: - Critic Contract

/// Anything that can review a pool. Implementations may be model-backed in a later phase; their
/// output is untrusted and always passes through `QCriticValidator`.
public protocol QEvidenceCritic: Sendable {
    func critique(pool: QEvidencePool) async throws -> [QCriticFinding]
}

/// The default critic: pure, deterministic, no model, no I/O, cannot fail.
public struct QDeterministicEvidenceCritic: QEvidenceCritic {
    public init() {}

    public func critique(pool: QEvidencePool) async throws -> [QCriticFinding] {
        try Task.checkCancellation()
        var findings: [QCriticFinding] = []

        if pool.claims.isEmpty {
            findings.append(QCriticFinding(kind: .missingEvidence))
        }

        for claim in pool.claims {
            let hasNonModelSupport = claim.trust >= .observed

            if claim.originKind == .modelGenerated, !hasNonModelSupport {
                findings.append(QCriticFinding(kind: .unsupportedClaim, claimIds: [claim.claimId]))
            }

            // A cited item that exists but whose own claims do not assert this proposition.
            let citedItems = claim.sourceEvidenceIds.dropFirst()
            if claim.originKind == .modelGenerated, !citedItems.isEmpty, !hasNonModelSupport {
                findings.append(QCriticFinding(kind: .reasoningGap, claimIds: [claim.claimId], evidenceIds: Array(citedItems)))
            }

            if claim.verificationRequired {
                switch claim.verification {
                case .pending:
                    findings.append(QCriticFinding(kind: .missingEvidence, claimIds: [claim.claimId]))
                case .unresolved, .unavailable, .contradicted:
                    findings.append(QCriticFinding(kind: .verificationFailure, claimIds: [claim.claimId]))
                case .verified, .notRequired:
                    break
                }
            } else if claim.verification == .contradicted {
                findings.append(QCriticFinding(kind: .verificationFailure, claimIds: [claim.claimId]))
            }

            // Certainty language matters for claims someone ASSERTS (model/retrieved); an execution
            // or user observation is a record, not an assertion of certainty.
            if claim.proposition.assertsCertainty, !claim.originKind.isSelfEvidencing, claim.status != .verified {
                findings.append(QCriticFinding(kind: .unsupportedCertainty, claimIds: [claim.claimId]))
            }
        }

        for contradiction in pool.contradictions where !contradiction.isResolved {
            findings.append(QCriticFinding(kind: .contradiction, claimIds: contradiction.claimIds))
        }

        for item in pool.items where item.flags.contains(.instructionLikeContent) {
            findings.append(QCriticFinding(kind: .instructionLikeEvidence, evidenceIds: [item.evidenceId]))
        }

        return findings
    }
}

// MARK: - Validator

public struct QCriticValidation: Sendable, Equatable {
    public let accepted: [QCriticFinding]
    public let rejectedCount: Int
}

/// The gate that makes critic output usable: everything the critic says is untrusted until it
/// passes here. Never raises trust, never touches the pool.
public enum QCriticValidator {
    public static func validate(_ findings: [QCriticFinding], against pool: QEvidencePool) -> QCriticValidation {
        var accepted: [QCriticFinding] = []
        var seen: Set<String> = []
        var rejected = 0

        for finding in findings {
            let claimIds = finding.claimIds.filter { pool.claim($0) != nil }
            let evidenceIds = finding.evidenceIds.filter { pool.item($0) != nil }
            // Any reference to something that does not exist means the critic invented it: reject
            // the whole finding rather than quietly trimming it into a plausible-looking one.
            let referencesAreReal = claimIds.count == finding.claimIds.count && evidenceIds.count == finding.evidenceIds.count
            let hasReference = !claimIds.isEmpty || !evidenceIds.isEmpty
            guard referencesAreReal, hasReference || !finding.kind.requiresReference else {
                rejected += 1
                continue
            }
            guard accepted.count < QEvidenceLimits.maxCriticFindings else {
                rejected += 1
                continue
            }
            // Re-derive the id and re-sanitise the detail from the validated fields so a critic
            // cannot smuggle a forged id or unbounded/credential-bearing text through.
            let sanitized = QCriticFinding(kind: finding.kind, claimIds: claimIds, evidenceIds: evidenceIds, detail: finding.detail)
            guard seen.insert(sanitized.findingId).inserted else { continue }
            accepted.append(sanitized)
        }
        return QCriticValidation(accepted: accepted, rejectedCount: rejected)
    }
}
