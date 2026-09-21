//
//  QTaskLifecycleEvent.swift
//  leanring-buddy
//
//  Q Security Architecture — Immutable Task Lifecycle Events (Phase 2D).
//  Provides event-sourced task tracking with schema versioning, strict timestamping,
//  and provenance preservation.
//

import Foundation

public enum QTaskLifecycleEventType: String, Codable, Sendable, Equatable {
    case taskCreated = "task.created"
    case taskPlanned = "task.planned"
    case stepStarted = "task.step.started"
    case stepCompleted = "task.step.completed"
    case stepFailed = "task.step.failed"
    case stepVerified = "task.step.verified"
    case goalEvaluated = "task.goal.evaluated"
    case replanRequested = "task.replan.requested"
    case replanCreated = "task.replan.created"
    case permissionRequested = "task.permission.requested"
    case permissionGranted = "task.permission.granted"
    case permissionDenied = "task.permission.denied"
    case securityBlocked = "task.security.blocked"
    /// Phase 2A.4: a `QDecisionPlan` (and, when applicable, a decomposition outcome) was computed
    /// for a task. Advisory/observability only — recording this event grants no permission,
    /// resource, or egress authority and never itself changes task state.
    case decisionEvaluated = "task.decision.evaluated"
    /// Phase 2B: one bounded candidate attempt the model orchestrator made. Payload carries only
    /// identity/outcome-label/duration metadata (`QModelAttemptOutcome.auditLabel`) — never raw
    /// model output, never prompt text. Advisory/observability only.
    case modelAttemptRecorded = "task.model.attempt"
    /// Phase 2B: one orchestration call finished (all its attempts are already individually
    /// recorded via `modelAttemptRecorded`). Payload carries only counts/booleans/the early-exit
    /// reason's own raw value. Advisory/observability only.
    case modelOrchestrationCompleted = "task.model.orchestration.completed"
    case taskPaused = "task.paused"
    case taskResumed = "task.resumed"
    case taskCompleted = "task.completed"
    case taskFailed = "task.failed"
    case taskAborted = "task.aborted"
}

public struct QTaskLifecycleEvent: Codable, Sendable, Equatable {
    public let eventId: String
    public let taskId: String
    public let sessionId: String
    public let eventType: QTaskLifecycleEventType
    public let timestamp: Date
    public let payload: [String: String]
    public let provenance: String
    public let schemaVersion: Int

    public init(
        eventId: String = UUID().uuidString,
        taskId: String,
        sessionId: String,
        eventType: QTaskLifecycleEventType,
        timestamp: Date = Date(),
        payload: [String: String] = [:],
        provenance: String = "trusted:system",
        schemaVersion: Int = 1
    ) {
        self.eventId = eventId
        self.taskId = taskId
        self.sessionId = sessionId
        self.eventType = eventType
        self.timestamp = timestamp
        self.payload = payload
        self.provenance = provenance
        self.schemaVersion = schemaVersion
    }
}
