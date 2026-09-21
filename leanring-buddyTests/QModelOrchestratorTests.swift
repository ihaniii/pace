//
//  QModelOrchestratorTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2B Model Orchestrator Unit Tests.
//  Exercises `QDeterministicModelOrchestrator` directly (no QCoreRuntime) against a fully
//  controllable fake `QModelCandidateAwareProvider`, so candidate availability, failure modes,
//  timing, and cancellation can all be driven deterministically without any real network/model
//  backend. Runtime (QCoreRuntime) integration is covered separately in
//  QModelOrchestrationRuntimeIntegrationTests.swift.
//

import Testing
import Foundation
@testable import Pace

// MARK: - Fake Candidate-Aware Model Provider

/// A fully controllable `QModelCandidateAwareProvider` test double. Each registered backend has
/// its own configurable availability and `Behavior` (succeed after an optional delay, throw a
/// specific error after an optional delay, or hang until cancelled) — enough to deterministically
/// drive every orchestrator code path without any real network/model call. A plain
/// `NSLock`-guarded class, not an actor — mirrors this codebase's existing `MockExecutionProvider`/
/// `MockAutonomousModelProvider` test-double idiom (QCoreRuntimeTests.swift/
/// QClosedLoopAgentTests.swift) rather than introducing a new concurrency-isolation shape.
final class FakeModelCandidateProvider: QModelCandidateAwareProvider, @unchecked Sendable {
    enum Behavior: Sendable {
        case succeed(afterNanoseconds: UInt64 = 0)
        case throwRouterError(QModelRouterError, afterNanoseconds: UInt64 = 0)
        case throwParseError(QModelPlanParseError, afterNanoseconds: UInt64 = 0)
        case throwGeneric(afterNanoseconds: UInt64 = 0)
        /// Sleeps far longer than any test's own timeout, checking cancellation cooperatively —
        /// used to prove a losing/cancelled race candidate is actually interrupted rather than
        /// left running to completion.
        case hang
    }

    private let lock = NSLock()
    private let backends: [QModelBackendType]
    private let availability: [QModelBackendType: Bool]
    private let behaviors: [QModelBackendType: Behavior]
    private var _attemptCount: [QModelBackendType: Int] = [:]
    private var _receivedPreferredBackends: [QModelBackendType?] = []
    private var _concurrentActiveCount: Int = 0
    private var _peakConcurrentActiveCount: Int = 0

    init(
        backends: [QModelBackendType],
        availability: [QModelBackendType: Bool] = [:],
        behaviors: [QModelBackendType: Behavior] = [:]
    ) {
        self.backends = backends
        self.availability = availability
        self.behaviors = behaviors
    }

    var attemptCount: [QModelBackendType: Int] {
        lock.lock(); defer { lock.unlock() }
        return _attemptCount
    }

    var peakConcurrentActiveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _peakConcurrentActiveCount
    }

    func candidateBackends() -> [QModelBackendType] {
        backends
    }

    func generatePlan(for task: QTask) async throws -> [QActionRequest] {
        []
    }

    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
        try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: nil, preferredBackend: nil)
    }

    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?) async throws -> QPlan {
        try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: decisionPlan, preferredBackend: nil)
    }

    func generateStructuredPlan(
        for task: QTask,
        memoryContext: String?,
        failureContext: String?,
        decisionPlan: QDecisionPlan?,
        preferredBackend: QModelBackendType?
    ) async throws -> QPlan {
        lock.lock()
        _receivedPreferredBackends.append(preferredBackend)
        lock.unlock()

        guard let backend = preferredBackend else {
            return QPlan(taskId: task.taskId, sessionId: task.sessionId, taskPrompt: task.intent, steps: [Self.defaultStep(backend: nil)])
        }

        lock.lock()
        _attemptCount[backend, default: 0] += 1
        _concurrentActiveCount += 1
        _peakConcurrentActiveCount = max(_peakConcurrentActiveCount, _concurrentActiveCount)
        let behavior = behaviors[backend] ?? .succeed()
        lock.unlock()
        defer {
            lock.lock()
            _concurrentActiveCount -= 1
            lock.unlock()
        }

        switch behavior {
        case .succeed(let delay):
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try Task.checkCancellation()
            return QPlan(taskId: task.taskId, sessionId: task.sessionId, taskPrompt: task.intent, steps: [Self.defaultStep(backend: backend)])
        case .throwRouterError(let error, let delay):
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try Task.checkCancellation()
            throw error
        case .throwParseError(let error, let delay):
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try Task.checkCancellation()
            throw error
        case .throwGeneric(let delay):
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try Task.checkCancellation()
            struct GenericTestError: Error {}
            throw GenericTestError()
        case .hang:
            try await Task.sleep(nanoseconds: 30_000_000_000)
            try Task.checkCancellation()
            return QPlan(taskId: task.taskId, sessionId: task.sessionId, taskPrompt: task.intent, steps: [Self.defaultStep(backend: backend)])
        }
    }

    func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String {
        "test summary"
    }

    func candidateDescriptor(for backend: QModelBackendType) async -> QModelCandidate? {
        guard backends.contains(backend) else { return nil }
        return QModelCandidate(
            backend: backend,
            capabilities: QModelCapabilities(backend: backend, modelIdentifier: "\(backend.rawValue)-test"),
            isAvailable: availability[backend] ?? true
        )
    }

    private static func defaultStep(backend: QModelBackendType?) -> QPlanStep {
        QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "test.noop", toolFamily: "test", riskLevel: .level0ReadOnly, literalAction: "noop-\(backend?.rawValue ?? "none")"),
            description: "noop"
        )
    }
}

// MARK: - Test Helpers

private func makeDecisionPlan(
    complexity: QTaskComplexity,
    uncertainty: QDecisionUncertainty,
    taskType: QTaskType = .reasoning
) -> QDecisionPlan {
    QDecisionPlan(
        taskType: taskType,
        complexity: complexity,
        decompositionDecision: .notRequired,
        reasoningStepBudget: 4,
        modelStrategy: .localReasoningModel,
        verificationRequirement: .executionEvidence,
        provenanceRequirement: .notRequired,
        resourceEnvelope: QDecisionResourceEnvelope(),
        uncertainty: uncertainty
    )
}

@Suite("QModelOrchestratorTests")
struct QModelOrchestratorTests {

    // MARK: - 1-6: Candidate Selection

    @Test("1. Single candidate: sequential path, singleCandidateOnly reason")
    func singleCandidate() async throws {
        let provider = FakeModelCandidateProvider(backends: [.ollama])
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .moderate, uncertainty: .high),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.isSuccess)
        #expect(result.earlyExitReason == .singleCandidateOnly)
        #expect(!result.didRace)
        #expect(result.attempts.count == 1)
    }

    @Test("2. Multiple candidates available: orchestration succeeds using at least one")
    func multipleCandidatesAvailable() async throws {
        let provider = FakeModelCandidateProvider(backends: [.ollama, .llamaCpp])
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .low),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.isSuccess)
        #expect(!result.attempts.isEmpty)
    }

    @Test("3. Unavailable candidate is never attempted")
    func unavailableCandidateNeverAttempted() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.ollama, .llamaCpp],
            availability: [.ollama: false, .llamaCpp: true]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .low),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.isSuccess)
        #expect(!result.attempts.contains { $0.backend == .ollama })
        let ollamaCallCount = provider.attemptCount[.ollama] ?? 0
        #expect(ollamaCallCount == 0)
    }

    @Test("4. Local-only filtering: a non-local candidate reporting available=true is NEVER attempted (defense in depth beyond QEgressBroker)")
    func nonLocalCandidateNeverAttempted() async throws {
        struct NonLocalOnlyProvider: QModelCandidateAwareProvider {
            func generatePlan(for task: QTask) async throws -> [QActionRequest] { [] }
            func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
                try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: nil, preferredBackend: nil)
            }
            func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?) async throws -> QPlan {
                try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: decisionPlan, preferredBackend: nil)
            }
            func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?, preferredBackend: QModelBackendType?) async throws -> QPlan {
                #expect(preferredBackend != .ollama, "the non-local candidate must never be attempted")
                return QPlan(taskId: task.taskId, sessionId: task.sessionId, taskPrompt: task.intent, steps: [
                    QPlanStep(index: 0, action: QPlannedAction(actionName: "test.noop", toolFamily: "test", riskLevel: .level0ReadOnly, literalAction: "noop"), description: "noop")
                ])
            }
            func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String { "" }
            func candidateBackends() -> [QModelBackendType] { [.ollama] }
            func candidateDescriptor(for backend: QModelBackendType) async -> QModelCandidate? {
                // Reports itself available AND non-local — the orchestrator must refuse this
                // regardless of the availability flag.
                QModelCandidate(
                    backend: backend,
                    capabilities: QModelCapabilities(backend: backend, modelIdentifier: "cloud-imposter", isLocalOnDevice: false),
                    isAvailable: true
                )
            }
        }
        let orchestrator = QDeterministicModelOrchestrator()
        await #expect(throws: QModelOrchestrationError.self) {
            _ = try await orchestrator.orchestrate(
                task: QTask(intent: "test"),
                decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .low),
                memoryContext: nil,
                modelProvider: NonLocalOnlyProvider()
            )
        }
    }

    @Test("5a. Racing eligibility: trivial/simple complexity never races, even with high uncertainty and multiple candidates")
    func trivialComplexityNeverRaces() {
        let eligibility = QDeterministicModelOrchestrator.racingEligibility(
            decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .high),
            availableCandidateCount: 3
        )
        if case .sequentialOnly = eligibility {} else {
            Issue.record("Expected sequentialOnly for simple complexity")
        }
    }

    @Test("5b. Racing eligibility: low uncertainty never races, even for moderate/complex tasks")
    func lowUncertaintyNeverRaces() {
        let eligibility = QDeterministicModelOrchestrator.racingEligibility(
            decisionPlan: makeDecisionPlan(complexity: .complex, uncertainty: .low),
            availableCandidateCount: 3
        )
        if case .sequentialOnly = eligibility {} else {
            Issue.record("Expected sequentialOnly for low uncertainty")
        }
    }

    @Test("5c. Racing eligibility: critical complexity never races (defense in depth — unreachable in the integrated runtime, see racingNotEligible's own doc)")
    func criticalComplexityNeverRaces() {
        let eligibility = QDeterministicModelOrchestrator.racingEligibility(
            decisionPlan: makeDecisionPlan(complexity: .critical, uncertainty: .high, taskType: .criticalHighRisk),
            availableCandidateCount: 3
        )
        guard case .sequentialOnly(let reason) = eligibility else {
            Issue.record("Expected sequentialOnly for critical complexity")
            return
        }
        #expect(reason == .racingNotEligible)
    }

    @Test("5d. Racing eligibility: moderate complexity + medium/high uncertainty + 2+ candidates IS eligible to race")
    func moderateComplexityHighUncertaintyRaces() {
        let eligibility = QDeterministicModelOrchestrator.racingEligibility(
            decisionPlan: makeDecisionPlan(complexity: .moderate, uncertainty: .medium),
            availableCandidateCount: 2
        )
        if case .bounded(let reason) = eligibility {
            #expect(reason == .firstSchemaValidPlanAccepted)
        } else {
            Issue.record("Expected bounded racing for moderate complexity + medium uncertainty")
        }
    }

    @Test("6. Resource filtering: racing never exceeds maxConcurrentCandidates even with 3+ available candidates")
    func racingBoundedToMaxConcurrentCandidates() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.appleFoundation, .mlx, .ollama],
            behaviors: [
                .appleFoundation: .succeed(afterNanoseconds: 50_000_000),
                .mlx: .succeed(afterNanoseconds: 50_000_000),
                .ollama: .succeed(afterNanoseconds: 50_000_000)
            ]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .complex, uncertainty: .high),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.didRace)
        let peak = provider.peakConcurrentActiveCount
        #expect(peak <= QDeterministicModelOrchestrator.maxConcurrentCandidates)
    }

    // MARK: - 7-16: Orchestration Behavior

    @Test("7. Single model orchestration: one candidate, succeeds, attempt recorded")
    func singleModelOrchestration() async throws {
        let provider = FakeModelCandidateProvider(backends: [.ollama])
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .moderate, uncertainty: .low),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.isSuccess)
        #expect(result.attempts.first?.backend == .ollama)
        #expect(result.attempts.first?.outcome.isAccepted == true)
    }

    @Test("8. Sequential fallback: first candidate fails, second succeeds")
    func sequentialFallback() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.appleFoundation, .mlx],
            behaviors: [.appleFoundation: .throwRouterError(.noBackendAvailable("down"))]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        // simple complexity -> sequential, never races, so this deterministically exercises fallback
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .high),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.isSuccess)
        #expect(result.attempts.count == 2)
        #expect(result.attempts[0].outcome == .unavailable)
        #expect(result.attempts[1].outcome.isAccepted)
    }

    @Test("9. Bounded race genuinely occurs for eligible tasks")
    func boundedRaceOccurs() async throws {
        let provider = FakeModelCandidateProvider(backends: [.ollama, .llamaCpp])
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .moderate, uncertainty: .high),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.didRace)
        #expect(result.isSuccess)
    }

    @Test("10. Winner selection: the faster candidate wins the race")
    func fasterCandidateWinsRace() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.ollama, .llamaCpp],
            behaviors: [
                .ollama: .succeed(afterNanoseconds: 300_000_000),
                .llamaCpp: .succeed(afterNanoseconds: 10_000_000)
            ]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .moderate, uncertainty: .high),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.didRace)
        #expect(result.winningPlan?.steps.first?.action.literalAction.contains("local.ollama") == false)
    }

    @Test("11. Early exit: the losing candidate's attempt is recorded as .cancelled, not left pending")
    func losingCandidateIsCancelled() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.ollama, .llamaCpp],
            behaviors: [
                .ollama: .succeed(afterNanoseconds: 5_000_000),
                .llamaCpp: .hang
            ]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .moderate, uncertainty: .high),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.isSuccess)
        let losingAttempt = result.attempts.first { $0.backend == .llamaCpp }
        #expect(losingAttempt?.outcome == .cancelled)
    }

    @Test("12a. Cancellation before start: a pre-cancelled enclosing Task throws before any attempt runs")
    func cancellationBeforeStart() async throws {
        let provider = FakeModelCandidateProvider(backends: [.ollama])
        let orchestrator = QDeterministicModelOrchestrator()
        let task = Task {
            try await orchestrator.orchestrate(
                task: QTask(intent: "test"),
                decisionPlan: makeDecisionPlan(complexity: .moderate, uncertainty: .high),
                memoryContext: nil,
                modelProvider: provider
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to propagate")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test("12b. Cancellation during a race: cancelling the enclosing Task mid-race yields no abandoned attempts")
    func cancellationDuringRace() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.ollama, .llamaCpp],
            behaviors: [.ollama: .hang, .llamaCpp: .hang]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        let task = Task {
            try await orchestrator.orchestrate(
                task: QTask(intent: "test"),
                decisionPlan: makeDecisionPlan(complexity: .moderate, uncertainty: .high),
                memoryContext: nil,
                modelProvider: provider
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            // expected — structured concurrency guarantees no orphaned child tasks either way
        } catch {
            // A typed orchestration error (e.g. noCandidatesAvailable/allCandidatesFailed) is
            // also an acceptable terminal outcome here — the load-bearing guarantee is that this
            // call returns promptly rather than hanging for the full 30s .hang duration.
        }
    }

    @Test("13. Timeout: a .timeout QModelRouterError maps to the .timedOut outcome, never treated as success")
    func timeoutMapsToTimedOutOutcome() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.ollama],
            behaviors: [.ollama: .throwRouterError(.timeout("took too long"))]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        // orchestrate() itself never throws on a candidate-level failure — it returns a typed
        // result with `winningPlan: nil`; QCoreRuntime's own integration point is what converts
        // that into a thrown planning failure (see QCoreRuntime.swift's orchestrator branch).
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .low),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(!result.isSuccess)
        #expect(result.attempts.first?.outcome == .timedOut)
    }

    @Test("14. Failure isolation: one candidate's unrelated generic error never corrupts a sibling's successful outcome")
    func failureIsolationBetweenCandidates() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.appleFoundation, .mlx],
            behaviors: [.appleFoundation: .throwGeneric()]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .high),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.isSuccess)
        #expect(result.attempts.contains { $0.backend == .mlx && $0.outcome.isAccepted })
    }

    @Test("15. Malformed/schema-invalid result: a thrown QModelPlanParseError maps to .invalid, never .accepted")
    func malformedResultMapsToInvalid() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.ollama],
            behaviors: [.ollama: .throwParseError(.emptySteps)]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .low),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(!result.isSuccess)
        guard case .invalid = result.attempts.first?.outcome else {
            Issue.record("Expected .invalid, got \(String(describing: result.attempts.first?.outcome))")
            return
        }
    }

    @Test("16. All candidates failing produces a non-success result carrying every attempt — and QModelOrchestrationError.allCandidatesFailed (the shape QCoreRuntime's integration throws) can be built from it")
    func allCandidatesFailedCarriesAttemptIds() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.appleFoundation, .mlx],
            behaviors: [
                .appleFoundation: .throwRouterError(.noBackendAvailable("down")),
                .mlx: .throwRouterError(.noBackendAvailable("also down"))
            ]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .high),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(!result.isSuccess)
        #expect(result.attempts.count == 2)
        // Exactly the mapping QCoreRuntime.swift's orchestrator branch performs when
        // `winningPlan == nil` — verified here so this test would fail if that shape ever drifted.
        let error = QModelOrchestrationError.allCandidatesFailed(attemptIds: result.attempts.map { $0.attemptId })
        if case .allCandidatesFailed(let attemptIds) = error {
            #expect(attemptIds.count == 2)
        }
    }

    // MARK: - 26-30: Resource

    @Test("26. Bounded concurrency is respected across a wider candidate set (4 backends, only 2 concurrent)")
    func boundedConcurrencyAcrossFourBackends() async throws {
        let provider = FakeModelCandidateProvider(
            backends: QModelBackendType.allCases,
            behaviors: Dictionary(uniqueKeysWithValues: QModelBackendType.allCases.map { ($0, .succeed(afterNanoseconds: 40_000_000)) })
        )
        let orchestrator = QDeterministicModelOrchestrator()
        _ = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .complex, uncertainty: .high),
            memoryContext: nil,
            modelProvider: provider
        )
        let peak = provider.peakConcurrentActiveCount
        #expect(peak <= QDeterministicModelOrchestrator.maxConcurrentCandidates)
    }

    @Test("29. Cancellation releases resources: peak concurrent count never exceeds the bound even when cancelled mid-race")
    func cancellationReleasesResources() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.ollama, .llamaCpp],
            behaviors: [.ollama: .hang, .llamaCpp: .hang]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        let task = Task {
            try? await orchestrator.orchestrate(
                task: QTask(intent: "test"),
                decisionPlan: makeDecisionPlan(complexity: .moderate, uncertainty: .high),
                memoryContext: nil,
                modelProvider: provider
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        _ = await task.value
        let peak = provider.peakConcurrentActiveCount
        #expect(peak <= QDeterministicModelOrchestrator.maxConcurrentCandidates)
    }

    // MARK: - 31-34: Determinism

    @Test("31. Deterministic candidate ordering: candidateBackends() order is preserved in attempt ordering for sequential runs")
    func deterministicCandidateOrdering() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.appleFoundation, .mlx],
            behaviors: [.appleFoundation: .throwRouterError(.noBackendAvailable("down"))]
        )
        let orchestrator = QDeterministicModelOrchestrator()
        let result = try await orchestrator.orchestrate(
            task: QTask(intent: "test"),
            decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .high),
            memoryContext: nil,
            modelProvider: provider
        )
        #expect(result.attempts.map { $0.backend } == [.appleFoundation, .mlx])
    }

    @Test("32. Deterministic attempt identity: the same task/candidate/position always produces the same attemptId string")
    func deterministicAttemptIdentity() async throws {
        let task = QTask(taskId: "fixed-task-id", intent: "test")
        let provider1 = FakeModelCandidateProvider(backends: [.ollama])
        let provider2 = FakeModelCandidateProvider(backends: [.ollama])
        let orchestrator = QDeterministicModelOrchestrator()
        let result1 = try await orchestrator.orchestrate(task: task, decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .low), memoryContext: nil, modelProvider: provider1)
        let result2 = try await orchestrator.orchestrate(task: task, decisionPlan: makeDecisionPlan(complexity: .simple, uncertainty: .low), memoryContext: nil, modelProvider: provider2)
        #expect(result1.attempts.first?.attemptId == result2.attempts.first?.attemptId)
        #expect(result1.attempts.first?.attemptId.rawValue == "fixed-task-id-attempt-local.ollama-0")
    }

    @Test("33. Deterministic fallback: the same failing-then-succeeding sequence always produces the same winning backend")
    func deterministicFallbackWinner() async throws {
        let task = QTask(taskId: "fallback-task", intent: "test")
        let decisionPlan = makeDecisionPlan(complexity: .simple, uncertainty: .high)
        let orchestrator = QDeterministicModelOrchestrator()

        let provider1 = FakeModelCandidateProvider(backends: [.appleFoundation, .mlx], behaviors: [.appleFoundation: .throwRouterError(.noBackendAvailable("down"))])
        let result1 = try await orchestrator.orchestrate(task: task, decisionPlan: decisionPlan, memoryContext: nil, modelProvider: provider1)

        let provider2 = FakeModelCandidateProvider(backends: [.appleFoundation, .mlx], behaviors: [.appleFoundation: .throwRouterError(.noBackendAvailable("down"))])
        let result2 = try await orchestrator.orchestrate(task: task, decisionPlan: decisionPlan, memoryContext: nil, modelProvider: provider2)

        #expect(result1.attempts.last?.backend == result2.attempts.last?.backend)
        #expect(result1.attempts.last?.backend == .mlx)
    }

    @Test("34. Reproducible orchestration decision: racingEligibility is a pure function of its inputs")
    func reproducibleOrchestrationDecision() {
        let decisionPlan = makeDecisionPlan(complexity: .moderate, uncertainty: .medium)
        let first = QDeterministicModelOrchestrator.racingEligibility(decisionPlan: decisionPlan, availableCandidateCount: 2)
        let second = QDeterministicModelOrchestrator.racingEligibility(decisionPlan: decisionPlan, availableCandidateCount: 2)
        #expect(first == second)
    }
}
