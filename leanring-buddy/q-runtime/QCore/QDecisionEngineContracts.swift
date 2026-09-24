//
//  QDecisionEngineContracts.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2A.1 Contracts Only.
//  Defines the additive data contracts a future Decision Engine and Task Decomposer will produce
//  and consume. This file contains DATA ONLY — no engine, no decomposer, no runtime integration.
//
//  These contracts describe DECISION INTENT, never authority:
//   - they never execute a task;
//   - they never select a concrete model provider or backend (that remains QModelRouter's job —
//     "which available model/backend should execute inference?" is unchanged and untouched here);
//   - they never grant a permission, capability, or resource scope (QCapability/QPermissionGate
//     remain the sole source of that authority);
//   - they never authorize network/cloud egress (the on-device moat and its egress enforcement
//     are untouched);
//   - they never override QResourceGuard's path-jail/denylist enforcement;
//   - they never weaken or bypass QActionVerifier's real, execution-level verification;
//   - they carry no model-capability scores, context-window sizes, or provider identifiers — see
//     QModelRouter.swift's QModelBackendType/QModelCapabilities for that, which this deliberately
//     does not duplicate.
//
//  A future Decision Engine answers "what kind of task is this, how complex is it, does it need
//  decomposition, what execution strategy is appropriate, what verification/provenance/resource
//  requirements apply?" — a strictly higher-level, provider-independent question than QModelRouter
//  already answers today. Nothing in this file changes QModelRouter, QCoreRuntime, QPlanExecutor,
//  QPermissionGate, QResourceGuard, QActionVerifier, or QEgressBroker; nothing here is wired into
//  the runtime yet. See docs/architecture/decisions/ for the ADR this phase corresponds to, if one
//  is added.
//

import Foundation

// MARK: - Task Classification

/// A coarse classification of what kind of task is being requested — DATA describing intent, not
/// an instruction to execute anything. Extensible: new cases may be added in a later phase, but
/// none are speculatively pre-added here beyond what Phase 2A.1 actually needs to describe.
public enum QTaskType: String, Codable, Sendable, Equatable, CaseIterable {
    case simpleQA
    case reasoning
    case coding
    case research
    case planning
    case creative
    case execution
    case criticalHighRisk
}

// MARK: - Task Complexity

/// A qualitative complexity classification. Deliberately NOT a numeric "intelligence" or
/// complexity score — this project's security architecture does not fabricate confidence numbers
/// it cannot actually measure (see `QDecisionUncertainty` below for the same principle applied to
/// uncertainty). A future Decision Engine reasons about complexity in these coarse bands only.
public enum QTaskComplexity: String, Codable, Sendable, Equatable, CaseIterable {
    case trivial
    case simple
    case moderate
    case complex
    case critical
}

// MARK: - Decomposition Decision

/// Whether a task should be broken into subtasks by a future Task Decomposer, and — when it
/// should — the explicit maximum number of subtasks that decomposition may ever produce. Every
/// case that implies decomposition carries its own bound; there is no case that permits unbounded
/// subtask generation. This describes a DECISION, not an execution — no subtasks are created by
/// this type itself.
public enum QDecompositionDecision: Codable, Sendable, Equatable {
    /// The task should be executed as a single unit; no decomposition is proposed.
    case notRequired
    /// Decomposition would likely help, but is not mandatory. `maximumSubtasks` is the explicit,
    /// non-negotiable ceiling on how many subtasks any decomposition attempt may produce.
    case recommended(maximumSubtasks: Int)
    /// Decomposition is required before execution can proceed. `maximumSubtasks` is the explicit,
    /// non-negotiable ceiling on how many subtasks any decomposition attempt may produce.
    case required(maximumSubtasks: Int)

    /// The explicit subtask bound this decision carries, or `nil` when no decomposition (and
    /// therefore no subtask count) applies at all.
    public var maximumSubtasks: Int? {
        switch self {
        case .notRequired:
            return nil
        case .recommended(let maximumSubtasks), .required(let maximumSubtasks):
            return maximumSubtasks
        }
    }
}

// MARK: - Model Execution Strategy (provider-independent)

/// The conceptual EXECUTION STRATEGY a decision calls for — never a concrete model provider,
/// backend, or model identifier. Answering "which available model/backend should execute
/// inference?" for a given strategy remains QModelRouter's job entirely; this type is not
/// consulted by, and does not change, QModelRouter today. Deliberately excludes model racing,
/// ensembles, consortiums, critics, early-exit, parallel models, or provider-specific names —
/// those are explicitly out of scope for Phase 2A.1.
public enum QModelStrategy: String, Codable, Sendable, Equatable, CaseIterable {
    /// A single local model handles the task end to end.
    case singleLocalModel
    /// A local model specialized/prompted for multi-step reasoning is appropriate.
    case localReasoningModel
    /// A local model specialized/prompted for structured planning is appropriate.
    case localPlannerModel
}

// MARK: - Verification Requirement (decision-level intent only)

/// The decision-level request for how much independent verification a task's execution should
/// receive. This is only a REQUESTED strategy-level preference — it can never weaken, bypass, or
/// substitute for `QActionVerifier`'s real, mandatory, execution-level closed-loop verification,
/// which is untouched by this type and remains authoritative regardless of what a decision plan
/// requests here.
public enum QVerificationRequirement: String, Codable, Sendable, Equatable, CaseIterable {
    /// No additional decision-level verification is being requested beyond whatever the executed
    /// capability's own mandatory verification already performs.
    case none
    /// The decision calls for the execution's own evidence (e.g. a capability's normal
    /// closed-loop check) to be present before the task is considered complete.
    case executionEvidence
    /// The decision calls for verification independent of the acting capability's own report.
    case independentVerification
}

// MARK: - Provenance Requirement (decision-level intent only)

/// Whether a decision requires provenance tracking to be present for the task's inputs. This
/// does not implement provenance tracking itself and is not a second provenance system — the
/// existing `QProvenanceKind`/`QProvenanceTag`/`QTaskContext` model (see `QProvenance.swift`)
/// remains the sole, authoritative implementation. This type only records the decision-level
/// intent of whether provenance is expected to be present.
public enum QProvenanceRequirement: String, Codable, Sendable, Equatable, CaseIterable {
    case notRequired
    case required
}

// MARK: - Decision-Level Resource Envelope (intent only — not a second Resource Guard)

/// A deliberately small, bounded description of resource INTENT for a decision — never a second
/// enforcement mechanism. `QResourceGuard` (filesystem path-jail/denylist enforcement) and
/// `QAgentBudget` (the live, stateful, enforced step/replan/duration budget `QCoreRuntime` already
/// consults) remain the sole enforcement authorities; this type is not consulted by either today
/// and grants nothing by existing. Reasoning-step budget intentionally lives on `QDecisionPlan`
/// directly (see below), not duplicated here, since it is the single most frequently consulted
/// bound and deserves top-level visibility on the decision artifact itself.
public struct QDecisionResourceEnvelope: Codable, Sendable, Equatable {
    /// The explicit, non-negotiable ceiling on subtasks this decision's resource intent allows —
    /// independent of (and never looser than) whatever `QDecompositionDecision.maximumSubtasks`
    /// a specific decomposition strategy proposes.
    public let maximumSubtasks: Int
    /// Whether this decision's execution intent may run in the background (e.g. without holding
    /// up an interactive turn) at all. Does not itself authorize anything — real background
    /// execution remains subject to every existing permission/resource/verification gate.
    public let allowsBackgroundExecution: Bool

    public init(
        maximumSubtasks: Int = 0,
        allowsBackgroundExecution: Bool = false
    ) {
        self.maximumSubtasks = maximumSubtasks
        self.allowsBackgroundExecution = allowsBackgroundExecution
    }
}

// MARK: - Decision Uncertainty

/// A qualitative uncertainty classification. Deliberately NOT a numeric confidence score — this
/// project does not fabricate factual/model-quality measurements it does not actually have.
public enum QDecisionUncertainty: String, Codable, Sendable, Equatable, CaseIterable {
    case low
    case medium
    case high
    case unknown
}

// MARK: - Decision Plan (the central auditable decision artifact)

/// The central, auditable artifact a future Decision Engine would produce — describing a decision
/// about how a task should be approached, never carrying out that decision. Contains no secrets,
/// raw credentials, raw screen content, or arbitrary model output; it describes decisions, not
/// user data. Nothing in this type grants a permission, selects a concrete model, authorizes
/// egress, or bypasses verification — see the per-field documentation above for what each part
/// deliberately does NOT do.
public struct QDecisionPlan: Codable, Sendable, Equatable {
    public let taskType: QTaskType
    public let complexity: QTaskComplexity
    public let decompositionDecision: QDecompositionDecision
    /// The explicit, non-negotiable ceiling on reasoning steps this decision allows. Hoisted to
    /// the top level of `QDecisionPlan` rather than nested inside `resourceEnvelope` — see that
    /// type's own documentation for why.
    public let reasoningStepBudget: Int
    public let modelStrategy: QModelStrategy
    public let verificationRequirement: QVerificationRequirement
    public let provenanceRequirement: QProvenanceRequirement
    public let resourceEnvelope: QDecisionResourceEnvelope
    public let uncertainty: QDecisionUncertainty

    public init(
        taskType: QTaskType,
        complexity: QTaskComplexity,
        decompositionDecision: QDecompositionDecision,
        reasoningStepBudget: Int,
        modelStrategy: QModelStrategy,
        verificationRequirement: QVerificationRequirement,
        provenanceRequirement: QProvenanceRequirement,
        resourceEnvelope: QDecisionResourceEnvelope,
        uncertainty: QDecisionUncertainty
    ) {
        self.taskType = taskType
        self.complexity = complexity
        self.decompositionDecision = decompositionDecision
        self.reasoningStepBudget = reasoningStepBudget
        self.modelStrategy = modelStrategy
        self.verificationRequirement = verificationRequirement
        self.provenanceRequirement = provenanceRequirement
        self.resourceEnvelope = resourceEnvelope
        self.uncertainty = uncertainty
    }
}

// MARK: - Conversational Classification Helper

public extension QDecisionPlan {
    /// Indicates whether this decision plan represents a conversational or informational query
    /// (e.g. simple Q&A, conversational memory, creative writing, or non-decomposed reasoning)
    /// rather than an action or execution task that alters system state.
    var isConversational: Bool {
        switch taskType {
        case .simpleQA:
            return true
        case .reasoning, .creative:
            return decompositionDecision == .notRequired
        case .coding, .research, .planning, .execution, .criticalHighRisk:
            return false
        }
    }
}
