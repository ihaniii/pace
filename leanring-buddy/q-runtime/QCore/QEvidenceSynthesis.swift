//
//  QEvidenceSynthesis.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2C Synthesis.
//  Builds the final structured result from the pool, contradictions, critic findings, and stage
//  outcomes. Synthesis SELECTS AND LABELS existing claims — it never writes new facts:
//   - a statement's text is rendered from a pool claim (`QClaimProposition.renderedText`), never
//     accepted from a synthesizer, so every statement is traceable to the evidence IDs of the claim
//     it renders, and no statement can assert something the pool does not contain;
//   - every statement's disposition (verified / corroborated / observed / unverified / unresolved /
//     contradicted) is recomputed from the pool by `QSynthesisPolicy`; a synthesizer that proposes a
//     stronger label is overruled and the attempt is counted in `draftViolationCount`;
//   - the overall status can never exceed what the pool supports and can never weaken the pool's
//     verification requirement (fixed at pool construction, no setter);
//   - conflicting claims are ALL retained and reported as contradictions — an omitted claim in a
//     synthesizer draft is restored, so a draft cannot silently pick a winner;
//   - insufficient evidence is reported as insufficient/unresolved — never manufactured certainty.
//
//  Synthesis output is untrusted until validated here, and even validated it grants nothing: the
//  result type carries no permission, egress, resource, approval, execution, or risk field.
//

import Foundation

// MARK: - Stage Reporting

public enum QEvidenceStageState: String, Sendable, Equatable, CaseIterable {
    case notRun
    case skipped
    case completed
    case unavailable
    case timedOut
    case cancelled

    /// Stages whose loss means the pool may be incomplete or unchecked.
    var compromisesCompleteness: Bool {
        self == .unavailable || self == .timedOut || self == .cancelled
    }
}

public struct QEvidenceStageReport: Sendable, Equatable {
    public var collection: QEvidenceStageState
    public var verification: QEvidenceStageState
    public var critic: QEvidenceStageState
    public var synthesis: QEvidenceStageState

    public init(
        collection: QEvidenceStageState = .notRun,
        verification: QEvidenceStageState = .notRun,
        critic: QEvidenceStageState = .notRun,
        synthesis: QEvidenceStageState = .notRun
    ) {
        self.collection = collection
        self.verification = verification
        self.critic = critic
        self.synthesis = synthesis
    }
}

// MARK: - Result Types

public enum QSynthesisStatus: String, Sendable, Equatable, CaseIterable {
    /// Every claim satisfies the verification requirement, nothing conflicts unresolved, and no
    /// stage was lost.
    case sufficient
    /// Some claims are satisfied; others are unverified/unresolved, or a stage was lost.
    case partial
    /// An unresolved contradiction exists. Both sides are preserved in the result.
    case contradictory
    /// No claim is satisfied (including the zero-evidence case).
    case insufficient
    /// Synthesis itself could not run.
    case unavailable

    var rank: Int {
        switch self {
        case .unavailable: return 0
        case .insufficient, .contradictory: return 1
        case .partial: return 2
        case .sufficient: return 3
        }
    }
}

public enum QStatementDisposition: String, Sendable, Equatable, CaseIterable {
    case verified
    case corroborated
    case observed
    case unverified
    case unresolved
    case contradicted
}

/// Fixed, content-free reasons the result is qualified. An enum, not prose: a synthesizer cannot
/// smuggle a factual claim in through a caveat.
public enum QSynthesisCaveat: String, Sendable, Equatable, CaseIterable, Comparable {
    case noEvidence
    case unresolvedContradiction
    case verificationIncomplete
    case verificationUnavailable
    case criticUnavailable
    case collectionIncomplete
    case synthesisUnavailable
    case stageTimedOut
    case stageCancelled
    case taintedSources
    case instructionLikeEvidenceIgnored
    case modelClaimsUnverified
    case criticFindingsPresent
    case independentVerificationRequired

    public static func < (lhs: QSynthesisCaveat, rhs: QSynthesisCaveat) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct QSynthesisStatement: Sendable, Equatable {
    public let claimId: QClaimID
    /// Rendered from the pool claim — never supplied by a synthesizer.
    public let text: String
    public let disposition: QStatementDisposition
    /// Always non-empty: every claim in the pool has at least its extracting item.
    public let evidenceIds: [QEvidenceID]
    public let contradictionId: String?
}

public struct QSynthesizedResult: Sendable, Equatable {
    public let taskId: String
    public let status: QSynthesisStatus
    public let statements: [QSynthesisStatement]
    public let contradictions: [QContradictionRecord]
    public let findings: [QCriticFinding]
    public let caveats: [QSynthesisCaveat]
    public let uncertainty: QDecisionUncertainty
    public let requirement: QVerificationRequirement
    /// How many times a synthesizer draft tried to exceed what the pool supports.
    public let draftViolationCount: Int

    public var isFullyTraceable: Bool {
        statements.allSatisfy { !$0.evidenceIds.isEmpty }
    }

    static func unavailable(taskId: String, requirement: QVerificationRequirement) -> QSynthesizedResult {
        QSynthesizedResult(
            taskId: taskId,
            status: .unavailable,
            statements: [],
            contradictions: [],
            findings: [],
            caveats: [.synthesisUnavailable],
            uncertainty: .high,
            requirement: requirement,
            draftViolationCount: 0
        )
    }
}

// MARK: - Synthesizer Contract

public struct QSynthesisInput: Sendable {
    public let pool: QEvidencePool
    public let findings: [QCriticFinding]
    public let stages: QEvidenceStageReport
}

/// What a synthesizer may PROPOSE. Untrusted: it can order claims and suggest labels/status, but
/// every suggestion is checked against `QSynthesisPolicy` by `QSynthesisValidator`.
public struct QSynthesisDraft: Sendable {
    public let orderedClaimIds: [QClaimID]
    public let proposedDispositions: [QClaimID: QStatementDisposition]
    public let proposedStatus: QSynthesisStatus
    public let proposedCaveats: [QSynthesisCaveat]

    public init(
        orderedClaimIds: [QClaimID],
        proposedDispositions: [QClaimID: QStatementDisposition] = [:],
        proposedStatus: QSynthesisStatus,
        proposedCaveats: [QSynthesisCaveat] = []
    ) {
        self.orderedClaimIds = orderedClaimIds
        self.proposedDispositions = proposedDispositions
        self.proposedStatus = proposedStatus
        self.proposedCaveats = proposedCaveats
    }
}

public protocol QEvidenceSynthesizer: Sendable {
    func synthesize(_ input: QSynthesisInput) async throws -> QSynthesisDraft
}

// MARK: - Policy (the authoritative derivation)

public enum QSynthesisPolicy {

    public static func disposition(for claim: QEvidenceClaim) -> QStatementDisposition {
        if claim.verification == .contradicted { return .contradicted }
        if claim.trust == .independentlyVerified { return .verified }
        if claim.contradiction == .conflicting { return .unresolved }
        switch claim.trust {
        case .corroborated: return .corroborated
        case .observed: return .observed
        case .independentlyVerified: return .verified
        case .untrusted:
            return (claim.verification == .unresolved || claim.verification == .unavailable) ? .unresolved : .unverified
        }
    }

    /// A claim that lost a RESOLVED contradiction is reported as contradicted but does not, by
    /// itself, make the result partial — the conflict was settled by independent evidence.
    private static func isResolvedLoser(_ claim: QEvidenceClaim, in pool: QEvidencePool) -> Bool {
        claim.verification == .contradicted
            && pool.contradictions.contains { $0.isResolved && $0.claimIds.contains(claim.claimId) }
    }

    public static func baselineStatus(pool: QEvidencePool, stages: QEvidenceStageReport) -> QSynthesisStatus {
        guard !pool.claims.isEmpty else { return .insufficient }
        if pool.contradictions.contains(where: { !$0.isResolved }) { return .contradictory }

        let satisfiedCount = pool.claims.filter { pool.isSatisfied($0) }.count
        let outstandingCount = pool.claims.filter { !pool.isSatisfied($0) && !isResolvedLoser($0, in: pool) }.count

        if satisfiedCount == 0 { return .insufficient }
        let stagesIntact = !stages.collection.compromisesCompleteness
            && !stages.verification.compromisesCompleteness
            && !stages.critic.compromisesCompleteness
        return (outstandingCount == 0 && stagesIntact) ? .sufficient : .partial
    }

    public static func caveats(pool: QEvidencePool, findings: [QCriticFinding], stages: QEvidenceStageReport) -> [QSynthesisCaveat] {
        var caveats: Set<QSynthesisCaveat> = []
        if pool.claims.isEmpty { caveats.insert(.noEvidence) }
        if pool.contradictions.contains(where: { !$0.isResolved }) { caveats.insert(.unresolvedContradiction) }
        if pool.claims.contains(where: { !pool.isSatisfied($0) && !isResolvedLoser($0, in: pool) }) { caveats.insert(.verificationIncomplete) }
        if stages.verification.compromisesCompleteness || pool.claims.contains(where: { $0.verification == .unavailable }) {
            caveats.insert(.verificationUnavailable)
        }
        if stages.critic.compromisesCompleteness { caveats.insert(.criticUnavailable) }
        if stages.collection.compromisesCompleteness { caveats.insert(.collectionIncomplete) }
        if stages.synthesis == .unavailable { caveats.insert(.synthesisUnavailable) }
        let all = [stages.collection, stages.verification, stages.critic, stages.synthesis]
        if all.contains(.timedOut) { caveats.insert(.stageTimedOut) }
        if all.contains(.cancelled) { caveats.insert(.stageCancelled) }
        if pool.isTainted { caveats.insert(.taintedSources) }
        if pool.items.contains(where: { $0.flags.contains(.instructionLikeContent) }) { caveats.insert(.instructionLikeEvidenceIgnored) }
        if pool.claims.contains(where: { $0.originKind == .modelGenerated && $0.trust == .untrusted }) { caveats.insert(.modelClaimsUnverified) }
        if !findings.isEmpty { caveats.insert(.criticFindingsPresent) }
        if pool.requirement == .independentVerification { caveats.insert(.independentVerificationRequired) }
        return caveats.sorted()
    }

    public static func uncertainty(for status: QSynthesisStatus, claimCount: Int) -> QDecisionUncertainty {
        guard claimCount > 0 else { return .unknown }
        switch status {
        case .sufficient: return .low
        case .partial: return .medium
        case .contradictory, .insufficient, .unavailable: return .high
        }
    }

    /// Display ordering: strongest standing first, contradicted last; ties by claim ID.
    static func displayRank(_ disposition: QStatementDisposition) -> Int {
        switch disposition {
        case .verified: return 0
        case .corroborated: return 1
        case .observed: return 2
        case .unresolved: return 3
        case .unverified: return 4
        case .contradicted: return 5
        }
    }
}

// MARK: - Deterministic Synthesizer

public struct QDeterministicEvidenceSynthesizer: QEvidenceSynthesizer {
    public init() {}

    public func synthesize(_ input: QSynthesisInput) async throws -> QSynthesisDraft {
        try Task.checkCancellation()
        let ordered = input.pool.claims.sorted { lhs, rhs in
            let lhsRank = QSynthesisPolicy.displayRank(QSynthesisPolicy.disposition(for: lhs))
            let rhsRank = QSynthesisPolicy.displayRank(QSynthesisPolicy.disposition(for: rhs))
            return lhsRank == rhsRank ? lhs.claimId < rhs.claimId : lhsRank < rhsRank
        }
        return QSynthesisDraft(
            orderedClaimIds: ordered.map { $0.claimId },
            proposedStatus: QSynthesisPolicy.baselineStatus(pool: input.pool, stages: input.stages)
        )
    }
}

// MARK: - Validator

public enum QSynthesisValidator {

    /// Turns an untrusted draft into a result the pool actually supports.
    public static func validate(_ draft: QSynthesisDraft, input: QSynthesisInput) -> QSynthesizedResult {
        let pool = input.pool
        var violations = 0
        var seen: Set<QClaimID> = []
        var orderedClaims: [QEvidenceClaim] = []

        for claimId in draft.orderedClaimIds {
            guard let claim = pool.claim(claimId) else { violations += 1; continue }   // invented claim
            if seen.insert(claimId).inserted { orderedClaims.append(claim) }
        }
        // A draft may not silently drop a claim — least of all one side of a conflict.
        for claim in pool.claims.sorted(by: { $0.claimId < $1.claimId }) where !seen.contains(claim.claimId) {
            orderedClaims.append(claim)
        }

        let contradictionIdByClaim: [QClaimID: String] = pool.contradictions.reduce(into: [:]) { partial, record in
            for claimId in record.claimIds { partial[claimId] = record.contradictionId }
        }

        var statements: [QSynthesisStatement] = []
        for claim in orderedClaims.prefix(QEvidenceLimits.maxStatements) {
            let authoritative = QSynthesisPolicy.disposition(for: claim)
            if let proposed = draft.proposedDispositions[claim.claimId], proposed != authoritative { violations += 1 }
            statements.append(
                QSynthesisStatement(
                    claimId: claim.claimId,
                    text: claim.proposition.renderedText,
                    disposition: authoritative,
                    evidenceIds: claim.sourceEvidenceIds,
                    contradictionId: contradictionIdByClaim[claim.claimId]
                )
            )
        }

        let baseline = QSynthesisPolicy.baselineStatus(pool: pool, stages: input.stages)
        let status: QSynthesisStatus
        if baseline == .contradictory {
            status = .contradictory
        } else if draft.proposedStatus == .unavailable {
            violations += 1
            status = baseline
        } else if draft.proposedStatus.rank > baseline.rank {
            violations += 1
            status = baseline
        } else {
            // A synthesizer may be MORE conservative than the pool supports, never less.
            status = draft.proposedStatus
        }

        let authoritativeCaveats = QSynthesisPolicy.caveats(pool: pool, findings: input.findings, stages: input.stages)
        let caveats = Set(authoritativeCaveats).union(draft.proposedCaveats).sorted()

        return QSynthesizedResult(
            taskId: pool.taskId,
            status: status,
            statements: statements,
            contradictions: pool.contradictions,
            findings: input.findings,
            caveats: caveats,
            uncertainty: QSynthesisPolicy.uncertainty(for: status, claimCount: pool.claims.count),
            requirement: pool.requirement,
            draftViolationCount: violations
        )
    }
}
