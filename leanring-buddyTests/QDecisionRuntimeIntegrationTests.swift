//
//  QDecisionRuntimeIntegrationTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2A.4 Runtime Integration Tests.
//  Exercises QCoreRuntime.submitIntent's real Decision Engine + Task Decomposer wiring
//  ("4b. Decision Engine & Task Decomposition (Phase 2A.4)" in QCoreRuntime.swift) against genuine
//  production QPlanExecutor / QPermissionGate / QResourceGuard / QGoalEvaluator / QApprovalCoordinator
//  pathways — only the leaf QModelProvider and (where noted) QExecutionProvider are faked, exactly
//  matching this codebase's existing QCoreRuntimeTests/QClosedLoopAgentTests/QControlledActionsTests
//  conventions (QPermissionGate.evaluate / QResourceGuard.validate are called directly by the real
//  QPlanExecutor regardless of which execution provider is plugged in — see QPlanExecutor.swift).
//
//  Proves the integration is strictly additive: a QDecisionPlan/decomposition can only ever make a
//  task MORE conservative (fail closed) or leave existing behavior byte-for-byte unchanged — it can
//  never grant, widen, or bypass permission/resource/egress/verification authority. Model Router
//  provider-selection and QEgressBroker authority are covered separately in QModelRouterTests.swift
//  (Phase 2A.4-L / Phase 2A.4-O), since that authority lives entirely inside QModelRouter, not here.
//

import Testing
import Foundation
@testable import Pace

// MARK: - Decision-Context-Aware Fake Model Provider

/// Mirrors `MockAutonomousModelProvider` (QClosedLoopAgentTests.swift) exactly, but additionally
/// conforms to `QDecisionContextAwareModelProvider` and records every `QDecisionPlan` it was
/// called with — proving `QCoreRuntime` actually threads a real, task-specific decision plan
/// through to the planner, not a placeholder, while otherwise behaving identically to the existing
/// non-decision-aware mock.
final class RecordingDecisionAwareModelProvider: QDecisionContextAwareModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var generatedPlanCount: Int = 0
    private(set) var receivedDecisionPlans: [QDecisionPlan?] = []
    var structuredPlansToReturn: [String] = []

    func generatePlan(for task: QTask) async throws -> [QActionRequest] {
        lock.lock(); defer { lock.unlock() }
        generatedPlanCount += 1
        return [QActionRequest(toolName: "ui.open_app", toolFamily: "ui", riskLevel: .level1SafeLocalAction, literalAction: "Launch Calculator", targetResources: ["Calculator"])]
    }

    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
        try await generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: nil)
    }

    func generateStructuredPlan(
        for task: QTask,
        memoryContext: String?,
        failureContext: String?,
        decisionPlan: QDecisionPlan?
    ) async throws -> QPlan {
        lock.lock()
        generatedPlanCount += 1
        receivedDecisionPlans.append(decisionPlan)
        let jsonString = structuredPlansToReturn.isEmpty ? nil : structuredPlansToReturn.removeFirst()
        lock.unlock()

        if let jsonString {
            return try QModelPlanParser.parse(rawText: jsonString, taskId: task.taskId, taskPrompt: task.intent, sessionId: task.sessionId)
        }

        // Default: same shape as MockAutonomousModelProvider's default (open Calculator) — a
        // safe, Level 1, no-approval-needed action, so tests that don't care about plan content
        // reach a clean terminal state without an unrelated halt.
        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.open_app",
                toolFamily: "ui",
                riskLevel: .level1SafeLocalAction,
                literalAction: "Launch Calculator",
                targetResources: ["Calculator"],
                arguments: ["appName": "Calculator"]
            ),
            description: "Launch Calculator"
        )
        return QPlan(taskId: task.taskId, sessionId: task.sessionId, taskPrompt: task.intent, steps: [step])
    }

    func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String {
        isSuccess ? "Successfully completed \(task.intent)." : "Failed to complete \(task.intent)."
    }
}

@Suite("QDecisionRuntimeIntegrationTests")
struct QDecisionRuntimeIntegrationTests {

    // MARK: - A-G: Task-type classification reaches the planner, per canonical task type

    @Test("A. Simple task (simpleQA): decision computed, no decomposition, planner receives it unchanged")
    func simpleTaskClassification() async throws {
        let model = RecordingDecisionAwareModelProvider()
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: MockExecutionProvider(), durableStore: store, endpointName: "decision-a-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "What is the capital of France?")

        #expect(model.generatedPlanCount == 1)
        #expect(model.receivedDecisionPlans.first.flatMap { $0 }?.taskType == .simpleQA)
        #expect(model.receivedDecisionPlans.first.flatMap { $0 }?.decompositionDecision == .notRequired)

        let events = try store.listEvents(taskId: task.taskId)
        let decompositionEvents = events.filter { $0.payload["decompositionStatus"] != nil }
        #expect(decompositionEvents.isEmpty, "notRequired must never record a decompositionStatus event")
    }

    @Test("B. Reasoning task: moderate complexity, decomposition recommended but not executed, original task still reaches the planner")
    func reasoningTaskClassification() async throws {
        let model = RecordingDecisionAwareModelProvider()
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: MockExecutionProvider(), durableStore: store, endpointName: "decision-b-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "Why do the trade-offs favor this approach?")

        #expect(model.generatedPlanCount == 1, "recommended decomposition must never block the original task from reaching the planner")
        let decisionPlan = try #require(model.receivedDecisionPlans.first.flatMap { $0 })
        #expect(decisionPlan.taskType == .reasoning)
        #expect(decisionPlan.complexity == .moderate)
        if case .recommended(let maximumSubtasks) = decisionPlan.decompositionDecision {
            #expect(maximumSubtasks == 3)
        } else {
            Issue.record("Expected .recommended decomposition for a moderate-complexity reasoning task")
        }

        let events = try store.listEvents(taskId: task.taskId)
        let decompositionEvent = events.first { $0.payload["decompositionStatus"] == "recommendedNotExecuted" }
        #expect(decompositionEvent != nil, "a recommended decomposition must be recorded as recommended-but-not-executed")
        // Matches QDeterministicTaskDecomposer's own fixed, minimal subtask count (never scaled
        // to the bound) — proving the integration reuses the same tested decomposer, not a
        // divergent reimplementation.
        #expect(decompositionEvent?.payload["subtaskCount"] == "2")
    }

    @Test("C. Coding task: complex complexity, wider decomposition bound than a moderate task")
    func codingTaskClassification() async throws {
        let model = RecordingDecisionAwareModelProvider()
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: MockExecutionProvider(), endpointName: "decision-c-\(UUID().uuidString)")

        _ = try await runtime.submitIntent(prompt: "Write a function to sort a list")

        let decisionPlan = try #require(model.receivedDecisionPlans.first.flatMap { $0 })
        #expect(decisionPlan.taskType == .coding)
        #expect(decisionPlan.complexity == .complex)
        if case .recommended(let maximumSubtasks) = decisionPlan.decompositionDecision {
            #expect(maximumSubtasks == 5)
        } else {
            Issue.record("Expected .recommended decomposition for a complex coding task")
        }
    }

    @Test("D. Research task: provenance is required, matching the decision engine's own research rule")
    func researchTaskClassification() async throws {
        let model = RecordingDecisionAwareModelProvider()
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: MockExecutionProvider(), endpointName: "decision-d-\(UUID().uuidString)")

        _ = try await runtime.submitIntent(prompt: "Research the latest developments in on-device inference")

        let decisionPlan = try #require(model.receivedDecisionPlans.first.flatMap { $0 })
        #expect(decisionPlan.taskType == .research)
        #expect(decisionPlan.provenanceRequirement == .required)
    }

    @Test("E. Planning task: conceptual strategy is localPlannerModel, never a concrete backend name")
    func planningTaskClassification() async throws {
        let model = RecordingDecisionAwareModelProvider()
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: MockExecutionProvider(), endpointName: "decision-e-\(UUID().uuidString)")

        _ = try await runtime.submitIntent(prompt: "Make a plan for the product launch")

        let decisionPlan = try #require(model.receivedDecisionPlans.first.flatMap { $0 })
        #expect(decisionPlan.taskType == .planning)
        #expect(decisionPlan.modelStrategy == .localPlannerModel)
    }

    @Test("F. Execution task: simple complexity, no decomposition, single local model strategy")
    func executionTaskClassification() async throws {
        let model = RecordingDecisionAwareModelProvider()
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: MockExecutionProvider(), endpointName: "decision-f-\(UUID().uuidString)")

        _ = try await runtime.submitIntent(prompt: "Open Notes for me")

        let decisionPlan = try #require(model.receivedDecisionPlans.first.flatMap { $0 })
        #expect(decisionPlan.taskType == .execution)
        #expect(decisionPlan.decompositionDecision == .notRequired)
        #expect(decisionPlan.modelStrategy == .singleLocalModel)
    }

    // MARK: - G / J / K: Required decomposition fails closed

    @Test("G/J/K. Critical/high-risk task: decomposition is required, but the runtime cannot execute decomposed subtasks yet, so it fails closed BEFORE the planner is ever invoked")
    func criticalHighRiskDecompositionFailsClosed() async throws {
        let model = RecordingDecisionAwareModelProvider()
        let exec = MockExecutionProvider()
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: exec, durableStore: store, endpointName: "decision-g-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "Delete the temporary project file")

        guard case .failed(let reason) = task.state else {
            Issue.record("Expected the task to fail closed, got \(task.state)")
            return
        }
        #expect(reason.contains("failing closed"))

        // The planner must NEVER be invoked for a required-but-unsupported decomposition — this
        // is not "generate a plan and then reject it", it is "never generate a plan at all".
        #expect(model.generatedPlanCount == 0)
        #expect(exec.executedActions.isEmpty)

        let events = try store.listEvents(taskId: task.taskId)
        let failureEvent = events.first { $0.eventType == .taskFailed }
        #expect(failureEvent?.payload["reason"] == "decomposition_required_unsupported")
        #expect(Int(failureEvent?.payload["subtaskCount"] ?? "") == 2)
    }

    // MARK: - M: Permission Gate remains authoritative

    @Test("M. A decision-aware provider's Level 2 step still halts at .awaitingApproval — a QDecisionPlan grants no auto-approval")
    func permissionGateRemainsAuthoritativeWithDecisionContext() async throws {
        let model = RecordingDecisionAwareModelProvider()
        model.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write marker to clipboard",
              "steps": [
                {
                  "actionName": "system.clipboard.write",
                  "toolFamily": "system",
                  "description": "Write a marker to the clipboard",
                  "parameters": {"text": "q-2a4-marker"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: QExecutionService.shared, endpointName: "decision-m-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "Write marker to clipboard")

        guard case .awaitingApproval = task.state else {
            Issue.record("Expected .awaitingApproval regardless of decision context, got \(task.state)")
            return
        }
        // A decision plan was genuinely computed and threaded through — the halt happened
        // downstream of it, not because the decision-aware path was skipped.
        #expect(model.receivedDecisionPlans.first != nil)
    }

    // MARK: - N: Resource Guard remains authoritative

    @Test("N. A decision-aware provider's denylisted-resource step is still rejected before dispatch — a QDecisionPlan grants no resource-guard bypass")
    func resourceGuardRemainsAuthoritativeWithDecisionContext() async throws {
        let model = RecordingDecisionAwareModelProvider()
        model.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Read my SSH keys",
              "steps": [
                {
                  "actionName": "fs.read",
                  "toolFamily": "fs",
                  "riskLevel": "level0ReadOnly",
                  "description": "Read SSH keys",
                  "targetResources": ["~/.ssh/id_rsa"]
                }
              ]
            }
            """
        ]
        let exec = MockExecutionProvider()
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: exec, endpointName: "decision-n-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "Read my SSH keys")

        guard case .failed(let reason) = task.state else {
            Issue.record("Expected the task to be rejected by QResourceGuard, got \(task.state)")
            return
        }
        #expect(reason.contains("Security Guard Denied"))
        #expect(exec.executedActions.isEmpty, "must never dispatch to the execution provider")
    }

    // MARK: - P: Verification (goal evaluation) remains authoritative

    @Test("P. A decision-aware provider's failed step is still never counted as satisfying evidence")
    func goalEvaluationRemainsAuthoritativeWithDecisionContext() async throws {
        let model = RecordingDecisionAwareModelProvider()
        model.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Why does this approach have trade-offs",
              "steps": [
                {
                  "actionName": "ui.open_app",
                  "toolFamily": "ui",
                  "riskLevel": "level1SafeLocalAction",
                  "description": "Open a nonexistent app",
                  "targetResources": ["DoesNotExist"],
                  "parameters": {"appName": "DoesNotExist"}
                }
              ]
            }
            """
        ]
        let failingExec = MockFailingExecutionProvider()
        failingExec.alwaysFail = true
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: failingExec, endpointName: "decision-p-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "Why does this approach have trade-offs")

        guard case .failed = task.state else {
            Issue.record("A failed step must never be treated as goal-satisfying, decision context or not, got \(task.state)")
            return
        }
        // Confirms the reasoning-task path (recommended decomposition, executionEvidence
        // verification requirement) was genuinely exercised, not bypassed.
        #expect(model.receivedDecisionPlans.first.flatMap { $0 }?.verificationRequirement == .executionEvidence)
    }

    // MARK: - Q: Decision engine failure-safety

    @Test("Q. An empty-intent task never crashes the runtime; the decision engine's honest .unknown uncertainty is recorded")
    func emptyIntentDoesNotCrashDecisionEngine() async throws {
        let model = RecordingDecisionAwareModelProvider()
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: MockExecutionProvider(), durableStore: store, endpointName: "decision-q-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "")

        #expect(task.state.isTerminal, "an empty intent must still reach a clean terminal state, never hang or trap")
        let events = try store.listEvents(taskId: task.taskId)
        let decisionEvent = events.first { $0.eventType == .decisionEvaluated && $0.payload["uncertainty"] != nil }
        #expect(decisionEvent?.payload["uncertainty"] == "unknown")
    }

    // MARK: - S: No raw content leakage into decision lifecycle metadata

    @Test("S. Decision lifecycle event payloads never carry the raw task intent text")
    func decisionLifecycleEventsCarryNoRawIntentText() async throws {
        let secretMarker = "q-2a4-secret-marker-\(UUID().uuidString)"
        let model = RecordingDecisionAwareModelProvider()
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: MockExecutionProvider(), durableStore: store, endpointName: "decision-s-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "Research \(secretMarker) thoroughly")

        let events = try store.listEvents(taskId: task.taskId)
        let decisionEvents = events.filter { $0.eventType == .decisionEvaluated }
        #expect(!decisionEvents.isEmpty)
        for event in decisionEvents {
            for value in event.payload.values {
                #expect(!value.contains(secretMarker), "decision lifecycle payloads must only ever carry bounded enum/count metadata, never raw task intent text")
            }
        }
    }

    // MARK: - T: No new security authority — the decision-aware path still records a normal, audited plan

    @Test("T. A decision-aware-generated plan is still persisted through the exact same durable plan/lifecycle pipeline as any other plan")
    func decisionAwarePlanStillFlowsThroughStandardPersistence() async throws {
        let model = RecordingDecisionAwareModelProvider()
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: MockExecutionProvider(), durableStore: store, endpointName: "decision-t-\(UUID().uuidString)")

        let task = try await runtime.submitIntent(prompt: "Open Notes for me")

        let durableState = try store.getTask(taskId: task.taskId)
        #expect(durableState?.currentPlanId != nil, "a decision-aware plan must still be persisted via QDurablePlanSnapshot exactly like any other plan")
        let events = try store.listEvents(taskId: task.taskId)
        #expect(events.contains { $0.eventType == .taskPlanned })
        #expect(events.contains { $0.eventType == .taskCompleted })
    }
}
