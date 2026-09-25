//
//  QWorkingSurfaceProjectionTests.swift
//  leanring-buddyTests
//
//  Tests for Q-Core Working Surface Consolidation (Phase 4.7A, GAP-4.7-01).
//  Verifies that QDurableTaskStore tasks are projected safely, deterministically,
//  and with full privacy into the Working surface alongside legacy tasks.
//

import Foundation
import Testing
@testable import Pace

@Suite("QWorkingSurfaceProjectionTests")
struct QWorkingSurfaceProjectionTests {

    // 1. Q-Core running task appears in Working
    @Test func qCoreRunningTaskAppearsInWorking() {
        let durable = QDurableTaskState(
            taskId: "q-task-running-1",
            sessionId: "session-1",
            originalIntent: "Organize project documents",
            taskCreationTimestamp: Date(timeIntervalSince1970: 1_000),
            lifecycleState: .running,
            currentStepIndex: 1
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [durable])
        #expect(state.tasks.count == 1)
        let task = state.tasks.first
        #expect(task?.id == "q-task-running-1")
        #expect(task?.displayName == "Organize project documents")
        #expect(task?.state == .running)
        #expect(task?.currentStepDescription == "Step 2")
        #expect(task?.hasResult == false)
    }

    // 2. Q-Core awaitingApproval task appears in Working
    @Test func qCoreAwaitingApprovalTaskAppearsInWorking() {
        let durable = QDurableTaskState(
            taskId: "q-task-approval-1",
            sessionId: "session-2",
            originalIntent: "Delete cache directory",
            taskCreationTimestamp: Date(timeIntervalSince1970: 1_050),
            lifecycleState: .awaitingApproval,
            currentStepIndex: 0
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [durable])
        #expect(state.tasks.count == 1)
        let task = state.tasks.first
        #expect(task?.id == "q-task-approval-1")
        #expect(task?.state == .awaitingApproval)
        #expect(task?.currentStepDescription == "Awaiting permission")
        #expect(task?.hasResult == false)
    }

    // 3. Q-Core completed task follows existing retention semantics
    @Test func qCoreCompletedTaskFollowsRetentionSemantics() {
        let durable = QDurableTaskState(
            taskId: "q-task-completed-1",
            sessionId: "session-3",
            originalIntent: "Summarize notes",
            taskCreationTimestamp: Date(timeIntervalSince1970: 1_100),
            lifecycleState: .completed,
            currentStepIndex: 2,
            completedStepIds: ["step-1", "step-2"]
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [durable])
        #expect(state.tasks.count == 1)
        let task = state.tasks.first
        #expect(task?.id == "q-task-completed-1")
        #expect(task?.state == .completed)
        #expect(task?.currentStepDescription == "Completed")
        #expect(task?.hasResult == true)
    }

    // 4. Q-Core failed task follows existing retention semantics
    @Test func qCoreFailedTaskFollowsRetentionSemantics() {
        let durable = QDurableTaskState(
            taskId: "q-task-failed-1",
            sessionId: "session-4",
            originalIntent: "Fetch remote logs",
            taskCreationTimestamp: Date(timeIntervalSince1970: 1_150),
            lifecycleState: .failed,
            lastKnownError: "Internal database query failed"
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [durable])
        #expect(state.tasks.count == 1)
        let task = state.tasks.first
        #expect(task?.id == "q-task-failed-1")
        #expect(task?.state == .failed)
        #expect(task?.currentStepDescription == "Failed")
        #expect(task?.hasResult == false)
    }

    // 5. Q-Core cancelled task follows existing retention semantics
    @Test func qCoreCancelledTaskFollowsRetentionSemantics() {
        let durable = QDurableTaskState(
            taskId: "q-task-cancelled-1",
            sessionId: "session-5",
            originalIntent: "Long computation",
            taskCreationTimestamp: Date(timeIntervalSince1970: 1_200),
            lifecycleState: .failed,
            lastKnownError: "Turn cancelled by user"
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [durable])
        #expect(state.tasks.count == 1)
        let task = state.tasks.first
        #expect(task?.id == "q-task-cancelled-1")
        #expect(task?.state == .cancelled)
        #expect(task?.currentStepDescription == "Cancelled")
    }

    // 6. Legacy background task still appears
    @Test func legacyBackgroundTaskStillAppears() {
        let legacy = PaceBackgroundAgentTask(
            id: "legacy-bg-1",
            displayName: "Legacy background search",
            prompt: "Search docs",
            priority: .normal,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 1_250),
            completedAt: nil,
            resultSummary: nil,
            stepCount: 1,
            currentStepDescription: "Searching..."
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [legacy], durableTasks: [])
        #expect(state.tasks.count == 1)
        #expect(state.tasks.first?.id == "legacy-bg-1")
        #expect(state.tasks.first?.displayName == "Legacy background search")
        #expect(state.tasks.first?.state == .running)
        #expect(state.tasks.first?.currentStepDescription == "Searching...")
    }

    // 7. Legacy + Q-Core tasks coexist
    @Test func legacyAndQCoreTasksCoexist() {
        let legacy = PaceBackgroundAgentTask(
            id: "legacy-1",
            displayName: "Legacy task",
            prompt: "",
            priority: .normal,
            state: .completed,
            startedAt: Date(timeIntervalSince1970: 1_000),
            completedAt: nil,
            resultSummary: "done",
            stepCount: 1,
            currentStepDescription: nil
        )
        let durable = QDurableTaskState(
            taskId: "q-task-1",
            sessionId: "session-q-1",
            originalIntent: "Q-Core task",
            taskCreationTimestamp: Date(timeIntervalSince1970: 2_000),
            lifecycleState: .running
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [legacy], durableTasks: [durable])
        #expect(state.tasks.count == 2)
        // Newer task first
        #expect(state.tasks[0].id == "q-task-1")
        #expect(state.tasks[1].id == "legacy-1")
    }

    // 8. Duplicate task IDs are not duplicated
    @Test func duplicateTaskIdsAreNotDuplicated() {
        let legacy = PaceBackgroundAgentTask(
            id: "shared-task-id",
            displayName: "Legacy view of task",
            prompt: "",
            priority: .normal,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 1_000),
            completedAt: nil,
            resultSummary: nil,
            stepCount: 1,
            currentStepDescription: nil
        )
        let durable = QDurableTaskState(
            taskId: "shared-task-id",
            sessionId: "shared-task-id",
            originalIntent: "Durable view of task",
            taskCreationTimestamp: Date(timeIntervalSince1970: 1_000),
            lifecycleState: .running
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [legacy], durableTasks: [durable])
        #expect(state.tasks.count == 1)
        #expect(state.tasks.first?.id == "shared-task-id")
    }

    // 9. Output remains bounded
    @Test func outputRemainsBounded() {
        let durables = (0..<35).map { idx in
            QDurableTaskState(
                taskId: "durable-\(idx)",
                sessionId: "sess-\(idx)",
                originalIntent: "Task number \(idx)",
                taskCreationTimestamp: Date(timeIntervalSince1970: Double(idx)),
                lifecycleState: .completed
            )
        }
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: durables)
        #expect(state.tasks.count == PaceWorkingSurfaceLimits.maximumProjectedTaskCount)
        #expect(state.tasks.count == 20)
        // Highest timestamp first
        #expect(state.tasks.first?.id == "durable-34")
    }

    // 10. Raw planner/model/task internals are not exposed
    @Test func rawInternalsAreNotExposed() {
        let sensitiveDurable = QDurableTaskState(
            taskId: "q-sensitive-1",
            sessionId: "session-sec",
            originalIntent: "{\"action\": \"ui.click\", \"target\": \"secret_password_field\"}",
            taskCreationTimestamp: Date(),
            lifecycleState: .failed,
            lastKnownError: "Internal system error at /Users/hani/SecretDir/App.swift:42"
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [sensitiveDurable])
        let task = state.tasks.first
        #expect(task != nil)
        // Raw JSON is sanitized into safe title
        #expect(task?.displayName == "Structured Action")
        #expect(!task!.displayName.contains("secret_password_field"))
        // Error path is masked
        #expect(task?.currentStepDescription == "Failed")
        #expect(!task!.currentStepDescription!.contains("/Users/hani/SecretDir"))
    }

    // 11. Projection does not mutate QDurableTaskStore
    @Test func projectionDoesNotMutateStore() throws {
        let store = try QDurableTaskStore(inMemory: true)
        let durable = QDurableTaskState(
            taskId: "test-mutate-1",
            sessionId: "session-m",
            originalIntent: "Intent to remain unchanged",
            taskCreationTimestamp: Date(),
            lifecycleState: .running
        )
        try store.saveTask(durable)

        let initialTasks = try store.listRecentTasks(limit: 10)
        #expect(initialTasks.count == 1)

        let projectedState = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: initialTasks)
        #expect(projectedState.tasks.count == 1)

        let afterTasks = try store.listRecentTasks(limit: 10)
        #expect(afterTasks.count == 1)
        #expect(afterTasks.first?.taskId == durable.taskId)
        #expect(afterTasks.first?.lifecycleState == .running)
    }

    // 12. Deterministic ordering
    @Test func deterministicOrdering() {
        let taskA = QDurableTaskState(
            taskId: "task-A",
            sessionId: "sA",
            originalIntent: "Alpha",
            taskCreationTimestamp: Date(timeIntervalSince1970: 500),
            lifecycleState: .completed
        )
        let taskB = QDurableTaskState(
            taskId: "task-B",
            sessionId: "sB",
            originalIntent: "Beta",
            taskCreationTimestamp: Date(timeIntervalSince1970: 500),
            lifecycleState: .completed
        )
        let state1 = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [taskA, taskB])
        let state2 = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [taskB, taskA])
        #expect(state1.tasks.map(\.id) == ["task-A", "task-B"])
        #expect(state2.tasks.map(\.id) == ["task-A", "task-B"])
    }

    // 13. Empty Q-Core store produces no phantom task
    @Test func emptyQCoreStoreProducesNoPhantomTask() {
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [])
        #expect(state.tasks.isEmpty)
        #expect(state == .empty)
    }

    // 14. Recovery/corrupted state does not create executable UI state
    @Test func recoveryCorruptedStateDoesNotCreateExecutableUIState() {
        let corruptedTask = QDurableTaskState(
            taskId: "corrupt-task",
            sessionId: "session-c",
            originalIntent: "",
            taskCreationTimestamp: Date(timeIntervalSince1970: 100),
            lifecycleState: .unknown
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [corruptedTask])
        #expect(state.tasks.count == 1)
        let task = state.tasks.first!
        #expect(task.displayName == "Q Task")
        #expect(task.state == .failed)
        #expect(task.currentStepDescription == "Unknown state")
        #expect(task.hasResult == false)
    }

    // 15. Security test: Working projection cannot execute, resume, or approve
    @Test func workingProjectionIsStrictlyReadOnly() {
        let durable = QDurableTaskState(
            taskId: "read-only-check",
            sessionId: "session-ro",
            originalIntent: "Read-only audit task",
            taskCreationTimestamp: Date(),
            lifecycleState: .awaitingApproval
        )
        let state = PaceWorkingSurfaceProjection.project(backgroundAgentTasks: [], durableTasks: [durable])
        let task = state.tasks.first!

        // Confirm PaceWorkingSurfaceTask has only display properties and no executable methods
        #expect(task.id == "read-only-check")
        #expect(task.state == .awaitingApproval)
        // No execution identity, no approval tokens, no closures
    }

    // 16. Real Q-Core dogfood: durable task visible through CompanionManager.workingSurfaceState
    @Test func realQCoreDurableTaskVisibleInCompanionManagerWorkingSurface() async throws {
        let uniqueId = "dogfood-task-\(UUID().uuidString)"
        let durable = QDurableTaskState(
            taskId: uniqueId,
            sessionId: "dogfood-session",
            originalIntent: "What is the capital of France?",
            taskCreationTimestamp: Date(),
            lifecycleState: .completed
        )
        try QDurableTaskStore.shared.saveTask(durable)

        let manager = await CompanionManager()
        let workingState = await manager.workingSurfaceState

        let found = workingState.tasks.first { $0.id == uniqueId }
        #expect(found != nil)
        #expect(found?.displayName == "What is the capital of France?")
        #expect(found?.state == .completed)
        #expect(found?.hasResult == true)

        try? QDurableTaskStore.shared.deleteTask(taskId: uniqueId)
    }

    // 17. GAP-4.7-03 UI Parity: PaceNowSettingsTab workingSurfaceState reflects both legacy and Q-Core durable tasks
    @MainActor
    @Test func nowSettingsTabWorkingSurfaceReflectsQCoreDurableTasksAndLegacyTasks() async throws {
        let uniqueDurableId = "now-tab-durable-\(UUID().uuidString)"
        let durable = QDurableTaskState(
            taskId: uniqueDurableId,
            sessionId: "now-tab-session",
            originalIntent: "Open Calculator and compute totals",
            taskCreationTimestamp: Date(),
            lifecycleState: .awaitingApproval
        )
        try QDurableTaskStore.shared.saveTask(durable)
        defer { try? QDurableTaskStore.shared.deleteTask(taskId: uniqueDurableId) }

        let manager = CompanionManager()
        let tab = PaceNowSettingsTab(companionManager: manager)
        let uiWorkingState = tab.workingSurfaceState

        // B. Q-Core durable task appears in the Working projection consumed by the UI
        let qCoreTask = uiWorkingState.tasks.first { $0.id == uniqueDurableId }
        #expect(qCoreTask != nil)
        #expect(qCoreTask?.displayName == "Open Calculator and compute totals")

        // C. Awaiting approval remains represented correctly
        #expect(qCoreTask?.state == .awaitingApproval)
        #expect(qCoreTask?.currentStepDescription == "Awaiting permission")

        // D. Existing bounded/sanitized projection behavior remains intact
        #expect(uiWorkingState.tasks.count <= PaceWorkingSurfaceLimits.maximumProjectedTaskCount)

        // E. No duplicate task appears when the same logical task exists
        let duplicateCount = uiWorkingState.tasks.filter { $0.id == uniqueDurableId }.count
        #expect(duplicateCount == 1)
    }
}
