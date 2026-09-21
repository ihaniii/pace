//
//  QModelOrchestrationContracts.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2B Model Orchestration Contracts.
//  Defines the additive data contracts a bounded, multi-candidate model orchestrator (Phase 2B,
//  `QModelOrchestrator.swift`) produces and consumes. DATA ONLY — no orchestration logic, no
//  execution, no network. See `QModelOrchestrator.swift` for the (also non-executing) deterministic
//  implementation that produces this data from a `QTask` + `QDecisionPlan`.
//
//  These contracts describe ORCHESTRATION OUTCOME, never authority:
//   - a `QModelCandidate` never selects a concrete provider by itself — it only ever describes one
//     backend `QModelRouter` already registered; `QModelRouter`'s own `routeInference` remains the
//     sole dispatcher and sole enforcer of egress/availability checks for every attempt;
//   - `QModelAttemptOutcome` never carries a fabricated quality/confidence score — every case is an
//     objective, typed state (accepted/rejected/invalid/timedOut/cancelled/unavailable), never a
//     number derived from response length, lexical overlap, or formatting;
//   - `QModelOrchestrationResult.winningPlan`, when present, already passed through the exact same
//     `QModelPlanParser` schema/risk validation every non-orchestrated plan always has — nothing
//     here re-validates or duplicates that logic, and nothing here grants a permission, resource,
//     or egress authority (`QPermissionGate`/`QResourceGuard`/`QEgressBroker` remain untouched and
//     solely authoritative over whatever plan eventually gets returned);
//   - `verificationFailed`/`needsVerification` (on `QModelAttemptOutcome`) are Phase 2C extension
//     points ONLY — this phase's own orchestrator never produces them (verification is an
//     execution-time concept owned by `QActionVerifier`, which runs strictly after orchestration,
//     unchanged); they exist now so a future Evidence Pool/Critic can populate them later without
//     a type redesign, per this phase's explicit forward-compatibility requirement.
//

import Foundation

// MARK: - Candidate Identity

/// A stable, deterministic candidate identifier — derived directly from the backend type, never a
/// random `UUID()`. The same backend always produces the same `QModelCandidateID`.
public struct QModelCandidateID: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(backend: QModelBackendType) {
        self.rawValue = backend.rawValue
    }
}

// MARK: - Model Candidate

/// One candidate backend the orchestrator may attempt — DATA describing what `QModelRouter` has
/// already registered, never a fabricated capability/quality score. Intentionally carries no
/// "supported task categories," "resource estimate," or "latency observation" fields: nothing in
/// this codebase measures those per-backend today, and inventing placeholder values for them would
/// misrepresent them as real measurements (the same "never fabricate a number you don't have"
/// principle `QDecisionUncertainty`/`QTaskComplexity` already establish). `capabilities`
/// (`QModelCapabilities`, already defined by `QModelRouter.swift`) is reused rather than
/// duplicated — its `contextWindowTokens`/`supportsVision`/`supportsAudio` are the only genuine,
/// already-known per-backend facts this codebase has.
public struct QModelCandidate: Sendable, Equatable {
    public let id: QModelCandidateID
    public let backend: QModelBackendType
    public let capabilities: QModelCapabilities
    /// Whether `QLocalModelBackend.isAvailable()` reported true at candidate-build time. This can
    /// still change by attempt time (a race condition inherent to any liveness check) — every
    /// attempt re-derives its own `.unavailable` outcome from the real dispatch call, never trusts
    /// this snapshot alone as proof of availability.
    public let isAvailable: Bool
    public let isLocalOnDevice: Bool

    public init(backend: QModelBackendType, capabilities: QModelCapabilities, isAvailable: Bool) {
        self.id = QModelCandidateID(backend: backend)
        self.backend = backend
        self.capabilities = capabilities
        self.isAvailable = isAvailable
        self.isLocalOnDevice = capabilities.isLocalOnDevice
    }
}

// MARK: - Attempt Identity & Outcome

/// A stable, deterministic attempt identifier — "<taskId>-attempt-<candidateId>-<index>", never a
/// random `UUID()`. The same task, candidate, and position always produce the same
/// `QModelAttemptID`.
public struct QModelAttemptID: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// The objective, typed outcome of one candidate attempt. Every case is derived from a concrete,
/// verifiable fact (did the call throw, what did it throw, was it cancelled) — never a numeric
/// score, never derived from response length/lexical overlap/formatting, never a model's own
/// self-rating.
public enum QModelAttemptOutcome: Sendable, Equatable {
    /// The candidate returned a `QPlan` that already passed `QModelPlanParser`'s schema and
    /// authoritative-risk validation (or the existing deterministic-fallback generator, which is
    /// valid by construction) — the exact same bar every non-orchestrated plan already clears.
    case accepted(plan: QPlan)
    /// The candidate's own dispatch was refused for a concrete, named reason (e.g. an egress
    /// policy refusal) — never a quality judgment.
    case rejected(reason: String)
    /// The candidate's raw output could not be turned into a valid plan at all.
    case invalid(reason: String)
    case timedOut
    case cancelled
    case unavailable
    /// Phase 2C extension point — never produced by this phase's own orchestrator. Reserved for a
    /// future Evidence Pool/Critic that can independently verify an attempt's result before it is
    /// allowed to win.
    case verificationFailed(reason: String)
    /// Phase 2C extension point — never produced by this phase's own orchestrator. Reserved for a
    /// future stage that defers acceptance until independent verification evidence exists.
    case needsVerification

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    /// A short, bounded, audit-safe label for this outcome — the case name only, never the
    /// associated `reason`/`plan` content. Used for `QTaskLifecycleEvent.payload` entries, which
    /// (like every other lifecycle event payload in this codebase) must never carry raw model
    /// output or unbounded free text.
    public var auditLabel: String {
        switch self {
        case .accepted: return "accepted"
        case .rejected: return "rejected"
        case .invalid: return "invalid"
        case .timedOut: return "timedOut"
        case .cancelled: return "cancelled"
        case .unavailable: return "unavailable"
        case .verificationFailed: return "verificationFailed"
        case .needsVerification: return "needsVerification"
        }
    }
}

/// One structured record of a single candidate attempt — the provenance unit Phase 2B's audit
/// trail is built from. Carries only bounded, non-sensitive identity/outcome/timing metadata;
/// never raw prompt text, never raw model output text (only ever a validated `QPlan`, on
/// `.accepted`, which is exactly what the existing non-orchestrated path already persists via
/// `QDurablePlanSnapshot` — nothing new here).
public struct QModelAttempt: Sendable, Equatable {
    public let attemptId: QModelAttemptID
    public let taskId: String
    public let candidateId: QModelCandidateID
    public let backend: QModelBackendType
    public let outcome: QModelAttemptOutcome
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        attemptId: QModelAttemptID,
        taskId: String,
        candidateId: QModelCandidateID,
        backend: QModelBackendType,
        outcome: QModelAttemptOutcome,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.attemptId = attemptId
        self.taskId = taskId
        self.candidateId = candidateId
        self.backend = backend
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var durationSeconds: Double {
        finishedAt.timeIntervalSince(startedAt)
    }
}

// MARK: - Early Exit

/// Why orchestration stopped when it stopped — an objective, named reason, never a quality
/// judgment about which candidate was "best."
public enum QModelEarlyExitReason: String, Sendable, Equatable {
    /// Only one real, available candidate existed — nothing to race or compare against.
    case singleCandidateOnly
    /// The decision plan's own complexity/uncertainty did not call for comparison — the first
    /// candidate attempted was accepted without racing.
    case firstValidResultSufficient
    /// Racing genuinely occurred; the first candidate to return a schema/risk-valid plan won and
    /// the rest were cancelled.
    case firstSchemaValidPlanAccepted
    /// Every available candidate was attempted (sequentially, after a race produced no acceptance,
    /// or because racing was never eligible) and none succeeded.
    case allCandidatesExhausted
    /// The decision-plan-derived eligibility rule determined racing should not be attempted for
    /// this task (e.g. `.critical` complexity) — defense in depth; in the integrated runtime this
    /// case is already unreachable because `.critical` complexity always fails closed at the
    /// Phase 2A.4 decomposition gate before orchestration is ever invoked (see
    /// `QCoreRuntime.submitIntent`'s `.required` decomposition branch).
    case racingNotEligible
}

// MARK: - Orchestration Result

/// The final, typed result of one orchestration call — never a bare `QPlan`; always paired with
/// the objective record of how it was produced, so the caller (and the audit trail) can always
/// answer "which candidates were tried, and why did this one win."
public struct QModelOrchestrationResult: Sendable, Equatable {
    public let winningPlan: QPlan?
    public let attempts: [QModelAttempt]
    public let earlyExitReason: QModelEarlyExitReason
    public let didRace: Bool

    public init(
        winningPlan: QPlan?,
        attempts: [QModelAttempt],
        earlyExitReason: QModelEarlyExitReason,
        didRace: Bool
    ) {
        self.winningPlan = winningPlan
        self.attempts = attempts
        self.earlyExitReason = earlyExitReason
        self.didRace = didRace
    }

    public var isSuccess: Bool {
        winningPlan != nil
    }
}

// MARK: - Orchestration Errors

public enum QModelOrchestrationError: Error, Sendable, Equatable {
    /// No registered candidate reported itself available at all — nothing to attempt.
    case noCandidatesAvailable
    /// Every candidate that was attempted failed, was rejected, was invalid, or timed out.
    case allCandidatesFailed(attemptIds: [QModelAttemptID])
}
