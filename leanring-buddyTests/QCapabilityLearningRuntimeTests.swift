//
//  QCapabilityLearningRuntimeTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2D/2E integration, authority-separation, privacy, and static
//  audit tests. Proves capability memory / outcome learning are ADVISORY: they reorder candidates
//  the orchestrator already vetted and record content-free observations, and every authority
//  (Model Router, Permission Gate, Resource Guard, Egress, verification) stays untouched.
//

import Testing
import Foundation
import SQLite3
@testable import Pace

// MARK: - Test doubles

/// An advisor that returns whatever order it is told to — including hostile ones.
private struct ScriptedAdvisor: QModelRoutingAdvisor {
    let order: [QModelBackendType]
    func advise(taskType: QTaskType, complexity: QTaskComplexity, candidates: [QModelBackendType], now: Date) -> QModelRoutingRecommendation {
        QModelRoutingRecommendation(orderedBackends: order, basis: [:], reordered: true)
    }
}

private final class AttemptedBackends: @unchecked Sendable {
    private let lock = NSLock()
    private var backends: [QModelBackendType] = []
    func append(_ backend: QModelBackendType) { lock.lock(); backends.append(backend); lock.unlock() }
    var all: [QModelBackendType] { lock.lock(); defer { lock.unlock() }; return backends }
}

/// A provider with two local candidates and one NON-local one (`.llamaCpp`), recording what is attempted.
private struct MixedLocalityProvider: QModelCandidateAwareProvider {
    let attempted: AttemptedBackends

    func generatePlan(for task: QTask) async throws -> [QActionRequest] { [] }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
        try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: nil, preferredBackend: nil)
    }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?) async throws -> QPlan {
        try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: decisionPlan, preferredBackend: nil)
    }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?, preferredBackend: QModelBackendType?) async throws -> QPlan {
        if let preferredBackend { attempted.append(preferredBackend) }
        let step = QPlanStep(index: 0, action: QPlannedAction(actionName: "test.noop", toolFamily: "test", riskLevel: .level0ReadOnly, literalAction: "noop"), description: "noop")
        return QPlan(taskId: task.taskId, sessionId: task.sessionId, taskPrompt: task.intent, steps: [step])
    }
    func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String { "" }
    func candidateBackends() -> [QModelBackendType] { [.ollama, .mlx, .llamaCpp] }
    func candidateDescriptor(for backend: QModelBackendType) async -> QModelCandidate? {
        QModelCandidate(
            backend: backend,
            capabilities: QModelCapabilities(backend: backend, modelIdentifier: "test", isLocalOnDevice: backend != .llamaCpp),
            isAvailable: true
        )
    }
}

/// A candidate-aware provider whose plan needs USER APPROVAL (Level 2).
private struct Level2ClipboardProvider: QModelCandidateAwareProvider {
    func generatePlan(for task: QTask) async throws -> [QActionRequest] { [] }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
        try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: nil, preferredBackend: nil)
    }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?) async throws -> QPlan {
        try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: decisionPlan, preferredBackend: nil)
    }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?, preferredBackend: QModelBackendType?) async throws -> QPlan {
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "system.clipboard.write", toolFamily: "system", riskLevel: .level2UserApproval, literalAction: "Write a marker to the clipboard", arguments: ["text": "q-2de-marker"]),
            description: "Write a marker"
        )
        return QPlan(taskId: task.taskId, sessionId: task.sessionId, taskPrompt: task.intent, steps: [step])
    }
    func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String { "" }
    func candidateBackends() -> [QModelBackendType] { [.ollama] }
    func candidateDescriptor(for backend: QModelBackendType) async -> QModelCandidate? {
        QModelCandidate(backend: backend, capabilities: QModelCapabilities(backend: backend, modelIdentifier: "test"), isAvailable: true)
    }
}

/// A candidate-aware provider whose plan touches a DENYLISTED resource.
private struct DenylistedReadProvider: QModelCandidateAwareProvider {
    func generatePlan(for task: QTask) async throws -> [QActionRequest] { [] }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
        try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: nil, preferredBackend: nil)
    }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?) async throws -> QPlan {
        try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: decisionPlan, preferredBackend: nil)
    }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?, preferredBackend: QModelBackendType?) async throws -> QPlan {
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "fs.read", toolFamily: "fs", riskLevel: .level0ReadOnly, literalAction: "Read SSH keys", targetResources: ["~/.ssh/id_rsa"]),
            description: "Read SSH keys"
        )
        return QPlan(taskId: task.taskId, sessionId: task.sessionId, taskPrompt: task.intent, steps: [step])
    }
    func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String { "" }
    func candidateBackends() -> [QModelBackendType] { [.ollama] }
    func candidateDescriptor(for backend: QModelBackendType) async -> QModelCandidate? {
        QModelCandidate(backend: backend, capabilities: QModelCapabilities(backend: backend, modelIdentifier: "test"), isAvailable: true)
    }
}

// MARK: - Advisory routing (orchestrator boundary)

@Suite("QCapabilityRoutingAdvisoryTests")
struct QCapabilityRoutingAdvisoryTests {

    private let simplePlan = EvidenceFixtures.decisionPlan(taskType: .simpleQA, complexity: .simple, requirement: .none)

    @Test("28. Advice reorders vetted candidates: the advised candidate is attempted first")
    func adviceReordersVettedCandidates() async throws {
        let provider = FakeModelCandidateProvider(backends: [.ollama, .llamaCpp])
        let orchestrator = QDeterministicModelOrchestrator(routingAdvisor: ScriptedAdvisor(order: [.llamaCpp, .ollama]))
        let result = try await orchestrator.orchestrate(task: QTask(intent: "q"), decisionPlan: simplePlan, memoryContext: nil, modelProvider: provider)

        #expect(result.attempts.first?.backend == .llamaCpp)
        #expect(provider.attemptCount[.llamaCpp] == 1)
        #expect(provider.attemptCount[.ollama] == nil)   // first valid plan wins; the other was never needed
    }

    @Test("29. Model Router authority preserved: hostile advice (unknown, duplicate, omitted, injected backends) can never add, drop, or substitute a candidate")
    func hostileAdviceCannotChangeTheCandidateSet() async throws {
        let provider = FakeModelCandidateProvider(
            backends: [.ollama, .llamaCpp],
            behaviors: [.ollama: .throwGeneric(), .llamaCpp: .throwGeneric()]   // force exhaustive attempts so every candidate is observable
        )
        let hostile = ScriptedAdvisor(order: [.mlx, .appleFoundation, .llamaCpp, .llamaCpp])   // injects 2 unregistered, duplicates one, omits ollama
        let orchestrator = QDeterministicModelOrchestrator(routingAdvisor: hostile)

        let result = try await orchestrator.orchestrate(task: QTask(intent: "q"), decisionPlan: simplePlan, memoryContext: nil, modelProvider: provider)

        #expect(result.attempts.map { $0.backend } == [.llamaCpp, .ollama])          // ollama kept (appended), nothing injected
        #expect(provider.attemptCount[.mlx] == nil && provider.attemptCount[.appleFoundation] == nil)
        #expect(provider.attemptCount[.llamaCpp] == 1 && provider.attemptCount[.ollama] == 1)
    }

    @Test("32. Egress authority preserved: advice can never cause a non-local candidate to be attempted")
    func adviceCannotReachANonLocalCandidate() async throws {
        let attempted = AttemptedBackends()
        let provider = MixedLocalityProvider(attempted: attempted)
        // The advisor tries to put the NON-local backend first.
        let orchestrator = QDeterministicModelOrchestrator(routingAdvisor: ScriptedAdvisor(order: [.llamaCpp, .mlx, .ollama]))

        let result = try await orchestrator.orchestrate(task: QTask(intent: "q"), decisionPlan: simplePlan, memoryContext: nil, modelProvider: provider)

        #expect(attempted.all == [.mlx])                         // the advised order applied among the LOCAL candidates only
        #expect(!attempted.all.contains(.llamaCpp))
        #expect(result.attempts.allSatisfy { $0.backend != .llamaCpp })
    }

    @Test("With no advisor (the default) candidate order is exactly what the provider reported — Phase 2B behaviour is unchanged")
    func noAdvisorMeansUnchangedOrder() async throws {
        let provider = FakeModelCandidateProvider(backends: [.ollama, .llamaCpp], behaviors: [.ollama: .throwGeneric(), .llamaCpp: .throwGeneric()])
        let result = try await QDeterministicModelOrchestrator().orchestrate(task: QTask(intent: "q"), decisionPlan: simplePlan, memoryContext: nil, modelProvider: provider)
        #expect(result.attempts.map { $0.backend } == [.ollama, .llamaCpp])
    }

    @Test("Real memory drives real advice through the orchestrator: history recorded earlier changes the next task's first attempt")
    func realMemoryDrivesAdvice() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let memory = QModelCapabilityMemory(store: store)
        CapabilityFixtures.seed(store, backend: .ollama, count: 6, successful: false, taskType: .simpleQA, complexity: .simple)
        CapabilityFixtures.seed(store, backend: .llamaCpp, count: 6, successful: true, taskType: .simpleQA, complexity: .simple)
        let provider = FakeModelCandidateProvider(backends: [.ollama, .llamaCpp])

        // The memory clock in the fixtures is fixed; give the advisor the same clock through a thin wrapper.
        struct FixedClockAdvisor: QModelRoutingAdvisor {
            let memory: QModelCapabilityMemory
            func advise(taskType: QTaskType, complexity: QTaskComplexity, candidates: [QModelBackendType], now: Date) -> QModelRoutingRecommendation {
                memory.advise(taskType: taskType, complexity: complexity, candidates: candidates, now: CapabilityFixtures.now.addingTimeInterval(100))
            }
        }
        let result = try await QDeterministicModelOrchestrator(routingAdvisor: FixedClockAdvisor(memory: memory))
            .orchestrate(task: QTask(intent: "q"), decisionPlan: simplePlan, memoryContext: nil, modelProvider: provider)
        #expect(result.attempts.first?.backend == .llamaCpp)
    }
}

// MARK: - Runtime integration

@Suite("QCapabilityLearningRuntimeTests")
struct QCapabilityLearningRuntimeTests {

    private func events(_ store: QDurableTaskStore, taskId: String, type: QTaskLifecycleEventType) throws -> [QTaskLifecycleEvent] {
        try store.listEvents(taskId: taskId).filter { $0.eventType == type }
    }

    private func decisionKey(_ prompt: String) -> (QTaskType, QTaskComplexity) {
        let plan = QDeterministicDecisionEngine().decide(for: QTask(intent: prompt))
        return (plan.taskType, plan.complexity)
    }

    @Test("A completed task records a verified success for the executed candidate, once, and an audit-safe learning event")
    func completedTaskIsLearnedFrom() async throws {
        let eventStore = try QDurableTaskStore(inMemory: true)
        let memoryStore = try QDurableTaskStore(inMemory: true)
        let memory = QModelCapabilityMemory(store: memoryStore)
        let provider = FakeModelCandidateProvider(backends: [.ollama])
        let runtime = QCoreRuntime(modelProvider: provider, executionProvider: MockExecutionProvider(), durableStore: eventStore, capabilityMemory: memory, endpointName: "cap-1-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "What is the capital of France?")

        #expect(task.state.isCompleted)
        let learned = try events(eventStore, taskId: task.taskId, type: .outcomeLearned)
        #expect(learned.count == 1)
        #expect(learned.first?.payload["winnerBackend"] == "local.ollama")
        #expect(learned.first?.payload["winnerOutcome"] == "success")

        let rows = memory.observations(forTask: task.taskId).observations
        let taskRow = try #require(rows.first { $0.source == .taskOutcome })
        #expect(taskRow.outcome == .success)
        #expect(taskRow.backend == .ollama)
        #expect(taskRow.taskType == .simpleQA)
        #expect(taskRow.latencyMilliseconds != nil)
    }

    @Test("Without capability memory the runtime behaves exactly as in Phase 2C: no learning event, no advice event")
    func noMemoryMeansNoLearning() async throws {
        let eventStore = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(modelProvider: FakeModelCandidateProvider(backends: [.ollama, .llamaCpp]), executionProvider: MockExecutionProvider(), durableStore: eventStore, endpointName: "cap-2-\(UUID().uuidString)")
        let task = try await runtime.submitIntent(prompt: "What is the capital of France?")
        #expect(task.state.isCompleted)
        #expect(try events(eventStore, taskId: task.taskId, type: .outcomeLearned).isEmpty)
        #expect(try events(eventStore, taskId: task.taskId, type: .modelRoutingAdvised).isEmpty)
    }

    @Test("28/29. Memory-informed routing end to end: history changes which candidate is tried first; the router/plan pipeline is otherwise identical")
    func memoryInformedRoutingEndToEnd() async throws {
        let prompt = "What is the capital of France?"
        let (taskType, complexity) = decisionKey(prompt)
        let eventStore = try QDurableTaskStore(inMemory: true)
        let memoryStore = try QDurableTaskStore(inMemory: true)
        // Real observations timestamped "recently" relative to the real clock.
        let realNow = Date()
        for (backend, successful) in [(QModelBackendType.ollama, false), (.llamaCpp, true)] {
            for index in 0..<6 {
                let timestamp = realNow.addingTimeInterval(-Double(3600 + index))
                memoryStore.record(
                    CapabilityFixtures.observation(
                        taskId: "history-\(backend.rawValue)-\(index)", taskType: taskType, complexity: complexity, backend: backend,
                        verification: successful ? .verified : .contradicted, execution: successful ? .succeeded : .failed, observedAt: timestamp
                    ),
                    now: realNow
                )
            }
        }
        let provider = FakeModelCandidateProvider(backends: [.ollama, .llamaCpp])
        let runtime = QCoreRuntime(modelProvider: provider, executionProvider: MockExecutionProvider(), durableStore: eventStore, capabilityMemory: QModelCapabilityMemory(store: memoryStore), endpointName: "cap-3-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: prompt)

        #expect(task.state.isCompleted)
        #expect(provider.attemptCount[.llamaCpp] == 1)
        #expect(provider.attemptCount[.ollama] == nil)
        let advised = try #require(try events(eventStore, taskId: task.taskId, type: .modelRoutingAdvised).first)
        #expect(advised.payload["reordered"] == "true")
        #expect(advised.payload["advisedOrder"] == "local.llama_cpp,local.ollama")
    }

    @Test("30. Permission authority preserved: a Level 2 step still halts at .awaitingApproval even for a candidate with a perfect history — and nothing is learned before execution")
    func permissionGateIgnoresLearnedHistory() async throws {
        let eventStore = try QDurableTaskStore(inMemory: true)
        let memoryStore = try QDurableTaskStore(inMemory: true)
        let (taskType, complexity) = decisionKey("Write marker to clipboard")
        let realNow = Date()
        for index in 0..<50 {
            memoryStore.record(CapabilityFixtures.observation(taskId: "perfect-\(index)", taskType: taskType, complexity: complexity, backend: .ollama, observedAt: realNow.addingTimeInterval(-Double(100 + index))), now: realNow)
        }
        let memory = QModelCapabilityMemory(store: memoryStore)
        let runtime = QCoreRuntime(modelProvider: Level2ClipboardProvider(), executionProvider: QExecutionService.shared, durableStore: eventStore, capabilityMemory: memory, endpointName: "cap-4-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "Write marker to clipboard")

        guard case .awaitingApproval = task.state else {
            Issue.record("Expected .awaitingApproval regardless of learned history, got \(task.state)")
            return
        }
        #expect(memory.observations(forTask: task.taskId).observations.isEmpty)   // no outcome yet → nothing to learn
        #expect(try events(eventStore, taskId: task.taskId, type: .outcomeLearned).isEmpty)
    }

    @Test("31/20. Resource authority preserved: a denylisted read is still rejected before dispatch, and is learned as `denied` (policy), not as a capability failure")
    func resourceGuardStillRejectsAndDenialIsNotAdverse() async throws {
        let eventStore = try QDurableTaskStore(inMemory: true)
        let memoryStore = try QDurableTaskStore(inMemory: true)
        let memory = QModelCapabilityMemory(store: memoryStore)
        let execution = MockExecutionProvider()
        let runtime = QCoreRuntime(modelProvider: DenylistedReadProvider(), executionProvider: execution, durableStore: eventStore, capabilityMemory: memory, endpointName: "cap-5-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "Read my SSH keys")

        guard case .failed(let reason) = task.state else {
            Issue.record("Expected rejection by QResourceGuard, got \(task.state)")
            return
        }
        #expect(reason.contains("Security Guard Denied"))
        #expect(execution.executedActions.isEmpty)
        let row = try #require(memory.observations(forTask: task.taskId).observations.first { $0.source == .taskOutcome })
        #expect(row.outcome == .denied)
        let profile = memory.profile(taskType: row.taskType, complexity: row.complexity, backend: .ollama)
        #expect(profile.deniedCount == 1)
        #expect(profile.adverseCount == 0)
    }

    @Test("33. Verification authority preserved: a failing execution is still a failed task and is learned as a failure — never as success")
    func failedExecutionIsLearnedAsFailure() async throws {
        let eventStore = try QDurableTaskStore(inMemory: true)
        let memory = QModelCapabilityMemory(store: try QDurableTaskStore(inMemory: true))
        let failing = MockFailingExecutionProvider()
        failing.alwaysFail = true
        let runtime = QCoreRuntime(modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: failing, durableStore: eventStore, capabilityMemory: memory, endpointName: "cap-6-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "What is the capital of France?")

        guard case .failed = task.state else {
            Issue.record("A failed step must never be treated as goal-satisfying, got \(task.state)")
            return
        }
        let row = try #require(memory.observations(forTask: task.taskId).observations.first { $0.source == .taskOutcome })
        #expect(row.outcome == .failure)
        #expect(memory.profile(taskType: row.taskType, complexity: row.complexity, backend: .ollama).verifiedSuccessCount == 0)
    }

    @Test("High-risk stays fail-closed before any model, learning, or advice runs")
    func highRiskNeverReachesLearning() async throws {
        let eventStore = try QDurableTaskStore(inMemory: true)
        let memory = QModelCapabilityMemory(store: try QDurableTaskStore(inMemory: true))
        let provider = FakeModelCandidateProvider(backends: [.ollama, .llamaCpp])
        let runtime = QCoreRuntime(modelProvider: provider, executionProvider: MockExecutionProvider(), durableStore: eventStore, capabilityMemory: memory, endpointName: "cap-7-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "Delete the temporary project file")

        guard case .failed(let reason) = task.state else {
            Issue.record("Expected fail-closed, got \(task.state)")
            return
        }
        #expect(reason.contains("failing closed"))
        #expect(provider.attemptCount.isEmpty)
        #expect(memory.observationCount() == 0)
    }

    @Test("23. Explicit user feedback through the runtime: recorded once, refused for an unknown task, and refused when learning is not configured")
    func userFeedbackThroughRuntime() async throws {
        let memory = QModelCapabilityMemory(store: try QDurableTaskStore(inMemory: true))
        let runtime = QCoreRuntime(modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: try QDurableTaskStore(inMemory: true), capabilityMemory: memory, endpointName: "cap-8-\(UUID().uuidString)")
        let task = try await runtime.submitIntent(prompt: "What is the capital of France?")

        #expect(runtime.recordUserFeedback(taskId: "unknown-task", feedback: .correction) == [.rejected(.noMatchingTaskObservation)])
        #expect(runtime.recordUserFeedback(taskId: task.taskId, feedback: .correction) == [.recorded])
        #expect(runtime.recordUserFeedback(taskId: task.taskId, feedback: .correction) == [.duplicate])

        let row = try #require(memory.observations(forTask: task.taskId).observations.first { $0.source == .taskOutcome })
        #expect(memory.profile(taskType: row.taskType, complexity: row.complexity, backend: .ollama).userCorrectionCount == 1)

        let bare = QCoreRuntime(modelProvider: nil, durableStore: try QDurableTaskStore(inMemory: true), endpointName: "cap-9-\(UUID().uuidString)")
        #expect(bare.recordUserFeedback(taskId: task.taskId, feedback: .correction) == [.storeUnavailable])
    }

    @Test("Bootstrap wires capability memory (advisory, bounded) without disturbing the existing components")
    func bootstrapWiresMemory() async throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let report = await QRuntimeBootstrap().bootstrap(databasePath: path)
        #expect(report.activeComponents.contains("QModelCapabilityMemory (Advisory, Bounded)"))
        #expect(report.activeComponents.contains("QPermissionGate"))
        #expect(report.activeComponents.contains("QResourceGuard"))
        #expect(report.activeComponents.contains("QEgressBroker (Air-Gap Offline)"))
    }

    // MARK: Privacy (34-39)

    @Test("34-38. Privacy: the persisted capability table has no free-text column, and no prompt/response/URL/credential text reaches any stored value or lifecycle payload")
    func persistedDataContainsNoContent() async throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let eventStore = try QDurableTaskStore(inMemory: true)
        let memory = QModelCapabilityMemory(store: try QDurableTaskStore(databasePath: path))
        let runtime = QCoreRuntime(modelProvider: FakeModelCandidateProvider(backends: [.ollama, .llamaCpp]), executionProvider: MockExecutionProvider(), durableStore: eventStore, capabilityMemory: memory, endpointName: "cap-10-\(UUID().uuidString)")

        let prompt = "Why do the trade-offs favor this approach? marker-zebra-7431 password=hunter2hunter2 https://private.example.com/secret"
        let task = try await runtime.submitIntent(prompt: prompt)
        #expect(task.state.isTerminal)
        _ = runtime.recordUserFeedback(taskId: task.taskId, feedback: .confirmation)

        var columnNames: [String] = []
        var storedValues: [String] = []
        CapabilityFixtures.withRawConnection(path) { connection in
            var info: OpaquePointer?
            sqlite3_prepare_v2(connection, "PRAGMA table_info(q_model_capability_observations);", -1, &info, nil)
            while sqlite3_step(info) == SQLITE_ROW { columnNames.append(String(cString: sqlite3_column_text(info, 1))) }
            sqlite3_finalize(info)

            var rows: OpaquePointer?
            sqlite3_prepare_v2(connection, "SELECT * FROM q_model_capability_observations;", -1, &rows, nil)
            while sqlite3_step(rows) == SQLITE_ROW {
                for index in 0..<sqlite3_column_count(rows) where sqlite3_column_type(rows, index) == SQLITE_TEXT {
                    storedValues.append(String(cString: sqlite3_column_text(rows, index)))
                }
            }
            sqlite3_finalize(rows)
        }

        #expect(columnNames == [
            "observation_id", "task_id", "attempt_id", "source", "task_type", "complexity", "backend", "strategy", "attempt_outcome",
            "verification", "completeness", "contradiction", "resource", "execution", "latency_ms", "outcome", "feedback",
            "observed_at", "recorded_at", "schema_version"
        ])
        #expect(!storedValues.isEmpty)
        let plainToken = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for value in storedValues {
            #expect(value.unicodeScalars.allSatisfy { plainToken.contains($0) }, "persisted value is not a plain token: \(value)")
            for forbidden in ["zebra", "hunter2", "trade-offs", "private.example.com", "http", "secret", "approach"] {
                #expect(!value.lowercased().contains(forbidden), "persisted value leaked \(forbidden)")
            }
        }
        for type in [QTaskLifecycleEventType.outcomeLearned, .modelRoutingAdvised] {
            for event in try events(eventStore, taskId: task.taskId, type: type) {
                for value in event.payload.values {
                    #expect(!value.contains("zebra") && !value.contains("hunter2") && !value.contains("http"))
                }
            }
        }
    }
}

// MARK: - Static audits & structural guarantees

@Suite("QCapabilityLearningSecurityTests")
struct QCapabilityLearningSecurityTests {

    private var qcoreDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("leanring-buddy/q-runtime/QCore")
    }

    private func phase2DESources() throws -> [(name: String, text: String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: qcoreDirectory.path)
            .filter { ($0.hasPrefix("QModelCapability") || $0 == "QOutcomeLearning.swift") && $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { ($0, try String(contentsOf: qcoreDirectory.appendingPathComponent($0), encoding: .utf8)) }
    }

    @Test("Static audit: Phase 2D/2E sources contain no network, process, shell, keychain, CGEvent, AX, or model-download API")
    func noForbiddenAPIs() throws {
        let sources = try phase2DESources()
        #expect(sources.count == 4, "expected Contracts/Store/Memory/OutcomeLearning, found \(sources.map { $0.name })")
        let forbidden = [
            "URLSession", "NWConnection", "NWPath", "import Network", "Process(", "NSTask", "posix_spawn", "system(",
            "CGEvent", "AXUIElement", "AXObserver", "NSAppleScript", "Keychain", "SecItem", "URL(", "FileManager", "FileHandle",
            "UserDefaults", "NSWorkspace", "dlopen", "import AppKit", "import CoreGraphics", "import ApplicationServices",
            "import Security", "http://", "https://", "sudo", "curl", "wget", "osascript", "bash", "download"
        ]
        for source in sources {
            for token in forbidden { #expect(!source.text.contains(token), "\(source.name) contains forbidden token \(token)") }
        }
    }

    @Test("Static audit: no Phase 2D/2E code references any authority type or makes any model call — learning has no way to grant, approve, or execute")
    func noAuthorityOrModelSymbols() throws {
        let authoritySymbols = [
            "QPermissionGate", "QResourceGuard", "QEgressBroker", "QApprovalCoordinator", "QActionAuthorizer", "QPlanExecutor",
            "QExecutionService", "QExecutionProvider", "QModelRouter", "QAuditLogger", "QActionVerifier", "QCapabilityLevel",
            "QModelProvider", "QStructuredModelProvider", "generateStructuredPlan", "QModelOrchestrator", "QCoreRuntime", "QCapability "
        ]
        for source in try phase2DESources() {
            let codeLines = source.text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for symbol in authoritySymbols {
                #expect(!codeLines.contains { $0.contains(symbol) }, "\(source.name) references \(symbol) in code")
            }
        }
    }

    @Test("Persistence reuses the existing store: the capability code opens no database of its own")
    func noSecondDatabase() throws {
        for source in try phase2DESources() {
            #expect(!source.text.contains("sqlite3_open"), "\(source.name) opens its own database")
        }
    }

    @Test("No fake scores: no profile, observation, or recommendation field is a floating-point number")
    func noFloatingPointScores() {
        let profile = QModelCapabilityProfile(observations: [CapabilityFixtures.observation()], key: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama))
        let observation = CapabilityFixtures.observation()
        let recommendation = QModelRoutingRecommender.recommend(candidates: [.ollama, .llamaCpp], profiles: [:])
        for subject in [profile as Any, observation as Any, recommendation as Any] {
            for child in Mirror(reflecting: subject).children {
                #expect(!(child.value is Double) && !(child.value is Float), "\(child.label ?? "?") is a floating-point value")
            }
        }
    }

    @Test("45. Authority escalation is unrepresentable: the recommendation and profile expose only counts, orderings, and explanations")
    func recommendationCarriesNoAuthorityFields() {
        let recommendation = QModelRoutingRecommender.recommend(candidates: [.ollama], profiles: [:])
        #expect(Mirror(reflecting: recommendation).children.compactMap { $0.label }.sorted() == ["basis", "orderedBackends", "reordered"])
        let profileLabels = Mirror(reflecting: QModelCapabilityProfile.empty(key: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama))).children.compactMap { $0.label }
        for label in profileLabels {
            for authorityWord in ["permission", "approval", "grant", "risk", "egress", "capabilityLevel", "execute", "allow"] {
                #expect(!label.lowercased().contains(authorityWord), "profile field \(label) looks like an authority")
            }
        }
    }

    @Test("Only the orchestrator's candidate ORDER is touched: the orchestrator source applies advice to already-vetted candidates and never to the availability/locality filter")
    func orchestratorAppliesAdviceAfterVetting() throws {
        let source = try String(contentsOf: qcoreDirectory.appendingPathComponent("QModelOrchestrator.swift"), encoding: .utf8)
        let filterIndex = try #require(source.range(of: "candidates.filter { $0.isLocalOnDevice && $0.isAvailable }"))
        let adviceIndex = try #require(source.range(of: "applyAdvisoryOrder(to: vettedCandidates"))
        #expect(filterIndex.lowerBound < adviceIndex.lowerBound)
    }
}
