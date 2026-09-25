//
//  CompanionManager+ActivityGoalModel.swift
//  leanring-buddy
//
//  Slice 2 of the activity-goal-model proposal
//  (openspec/changes/2026-09-13-add-activity-goal-model): the deterministic
//  frontmost-app/window-transition producer. Reuses the exact signal
//  `PaceAppUsageTracker` already receives from `NSWorkspace` — no new
//  capture, no new permission prompt, no model call. When the
//  `appUsageHistory` toggle has `appUsageTracker` stopped, this producer is
//  silent too (it only fires from inside `handleApplicationActivated`,
//  which the same `isRunning` gate protects).
//
//  Phase 4.7E: Safe, deterministic parity between meaningful Q-Core work
//  and the existing Now/Current Activity projection. Reuses PaceActivityGoalStore
//  and PaceActivityEvidenceKind.authorizedTask. Direct conversational answers
//  must NEVER create or mutate activity.
//

import Foundation

@MainActor
extension CompanionManager {
    /// Confidence assigned to a raw frontmost-app-transition observation.
    /// Deliberately modest: an app switch is real signal about what the
    /// user is doing, but far weaker evidence than an explicit user
    /// statement (`userStated`, confidence ~0.9+) or an authorized task run.
    private static let frontmostApplicationObservationConfidence: Double = 0.5

    /// Confidence assigned to an authorized, execution-backed Q-Core task.
    /// Higher than raw background app observations (0.5), but strictly lower than
    /// an explicit user statement (`userStated`, confidence 0.95).
    public static let qCoreExecutionObservationConfidence: Double = 0.85

    /// Defensive in-flight execution horizon: if a task hangs without updating or completing,
    /// it auto-expires after 5 minutes rather than remaining active indefinitely.
    public static let qCoreActiveTaskMaxHorizonInSeconds: TimeInterval = 300

    /// Called from `PaceAppUsageTracker.onActivityObserved` on every
    /// frontmost-app transition. Records one bounded `observed` activity
    /// observation and persists the store.
    func recordActivityGoalObservation(applicationName: String, at activationDate: Date) {
        let observation = PaceActivityObservation(
            recordedAt: activationDate,
            evidenceKind: .observed,
            subject: applicationName,
            confidence: Self.frontmostApplicationObservationConfidence,
            provenanceSourceSystem: "PaceAppUsageTracker"
        )
        activityGoalStore.apply(observation)
        activityGoalPersistenceStore.save(activityGoalStore.allObservations)
    }

    /// Rehydrate persisted activity observations at launch. Called once
    /// from `start()`, mirroring `restorePersistedThreadMemoryIfEnabled()`.
    func restorePersistedActivityGoalObservations() {
        let persistedObservations = activityGoalPersistenceStore.load()
        guard !persistedObservations.isEmpty else { return }
        activityGoalStore.restore(from: persistedObservations)
        print("🧭 Activity-goal observations restored: \(persistedObservations.count)")

        // Phase 4.7E: Ensure restart/recovery does not resurrect stale active QCore tasks
        let restored = activityGoalStore.allObservations
        let supersededIds = Set(restored.compactMap { $0.supersedesObservationId })
        let now = Date()
        var didCleanStale = false

        for obs in restored where obs.evidenceKind == .authorizedTask &&
                                  obs.provenanceSourceSystem == "QCoreExecution:active" &&
                                  !supersededIds.contains(obs.identifier) &&
                                  (obs.expiresAt == nil || obs.expiresAt! > now) {
            let recoveryObservation = PaceActivityObservation(
                identifier: "\(obs.identifier)-recovered",
                recordedAt: now,
                evidenceKind: .authorizedTask,
                subject: obs.subject,
                confidence: obs.confidence,
                provenanceSourceSystem: "QCoreExecution:cancelled",
                provenanceEvidenceReferenceId: obs.provenanceEvidenceReferenceId,
                expiresAt: now,
                supersedesObservationId: obs.identifier
            )
            activityGoalStore.apply(recoveryObservation)
            didCleanStale = true
        }

        if didCleanStale {
            activityGoalPersistenceStore.save(activityGoalStore.allObservations)
        }
    }

    // MARK: - Phase 4.7E Q-Core Current Activity Lifecycle

    /// Records the start of an execution-backed Q-Core task.
    /// Direct conversational questions must NEVER call this method.
    func recordQCoreExecutionStarted(taskId: String, taskPrompt: String, at startDate: Date = Date()) {
        let sanitized = PaceActivitySanitizer.sanitizeSubject(taskPrompt)

        let activeObservations = activityGoalStore.allObservations
        let supersededIds = Set(activeObservations.compactMap { $0.supersedesObservationId })
        let priorActiveId = activeQCoreObservationId ?? activeObservations.last(where: {
            $0.evidenceKind == .authorizedTask &&
            $0.provenanceSourceSystem == "QCoreExecution:active" &&
            !supersededIds.contains($0.identifier) &&
            ($0.expiresAt == nil || $0.expiresAt! > startDate)
        })?.identifier

        let observation = PaceActivityObservation(
            identifier: "qcore-\(taskId)-active",
            recordedAt: startDate,
            evidenceKind: .authorizedTask,
            subject: sanitized,
            confidence: Self.qCoreExecutionObservationConfidence,
            provenanceSourceSystem: "QCoreExecution:active",
            provenanceEvidenceReferenceId: taskId,
            expiresAt: startDate.addingTimeInterval(Self.qCoreActiveTaskMaxHorizonInSeconds),
            supersedesObservationId: priorActiveId
        )

        activeQCoreObservationId = observation.identifier
        activityGoalStore.apply(observation)
        activityGoalPersistenceStore.save(activityGoalStore.allObservations)
    }

    /// Records successful completion of a Q-Core execution task, expiring the active task
    /// so the Current Activity projection cleanly reverts to foreground app observations.
    func recordQCoreExecutionCompleted(taskId: String, at completionDate: Date = Date()) {
        let activeObservations = activityGoalStore.allObservations
        let supersededIds = Set(activeObservations.compactMap { $0.supersedesObservationId })
        guard let activeObs = activeObservations.last(where: {
            $0.evidenceKind == .authorizedTask &&
            $0.provenanceSourceSystem == "QCoreExecution:active" &&
            ($0.provenanceEvidenceReferenceId == taskId || $0.identifier == activeQCoreObservationId) &&
            !supersededIds.contains($0.identifier)
        }) else {
            return
        }

        let completedObservation = PaceActivityObservation(
            identifier: "qcore-\(taskId)-completed",
            recordedAt: completionDate,
            evidenceKind: .authorizedTask,
            subject: activeObs.subject,
            confidence: Self.qCoreExecutionObservationConfidence,
            provenanceSourceSystem: "QCoreExecution:completed",
            provenanceEvidenceReferenceId: taskId,
            expiresAt: Date.distantPast,
            supersedesObservationId: activeObs.identifier
        )

        activeQCoreObservationId = nil
        activityGoalStore.apply(completedObservation)
        activityGoalPersistenceStore.save(activityGoalStore.allObservations)
    }

    /// Records failure of a Q-Core execution task without claiming success, clearing the active state.
    func recordQCoreExecutionFailed(taskId: String, reason: String, at failureDate: Date = Date()) {
        let activeObservations = activityGoalStore.allObservations
        let supersededIds = Set(activeObservations.compactMap { $0.supersedesObservationId })
        guard let activeObs = activeObservations.last(where: {
            $0.evidenceKind == .authorizedTask &&
            $0.provenanceSourceSystem == "QCoreExecution:active" &&
            ($0.provenanceEvidenceReferenceId == taskId || $0.identifier == activeQCoreObservationId) &&
            !supersededIds.contains($0.identifier)
        }) else {
            return
        }

        let failedObservation = PaceActivityObservation(
            identifier: "qcore-\(taskId)-failed",
            recordedAt: failureDate,
            evidenceKind: .authorizedTask,
            subject: activeObs.subject,
            confidence: Self.qCoreExecutionObservationConfidence,
            provenanceSourceSystem: "QCoreExecution:failed",
            provenanceEvidenceReferenceId: taskId,
            expiresAt: Date.distantPast,
            supersedesObservationId: activeObs.identifier
        )

        activeQCoreObservationId = nil
        activityGoalStore.apply(failedObservation)
        activityGoalPersistenceStore.save(activityGoalStore.allObservations)
    }

    /// Records cancellation of a Q-Core execution task, ensuring it does not linger as active.
    func recordQCoreExecutionCancelled(taskId: String, at cancellationDate: Date = Date()) {
        let activeObservations = activityGoalStore.allObservations
        let supersededIds = Set(activeObservations.compactMap { $0.supersedesObservationId })
        guard let activeObs = activeObservations.last(where: {
            $0.evidenceKind == .authorizedTask &&
            $0.provenanceSourceSystem == "QCoreExecution:active" &&
            (taskId.isEmpty || $0.provenanceEvidenceReferenceId == taskId || $0.identifier == activeQCoreObservationId) &&
            !supersededIds.contains($0.identifier)
        }) else {
            return
        }

        let effectiveTaskId = taskId.isEmpty ? (activeObs.provenanceEvidenceReferenceId ?? "cancelled") : taskId
        let cancelledObservation = PaceActivityObservation(
            identifier: "qcore-\(effectiveTaskId)-cancelled",
            recordedAt: cancellationDate,
            evidenceKind: .authorizedTask,
            subject: activeObs.subject,
            confidence: Self.qCoreExecutionObservationConfidence,
            provenanceSourceSystem: "QCoreExecution:cancelled",
            provenanceEvidenceReferenceId: effectiveTaskId,
            expiresAt: Date.distantPast,
            supersedesObservationId: activeObs.identifier
        )

        activeQCoreObservationId = nil
        activityGoalStore.apply(cancelledObservation)
        activityGoalPersistenceStore.save(activityGoalStore.allObservations)
    }

    /// Convenience to clear any active Q-Core execution activity on barge-in or manual turn stop.
    func clearActiveQCoreExecutionActivity(at timestamp: Date = Date()) {
        recordQCoreExecutionCancelled(taskId: "", at: timestamp)
    }
}
