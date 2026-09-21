//
//  QModelCapabilityContracts.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2D Model Capability Memory contracts.
//  Typed vocabulary for durable, local, ADVISORY observations of how a model candidate actually
//  performed. DATA + pure validation only — no persistence (see `QModelCapabilityStore.swift`),
//  no routing (see `QModelCapabilityMemory.swift`), no execution, no network.
//
//  What this memory is NOT — by type, not by convention:
//   - not an authority: nothing here references a permission, egress, resource, approval,
//     verification, or risk type, and no field can carry such a grant. Memory can only ever
//     produce a routing RECOMMENDATION that the (unchanged) orchestrator/router still vets;
//   - not a score: there is no "Model A = 0.93". A profile is a set of typed COUNTS of things that
//     were actually observed (verified successes, verification failures, timeouts, corrections…).
//     The only derived figures are exact integer counts/means of real measurements;
//   - not a content store: an observation carries enums, a backend type, deterministic IDs, a
//     measured latency and a timestamp. No prompt, response, screen text, OCR, typed text,
//     credential, URL, or document body exists anywhere in these types;
//   - not taken on a model's word: `outcome` is never accepted from a producer — it must equal
//     `QOutcomeClassifier.classify(...)` recomputed from the authoritative facts in the same
//     observation, or the observation is rejected. A model that "claims it succeeded" while
//     verification failed therefore cannot even be represented.
//

import Foundation
import CryptoKit

// MARK: - Explicit Bounds

/// Every retention / aggregation / influence bound. Nothing in Phase 2D/2E grows without limit.
public enum QModelCapabilityLimits {
    /// Retention is a sliding window: observations older than this are pruned on write and ignored
    /// on read. This IS the decay policy — no weighting, no half-life, no false precision.
    public static let retentionSeconds: TimeInterval = 90 * 24 * 60 * 60
    public static let maxObservationsPerKey = 200
    public static let maxTotalObservations = 5_000
    /// At most this many non-feedback observations per (task, backend): one task cannot flood a
    /// model's history no matter how many times it is reported.
    public static let maxObservationsPerTaskPerBackend = 3
    /// A candidate is only ranked once this many DISTINCT tasks have been observed for its key.
    public static let minimumDistinctTasksForRecommendation = 5
    /// Clock-skew tolerance for `observedAt` in the future.
    public static let maxFutureSkewSeconds: TimeInterval = 300
    public static let maxLatencyMilliseconds = 24 * 60 * 60 * 1000
    public static let maxIdentifierCharacters = 128
    public static let currentSchemaVersion = 1
}

// MARK: - Observation vocabulary

/// The outcome states a task/attempt can be classified into. One vocabulary, derived — never
/// supplied — see `QOutcomeClassifier`.
public enum QLearnedOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case success
    case failure
    case partial
    case cancelled
    case timedOut
    case denied
    case verificationFailed
    case unresolved
    case correctedByUser
}

/// Mirrors `QModelAttemptOutcome` (Phase 2B) as a plain, payload-free, storable enum.
public enum QObservedAttemptOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case accepted
    case rejected
    case invalid
    case timedOut
    case cancelled
    case unavailable
    case verificationFailed
    case needsVerification

    public init(_ outcome: QModelAttemptOutcome) {
        switch outcome {
        case .accepted: self = .accepted
        case .rejected: self = .rejected
        case .invalid: self = .invalid
        case .timedOut: self = .timedOut
        case .cancelled: self = .cancelled
        case .unavailable: self = .unavailable
        case .verificationFailed: self = .verificationFailed
        case .needsVerification: self = .needsVerification
        }
    }
}

/// Verification standing of what the candidate produced — mirrors `QEvidenceVerificationState`.
public enum QObservedVerification: String, Codable, Sendable, Equatable, CaseIterable {
    case verified
    case contradicted
    case unresolved
    case unavailable
    case notRequired
    case pending
}

public enum QObservedContradiction: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case resolved
    case unresolved
}

/// What happened to the candidate's own resources. An OBSERVATION, never a limit: it cannot
/// loosen or replace `QResourceGuard`.
public enum QObservedResource: String, Codable, Sendable, Equatable, CaseIterable {
    case completed
    case timedOut
    case cancelled
    case failed
}

/// What the (authoritative) execution/goal evaluation established.
public enum QObservedExecution: String, Codable, Sendable, Equatable, CaseIterable {
    case succeeded
    case partial
    case failed
    case blocked
    case notApplicable
}

public enum QObservationSource: String, Codable, Sendable, Equatable, CaseIterable {
    /// One candidate attempt that was not the one used for the task result.
    case modelAttempt
    /// The task-level result, credited to the candidate whose plan was executed.
    case taskOutcome
    /// Explicit user feedback about a task already observed.
    case userFeedback
}

/// Explicit user feedback ONLY. It is never inferred from silence, message length, sentiment, or
/// unrelated behaviour; no code path constructs it except an explicit feedback call.
public enum QExplicitUserFeedback: String, Codable, Sendable, Equatable, CaseIterable {
    case correction
    case confirmation
}

// MARK: - Deterministic outcome classification (the single derivation)

public enum QOutcomeClassifier {

    /// Derives the outcome from authoritative facts. First matching rule wins; the order encodes
    /// "authoritative negative evidence beats everything, and success needs positive verification".
    public static func classify(
        source: QObservationSource,
        attemptOutcome: QObservedAttemptOutcome,
        verification: QObservedVerification,
        contradiction: QObservedContradiction,
        resource: QObservedResource,
        execution: QObservedExecution,
        feedback: QExplicitUserFeedback?
    ) -> QLearnedOutcome {
        if source == .userFeedback {
            return feedback == .correction ? .correctedByUser : .unresolved
        }
        if resource == .timedOut || attemptOutcome == .timedOut { return .timedOut }
        if resource == .cancelled || attemptOutcome == .cancelled { return .cancelled }
        if attemptOutcome == .rejected || execution == .blocked { return .denied }
        if attemptOutcome == .verificationFailed || verification == .contradicted { return .verificationFailed }
        if attemptOutcome == .invalid || resource == .failed || execution == .failed { return .failure }
        if attemptOutcome == .unavailable || attemptOutcome == .needsVerification { return .unresolved }
        if verification == .unresolved || verification == .unavailable || verification == .pending || contradiction == .unresolved {
            return .unresolved
        }
        if execution == .partial { return .partial }
        // Success needs BOTH the authoritative execution judge to have said "succeeded" AND
        // verification to be positive (or genuinely not required). "Unknown" execution is never success.
        if execution == .succeeded, verification == .verified || verification == .notRequired { return .success }
        return .unresolved
    }
}

// MARK: - Rejections & results

public enum QObservationRejection: String, Sendable, Equatable, CaseIterable {
    case malformedIdentifier
    case futureTimestamp
    case expired
    case impossibleLatency
    case identityMismatch
    case inconsistentOutcome
    case inconsistentFeedback
    case perTaskLimitReached
    case schemaVersionUnsupported
    case noMatchingTaskObservation
}

public enum QObservationRecordResult: Sendable, Equatable {
    case recorded
    /// An earlier explicit confirmation was replaced by an explicit correction (monotone: adverse
    /// explicit feedback may supersede a confirmation, never the reverse).
    case upgraded
    case duplicate
    /// Same identity, different facts: the FIRST observation stands, the later one is refused.
    case conflictingDuplicate
    case rejected(QObservationRejection)
    /// The store could not complete the write; nothing was changed.
    case storeUnavailable
}

// MARK: - Observation

public struct QModelCapabilityObservation: Sendable, Equatable {
    public let observationId: String
    public let taskId: String
    /// The Phase 2B attempt ID for attempt-level rows; the task ID's own marker otherwise.
    public let attemptId: String
    public let source: QObservationSource
    public let taskType: QTaskType
    public let complexity: QTaskComplexity
    public let backend: QModelBackendType
    public let strategy: QModelStrategy
    public let attemptOutcome: QObservedAttemptOutcome
    public let verification: QObservedVerification
    public let evidenceCompleteness: QEvidenceCompleteness
    public let contradiction: QObservedContradiction
    public let resource: QObservedResource
    public let execution: QObservedExecution
    /// A real measured duration; `nil` when none was measured. Never estimated.
    public let latencyMilliseconds: Int?
    public let outcome: QLearnedOutcome
    public let feedback: QExplicitUserFeedback?
    public let observedAt: Date
    public let schemaVersion: Int

    public init(
        taskId: String,
        attemptId: String,
        source: QObservationSource,
        taskType: QTaskType,
        complexity: QTaskComplexity,
        backend: QModelBackendType,
        strategy: QModelStrategy,
        attemptOutcome: QObservedAttemptOutcome,
        verification: QObservedVerification,
        evidenceCompleteness: QEvidenceCompleteness,
        contradiction: QObservedContradiction,
        resource: QObservedResource,
        execution: QObservedExecution,
        latencyMilliseconds: Int?,
        feedback: QExplicitUserFeedback? = nil,
        observedAt: Date,
        schemaVersion: Int = QModelCapabilityLimits.currentSchemaVersion
    ) {
        self.taskId = taskId
        self.attemptId = attemptId
        self.source = source
        self.taskType = taskType
        self.complexity = complexity
        self.backend = backend
        self.strategy = strategy
        self.attemptOutcome = attemptOutcome
        self.verification = verification
        self.evidenceCompleteness = evidenceCompleteness
        self.contradiction = contradiction
        self.resource = resource
        self.execution = execution
        self.latencyMilliseconds = latencyMilliseconds
        self.feedback = feedback
        self.observedAt = observedAt
        self.schemaVersion = schemaVersion
        // Derived here, never accepted: see `QOutcomeClassifier`.
        self.outcome = QOutcomeClassifier.classify(
            source: source, attemptOutcome: attemptOutcome, verification: verification,
            contradiction: contradiction, resource: resource, execution: execution, feedback: feedback
        )
        self.observationId = Self.deterministicId(taskId: taskId, attemptId: attemptId, backend: backend, source: source)
    }

    /// Storage-layer initializer: rebuilds an observation from persisted columns, INCLUDING the
    /// stored id and outcome, so that tampering or corruption is caught by `QObservationValidator`
    /// rather than silently re-derived away.
    init(
        storedObservationId: String,
        storedOutcome: QLearnedOutcome,
        taskId: String, attemptId: String, source: QObservationSource,
        taskType: QTaskType, complexity: QTaskComplexity, backend: QModelBackendType, strategy: QModelStrategy,
        attemptOutcome: QObservedAttemptOutcome, verification: QObservedVerification,
        evidenceCompleteness: QEvidenceCompleteness, contradiction: QObservedContradiction,
        resource: QObservedResource, execution: QObservedExecution,
        latencyMilliseconds: Int?, feedback: QExplicitUserFeedback?, observedAt: Date, schemaVersion: Int
    ) {
        self.observationId = storedObservationId
        self.outcome = storedOutcome
        self.taskId = taskId
        self.attemptId = attemptId
        self.source = source
        self.taskType = taskType
        self.complexity = complexity
        self.backend = backend
        self.strategy = strategy
        self.attemptOutcome = attemptOutcome
        self.verification = verification
        self.evidenceCompleteness = evidenceCompleteness
        self.contradiction = contradiction
        self.resource = resource
        self.execution = execution
        self.latencyMilliseconds = latencyMilliseconds
        self.feedback = feedback
        self.observedAt = observedAt
        self.schemaVersion = schemaVersion
    }

    /// Deterministic identity. Attempt-level and task-level rows are identified by task + attempt +
    /// backend + source. Feedback rows deliberately ignore the attempt: one feedback row per
    /// (task, backend), so feedback cannot be replayed into extra weight.
    public static func deterministicId(taskId: String, attemptId: String, backend: QModelBackendType, source: QObservationSource) -> String {
        let attemptComponent = source == .userFeedback ? "feedback" : attemptId
        let material = [taskId, attemptComponent, backend.rawValue, source.rawValue].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "obs-" + String(digest.prefix(24))
    }

    /// Key for aggregation.
    var profileKey: QModelCapabilityProfileKey {
        QModelCapabilityProfileKey(taskType: taskType, complexity: complexity, backend: backend)
    }
}

// MARK: - Validation (pure)

public enum QObservationValidator {

    private static func isWellFormedIdentifier(_ text: String) -> Bool {
        !text.isEmpty
            && text.count <= QModelCapabilityLimits.maxIdentifierCharacters
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Returns the first reason `observation` must be refused, or `nil` if it is acceptable.
    public static func rejection(for observation: QModelCapabilityObservation, now: Date) -> QObservationRejection? {
        guard observation.schemaVersion == QModelCapabilityLimits.currentSchemaVersion else { return .schemaVersionUnsupported }
        guard isWellFormedIdentifier(observation.taskId), isWellFormedIdentifier(observation.attemptId) else { return .malformedIdentifier }
        if observation.observedAt > now.addingTimeInterval(QModelCapabilityLimits.maxFutureSkewSeconds) { return .futureTimestamp }
        if observation.observedAt < now.addingTimeInterval(-QModelCapabilityLimits.retentionSeconds) { return .expired }
        if let latency = observation.latencyMilliseconds, latency < 0 || latency > QModelCapabilityLimits.maxLatencyMilliseconds {
            return .impossibleLatency
        }
        let expectedId = QModelCapabilityObservation.deterministicId(
            taskId: observation.taskId, attemptId: observation.attemptId, backend: observation.backend, source: observation.source
        )
        guard observation.observationId == expectedId else { return .identityMismatch }

        let expectedOutcome = QOutcomeClassifier.classify(
            source: observation.source, attemptOutcome: observation.attemptOutcome, verification: observation.verification,
            contradiction: observation.contradiction, resource: observation.resource, execution: observation.execution,
            feedback: observation.feedback
        )
        guard observation.outcome == expectedOutcome else { return .inconsistentOutcome }

        // Feedback rows must carry feedback; every other row must not (feedback is never implied).
        if (observation.source == .userFeedback) != (observation.feedback != nil) { return .inconsistentFeedback }
        return nil
    }
}

// MARK: - Profile (typed counts, no scores)

public struct QModelCapabilityProfileKey: Sendable, Equatable, Hashable {
    public let taskType: QTaskType
    public let complexity: QTaskComplexity
    public let backend: QModelBackendType
}

/// Bounded, deterministic, explainable aggregate of retained observations for one key. Every field
/// is a count of something that actually happened (or an exact mean of measured latencies).
public struct QModelCapabilityProfile: Sendable, Equatable {
    public let key: QModelCapabilityProfileKey
    public let sampleCount: Int
    public let distinctTaskCount: Int
    public let verifiedSuccessCount: Int
    public let verifiedFailureCount: Int
    public let failureCount: Int
    public let partialCount: Int
    public let unresolvedCount: Int
    public let verificationUnavailableCount: Int
    public let timeoutCount: Int
    public let cancellationCount: Int
    public let deniedCount: Int
    public let resourceFailureCount: Int
    public let unresolvedContradictionCount: Int
    public let userCorrectionCount: Int
    public let userConfirmationCount: Int
    public let latencySampleCount: Int
    public let meanLatencyMilliseconds: Int?
    public let lastObserved: Date?

    /// Observations that count AGAINST a model's capability. Cancellation (e.g. a race loser),
    /// denial (policy, not capability), and unresolved/unavailable (no evidence either way) do not.
    public var adverseCount: Int {
        failureCount + verifiedFailureCount + timeoutCount + userCorrectionCount
    }

    static func empty(key: QModelCapabilityProfileKey) -> QModelCapabilityProfile {
        QModelCapabilityProfile(observations: [], key: key)
    }

    /// Aggregates `observations` (already validated and retention-filtered). Feedback rows
    /// contribute ONLY their feedback counters; outcome counters come from non-feedback rows.
    init(observations: [QModelCapabilityObservation], key: QModelCapabilityProfileKey) {
        self.key = key
        let outcomeRows = observations.filter { $0.source != .userFeedback }
        let feedbackRows = observations.filter { $0.source == .userFeedback }
        sampleCount = outcomeRows.count
        distinctTaskCount = Set(outcomeRows.map { $0.taskId }).count
        verifiedSuccessCount = outcomeRows.filter { $0.outcome == .success }.count
        verifiedFailureCount = outcomeRows.filter { $0.outcome == .verificationFailed }.count
        failureCount = outcomeRows.filter { $0.outcome == .failure }.count
        partialCount = outcomeRows.filter { $0.outcome == .partial }.count
        unresolvedCount = outcomeRows.filter { $0.outcome == .unresolved }.count
        verificationUnavailableCount = outcomeRows.filter { $0.verification == .unavailable }.count
        timeoutCount = outcomeRows.filter { $0.outcome == .timedOut }.count
        cancellationCount = outcomeRows.filter { $0.outcome == .cancelled }.count
        deniedCount = outcomeRows.filter { $0.outcome == .denied }.count
        resourceFailureCount = outcomeRows.filter { $0.resource == .failed }.count
        unresolvedContradictionCount = outcomeRows.filter { $0.contradiction == .unresolved }.count
        userCorrectionCount = feedbackRows.filter { $0.feedback == .correction }.count
        userConfirmationCount = feedbackRows.filter { $0.feedback == .confirmation }.count
        let latencies = outcomeRows.compactMap { $0.latencyMilliseconds }
        latencySampleCount = latencies.count
        meanLatencyMilliseconds = latencies.isEmpty ? nil : latencies.reduce(0, +) / latencies.count
        lastObserved = observations.map { $0.observedAt }.max()
    }
}
