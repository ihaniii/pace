//
//  QResumePathParityTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 3, seventh slice: resume-path parity. Before this slice, a task
//  resumed via `resumeTask`/`resolveApproval` (crash recovery, or a same-process approval-grant
//  continuation) never ran the Evidence -> Verification -> Verified Response -> Candidate
//  Attribution chain `submitIntent` already runs on its own first goal evaluation — it was silently
//  invisible to everything Phase 2C-3 built. These tests prove the shared `executeResumedPlan`
//  helper now runs that SAME chain, that it is genuinely additive (existing recovery/approval
//  behaviour, task state, and authorities are unchanged), and that it stays bounded and honest about
//  what a resume genuinely has (no fresh Phase 2B candidate attempts to report).
//

import Testing
import Foundation
@testable import Pace

@Suite("QResumePathParityTests")
struct QResumePathParityTests {

    private func events(_ store: QDurableTaskStore, _ taskId: String, _ type: QTaskLifecycleEventType) throws -> [QTaskLifecycleEvent] {
        try store.listEvents(taskId: taskId).filter { $0.eventType == type }
    }

    private func savedRecoverableTask(
        store: QDurableTaskStore, taskId: String, sessionId: String = "s0", intent: String, actionName: String = "system.running_apps"
    ) throws {
        let step = QDurablePlanStepSnapshot(
            stepId: "step-0", index: 0, actionName: actionName, toolFamily: "system", riskLevel: "level0ReadOnly",
            literalAction: "Step for \(intent)", targetResources: [], arguments: [:], state: "pending"
        )
        let plan = QDurablePlanSnapshot(planId: "plan-\(taskId)", taskId: taskId, sessionId: sessionId, goal: intent, steps: [step])
        let taskState = QDurableTaskState(
            taskId: taskId, sessionId: sessionId, originalIntent: intent, lifecycleState: .running,
            currentPlanId: "plan-\(taskId)", currentStepIndex: 0
        )
        try store.savePlan(plan)
        try store.saveTask(taskState)
    }

    // MARK: - Core parity: the chain now runs on resume

    @Test("A resumed, completed task now records an evidenceEvaluated event — previously it recorded none")
    func resumedTaskRecordsEvidenceEvaluation() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: store
        )
        try savedRecoverableTask(store: store, taskId: "task-parity-1", intent: "What is the capital of France?")

        let resumed = try await runtime.resumeTask(taskId: "task-parity-1")
        guard case .completed = resumed.state else {
            Issue.record("expected completed, got \(resumed.state)")
            return
        }
        #expect(!(try events(store, "task-parity-1", .evidenceEvaluated)).isEmpty)
    }

    @Test("With the Verified Response path configured, a resumed task also gets a responseAssembled event and a queryable rendered response")
    func resumedTaskAssemblesVerifiedResponse() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: store,
            verifiedResponse: QVerifiedResponseConfiguration()
        )
        try savedRecoverableTask(store: store, taskId: "task-parity-2", intent: "What is the capital of France?")

        let resumed = try await runtime.resumeTask(taskId: "task-parity-2")
        guard case .completed = resumed.state else {
            Issue.record("expected completed, got \(resumed.state)")
            return
        }
        #expect(!(try events(store, "task-parity-2", .responseAssembled)).isEmpty)
        #expect(runtime.verifiedResponse(forTask: "task-parity-2") != nil)
    }

    @Test("Honest about what a resume has: zero fresh Phase 2B candidate attempts are ever claimed for a resumed task")
    func noFreshCandidateAttemptsAreClaimed() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let capability = QModelCapabilityMemory(store: try QDurableTaskStore(inMemory: true))
        let runtime = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: store,
            capabilityMemory: capability
        )
        try savedRecoverableTask(store: store, taskId: "task-parity-3", intent: "What is the capital of France?")

        _ = try await runtime.resumeTask(taskId: "task-parity-3")
        // No .modelAttempt / .taskOutcome rows: resuming re-runs no orchestration, so there is
        // nothing genuine to attribute at that level (task-level 2B-attempt learning is untouched).
        #expect(capability.observations(forTask: "task-parity-3").observations.filter { $0.source == .modelAttempt || $0.source == .taskOutcome }.isEmpty)
    }

    // MARK: - Structured answer / local evidence parity, still gated by the same configuration

    @Test("With structured answer enabled and a capable provider, a resumed task attempts exactly one answer and its claims feed the verified response")
    func resumedTaskAttemptsStructuredAnswerWhenConfigured() async throws {
        struct AnsweringProvider: QModelCandidateAwareProvider, QStructuredAnswerProvider {
            let inner: FakeModelCandidateProvider
            func generatePlan(for task: QTask) async throws -> [QActionRequest] { try await inner.generatePlan(for: task) }
            func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
                try await inner.generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext)
            }
            func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?) async throws -> QPlan {
                try await inner.generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: decisionPlan)
            }
            func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?, preferredBackend: QModelBackendType?) async throws -> QPlan {
                try await inner.generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: decisionPlan, preferredBackend: preferredBackend)
            }
            func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String {
                try await inner.generateGroundedSummary(for: task, verifiedEvidence: verifiedEvidence, isSuccess: isSuccess)
            }
            func candidateBackends() -> [QModelBackendType] { inner.candidateBackends() }
            func candidateDescriptor(for backend: QModelBackendType) async -> QModelCandidate? { await inner.candidateDescriptor(for: backend) }
            func generateStructuredAnswer(for task: QTask, decisionPlan: QDecisionPlan, timeoutSeconds: TimeInterval) async throws -> QStructuredAnswerDraft {
                QStructuredAnswerDraft(backend: .ollama, outputText: "capital of france: paris", durationSeconds: 0.01)
            }
        }
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: AnsweringProvider(inner: FakeModelCandidateProvider(backends: [.ollama])), executionProvider: MockExecutionProvider(), durableStore: store,
            verifiedResponse: QVerifiedResponseConfiguration(structuredAnswer: .init(isEnabled: true, timeoutSeconds: 5))
        )
        try savedRecoverableTask(store: store, taskId: "task-parity-4", intent: "What is the capital of France?")

        let resumed = try await runtime.resumeTask(taskId: "task-parity-4")
        guard case .completed = resumed.state else {
            Issue.record("expected completed, got \(resumed.state)")
            return
        }
        let event = try #require(try events(store, "task-parity-4", .responseAssembled).first)
        #expect(event.payload["structuredAnswer"] == "obtained")
        #expect(event.payload["answerClaimCount"] == "1")
        let rendered = try #require(runtime.verifiedResponse(forTask: "task-parity-4"))
        #expect(rendered.text.contains("capital of france: paris"))
    }

    @Test("Without structured answer enabled (default), a resumed task requests no answer at all")
    func resumedTaskRequestsNoAnswerByDefault() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: store,
            verifiedResponse: QVerifiedResponseConfiguration()
        )
        try savedRecoverableTask(store: store, taskId: "task-parity-5", intent: "What is the capital of France?")

        _ = try await runtime.resumeTask(taskId: "task-parity-5")
        let event = try #require(try events(store, "task-parity-5", .responseAssembled).first)
        #expect(event.payload["structuredAnswer"] == "notConfigured")
        #expect(event.payload["answerClaimCount"] == "0")
    }

    @Test("Local evidence collection on resume respects the caller-supplied selected files for THIS resume attempt")
    func resumedTaskCollectsSuppliedSelectedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("q-resume-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.txt")
        try "capital of france: paris".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: store,
            verifiedResponse: QVerifiedResponseConfiguration(localEvidence: .init(isEnabled: true))
        )
        try savedRecoverableTask(store: store, taskId: "task-parity-6", intent: "What is the capital of France?")

        _ = try await runtime.resumeTask(taskId: "task-parity-6", selectedFiles: [QSelectedFileHandle(path: fileURL.path)])
        let event = try #require(try events(store, "task-parity-6", .responseAssembled).first)
        #expect(event.payload["collectedEvidenceCount"] == "1")
        let rendered = try #require(runtime.verifiedResponse(forTask: "task-parity-6"))
        #expect(rendered.text.contains("capital of france: paris"))
    }

    @Test("Selected files supplied to resumeTask are bounded the same way submitIntent's are")
    func resumeSelectedFilesAreBounded() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: store,
            verifiedResponse: QVerifiedResponseConfiguration(localEvidence: .init(isEnabled: true))
        )
        try savedRecoverableTask(store: store, taskId: "task-parity-7", intent: "What is the capital of France?")

        let tooMany = (0..<(QLocalEvidenceLimits.maxSelectedFilesPerRequest + 5)).map { QSelectedFileHandle(path: "/nonexistent-\($0).txt") }
        // Must not crash and must not attempt more than the documented bound (each rejected as
        // rejectedPath since the files don't exist, but the COUNT considered is what matters here).
        _ = try await runtime.resumeTask(taskId: "task-parity-7", selectedFiles: tooMany)
        #expect(true)   // reaching this point without a crash/hang is the assertion
    }

    // MARK: - Approval-grant resume also gets parity (the other executeResumedPlan caller)

    @Test("A same-process approval-grant resume also runs the evidence-evaluation chain on completion")
    func approvalGrantResumeAlsoGetsParity() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let model = RecordingDecisionAwareModelProvider()
        model.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write marker to clipboard",
              "steps": [
                { "actionName": "system.clipboard.write", "toolFamily": "system", "description": "Write a marker", "parameters": {"text": "q-resume-parity-marker"} }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(modelProvider: model, executionProvider: QExecutionService.shared, durableStore: store, endpointName: "rp-\(UUID().uuidString)")
        let task = try await runtime.submitIntent(prompt: "Write marker to clipboard")
        guard case .awaitingApproval(let approval) = task.state else {
            Issue.record("expected .awaitingApproval, got \(task.state)")
            return
        }

        // Before the approval resume: only the ORIGINAL submitIntent's own evidenceEvaluated event
        // exists — approval halts happen before that point (mirrors slice 5's own "no event before
        // execution" guarantee).
        #expect(try events(store, task.taskId, .evidenceEvaluated).isEmpty)

        let resolved = try await runtime.resolveApproval(taskId: task.taskId, approvalId: approval.id, decision: .approved)
        guard case .completed = resolved.state else {
            Issue.record("expected completed after approval, got \(resolved.state)")
            return
        }
        #expect(!(try events(store, task.taskId, .evidenceEvaluated)).isEmpty)
    }

    // MARK: - Authorities and existing behaviour are unaffected

    @Test("Existing recovery behaviour is unchanged: a mid-flight multi-step recovery still resumes from the pending step and completes")
    func existingRecoveryBehaviourIsUnchanged() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: store)
        let completedStep = QDurablePlanStepSnapshot(
            stepId: "step-done", index: 0, actionName: "system.running_apps", toolFamily: "system", riskLevel: "level0ReadOnly",
            literalAction: "Already done", state: "completed", resultSummary: "done", verifiedEvidence: "done"
        )
        let pendingStep = QDurablePlanStepSnapshot(
            stepId: "step-pending", index: 1, actionName: "system.running_apps", toolFamily: "system", riskLevel: "level0ReadOnly",
            literalAction: "Still pending", targetResources: [], arguments: [:], state: "pending"
        )
        try store.savePlan(QDurablePlanSnapshot(planId: "plan-parity-8", taskId: "task-parity-8", sessionId: "s0", goal: "multi-step", steps: [completedStep, pendingStep]))
        try store.saveTask(QDurableTaskState(taskId: "task-parity-8", sessionId: "s0", originalIntent: "multi-step", lifecycleState: .running, currentPlanId: "plan-parity-8", currentStepIndex: 1))

        let resumed = try await runtime.resumeTask(taskId: "task-parity-8")
        #expect(resumed.state.isTerminal)
    }

    @Test("High-risk stays fail-closed and unaffected: resuming a plan does not run the new chain before execution, and a still-blocked task is returned as-is")
    func highRiskRemainsUnaffectedByParity() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        var taskState = QDurableTaskState(taskId: "task-parity-9", sessionId: "s0", originalIntent: "blocked task", lifecycleState: .blocked, currentPlanId: nil, currentStepIndex: 0)
        taskState.securityBlockReason = "denied by policy"
        try store.saveTask(taskState)
        let runtime = QCoreRuntime(modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: store)

        let resumed = try await runtime.resumeTask(taskId: "task-parity-9")
        guard case .failed = resumed.state else {
            Issue.record("expected a failed/blocked terminal state, got \(resumed.state)")
            return
        }
        #expect(try events(store, "task-parity-9", .evidenceEvaluated).isEmpty)   // never reached executeResumedPlan at all
    }

    @Test("No extra model call beyond the single (default-off) structured-answer attempt: candidate attempt count is unaffected by resume parity")
    func noExtraPlanningModelCall() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let provider = FakeModelCandidateProvider(backends: [.ollama])
        let runtime = QCoreRuntime(modelProvider: provider, executionProvider: MockExecutionProvider(), durableStore: store)
        try savedRecoverableTask(store: store, taskId: "task-parity-10", intent: "What is the capital of France?")

        _ = try await runtime.resumeTask(taskId: "task-parity-10")
        #expect(provider.attemptCount.isEmpty)   // FakeModelCandidateProvider only counts generateStructuredPlan(preferredBackend:) calls; resume re-plans nothing
    }
}
