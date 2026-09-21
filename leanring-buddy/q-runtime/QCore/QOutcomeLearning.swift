//
//  QOutcomeLearning.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2E Outcome Learning.
//  Turns REAL, already-established outcomes into capability observations:
//
//      Phase 2C `QEvidenceOutcomeMetadata` (structured, content-free)
//    + Phase 2B candidate attempts (identity, outcome label, measured duration)
//    + the authoritative goal-evaluation state (`QGoalEvaluationState`)
//    + explicit user feedback (only via `recordUserFeedback`)
//      → `QModelCapabilityObservation`s → `QModelCapabilityMemory`
//
//  Learning is downstream of, and separate from, every authority. It runs AFTER execution and
//  verification have already decided; it cannot execute, approve, widen a permission, lower a risk,
//  weaken verification, or touch a resource limit — it has no reference to any of them. Its only
//  output is durable, bounded, content-free observations that may later influence routing ORDER
//  (see `QModelCapabilityMemory`) through the unchanged orchestrator.
//
//  Poisoning defense (defence in depth, each independently tested):
//   - no producer-supplied outcome: every `outcome` is derived by `QOutcomeClassifier` from the
//     authoritative facts, and the store re-derives and rejects mismatches;
//   - the only inputs are typed metadata and enums — no model text can reach this layer, so a
//     model cannot "claim" success, verification, or feedback;
//   - deterministic identity + idempotent store: a replayed/duplicated report adds no weight, a
//     conflicting re-report is refused (first stands);
//   - per-(task, backend) cap, per-key cap, global cap, and a retention window bound the influence
//     of any one task, model, or burst;
//   - task-level results are credited only to the candidate whose plan was actually used; a race
//     loser's cancellation and a candidate's mere unavailability are never counted against it;
//   - the Phase 2C metadata is task-level, so verification/execution facts are attributed only to
//     that one candidate. The evidence pipeline's own timeouts are NOT attributed to any model.
//

import Foundation

// MARK: - Input / report

public struct QOutcomeLearningInput: Sendable {
    public let taskId: String
    public let decisionPlan: QDecisionPlan
    public let evidenceMetadata: QEvidenceOutcomeMetadata
    public let attempts: [QModelAttempt]
    /// The attempt whose plan was executed; `nil` when no candidate produced a usable plan.
    public let winningAttemptId: QModelAttemptID?
    public let goalState: QGoalEvaluationState

    public init(
        taskId: String,
        decisionPlan: QDecisionPlan,
        evidenceMetadata: QEvidenceOutcomeMetadata,
        attempts: [QModelAttempt],
        winningAttemptId: QModelAttemptID?,
        goalState: QGoalEvaluationState
    ) {
        self.taskId = taskId
        self.decisionPlan = decisionPlan
        self.evidenceMetadata = evidenceMetadata
        self.attempts = attempts
        self.winningAttemptId = winningAttemptId
        self.goalState = goalState
    }
}

public struct QOutcomeLearningReport: Sendable, Equatable {
    public var recorded = 0
    public var duplicates = 0
    public var conflicts = 0
    public var storeUnavailable = 0
    public var rejections: [QObservationRejection: Int] = [:]
    public var winnerBackend: QModelBackendType?
    public var winnerOutcome: QLearnedOutcome?

    public var rejectedCount: Int { rejections.values.reduce(0, +) }

    mutating func tally(_ result: QObservationRecordResult) {
        switch result {
        case .recorded, .upgraded: recorded += 1
        case .duplicate: duplicates += 1
        case .conflictingDuplicate: conflicts += 1
        case .rejected(let reason): rejections[reason, default: 0] += 1
        case .storeUnavailable: storeUnavailable += 1
        }
    }

    /// Counts and enum raw values only — safe for a lifecycle event payload.
    public var auditPayload: [String: String] {
        [
            "recorded": "\(recorded)",
            "duplicates": "\(duplicates)",
            "conflicts": "\(conflicts)",
            "rejected": "\(rejectedCount)",
            "storeUnavailable": "\(storeUnavailable)",
            "winnerBackend": winnerBackend?.rawValue ?? "none",
            "winnerOutcome": winnerOutcome?.rawValue ?? "none"
        ]
    }
}

// MARK: - Derivations from authoritative facts (pure)

public enum QOutcomeDerivation {

    /// Task-level verification standing, derived ONLY from Phase 2C's structured metadata.
    public static func verification(from metadata: QEvidenceOutcomeMetadata) -> QObservedVerification {
        // Conservative by design: the metadata is task-level, so it cannot say WHICH candidate a
        // contradicted claim belonged to. Negative verification evidence therefore always wins —
        // it can only make learning more cautious, never less.
        if metadata.contradictedClaimCount > 0 { return .contradicted }
        if metadata.requirement == QVerificationRequirement.none.rawValue { return .notRequired }
        let lostStages: Set<String> = [QEvidenceStageState.unavailable.rawValue, QEvidenceStageState.timedOut.rawValue, QEvidenceStageState.cancelled.rawValue]
        if lostStages.contains(metadata.verificationStage) { return .unavailable }
        if metadata.synthesisStatus == QSynthesisStatus.sufficient.rawValue { return .verified }
        return .unresolved
    }

    public static func contradiction(from metadata: QEvidenceOutcomeMetadata) -> QObservedContradiction {
        if metadata.unresolvedContradictionCount > 0 { return .unresolved }
        return metadata.contradictionCount > 0 ? .resolved : .none
    }

    /// The goal evaluator is the authoritative execution judge; this only re-labels its state.
    public static func execution(from goalState: QGoalEvaluationState) -> QObservedExecution {
        switch goalState {
        case .satisfied: return .succeeded
        case .partiallySatisfied: return .partial
        case .unsatisfied: return .failed
        case .blocked: return .blocked
        case .unknown: return .notApplicable
        }
    }

    static func latencyMilliseconds(_ attempt: QModelAttempt) -> Int? {
        let milliseconds = attempt.durationSeconds * 1000
        guard milliseconds.isFinite, milliseconds >= 0 else { return nil }
        return Int(min(milliseconds, Double(QModelCapabilityLimits.maxLatencyMilliseconds)))
    }
}

// MARK: - Service

public struct QOutcomeLearningService: Sendable {
    public let memory: QModelCapabilityMemory

    /// A generous but bounded ceiling on attempts considered per task (Phase 2B itself attempts at
    /// most a handful).
    static let maxAttemptsConsidered = 16

    public init(memory: QModelCapabilityMemory) {
        self.memory = memory
    }

    /// Records one observation per candidate attempt. The candidate whose plan was executed
    /// (`winningAttemptId`) additionally carries the task-level verification/execution facts.
    /// Safe to call repeatedly with the same input: identity is deterministic, so repeats are
    /// `.duplicate`, never extra weight.
    ///
    /// Each observation is timestamped with the attempt's own measured `finishedAt` (a real event
    /// time, never a caller-chosen one) and validated against `now` — the caller's clock — so an
    /// attempt with an impossible (future/expired) time is rejected, not trusted.
    @discardableResult
    public func learn(_ input: QOutcomeLearningInput, now: Date) -> QOutcomeLearningReport {
        var report = QOutcomeLearningReport()
        let taskVerification = QOutcomeDerivation.verification(from: input.evidenceMetadata)
        let taskContradiction = QOutcomeDerivation.contradiction(from: input.evidenceMetadata)
        let taskExecution = QOutcomeDerivation.execution(from: input.goalState)

        for attempt in input.attempts.prefix(Self.maxAttemptsConsidered) {
            let attemptOutcome = QObservedAttemptOutcome(attempt.outcome)
            let isWinner = attempt.attemptId == input.winningAttemptId && attemptOutcome == .accepted

            let observation: QModelCapabilityObservation
            if isWinner {
                observation = QModelCapabilityObservation(
                    taskId: input.taskId, attemptId: attempt.attemptId.rawValue, source: .taskOutcome,
                    taskType: input.decisionPlan.taskType, complexity: input.decisionPlan.complexity,
                    backend: attempt.backend, strategy: input.decisionPlan.modelStrategy,
                    attemptOutcome: attemptOutcome, verification: taskVerification,
                    evidenceCompleteness: input.evidenceMetadata.evidenceCompleteness, contradiction: taskContradiction,
                    resource: .completed, execution: taskExecution,
                    latencyMilliseconds: QOutcomeDerivation.latencyMilliseconds(attempt), observedAt: attempt.finishedAt
                )
                report.winnerBackend = attempt.backend
                report.winnerOutcome = observation.outcome
            } else {
                observation = QModelCapabilityObservation(
                    taskId: input.taskId, attemptId: attempt.attemptId.rawValue, source: .modelAttempt,
                    taskType: input.decisionPlan.taskType, complexity: input.decisionPlan.complexity,
                    backend: attempt.backend, strategy: input.decisionPlan.modelStrategy,
                    attemptOutcome: attemptOutcome, verification: Self.attemptVerification(attemptOutcome),
                    evidenceCompleteness: .none, contradiction: .none,
                    resource: Self.attemptResource(attemptOutcome), execution: .notApplicable,
                    latencyMilliseconds: QOutcomeDerivation.latencyMilliseconds(attempt), observedAt: attempt.finishedAt
                )
            }
            report.tally(memory.record(observation, now: now))
        }
        return report
    }

    /// Explicit user feedback about an already-observed task. Never inferred; refused (not
    /// invented) when the task has no task-outcome observation.
    @discardableResult
    public func recordUserFeedback(taskId: String, feedback: QExplicitUserFeedback, now: Date = Date()) -> [QObservationRecordResult] {
        memory.recordUserFeedback(taskId: taskId, feedback: feedback, now: now)
    }

    private static func attemptVerification(_ outcome: QObservedAttemptOutcome) -> QObservedVerification {
        switch outcome {
        case .accepted, .needsVerification: return .pending
        case .verificationFailed: return .contradicted
        case .rejected, .invalid, .timedOut, .cancelled, .unavailable: return .unavailable
        }
    }

    private static func attemptResource(_ outcome: QObservedAttemptOutcome) -> QObservedResource {
        switch outcome {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .accepted, .rejected, .invalid, .unavailable, .verificationFailed, .needsVerification: return .completed
        }
    }
}
