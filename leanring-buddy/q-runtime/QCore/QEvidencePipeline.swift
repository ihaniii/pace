//
//  QEvidencePipeline.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2C Evidence → Verification → Critic → Synthesis Pipeline.
//  Sits strictly AFTER the Phase 2B model orchestrator and after execution: it evaluates results,
//  it is never an execution path.
//
//      model results / candidate attempts / user facts / execution observations / retrieved drafts
//        → Evidence Pool (hash + bounded claims, trust computed by the pool)
//        → Independent Verification → Critic (validated) → Synthesis (validated)
//        → QEvidencePipelineResult (+ audit-safe `QEvidenceOutcomeMetadata`)
//
//  For execution tasks the authoritative chain is unchanged and does not pass through here:
//      model → proposed QPlan → QModelPlanSchema → capability registry → authoritative risk →
//      QPermissionGate → QResourceGuard → execution → observation → QActionVerifier.
//  Evidence, Critic and Synthesis can only EVALUATE what that chain produced. No type in this file
//  can grant permission, egress, resource, approval, execution, capability, or risk authority, and
//  none performs network or model I/O of its own — collector / verifier / critic / synthesizer
//  backends are injected protocols (model-backed ones would go through `QModelRouter`, whose
//  egress/availability checks stay authoritative).
//
//  Every stage is bounded (`QEvidenceLimits`), has a timeout, is cancellable, and is isolated: a
//  failing, slow, or cancelled stage yields a typed stage state and a partial result — never a
//  crash and never a manufactured verified answer. All async work runs in structured task groups;
//  nothing is detached, so nothing can be abandoned.
//
//  Phase 2D/2E extension point: `QEvidenceOutcomeMetadata` is the only thing intended to leave this
//  pipeline for later phases (candidate, task type, result/verification state, evidence
//  completeness, contradiction, user correction, resource outcome) — enums and counts only.
//

import Foundation

// MARK: - Inputs

/// Untrusted retrieval boundary. Implementations must honour cancellation and must not perform
/// egress except through `QEgressBroker`-mediated, already-authorised channels; the pipeline itself
/// performs no network I/O.
public protocol QEvidenceCollector: Sendable {
    func collect(taskId: String, limit: Int) async throws -> [QEvidenceDraft]
}

/// A model's textual output for one candidate/attempt. `outputText` is TRANSIENT: hashed and mined
/// for claims, never stored.
public struct QEvidenceModelResult: Sendable {
    public let attemptId: QModelAttemptID?
    public let candidateId: QModelCandidateID?
    public let backend: QModelBackendType?
    public let outputText: String

    public init(attemptId: QModelAttemptID? = nil, candidateId: QModelCandidateID? = nil, backend: QModelBackendType? = nil, outputText: String) {
        self.attemptId = attemptId
        self.candidateId = candidateId
        self.backend = backend
        self.outputText = outputText
    }
}

/// A fact Q's own machinery observed (execution) or computed deterministically (check). Only
/// trusted-system plumbing should construct these; a model can never reach this type.
public struct QEvidenceObservation: Sendable {
    public let sourceId: String
    public let subject: String
    public let value: String
    public let kind: QEvidenceSourceKind

    public init(sourceId: String, subject: String, value: String, kind: QEvidenceSourceKind = .executionObserved) {
        self.sourceId = sourceId
        self.subject = subject
        self.value = value
        self.kind = kind
    }
}

public struct QUserProvidedFact: Sendable {
    public let sourceId: String
    public let subject: String
    public let value: String

    public init(sourceId: String, subject: String, value: String) {
        self.sourceId = sourceId
        self.subject = subject
        self.value = value
    }
}

public struct QEvidencePipelineInput: Sendable {
    public let taskId: String
    public let decisionPlan: QDecisionPlan
    public let modelResults: [QEvidenceModelResult]
    public let candidateAttempts: [QModelAttempt]
    public let observations: [QEvidenceObservation]
    public let userFacts: [QUserProvidedFact]
    public let collector: (any QEvidenceCollector)?
    public let userCorrectionObserved: Bool

    public init(
        taskId: String,
        decisionPlan: QDecisionPlan,
        modelResults: [QEvidenceModelResult] = [],
        candidateAttempts: [QModelAttempt] = [],
        observations: [QEvidenceObservation] = [],
        userFacts: [QUserProvidedFact] = [],
        collector: (any QEvidenceCollector)? = nil,
        userCorrectionObserved: Bool = false
    ) {
        self.taskId = taskId
        self.decisionPlan = decisionPlan
        self.modelResults = modelResults
        self.candidateAttempts = candidateAttempts
        self.observations = observations
        self.userFacts = userFacts
        self.collector = collector
        self.userCorrectionObserved = userCorrectionObserved
    }
}

// MARK: - Requirement Policy

extension QVerificationRequirement {
    var strength: Int {
        switch self {
        case .none: return 0
        case .executionEvidence: return 1
        case .independentVerification: return 2
        }
    }
}

public enum QEvidenceRequirementPolicy {
    /// The requirement the pool enforces: never weaker than the Decision Plan asked for, and never
    /// weaker than independent verification for critical / high-risk work. Nothing in Phase 2C can
    /// lower it afterwards.
    public static func effectiveRequirement(for decisionPlan: QDecisionPlan) -> QVerificationRequirement {
        let isHighRisk = decisionPlan.taskType == .criticalHighRisk || decisionPlan.complexity == .critical
        let floor: QVerificationRequirement = isHighRisk ? .independentVerification : .none
        return decisionPlan.verificationRequirement.strength >= floor.strength ? decisionPlan.verificationRequirement : floor
    }
}

// MARK: - Phase 2B Bridge

public enum QEvidenceIngestion {
    /// Turns a Phase 2B attempt into an evidence item carrying IDENTITY AND OUTCOME ONLY — never
    /// the candidate's plan or any model text. Candidate → attempt → result stays a separate
    /// lineage from evidence → claim → verification → synthesis; `QEvidenceOrigin` is the bridge.
    static func draft(for attempt: QModelAttempt, taskId: String) -> QEvidenceDraft {
        let verification: QEvidenceVerificationState
        switch attempt.outcome {
        case .accepted, .needsVerification: verification = .pending
        case .verificationFailed: verification = .contradicted
        case .rejected, .invalid, .timedOut, .cancelled, .unavailable: verification = .unavailable
        }
        return QEvidenceDraft(
            taskId: taskId,
            sourceId: attempt.attemptId.rawValue,
            kind: .modelGenerated,
            provenance: .untrustedTool(toolName: "model:\(attempt.backend.rawValue)"),
            origin: QEvidenceOrigin(attemptId: attempt.attemptId, candidateId: attempt.candidateId, backend: attempt.backend),
            content: "attempt:\(attempt.attemptId.rawValue):\(attempt.outcome.auditLabel)",
            metadata: ["outcome": attempt.outcome.auditLabel, "backend": attempt.backend.rawValue],
            initialVerification: verification
        )
    }
}

// MARK: - Result

public enum QEvidenceCompleteness: String, Codable, Sendable, Equatable {
    case none
    case partial
    case complete
}

/// The audit-safe, Phase-2D/2E-facing outcome record. Enums and counts ONLY — no claim text, no
/// evidence text, no prompts, no responses, no URLs, no locators. This is the only Codable type in
/// Phase 2C that carries outcome data (the other two are opaque ID wrappers).
public struct QEvidenceOutcomeMetadata: Codable, Sendable, Equatable {
    public let taskType: String
    public let complexity: String
    public let requirement: String
    public let synthesisStatus: String
    public let uncertainty: String
    public let evidenceCompleteness: QEvidenceCompleteness
    public let evidenceCount: Int
    public let claimCount: Int
    public let verifiedClaimCount: Int
    public let unresolvedClaimCount: Int
    public let contradictedClaimCount: Int
    public let contradictionCount: Int
    public let unresolvedContradictionCount: Int
    public let rejectedInputCount: Int
    public let criticFindingCount: Int
    public let draftViolationCount: Int
    public let collectionStage: String
    public let verificationStage: String
    public let criticStage: String
    public let synthesisStage: String
    public let candidateBackends: [String]
    public let candidateVerificationStates: [String: String]
    public let resourceOutcome: String
    public let userCorrection: String
    public let isTainted: Bool

    /// Flat string payload for `QTaskLifecycleEvent`. Every value is an enum raw value, a count, or
    /// a boolean.
    public var auditPayload: [String: String] {
        [
            "taskType": taskType,
            "complexity": complexity,
            "requirement": requirement,
            "synthesisStatus": synthesisStatus,
            "uncertainty": uncertainty,
            "evidenceCompleteness": evidenceCompleteness.rawValue,
            "evidenceCount": "\(evidenceCount)",
            "claimCount": "\(claimCount)",
            "verifiedClaimCount": "\(verifiedClaimCount)",
            "unresolvedClaimCount": "\(unresolvedClaimCount)",
            "contradictedClaimCount": "\(contradictedClaimCount)",
            "contradictionCount": "\(contradictionCount)",
            "unresolvedContradictionCount": "\(unresolvedContradictionCount)",
            "rejectedInputCount": "\(rejectedInputCount)",
            "criticFindingCount": "\(criticFindingCount)",
            "draftViolationCount": "\(draftViolationCount)",
            "collectionStage": collectionStage,
            "verificationStage": verificationStage,
            "criticStage": criticStage,
            "synthesisStage": synthesisStage,
            "candidateBackends": candidateBackends.joined(separator: ","),
            "resourceOutcome": resourceOutcome,
            "userCorrection": userCorrection,
            "tainted": "\(isTainted)"
        ]
    }
}

public struct QEvidencePipelineResult: Sendable, Equatable {
    public let pool: QEvidencePool
    public let findings: [QCriticFinding]
    public let criticRejectedFindingCount: Int
    public let stages: QEvidenceStageReport
    /// `nil` only when the run was cancelled before synthesis could run.
    public let synthesis: QSynthesizedResult?
    public let metadata: QEvidenceOutcomeMetadata
}

// MARK: - Pipeline

public struct QEvidencePipeline: Sendable {
    public let extractor: any QClaimExtractor
    public let verificationService: QIndependentVerificationService
    public let critic: any QEvidenceCritic
    public let synthesizer: any QEvidenceSynthesizer
    public let collectionTimeout: TimeInterval
    public let verificationTimeout: TimeInterval
    public let criticTimeout: TimeInterval
    public let synthesisTimeout: TimeInterval

    public init(
        extractor: any QClaimExtractor = QDeterministicClaimExtractor(),
        verificationService: QIndependentVerificationService = QIndependentVerificationService(backends: [QExecutionEvidenceVerificationBackend()]),
        critic: any QEvidenceCritic = QDeterministicEvidenceCritic(),
        synthesizer: any QEvidenceSynthesizer = QDeterministicEvidenceSynthesizer(),
        collectionTimeout: TimeInterval = 10,
        verificationTimeout: TimeInterval = 20,
        criticTimeout: TimeInterval = 5,
        synthesisTimeout: TimeInterval = 5
    ) {
        self.extractor = extractor
        self.verificationService = verificationService
        self.critic = critic
        self.synthesizer = synthesizer
        self.collectionTimeout = collectionTimeout
        self.verificationTimeout = verificationTimeout
        self.criticTimeout = criticTimeout
        self.synthesisTimeout = synthesisTimeout
    }

    public func run(_ input: QEvidencePipelineInput) async -> QEvidencePipelineResult {
        var pool = QEvidencePool(taskId: input.taskId, requirement: QEvidenceRequirementPolicy.effectiveRequirement(for: input.decisionPlan))
        var stages = QEvidenceStageReport()
        var findings: [QCriticFinding] = []
        var criticRejected = 0
        var synthesis: QSynthesizedResult?
        var resourceOutcome = "completed"

        ingestLocalInputs(input, into: &pool)

        // 1. Collection (untrusted retrieval — bounded, cancellable, failure-isolated).
        if let collector = input.collector {
            let remainingCapacity = max(QEvidenceLimits.maxEvidenceItems - pool.items.count, 0)
            let taskId = input.taskId
            let outcome = await QEvidenceAsync.run(timeout: collectionTimeout) {
                try await collector.collect(taskId: taskId, limit: remainingCapacity)
            }
            switch outcome {
            case .value(let drafts):
                for draft in drafts.prefix(QEvidenceLimits.maxEvidenceItems) { pool.ingest(draft, extractor: extractor) }
                stages.collection = .completed
            case .timedOut: stages.collection = .timedOut
            case .failed: stages.collection = .unavailable
            case .cancelled: stages.collection = .cancelled
            }
        } else {
            stages.collection = .skipped
        }

        // 2. Independent verification.
        if stages.collection == .cancelled || Task.isCancelled {
            stages.verification = .skipped
        } else if pool.claims.contains(where: { $0.verificationRequired || $0.contradiction == .conflicting }) {
            let snapshot = pool
            let service = verificationService
            let outcome = await QEvidenceAsync.run(timeout: verificationTimeout) { await service.verify(pool: snapshot) }
            switch outcome {
            case .value(let run):
                pool.applyVerification(run.records)
                stages.verification = run.wasCancelled ? .cancelled : .completed
            case .timedOut: stages.verification = .timedOut
            case .failed: stages.verification = .unavailable
            case .cancelled: stages.verification = .cancelled
            }
        } else {
            stages.verification = .skipped
        }

        // 3. Critic (one pass; output untrusted until validated).
        if stages.collection == .cancelled || stages.verification == .cancelled || Task.isCancelled {
            stages.critic = .skipped
        } else {
            let snapshot = pool
            let reviewer = critic
            let outcome = await QEvidenceAsync.run(timeout: criticTimeout) { try await reviewer.critique(pool: snapshot) }
            switch outcome {
            case .value(let proposed):
                let validation = QCriticValidator.validate(proposed, against: pool)
                findings = validation.accepted
                criticRejected = validation.rejectedCount
                stages.critic = .completed
            case .timedOut: stages.critic = .timedOut
            case .failed: stages.critic = .unavailable
            case .cancelled: stages.critic = .cancelled
            }
        }

        // 4. Synthesis (one attempt, no retries; validated against the pool).
        let cancelledEarlier = [stages.collection, stages.verification, stages.critic].contains(.cancelled) || Task.isCancelled
        if cancelledEarlier {
            stages.synthesis = .skipped
            resourceOutcome = "cancelled"
        } else {
            let synthesisInput = QSynthesisInput(pool: pool, findings: findings, stages: stages)
            let composer = synthesizer
            let outcome = await QEvidenceAsync.run(timeout: synthesisTimeout) { try await composer.synthesize(synthesisInput) }
            switch outcome {
            case .value(let draft):
                synthesis = QSynthesisValidator.validate(draft, input: synthesisInput)
                stages.synthesis = .completed
            case .timedOut:
                stages.synthesis = .timedOut
                synthesis = QSynthesizedResult.unavailable(taskId: input.taskId, requirement: pool.requirement)
            case .failed:
                stages.synthesis = .unavailable
                synthesis = QSynthesizedResult.unavailable(taskId: input.taskId, requirement: pool.requirement)
            case .cancelled:
                stages.synthesis = .cancelled
                resourceOutcome = "cancelled"
            }
        }
        if resourceOutcome == "completed", [stages.collection, stages.verification, stages.critic, stages.synthesis].contains(.timedOut) {
            resourceOutcome = "timedOut"
        }

        let metadata = Self.makeMetadata(
            input: input,
            pool: pool,
            findings: findings,
            stages: stages,
            synthesis: synthesis,
            resourceOutcome: resourceOutcome
        )
        return QEvidencePipelineResult(
            pool: pool,
            findings: findings,
            criticRejectedFindingCount: criticRejected,
            stages: stages,
            synthesis: synthesis,
            metadata: metadata
        )
    }

    // MARK: Local (already-in-hand) inputs

    private func ingestLocalInputs(_ input: QEvidencePipelineInput, into pool: inout QEvidencePool) {
        for fact in input.userFacts {
            let draft = QEvidenceDraft(
                taskId: input.taskId,
                sourceId: fact.sourceId,
                kind: .userProvided,
                provenance: .trustedUser(channel: "evidence"),
                content: "\(fact.subject): \(fact.value)"
            )
            addStructuredClaim(draft: draft, subject: fact.subject, value: fact.value, into: &pool)
        }

        for observation in input.observations {
            // Only the two model-independent kinds are legitimate here; anything else is a caller
            // bug and is rejected by the pool's provenance/kind consistency check.
            let provenance: QProvenanceKind = observation.kind == .deterministicCheck ? .trustedLocal : .trustedSystem
            let draft = QEvidenceDraft(
                taskId: input.taskId,
                sourceId: observation.sourceId,
                kind: observation.kind,
                provenance: provenance,
                content: "\(observation.subject): \(observation.value)"
            )
            addStructuredClaim(draft: draft, subject: observation.subject, value: observation.value, into: &pool)
        }

        for attempt in input.candidateAttempts {
            pool.addEvidence(QEvidenceIngestion.draft(for: attempt, taskId: input.taskId))
        }

        for (index, result) in input.modelResults.enumerated() {
            let sourceId = result.attemptId?.rawValue ?? "model-output-\(index)"
            let backendLabel = result.backend?.rawValue ?? "unknown"
            let draft = QEvidenceDraft(
                taskId: input.taskId,
                sourceId: sourceId,
                kind: .modelGenerated,
                provenance: .untrustedTool(toolName: "model:\(backendLabel)"),
                origin: QEvidenceOrigin(attemptId: result.attemptId, candidateId: result.candidateId, backend: result.backend),
                content: result.outputText
            )
            pool.ingest(draft, extractor: extractor)
        }
    }

    private func addStructuredClaim(draft: QEvidenceDraft, subject: String, value: String, into pool: inout QEvidencePool) {
        guard let proposition = QClaimProposition(subject: subject, value: value) else { return }
        switch pool.addEvidence(draft) {
        case .added(let evidenceId), .duplicate(let evidenceId):
            pool.addClaim(proposition: proposition, originEvidenceId: evidenceId)
        case .rejected:
            break
        }
    }

    // MARK: Metadata

    private static func makeMetadata(
        input: QEvidencePipelineInput,
        pool: QEvidencePool,
        findings: [QCriticFinding],
        stages: QEvidenceStageReport,
        synthesis: QSynthesizedResult?,
        resourceOutcome: String
    ) -> QEvidenceOutcomeMetadata {
        let completeness: QEvidenceCompleteness
        if pool.claims.isEmpty {
            completeness = .none
        } else if synthesis?.status == .sufficient {
            completeness = .complete
        } else {
            completeness = .partial
        }

        var backends: [String] = []
        var candidateStates: [String: String] = [:]
        for item in pool.items {
            guard let origin = item.source.origin else { continue }
            if let backend = origin.backend, !backends.contains(backend.rawValue) { backends.append(backend.rawValue) }
            if let candidateId = origin.candidateId { candidateStates[candidateId.rawValue] = item.verification.rawValue }
        }

        return QEvidenceOutcomeMetadata(
            taskType: input.decisionPlan.taskType.rawValue,
            complexity: input.decisionPlan.complexity.rawValue,
            requirement: pool.requirement.rawValue,
            synthesisStatus: synthesis?.status.rawValue ?? "cancelled",
            uncertainty: synthesis?.uncertainty.rawValue ?? QDecisionUncertainty.unknown.rawValue,
            evidenceCompleteness: completeness,
            evidenceCount: pool.items.count,
            claimCount: pool.claims.count,
            verifiedClaimCount: pool.claims.filter { $0.status == .verified }.count,
            unresolvedClaimCount: pool.claims.filter { $0.status == .unresolved || $0.status == .unverified }.count,
            contradictedClaimCount: pool.claims.filter { $0.status == .contradicted }.count,
            contradictionCount: pool.contradictions.count,
            unresolvedContradictionCount: pool.contradictions.filter { !$0.isResolved }.count,
            rejectedInputCount: pool.totalRejections,
            criticFindingCount: findings.count,
            draftViolationCount: synthesis?.draftViolationCount ?? 0,
            collectionStage: stages.collection.rawValue,
            verificationStage: stages.verification.rawValue,
            criticStage: stages.critic.rawValue,
            synthesisStage: stages.synthesis.rawValue,
            candidateBackends: backends,
            candidateVerificationStates: candidateStates,
            resourceOutcome: resourceOutcome,
            userCorrection: input.userCorrectionObserved ? "observed" : "notObserved",
            isTainted: pool.isTainted
        )
    }
}
