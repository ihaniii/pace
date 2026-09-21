//
//  QModelOrchestrator.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2B Bounded Multi-Model Orchestration.
//  Sits strictly ABOVE QModelRouter, exactly like the Decision Engine sits strictly above the
//  planner (Phase 2A.4): it asks the router which candidates exist, attempts a small, bounded
//  number of them (sequentially or — only when the decision plan calls for it — racing at most
//  `maxConcurrentCandidates` at once), and returns a typed `QModelOrchestrationResult`. It NEVER
//  selects a concrete backend on its own authority (every attempt still goes through
//  `QModelRouter.generateStructuredPlan(...,preferredBackend:)`, which still runs `routeInference`'s
//  own unchanged availability/egress checks for that backend), NEVER executes a `QPlan` action,
//  and NEVER grants a permission/resource/egress authority. Every plan this produces still flows
//  through the exact same `QModelPlanParser` → `QPlanExecutor` → `QPermissionGate` →
//  `QResourceGuard` → `QActionVerifier` pipeline any other plan already does.
//
//  Architecture: `QTask + QDecisionPlan → QModelOrchestrator.orchestrate(...) →
//  QModelOrchestrationResult (a QPlan, or none, plus the full attempt record)`. Nothing here is
//  wired into `QCoreRuntime` by this file alone — see `QCoreRuntime.swift`'s own integration point
//  for how a `QModelCandidateAwareProvider` gets preferred over the plain decision-aware path.
//

import Foundation

// MARK: - Candidate-Aware Model Provider

/// A `QDecisionContextAwareModelProvider` that can additionally be asked to attempt a SPECIFIC
/// backend candidate, and that can report which backends it has registered. `QCoreRuntime` prefers
/// this path (via `QModelOrchestrator`) when the configured model provider conforms to it;
/// providers that don't conform are entirely unaffected and keep using their existing
/// `QDecisionContextAwareModelProvider`/`QStructuredModelProvider` conformance exactly as before.
public protocol QModelCandidateAwareProvider: QDecisionContextAwareModelProvider {
    /// Identical contract to the 4-arg `decisionPlan`-aware overload, with one additional,
    /// optional parameter: a specific backend to target. `preferredBackend: nil` MUST behave
    /// identically to the 4-arg overload (auto-selection, unchanged). Implementations must still
    /// perform their own full availability/egress checks for the preferred backend — this
    /// parameter is a request, never a bypass.
    func generateStructuredPlan(
        for task: QTask,
        memoryContext: String?,
        failureContext: String?,
        decisionPlan: QDecisionPlan?,
        preferredBackend: QModelBackendType?
    ) async throws -> QPlan

    /// The backends this provider currently has registered, in its own priority order — never a
    /// claim about which are actually available right now, and never a quality ranking.
    func candidateBackends() -> [QModelBackendType]

    /// The registered backend descriptor for `backend`, if any — used to build a
    /// `QModelCandidate`'s `capabilities`/`isAvailable` fields without the orchestrator needing to
    /// know anything about how the provider stores its backends internally.
    func candidateDescriptor(for backend: QModelBackendType) async -> QModelCandidate?
}

extension QModelRouter {
    public func candidateDescriptor(for backend: QModelBackendType) async -> QModelCandidate? {
        guard let registered = getBackend(type: backend) else { return nil }
        let available = await registered.isAvailable()
        return QModelCandidate(backend: backend, capabilities: registered.capabilities, isAvailable: available)
    }
}

// MARK: - Racing Eligibility (internal derivation, never a new QDecisionPlan field)

/// How orchestration should proceed for this task — derived entirely from `QDecisionPlan` fields
/// that already exist (Phase 2A never gained a new "allow racing" field, deliberately — see
/// `QDecisionEngineContracts.swift`'s own `QModelStrategy` doc, which explicitly excludes racing
/// from what a `QDecisionPlan` may express). This derivation lives in the orchestrator, not the
/// Decision Engine, because it is about HOW to attempt a strategy, not WHAT the strategy is.
enum QModelRacingEligibility: Equatable {
    case sequentialOnly(reason: QModelEarlyExitReason)
    case bounded(reason: QModelEarlyExitReason)
}

// MARK: - Orchestrator Protocol

/// Provider-independent contract for anything that can orchestrate bounded candidate attempts for
/// a task — mirrors this codebase's existing `QDecisionEngine`/`QTaskDecomposer` provider-protocol
/// shape. A conforming type only ever ATTEMPTS candidates and SELECTS among their typed outcomes;
/// it never executes a `QPlan` action and never grants permission/resource/egress authority.
public protocol QModelOrchestrator: Sendable {
    func orchestrate(
        task: QTask,
        decisionPlan: QDecisionPlan,
        memoryContext: String?,
        modelProvider: any QModelCandidateAwareProvider
    ) async throws -> QModelOrchestrationResult
}

// MARK: - Deterministic Model Orchestrator

/// The first real `QModelOrchestrator` implementation. Purely rule-based candidate selection and
/// eligibility — no model invocation of its own beyond what it asks `modelProvider` to perform, no
/// learning, no capability scoring. See this file's header for the full design rationale.
public struct QDeterministicModelOrchestrator: QModelOrchestrator, Sendable {

    /// The hard ceiling on simultaneously-in-flight candidate attempts. Fixed at 2, never
    /// configurable upward from outside this type: on the M1 Pro 16GB baseline this project
    /// targets, running more than two local models' inference concurrently risks real memory/
    /// thermal contention for no benefit this phase's own early-exit criteria can use (the first
    /// schema-valid plan already wins) — "default to the smallest safe candidate count" from this
    /// phase's own spec, taken literally.
    public static let maxConcurrentCandidates = 2

    /// Optional, ADVISORY candidate-order source (Phase 2D capability memory). It can only reorder
    /// candidates this orchestrator has already filtered to registered + local + available; it can
    /// neither add nor remove one, and every attempt still runs the unmodified router checks.
    /// `nil` (the default) leaves candidate order exactly as the provider reported it.
    private let routingAdvisor: (any QModelRoutingAdvisor)?

    public init(routingAdvisor: (any QModelRoutingAdvisor)? = nil) {
        self.routingAdvisor = routingAdvisor
    }

    public func orchestrate(
        task: QTask,
        decisionPlan: QDecisionPlan,
        memoryContext: String?,
        modelProvider: any QModelCandidateAwareProvider
    ) async throws -> QModelOrchestrationResult {
        try Task.checkCancellation()

        let candidates = await buildCandidates(modelProvider: modelProvider)
        // Defense in depth beyond QEgressBroker/QModelRouter's own localOnly setting: this
        // orchestrator refuses to ever attempt a non-local candidate, full stop, regardless of
        // what any provider reports as "available." No cloud fallback is possible from here even
        // if a future provider mis-registers a non-local backend as available.
        let vettedCandidates = candidates.filter { $0.isLocalOnDevice && $0.isAvailable }

        guard !vettedCandidates.isEmpty else {
            throw QModelOrchestrationError.noCandidatesAvailable
        }
        let localAvailableCandidates = applyAdvisoryOrder(to: vettedCandidates, decisionPlan: decisionPlan)

        let eligibility = Self.racingEligibility(
            decisionPlan: decisionPlan,
            availableCandidateCount: localAvailableCandidates.count
        )

        switch eligibility {
        case .sequentialOnly(let reason):
            return try await runSequential(
                candidates: localAvailableCandidates,
                task: task,
                decisionPlan: decisionPlan,
                memoryContext: memoryContext,
                modelProvider: modelProvider,
                earlyExitReason: reason,
                didRace: false
            )

        case .bounded(let reason):
            let raceCandidates = Array(localAvailableCandidates.prefix(Self.maxConcurrentCandidates))
            let raceResult = try await runBoundedRace(
                candidates: raceCandidates,
                task: task,
                decisionPlan: decisionPlan,
                memoryContext: memoryContext,
                modelProvider: modelProvider,
                earlyExitReason: reason
            )
            if raceResult.isSuccess {
                return raceResult
            }
            // The race itself produced no acceptance — fall back sequentially through any
            // remaining, not-yet-attempted available candidates rather than giving up immediately.
            // "Prefer sequential fallback when concurrency would exceed safe resource bounds" and
            // general robustness both call for this rather than a hard stop at the race alone.
            let remaining = Array(localAvailableCandidates.dropFirst(raceCandidates.count))
            guard !remaining.isEmpty else {
                return raceResult
            }
            let fallbackResult = try await runSequential(
                candidates: remaining,
                task: task,
                decisionPlan: decisionPlan,
                memoryContext: memoryContext,
                modelProvider: modelProvider,
                earlyExitReason: .allCandidatesExhausted,
                didRace: true,
                priorAttempts: raceResult.attempts
            )
            return fallbackResult
        }
    }

    // MARK: - Advisory Ordering

    /// Applies the advisor's order to ALREADY-VETTED candidates. The result is always a permutation
    /// of `candidates`: unknown or duplicate backends in the advice are ignored, and any candidate
    /// the advice omits keeps its relative position at the end — advice can never inject, drop, or
    /// substitute a candidate.
    private func applyAdvisoryOrder(to candidates: [QModelCandidate], decisionPlan: QDecisionPlan) -> [QModelCandidate] {
        guard let routingAdvisor, candidates.count > 1 else { return candidates }
        let advice = routingAdvisor.advise(
            taskType: decisionPlan.taskType,
            complexity: decisionPlan.complexity,
            candidates: candidates.map { $0.backend },
            now: Date()
        )
        var remaining = candidates
        var ordered: [QModelCandidate] = []
        for backend in advice.orderedBackends {
            if let index = remaining.firstIndex(where: { $0.backend == backend }) {
                ordered.append(remaining.remove(at: index))
            }
        }
        ordered.append(contentsOf: remaining)
        return ordered
    }

    // MARK: - Candidate Construction

    private func buildCandidates(modelProvider: any QModelCandidateAwareProvider) async -> [QModelCandidate] {
        var candidates: [QModelCandidate] = []
        for backend in modelProvider.candidateBackends() {
            if let descriptor = await modelProvider.candidateDescriptor(for: backend) {
                candidates.append(descriptor)
            }
        }
        return candidates
    }

    // MARK: - Racing Eligibility

    /// Derives whether this task should ever attempt more than one candidate concurrently, from
    /// `QDecisionPlan` fields that already exist — never a new field on `QDecisionPlan` itself
    /// (see `QModelRacingEligibility`'s own doc for why). Never races `.trivial`/`.simple`
    /// complexity (nothing to usefully compare) or a `.low`-uncertainty decision (the engine is
    /// already confident; racing would spend resources for no expected benefit). `.critical`
    /// complexity always falls through to `.sequentialOnly` here too — defense in depth, though in
    /// the integrated runtime it is already unreachable (see `QModelEarlyExitReason.racingNotEligible`'s
    /// own doc).
    static func racingEligibility(decisionPlan: QDecisionPlan, availableCandidateCount: Int) -> QModelRacingEligibility {
        guard availableCandidateCount > 1 else {
            return .sequentialOnly(reason: .singleCandidateOnly)
        }
        guard decisionPlan.complexity == .moderate || decisionPlan.complexity == .complex else {
            return .sequentialOnly(reason: decisionPlan.complexity == .critical ? .racingNotEligible : .firstValidResultSufficient)
        }
        guard decisionPlan.uncertainty == .medium || decisionPlan.uncertainty == .high else {
            return .sequentialOnly(reason: .firstValidResultSufficient)
        }
        return .bounded(reason: .firstSchemaValidPlanAccepted)
    }

    // MARK: - Sequential Attempts

    private func runSequential(
        candidates: [QModelCandidate],
        task: QTask,
        decisionPlan: QDecisionPlan,
        memoryContext: String?,
        modelProvider: any QModelCandidateAwareProvider,
        earlyExitReason: QModelEarlyExitReason,
        didRace: Bool,
        priorAttempts: [QModelAttempt] = []
    ) async throws -> QModelOrchestrationResult {
        var attempts = priorAttempts
        for candidate in candidates {
            try Task.checkCancellation()
            let attempt = await Self.attempt(
                candidate: candidate,
                index: attempts.count,
                task: task,
                decisionPlan: decisionPlan,
                memoryContext: memoryContext,
                modelProvider: modelProvider
            )
            attempts.append(attempt)
            if case .accepted(let plan) = attempt.outcome {
                // A sequential loop inherently stops at the first success, whichever position it
                // was found at — that IS what `earlyExitReason` already describes (e.g. "first
                // valid result sufficient"); `.allCandidatesExhausted` is reserved for the no-
                // success case below, never overloaded to also mean "succeeded, but not first."
                return QModelOrchestrationResult(
                    winningPlan: plan,
                    attempts: attempts,
                    earlyExitReason: earlyExitReason,
                    didRace: didRace
                )
            }
        }
        return QModelOrchestrationResult(
            winningPlan: nil,
            attempts: attempts,
            earlyExitReason: .allCandidatesExhausted,
            didRace: didRace
        )
    }

    // MARK: - Bounded Race

    private func runBoundedRace(
        candidates: [QModelCandidate],
        task: QTask,
        decisionPlan: QDecisionPlan,
        memoryContext: String?,
        modelProvider: any QModelCandidateAwareProvider,
        earlyExitReason: QModelEarlyExitReason
    ) async throws -> QModelOrchestrationResult {
        try await withThrowingTaskGroup(of: QModelAttempt.self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    await Self.attempt(
                        candidate: candidate,
                        index: index,
                        task: task,
                        decisionPlan: decisionPlan,
                        memoryContext: memoryContext,
                        modelProvider: modelProvider
                    )
                }
            }

            var attempts: [QModelAttempt] = []
            var winningPlan: QPlan?
            while let attempt = try await group.next() {
                attempts.append(attempt)
                if case .accepted(let plan) = attempt.outcome, winningPlan == nil {
                    winningPlan = plan
                    // Cooperatively cancel every still-running losing candidate — no abandoned
                    // background inference once a winner is confirmed. `withThrowingTaskGroup`
                    // still awaits every child before this function returns (structured
                    // concurrency's own guarantee), so this only ever shortens how long losers
                    // keep running, never leaves anything detached.
                    group.cancelAll()
                }
            }

            return QModelOrchestrationResult(
                winningPlan: winningPlan,
                attempts: attempts.sorted { $0.startedAt < $1.startedAt },
                earlyExitReason: winningPlan != nil ? earlyExitReason : .allCandidatesExhausted,
                didRace: true
            )
        }
    }

    // MARK: - Single Attempt

    private static func attempt(
        candidate: QModelCandidate,
        index: Int,
        task: QTask,
        decisionPlan: QDecisionPlan,
        memoryContext: String?,
        modelProvider: any QModelCandidateAwareProvider
    ) async -> QModelAttempt {
        let attemptId = QModelAttemptID(rawValue: "\(task.taskId)-attempt-\(candidate.id.rawValue)-\(index)")
        let startedAt = Date()

        if Task.isCancelled {
            return QModelAttempt(
                attemptId: attemptId,
                taskId: task.taskId,
                candidateId: candidate.id,
                backend: candidate.backend,
                outcome: .cancelled,
                startedAt: startedAt,
                finishedAt: Date()
            )
        }

        do {
            let plan = try await modelProvider.generateStructuredPlan(
                for: task,
                memoryContext: memoryContext,
                failureContext: nil,
                decisionPlan: decisionPlan,
                preferredBackend: candidate.backend
            )
            return QModelAttempt(
                attemptId: attemptId,
                taskId: task.taskId,
                candidateId: candidate.id,
                backend: candidate.backend,
                outcome: .accepted(plan: plan),
                startedAt: startedAt,
                finishedAt: Date()
            )
        } catch is CancellationError {
            return QModelAttempt(
                attemptId: attemptId,
                taskId: task.taskId,
                candidateId: candidate.id,
                backend: candidate.backend,
                outcome: .cancelled,
                startedAt: startedAt,
                finishedAt: Date()
            )
        } catch let error as QModelRouterError {
            let outcome: QModelAttemptOutcome
            switch error {
            case .noBackendAvailable:
                outcome = .unavailable
            case .egressBlocked(let message):
                outcome = .rejected(reason: message)
            case .timeout:
                outcome = .timedOut
            }
            return QModelAttempt(
                attemptId: attemptId,
                taskId: task.taskId,
                candidateId: candidate.id,
                backend: candidate.backend,
                outcome: outcome,
                startedAt: startedAt,
                finishedAt: Date()
            )
        } catch let error as QModelPlanParseError {
            return QModelAttempt(
                attemptId: attemptId,
                taskId: task.taskId,
                candidateId: candidate.id,
                backend: candidate.backend,
                outcome: .invalid(reason: "\(error)"),
                startedAt: startedAt,
                finishedAt: Date()
            )
        } catch {
            return QModelAttempt(
                attemptId: attemptId,
                taskId: task.taskId,
                candidateId: candidate.id,
                backend: candidate.backend,
                outcome: .rejected(reason: error.localizedDescription),
                startedAt: startedAt,
                finishedAt: Date()
            )
        }
    }
}
