//
//  QModelCapabilityMemory.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2D Capability Memory facade & routing recommendation.
//
//      Outcome → Evidence → Capability Observation → Capability Memory → Routing Recommendation
//                                                                          │ (advice only)
//                                                                          ▼
//      Model Orchestrator / Model Router → the existing, unchanged security pipeline
//
//  Memory produces a RECOMMENDATION and nothing else. The recommendation can only REORDER
//  candidates the orchestrator has already established are registered, local, and available
//  (`QDeterministicModelOrchestrator` re-validates the permutation, so an advisor can neither add
//  nor remove a candidate). Every attempt still runs through `QModelRouter`'s unchanged
//  availability/egress checks and `QModelPlanParser`'s schema/risk validation, and every plan still
//  passes Permission → Resource Guard → execution → verification. Nothing in this file can grant a
//  permission, lower a risk, weaken verification, reach a cloud backend, or create a capability —
//  the types have no way to express any of that.
//
//  The ranking rule is deliberately not a score. It compares exact integer fractions (verified
//  successes / samples, adverse / samples) of REAL observations, only for candidates with at least
//  `minimumDistinctTasksForRecommendation` distinct observed tasks, and candidates without enough
//  observations keep their original position (a new model is neither promoted nor penalised for
//  being new).
//

import Foundation

// MARK: - Recommendation

public enum QRecommendationBasis: Sendable, Equatable {
    /// Not enough distinct observed tasks to rank this candidate; it keeps its original slot.
    case insufficientObservations(distinctTasks: Int)
    /// Ranked from real counts (these ARE the explanation — there is nothing hidden behind them).
    case observedOutcomes(samples: Int, verifiedSuccesses: Int, adverse: Int)
}

public struct QModelRoutingRecommendation: Sendable, Equatable {
    public let orderedBackends: [QModelBackendType]
    public let basis: [QModelBackendType: QRecommendationBasis]
    /// Whether the recommendation differs from the order it was given.
    public let reordered: Bool

    public static func unchanged(_ candidates: [QModelBackendType]) -> QModelRoutingRecommendation {
        QModelRoutingRecommendation(orderedBackends: candidates, basis: [:], reordered: false)
    }
}

/// Anything that can advise on candidate ORDER. Advice only: the orchestrator treats the result as
/// a suggestion over candidates it already vetted.
public protocol QModelRoutingAdvisor: Sendable {
    func advise(taskType: QTaskType, complexity: QTaskComplexity, candidates: [QModelBackendType], now: Date) -> QModelRoutingRecommendation
}

// MARK: - Recommender (pure)

public enum QModelRoutingRecommender {

    /// `profiles` are per-candidate profiles for the SAME (task type, complexity) key.
    public static func recommend(
        candidates: [QModelBackendType],
        profiles: [QModelBackendType: QModelCapabilityProfile]
    ) -> QModelRoutingRecommendation {
        var basis: [QModelBackendType: QRecommendationBasis] = [:]
        var rankable: [(backend: QModelBackendType, profile: QModelCapabilityProfile)] = []

        for backend in candidates {
            let profile = profiles[backend]
            let distinctTasks = profile?.distinctTaskCount ?? 0
            if let profile, distinctTasks >= QModelCapabilityLimits.minimumDistinctTasksForRecommendation, profile.sampleCount > 0 {
                basis[backend] = .observedOutcomes(samples: profile.sampleCount, verifiedSuccesses: profile.verifiedSuccessCount, adverse: profile.adverseCount)
                rankable.append((backend, profile))
            } else {
                basis[backend] = .insufficientObservations(distinctTasks: distinctTasks)
            }
        }

        // Stable, deterministic ordering by exact integer cross-multiplication (no floating point,
        // no synthetic score): higher verified-success fraction first, then lower adverse fraction,
        // then the ORIGINAL candidate order.
        var originalIndex: [QModelBackendType: Int] = [:]
        for (index, backend) in candidates.enumerated() where originalIndex[backend] == nil { originalIndex[backend] = index }
        let ranked = rankable.sorted { lhs, rhs in
            let lhsSamples = lhs.profile.sampleCount, rhsSamples = rhs.profile.sampleCount
            let lhsSuccess = lhs.profile.verifiedSuccessCount * rhsSamples
            let rhsSuccess = rhs.profile.verifiedSuccessCount * lhsSamples
            if lhsSuccess != rhsSuccess { return lhsSuccess > rhsSuccess }
            let lhsAdverse = lhs.profile.adverseCount * rhsSamples
            let rhsAdverse = rhs.profile.adverseCount * lhsSamples
            if lhsAdverse != rhsAdverse { return lhsAdverse < rhsAdverse }
            return (originalIndex[lhs.backend] ?? 0) < (originalIndex[rhs.backend] ?? 0)
        }.map { $0.backend }

        // Ranked candidates refill the slots ranked candidates already occupied; everyone else stays put.
        var rankedIterator = ranked.makeIterator()
        let rankedSet = Set(ranked)
        let ordered = candidates.map { rankedSet.contains($0) ? (rankedIterator.next() ?? $0) : $0 }

        return QModelRoutingRecommendation(orderedBackends: ordered, basis: basis, reordered: ordered != candidates)
    }
}

// MARK: - Memory facade

/// Durable capability memory over any `QModelCapabilityObservationStoring` (in production the
/// existing `QDurableTaskStore`). Reads and writes fail safe: an unavailable store yields an empty
/// profile / unchanged recommendation, never an error that could block a task.
public final class QModelCapabilityMemory: QModelRoutingAdvisor, @unchecked Sendable {
    private let store: any QModelCapabilityObservationStoring

    public init(store: any QModelCapabilityObservationStoring) {
        self.store = store
    }

    @discardableResult
    public func record(_ observation: QModelCapabilityObservation, now: Date = Date()) -> QObservationRecordResult {
        store.record(observation, now: now)
    }

    public func profile(taskType: QTaskType, complexity: QTaskComplexity, backend: QModelBackendType, now: Date = Date()) -> QModelCapabilityProfile {
        store.profile(for: QModelCapabilityProfileKey(taskType: taskType, complexity: complexity, backend: backend), now: now)
    }

    public func allProfiles(now: Date = Date()) -> [QModelCapabilityProfile] {
        store.profiles(now: now)
    }

    public func observations(forTask taskId: String, now: Date = Date()) -> QCapabilityReadResult {
        store.observations(forTask: taskId, now: now)
    }

    public func observationCount() -> Int {
        store.observationCount()
    }

    public func advise(taskType: QTaskType, complexity: QTaskComplexity, candidates: [QModelBackendType], now: Date = Date()) -> QModelRoutingRecommendation {
        guard candidates.count > 1 else { return .unchanged(candidates) }
        var profiles: [QModelBackendType: QModelCapabilityProfile] = [:]
        for backend in candidates {
            profiles[backend] = profile(taskType: taskType, complexity: complexity, backend: backend, now: now)
        }
        return QModelRoutingRecommender.recommend(candidates: candidates, profiles: profiles)
    }

    /// Records EXPLICIT user feedback about a task that was already observed. Attaches to the
    /// candidate(s) whose plan was actually used (the task-outcome rows); refuses — never invents —
    /// feedback for a task with no such observation.
    @discardableResult
    public func recordUserFeedback(taskId: String, feedback: QExplicitUserFeedback, now: Date = Date()) -> [QObservationRecordResult] {
        let taskRows = store.observations(forTask: taskId, now: now).observations.filter { $0.source == .taskOutcome }
        guard !taskRows.isEmpty else { return [.rejected(.noMatchingTaskObservation)] }
        return taskRows.map { row in
            store.record(
                QModelCapabilityObservation(
                    taskId: row.taskId, attemptId: row.attemptId, source: .userFeedback,
                    taskType: row.taskType, complexity: row.complexity, backend: row.backend, strategy: row.strategy,
                    attemptOutcome: row.attemptOutcome, verification: row.verification,
                    evidenceCompleteness: row.evidenceCompleteness, contradiction: row.contradiction,
                    resource: row.resource, execution: row.execution, latencyMilliseconds: nil,
                    feedback: feedback, observedAt: now
                ),
                now: now
            )
        }
    }
}

/// Wraps an advisor and remembers the last recommendation it gave, so the runtime can record what
/// was advised (observability) without querying memory twice.
public final class QRecordingRoutingAdvisor: QModelRoutingAdvisor, @unchecked Sendable {
    private let wrapped: any QModelRoutingAdvisor
    private let lock = NSLock()
    private var recorded: QModelRoutingRecommendation?

    public init(wrapping advisor: any QModelRoutingAdvisor) {
        self.wrapped = advisor
    }

    public var lastRecommendation: QModelRoutingRecommendation? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    public func advise(taskType: QTaskType, complexity: QTaskComplexity, candidates: [QModelBackendType], now: Date) -> QModelRoutingRecommendation {
        let recommendation = wrapped.advise(taskType: taskType, complexity: complexity, candidates: candidates, now: now)
        lock.lock()
        recorded = recommendation
        lock.unlock()
        return recommendation
    }
}
