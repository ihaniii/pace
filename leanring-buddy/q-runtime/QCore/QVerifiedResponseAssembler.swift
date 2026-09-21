//
//  QVerifiedResponseAssembler.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 3 (Verified Response Path), first slice: the deterministic
//  verified-response assembler and renderer.
//
//      Evidence Pool (+ critic findings, stage state)
//        → QVerifiedResponseAssembler  → QVerifiedResponse   (references + standing, no text)
//        → QVerifiedResponseRenderer   → QRenderedResponse   (deterministic lines, transient)
//
//  Deliberately boring, explicit, and auditable:
//   - NO model call and NO paraphrase. Statement text is rendered from the pool's own claim
//     (`QClaimProposition.renderedText`) with a fixed label per standing; nothing is generated, so
//     nothing can be invented. There is no scoring of any kind (no length, lexical overlap,
//     formatting, token count, or confidence number);
//   - there is exactly ONE trust system: this file never computes trust. Standing, status, caveats
//     and uncertainty come from the existing `QSynthesisPolicy` (the same derivation Phase 2C uses),
//     re-run against the pool — a caller-supplied synthesis result is never trusted;
//   - fail closed: a statement whose claim or evidence references are empty or do not resolve in the
//     pool is DROPPED (never rendered as fact) and counted; with no valid statement the response is
//     `insufficient` and renders an explicit "no evidence-backed statements" line — missing evidence
//     never becomes prose;
//   - the assembler takes the pool BY VALUE and cannot mutate it: critic findings only add a caveat,
//     they never promote trust; citations, repetition, authority language, and model confidence have
//     no input path at all (the pool already ignores them);
//   - critical / high-risk work keeps its mandatory requirement: the requirement lives on the pool
//     (fixed at construction from the Decision Plan) and `QSynthesisPolicy` enforces it;
//   - informational only. Nothing here executes, approves, authorizes, or touches any authority.
//

import Foundation

// MARK: - Assembler

public enum QVerifiedResponseAssembler {

    /// Assembles from a finished pipeline run (uses its pool, findings, and stage state — NOT its
    /// `synthesis` value, which is recomputed from the pool by the same policy).
    public static func assemble(from result: QEvidencePipelineResult, now: Date) -> QVerifiedResponse {
        assemble(pool: result.pool, findings: result.findings, stages: result.stages, now: now)
    }

    public static func assemble(
        pool: QEvidencePool,
        findings: [QCriticFinding] = [],
        stages: QEvidenceStageReport = QEvidenceStageReport(),
        now: Date
    ) -> QVerifiedResponse {
        assemble(pool: pool, claims: pool.claims, findings: findings, stages: stages, now: now)
    }

    /// The claims to project are a separate input ONLY so the fail-closed reference check can be
    /// exercised with a claim whose evidence does not resolve (the pool's own API cannot produce
    /// one). Public entry points always pass `pool.claims`.
    static func assemble(
        pool: QEvidencePool,
        claims: [QEvidenceClaim],
        findings: [QCriticFinding],
        stages: QEvidenceStageReport,
        now: Date
    ) -> QVerifiedResponse {
        // Same display order Phase 2C's synthesizer uses: strongest standing first, ties by claim ID.
        let orderedClaims = claims.sorted { lhs, rhs in
            let lhsRank = QSynthesisPolicy.displayRank(QSynthesisPolicy.disposition(for: lhs))
            let rhsRank = QSynthesisPolicy.displayRank(QSynthesisPolicy.disposition(for: rhs))
            return lhsRank == rhsRank ? lhs.claimId < rhs.claimId : lhsRank < rhsRank
        }

        let contradictionIdByClaim: [QClaimID: String] = pool.contradictions.reduce(into: [:]) { partial, record in
            for claimId in record.claimIds { partial[claimId] = record.contradictionId }
        }

        var statements: [QVerifiedResponseStatement] = []
        var rejected = 0
        for claim in orderedClaims.prefix(QEvidenceLimits.maxStatements) {
            guard hasResolvableEvidence(claim, in: pool) else {
                rejected += 1
                continue
            }
            statements.append(
                QVerifiedResponseStatement(
                    claimId: claim.claimId.rawValue,
                    evidenceIds: supportingEvidenceIds(for: claim, in: pool).map { $0.rawValue },
                    standing: QResponseStanding(QSynthesisPolicy.disposition(for: claim)),
                    trust: QResponseTrust(claim.trust),
                    verification: QResponseVerification(claim.verification),
                    contradiction: QResponseContradictionState(claim.contradiction),
                    contradictionId: contradictionIdByClaim[claim.claimId],
                    sourceKind: claim.originKind.rawValue,
                    memoryWriteBackEligible: isWriteBackEligible(claim, in: pool)
                )
            )
        }
        rejected += max(claims.count - QEvidenceLimits.maxStatements, 0)

        // Status/caveats/uncertainty: the existing policy, re-run against the pool.
        var synthesisStatus = QSynthesisPolicy.baselineStatus(pool: pool, stages: stages)
        if statements.isEmpty {
            synthesisStatus = .insufficient
        } else if rejected > 0, synthesisStatus == .sufficient {
            synthesisStatus = .partial   // something was dropped, so this cannot be called complete
        }

        var caveats = QSynthesisPolicy.caveats(pool: pool, findings: findings, stages: stages).map { $0.rawValue }
        if rejected > 0 { caveats.append(QVerifiedResponse.invalidReferencesCaveat) }

        let contradictions = pool.contradictions.map { record in
            QVerifiedResponseContradiction(
                contradictionId: record.contradictionId,
                claimIds: record.claimIds.map { $0.rawValue },
                isResolved: record.isResolved
            )
        }

        let completeness: QEvidenceCompleteness
        if statements.isEmpty {
            completeness = .none
        } else {
            completeness = synthesisStatus == .sufficient ? .complete : .partial
        }

        return QVerifiedResponse(
            schemaVersion: QVerifiedResponse.currentSchemaVersion,
            renderingVersion: QVerifiedResponseRenderer.renderingVersion,
            status: QVerifiedResponseStatus(synthesisStatus),
            statements: statements,
            contradictions: contradictions,
            caveats: caveats,
            completeness: completeness,
            uncertainty: QSynthesisPolicy.uncertainty(for: synthesisStatus, claimCount: statements.count),
            requirement: pool.requirement,
            provenance: QVerifiedResponseProvenance(
                taskId: pool.taskId,
                assembledAt: now,
                sourceKinds: Array(Set(statements.map { $0.sourceKind })).sorted(),
                isTainted: pool.isTainted,
                rejectedStatementCount: rejected
            )
        )
    }

    // MARK: Reference validation

    /// A statement is only assemblable if it cites at least one evidence item and EVERY cited ID
    /// resolves in the pool. Empty or dangling references fail closed.
    static func hasResolvableEvidence(_ claim: QEvidenceClaim, in pool: QEvidencePool) -> Bool {
        guard !claim.claimId.rawValue.isEmpty, !claim.sourceEvidenceIds.isEmpty else { return false }
        return claim.sourceEvidenceIds.allSatisfy { !$0.rawValue.isEmpty && pool.item($0) != nil }
    }

    /// The claim's own source evidence first, then the evidence items of any model-INDEPENDENT
    /// claims (execution observations / deterministic checks) that assert the same proposition —
    /// i.e. the evidence that actually established it. Deterministic order, bounded, and every ID
    /// comes from an item that exists in the pool.
    static func supportingEvidenceIds(for claim: QEvidenceClaim, in pool: QEvidencePool) -> [QEvidenceID] {
        var ids = claim.sourceEvidenceIds
        let supporters = pool.claims
            .filter {
                $0.claimId != claim.claimId
                    && $0.originKind.isIndependentOfModels
                    && $0.proposition.subjectKey == claim.proposition.subjectKey
                    && $0.proposition.normalizedValueHash == claim.proposition.normalizedValueHash
            }
            .flatMap { $0.sourceEvidenceIds }
            .filter { pool.item($0) != nil }
            .sorted { $0.rawValue < $1.rawValue }
        for id in supporters where !ids.contains(id) { ids.append(id) }
        return Array(ids.prefix(QVerifiedMemoryLimits.maxEvidenceIdsPerProposition))
    }

    // MARK: Write-back eligibility (the one predicate; the writer re-applies it independently)

    /// Eligible only if the pool independently verified the claim with a truth-establishing basis,
    /// the pool's own requirement is satisfied, nothing conflicts, every evidence reference resolves,
    /// and the content passes the URL/credential/instruction screen. Observed, corroborated,
    /// unresolved, unverified, and contradicted claims are NEVER eligible.
    static func isWriteBackEligible(_ claim: QEvidenceClaim, in pool: QEvidencePool) -> Bool {
        guard claim.trust == .independentlyVerified,
              claim.verification == .verified,
              claim.verifiedBasis?.canEstablishTruth == true,
              claim.contradiction != .conflicting,
              pool.isSatisfied(claim),
              hasResolvableEvidence(claim, in: pool) else {
            return false
        }
        return QVerifiedPropositionScreen.rejection(subject: claim.proposition.subjectKey, value: claim.proposition.value) == nil
    }
}

// MARK: - Renderer

public enum QVerifiedResponseRenderer {

    /// Bump when the deterministic output format below changes.
    public static let renderingVersion = 1

    /// Fixed sentences for the caveat vocabulary. An unknown caveat string is not rendered (fail closed).
    private static let caveatSentences: [String: String] = [
        "noEvidence": "No evidence was available.",
        "unresolvedContradiction": "Some claims conflict and are not settled; all positions are shown.",
        "verificationIncomplete": "Some claims are not verified to the required standard.",
        "verificationUnavailable": "Independent verification was unavailable for some claims.",
        "criticUnavailable": "The critic was unavailable.",
        "collectionIncomplete": "Evidence collection was incomplete.",
        "synthesisUnavailable": "Synthesis was unavailable.",
        "stageTimedOut": "A processing stage timed out.",
        "stageCancelled": "A processing stage was cancelled.",
        "taintedSources": "Some sources are untrusted.",
        "instructionLikeEvidenceIgnored": "Instruction-like text in the evidence was ignored.",
        "modelClaimsUnverified": "Some model-produced claims are not verified.",
        "criticFindingsPresent": "The critic raised concerns (advisory only).",
        "independentVerificationRequired": "This task requires independent verification.",
        QVerifiedResponse.invalidReferencesCaveat: "Some statements were dropped because their evidence references were invalid."
    ]

    private static func label(for standing: QResponseStanding) -> String {
        switch standing {
        case .verified: return "VERIFIED"
        case .corroborated: return "CORROBORATED — not independently verified"
        case .observed: return "OBSERVED — not independently verified"
        case .unverified: return "UNVERIFIED — not established"
        case .unresolved: return "UNRESOLVED"
        case .contradicted: return "CONTRADICTED"
        }
    }

    /// Joins the content-free response back to claim text held in `pool`. Deterministic: the same
    /// response and pool always render the same lines. A statement whose claim is missing from the
    /// pool renders an explicit unavailable line — never invented text.
    public static func render(_ response: QVerifiedResponse, pool: QEvidencePool) -> QRenderedResponse {
        var lines: [String] = [
            "Status: \(response.status.rawValue) · uncertainty: \(response.uncertainty.rawValue) · completeness: \(response.completeness.rawValue)"
        ]

        if response.statements.isEmpty {
            lines.append("No evidence-backed statements are available.")
        }

        for statement in response.statements {
            let evidenceList = statement.evidenceIds.joined(separator: ", ")
            if let claim = pool.claim(QClaimID(rawValue: statement.claimId)) {
                let conflict = statement.contradictionId.map { " [conflict \($0)]" } ?? ""
                lines.append("[\(label(for: statement.standing))] \(claim.proposition.renderedText)\(conflict) (evidence: \(evidenceList))")
            } else {
                lines.append("[UNAVAILABLE] Statement \(statement.claimId) could not be resolved to evidence. (evidence: \(evidenceList))")
            }
        }

        for contradiction in response.contradictions {
            lines.append("Conflict \(contradiction.contradictionId): \(contradiction.isResolved ? "settled by independent verification" : "unresolved — every position is shown above").")
        }

        for caveat in response.caveats {
            if let sentence = caveatSentences[caveat] { lines.append("Caveat: \(sentence)") }
        }
        return QRenderedResponse(response: response, lines: lines)
    }
}
