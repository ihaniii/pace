//
//  QPlanExecutorMemoryParityTests.swift
//  leanring-buddyTests
//
//  Proves a completed plan's `plan_<planId>` memory record lands in the SAME
//  store as the rest of its runtime's memory. Before QPlanMemoryDestination,
//  QPlanExecutor always wrote to QRuntimeBootstrap.shared.getMemoryStore(), so
//  a runtime with its own injected store split one task's memory across two
//  stores. A bare QPlanExecutor keeps its original process-default behavior.
//
//  Deterministic: runtime cases use the resume path with an already-completed
//  step plus MockExecutionProvider — no live Accessibility, no real actions.
//  Only synthetic sentinels are used, and assertions report presence/absence,
//  never the persisted content.
//

import Foundation
import Testing
@testable import Pace

/// A memory provider that is deliberately NOT a QMemoryStore.
private final class RecordingOnlyMemoryProvider: QMemoryProvider, @unchecked Sendable {
    func recordTaskStart(_ task: QTask) async throws {}
    func recordTaskCompletion(_ task: QTask, result: String) async throws {}
    func queryContext(for query: String, limit: Int) async throws -> [String] { [] }
}

@MainActor
@Suite("QPlanExecutor memory-destination parity", .serialized)
struct QPlanExecutorMemoryParityTests {

    // Synthetic, non-sensitive sentinels embedded in credential-shaped
    // assignments, so QSecretRedactor's assignment pattern must remove them.
    private static let secretSentinel = "TEST_SECRET_SENTINEL_9F31"
    private static let passwordSentinel = "TEST_PASSWORD_SENTINEL_7A42"
    private static let credentialShapedEvidence = "Found: api_key=\(secretSentinel) password=\(passwordSentinel)"

    // MARK: - Fixtures

    /// Saves a resumable task whose first step is already completed (carrying the
    /// credential-shaped evidence into the plan's final summary) and whose second step is
    /// pending (executed by MockExecutionProvider).
    private static func saveResumableTask(store: QDurableTaskStore, taskId: String, sessionId: String) throws {
        let completedStep = QDurablePlanStepSnapshot(
            stepId: "step-done", index: 0, actionName: "system.running_apps", toolFamily: "system", riskLevel: "level0ReadOnly",
            literalAction: "Already done", state: "completed",
            resultSummary: credentialShapedEvidence, verifiedEvidence: credentialShapedEvidence
        )
        let pendingStep = QDurablePlanStepSnapshot(
            stepId: "step-pending", index: 1, actionName: "system.running_apps", toolFamily: "system", riskLevel: "level0ReadOnly",
            literalAction: "Still pending", targetResources: [], arguments: [:], state: "pending"
        )
        try store.savePlan(QDurablePlanSnapshot(planId: "plan-\(taskId)", taskId: taskId, sessionId: sessionId, goal: "memory parity", steps: [completedStep, pendingStep]))
        try store.saveTask(QDurableTaskState(
            taskId: taskId, sessionId: sessionId, originalIntent: "memory parity",
            lifecycleState: .running, currentPlanId: "plan-\(taskId)", currentStepIndex: 1
        ))
    }

    /// Plan records written by QPlanExecutor for this session, if a store is present.
    private static func planRecords(in memoryStore: (any QMemoryStore)?, sessionId: String) throws -> [QMemoryRecord] {
        guard let memoryStore else { return [] }
        return try memoryStore.listRecent(sessionId: sessionId, limit: 50)
            .filter { $0.key.hasPrefix("plan_") && $0.provenanceSource == "q_plan_executor" }
    }

    /// A plan whose only step is already completed, so a bare executor goes straight to
    /// plan completion and its memory write — no execution.
    private static func alreadyCompletedPlan(sessionId: String) -> QPlan {
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(actionName: "system.running_apps", toolFamily: "system", riskLevel: .level0ReadOnly, literalAction: "Query running apps"),
            description: "Query",
            state: .completed,
            result: QPlanStepResult(stepId: UUID(), success: true, summary: credentialShapedEvidence, verifiedEvidence: credentialShapedEvidence)
        )
        return QPlan(taskId: "task-\(UUID().uuidString)", sessionId: sessionId, taskPrompt: "Query", steps: [step])
    }

    private static func resumeToCompletion(_ runtime: QCoreRuntime, taskId: String) async throws {
        let resumed = try await runtime.resumeTask(taskId: taskId)
        guard case .completed = resumed.state else {
            Issue.record("expected the resumed task to complete, got \(resumed.state)")
            return
        }
    }

    // MARK: - Runtime with an injected store (A, B, D, E)

    @Test("A/B/D/E. A runtime's plan record lands only in its injected store, redacted")
    func runtimeWritesPlanRecordToItsInjectedStoreOnly() async throws {
        let durableStore = try QDurableTaskStore(inMemory: true)
        let injectedMemoryStore = try QSQLiteMemoryStore(inMemory: true)
        let sessionId = "parity-\(UUID().uuidString)"
        let taskId = "task-\(UUID().uuidString)"
        try Self.saveResumableTask(store: durableStore, taskId: taskId, sessionId: sessionId)
        let runtime = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]),
            memoryProvider: injectedMemoryStore,
            executionProvider: MockExecutionProvider(),
            durableStore: durableStore
        )

        try await Self.resumeToCompletion(runtime, taskId: taskId)

        // A. The injected store holds exactly one plan record for this task.
        let injectedPlanRecords = try Self.planRecords(in: injectedMemoryStore, sessionId: sessionId)
        #expect(injectedPlanRecords.count == 1)
        let planRecord = try #require(injectedPlanRecords.first)
        #expect(planRecord.taskId == taskId)

        // B. The process-wide store received nothing for this session.
        #expect(try Self.planRecords(in: QRuntimeBootstrap.shared.getMemoryStore(), sessionId: sessionId).isEmpty)

        // D/E. Redaction unchanged: sentinels absent, redaction marker present.
        #expect(!planRecord.content.contains(Self.secretSentinel))
        #expect(!planRecord.content.contains(Self.passwordSentinel))
        #expect(planRecord.content.contains("[REDACTED_SECRET]"))
    }

    // MARK: - Resolver (C, I)

    @Test("C/I. The resolver returns the exact injected store instance, deterministically")
    func resolverUsesExactInjectedInstance() throws {
        let injectedMemoryStore = try QSQLiteMemoryStore(inMemory: true)
        for _ in 0..<3 {
            guard case .store(let resolvedStore) = QCoreRuntime.planMemoryDestination(for: injectedMemoryStore) else {
                Issue.record("expected .store for a QMemoryStore provider")
                return
            }
            #expect((resolvedStore as AnyObject) === injectedMemoryStore)
        }
        for _ in 0..<3 {
            guard case .none = QCoreRuntime.planMemoryDestination(for: nil) else {
                Issue.record("expected .none for a nil provider")
                return
            }
            guard case .none = QCoreRuntime.planMemoryDestination(for: RecordingOnlyMemoryProvider()) else {
                Issue.record("expected .none for a non-QMemoryStore provider")
                return
            }
        }
    }

    // MARK: - Bare executor (F)

    @Test("F. A bare QPlanExecutor keeps writing to the process-default store")
    func bareExecutorKeepsProcessDefault() async throws {
        let processStore = try #require(QRuntimeBootstrap.shared.getMemoryStore(), "the test host bootstraps a process-wide store at launch")
        let sessionId = "parity-bare-\(UUID().uuidString)"
        let executor = QPlanExecutor(executionProvider: MockExecutionProvider())

        let plan = Self.alreadyCompletedPlan(sessionId: sessionId)
        let executedPlan = try await executor.execute(plan: plan, context: QTaskContext(taskId: plan.taskId))
        #expect(executedPlan.isComplete)

        let processPlanRecords = try Self.planRecords(in: processStore, sessionId: sessionId)
        #expect(processPlanRecords.count == 1)
        let planRecord = try #require(processPlanRecords.first)
        #expect(!planRecord.content.contains(Self.secretSentinel))
        #expect(planRecord.content.contains("[REDACTED_SECRET]"))
    }

    // MARK: - Runtimes without a QMemoryStore (G, H)

    @Test("G. A runtime with no memory provider writes no plan record anywhere")
    func runtimeWithoutMemoryWritesNoPlanRecord() async throws {
        let durableStore = try QDurableTaskStore(inMemory: true)
        let sessionId = "parity-none-\(UUID().uuidString)"
        let taskId = "task-\(UUID().uuidString)"
        try Self.saveResumableTask(store: durableStore, taskId: taskId, sessionId: sessionId)
        let runtime = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]),
            executionProvider: MockExecutionProvider(),
            durableStore: durableStore
        )

        try await Self.resumeToCompletion(runtime, taskId: taskId)

        #expect(try Self.planRecords(in: QRuntimeBootstrap.shared.getMemoryStore(), sessionId: sessionId).isEmpty)
    }

    @Test("H. A runtime whose memory provider is not a QMemoryStore writes no plan record anywhere")
    func runtimeWithNonStoreProviderWritesNoPlanRecord() async throws {
        let durableStore = try QDurableTaskStore(inMemory: true)
        let recordingProvider = RecordingOnlyMemoryProvider()
        let sessionId = "parity-nonstore-\(UUID().uuidString)"
        let taskId = "task-\(UUID().uuidString)"
        try Self.saveResumableTask(store: durableStore, taskId: taskId, sessionId: sessionId)
        let runtime = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]),
            memoryProvider: recordingProvider,
            executionProvider: MockExecutionProvider(),
            durableStore: durableStore
        )

        try await Self.resumeToCompletion(runtime, taskId: taskId)

        #expect(try Self.planRecords(in: QRuntimeBootstrap.shared.getMemoryStore(), sessionId: sessionId).isEmpty)
    }

    // MARK: - Redaction semantics (J)

    @Test("J. The destination changes only WHERE the record goes, never its content or provenance")
    func destinationDoesNotChangeRecordSemantics() async throws {
        let firstStore = try QSQLiteMemoryStore(inMemory: true)
        let secondStore = try QSQLiteMemoryStore(inMemory: true)
        let sessionId = "parity-semantics-\(UUID().uuidString)"
        let plan = Self.alreadyCompletedPlan(sessionId: sessionId)

        _ = try await QPlanExecutor(executionProvider: MockExecutionProvider(), planMemoryDestination: .store(firstStore))
            .execute(plan: plan, context: QTaskContext(taskId: plan.taskId))
        _ = try await QPlanExecutor(executionProvider: MockExecutionProvider(), planMemoryDestination: .store(secondStore))
            .execute(plan: plan, context: QTaskContext(taskId: plan.taskId))
        _ = try await QPlanExecutor(executionProvider: MockExecutionProvider(), planMemoryDestination: .none)
            .execute(plan: plan, context: QTaskContext(taskId: plan.taskId))

        let firstRecord = try #require(try Self.planRecords(in: firstStore, sessionId: sessionId).first)
        let secondRecord = try #require(try Self.planRecords(in: secondStore, sessionId: sessionId).first)
        #expect(firstRecord.key == secondRecord.key)
        #expect(firstRecord.key == "plan_\(plan.id.uuidString)")
        #expect(firstRecord.content == secondRecord.content)
        #expect(firstRecord.provenanceKind == secondRecord.provenanceKind)
        #expect(firstRecord.provenanceSource == "q_plan_executor")
        #expect(!firstRecord.content.contains(Self.secretSentinel))
        #expect(!firstRecord.content.contains(Self.passwordSentinel))
        #expect(firstRecord.content.contains("[REDACTED_SECRET]"))
    }
}
