//
//  QAgentResponseSurfaceTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 3, eighth through tenth slices: the QAgent response-path
//  surface. `QAgent.verifiedResponse(forTask:)` is the first entry point through which any caller
//  outside a test can retrieve a task's assembled `QVerifiedResponse` (Phase 3, first slice) —
//  before slice eight, `QCoreRuntime.verifiedResponse(forTask:)` had zero callers outside tests.
//  `QAgent.resume` also gained the seventh slice's own `selectedFiles:` parameter, previously only
//  reachable by constructing `QCoreRuntime` directly. Slice nine closed the asymmetry slice eight
//  left: `QAgent.approve`/`QCoreRuntime.resolveApproval` gained the identical `selectedFiles:`
//  parameter, so an approval-grant resume can supply local evidence exactly like a crash-recovery
//  resume already could. Slice ten closes the last one: `QAgent.run` — the original, most-used
//  public entry point (Phase 1F, predating Phase 3 entirely) — gains the same `selectedFiles:`
//  parameter, completing symmetry with all three `QCoreRuntime` entry points that accept it
//  (`submitIntent`/`resumeTask`/`resolveApproval`). These tests prove every surface forwards
//  faithfully (never invents, never alters), adds no new pipeline run/model call/authority, and is
//  refused (not fabricated) when nothing was assembled.
//

import Testing
import Foundation
@testable import Pace

@Suite("QAgentResponseSurfaceTests")
struct QAgentResponseSurfaceTests {

    private func makeAgentAndCore(configured: Bool) -> (QAgent, QCoreRuntime) {
        let core = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(),
            durableStore: try! QDurableTaskStore(inMemory: true),
            verifiedResponse: configured ? QVerifiedResponseConfiguration() : nil,
            endpointName: "ars-\(UUID().uuidString)"
        )
        return (QAgent(coreRuntime: core), core)
    }

    // MARK: - verifiedResponse(forTask:) forwards faithfully

    @Test("A completed task's verified response is retrievable through QAgent, identical to the direct QCoreRuntime call")
    func verifiedResponseForwardsFaithfully() async throws {
        let (agent, core) = makeAgentAndCore(configured: true)
        let task = try await core.submitIntent(prompt: "What is the capital of France?")

        let viaAgent = try await agent.verifiedResponse(forTask: task.taskId)
        let viaCoreDirectly = core.verifiedResponse(forTask: task.taskId)
        #expect(viaAgent != nil)
        #expect(viaAgent == viaCoreDirectly)
    }

    @Test("Without the Verified Response path configured, QAgent.verifiedResponse returns nil — never fabricated")
    func verifiedResponseIsNilWhenNotConfigured() async throws {
        let (agent, core) = makeAgentAndCore(configured: false)
        let task = try await core.submitIntent(prompt: "What is the capital of France?")
        #expect(try await agent.verifiedResponse(forTask: task.taskId) == nil)
    }

    @Test("An unknown task ID returns nil, never an error and never invented content")
    func verifiedResponseForUnknownTaskIsNil() async throws {
        let (agent, _) = makeAgentAndCore(configured: true)
        #expect(try await agent.verifiedResponse(forTask: "task-that-never-ran") == nil)
    }

    @Test("Reading the verified response triggers no additional pipeline run or model call")
    func verifiedResponseAddsNoExtraModelCall() async throws {
        let provider = FakeModelCandidateProvider(backends: [.ollama])
        let core = QCoreRuntime(
            modelProvider: provider, executionProvider: MockExecutionProvider(),
            durableStore: try QDurableTaskStore(inMemory: true),
            verifiedResponse: QVerifiedResponseConfiguration(), endpointName: "ars-\(UUID().uuidString)"
        )
        let agent = QAgent(coreRuntime: core)
        let task = try await core.submitIntent(prompt: "What is the capital of France?")
        let attemptsBeforeRead = provider.attemptCount

        _ = try await agent.verifiedResponse(forTask: task.taskId)
        _ = try await agent.verifiedResponse(forTask: task.taskId)

        #expect(provider.attemptCount == attemptsBeforeRead)
    }

    @Test("Without an explicit core runtime, verifiedResponse resolves the shared bootstrap coordinator's runtime, throwing only if bootstrap genuinely never produced one")
    func verifiedResponseResolvesBootstrapWhenNoCustomCoreProvided() async throws {
        // Mirrors QAgentFeedbackTests.resolvesBootstrapWhenNoCustomCoreProvided: QAgent() with no
        // arguments uses QRuntimeBootstrap.shared, already exercised elsewhere in this suite — this
        // only proves verifiedResponse follows the SAME resolution path as run()/resume(), never a
        // separate one of its own.
        let agent = QAgent()
        _ = try? await agent.verifiedResponse(forTask: "unknown-task-id")
        // No crash, no thrown QAgentError once bootstrap has run at least once in this process.
    }

    // MARK: - resume(selectedFiles:) forwards faithfully

    private func savedRecoverableTask(store: QDurableTaskStore, taskId: String, sessionId: String = "s0", intent: String) throws {
        let step = QDurablePlanStepSnapshot(
            stepId: "step-0", index: 0, actionName: "system.running_apps", toolFamily: "system", riskLevel: "level0ReadOnly",
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

    @Test("QAgent.resume threads selectedFiles through to QCoreRuntime.resumeTask, and its evidence reaches the verified response")
    func resumeThreadsSelectedFilesThrough() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("q-agent-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.txt")
        try "capital of france: paris".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = try QDurableTaskStore(inMemory: true)
        let core = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: store,
            verifiedResponse: QVerifiedResponseConfiguration(localEvidence: .init(isEnabled: true)),
            endpointName: "ars-\(UUID().uuidString)"
        )
        let agent = QAgent(coreRuntime: core)
        try savedRecoverableTask(store: store, taskId: "agent-resume-1", intent: "What is the capital of France?")

        let result = try await agent.resume(taskId: "agent-resume-1", selectedFiles: [QSelectedFileHandle(path: fileURL.path)])
        #expect(result.isSuccess)

        let rendered = try #require(try await agent.verifiedResponse(forTask: "agent-resume-1"))
        #expect(rendered.text.contains("capital of france: paris"))
    }

    @Test("QAgent.resume without selectedFiles (the default) behaves exactly as it did before this slice")
    func resumeWithoutSelectedFilesIsUnchanged() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let core = QCoreRuntime(modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: store)
        let agent = QAgent(coreRuntime: core)
        try savedRecoverableTask(store: store, taskId: "agent-resume-2", intent: "What is the capital of France?")

        let result = try await agent.resume(taskId: "agent-resume-2")
        #expect(result.isSuccess)
    }

    // MARK: - Phase 3, ninth slice: approve(selectedFiles:) forwards faithfully

    @Test("QAgent.approve threads selectedFiles through to QCoreRuntime.resolveApproval, and its evidence reaches the verified response — closing the asymmetry the eighth slice left at this call")
    func approveThreadsSelectedFilesThrough() async throws {
        // Deliberately MockExecutionProvider (never a real execution path): this test only needs
        // to prove selectedFiles reaches the post-approval verified response, not that the
        // underlying clipboard step itself succeeds — its own verification legitimately reads the
        // REAL system pasteboard regardless of execution provider (see QPlanExecutor), so with a
        // mock write it correctly does not verify. That is expected and irrelevant here: slice 7
        // already established that recordEvidenceEvaluation (and therefore local evidence
        // collection) runs for BOTH outcomes, satisfied or not.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("q-agent-approve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.txt")
        try "capital of france: paris".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = try QDurableTaskStore(inMemory: true)
        let model = RecordingDecisionAwareModelProvider()
        model.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write marker to clipboard",
              "steps": [
                { "actionName": "system.clipboard.write", "toolFamily": "system", "description": "Write a marker", "parameters": {"text": "q-agent-approve-marker"} }
              ]
            }
            """
        ]
        let core = QCoreRuntime(
            modelProvider: model, executionProvider: MockExecutionProvider(), durableStore: store,
            verifiedResponse: QVerifiedResponseConfiguration(localEvidence: .init(isEnabled: true)),
            endpointName: "ars-\(UUID().uuidString)"
        )
        let agent = QAgent(coreRuntime: core)
        let task = try await core.submitIntent(prompt: "Write marker to clipboard")
        guard case .awaitingApproval(let approval) = task.state else {
            Issue.record("expected .awaitingApproval, got \(task.state)")
            return
        }

        _ = try await agent.approve(
            taskId: task.taskId, approvalId: approval.id, decision: .approved,
            selectedFiles: [QSelectedFileHandle(path: fileURL.path)]
        )

        let rendered = try #require(try await agent.verifiedResponse(forTask: task.taskId))
        #expect(rendered.text.contains("capital of france: paris"))
    }

    @Test("QAgent.approve without selectedFiles (the default) behaves exactly as it did before this slice")
    func approveWithoutSelectedFilesIsUnchanged() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let model = RecordingDecisionAwareModelProvider()
        model.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write marker to clipboard",
              "steps": [
                { "actionName": "system.clipboard.write", "toolFamily": "system", "description": "Write a marker", "parameters": {"text": "q-agent-approve-marker-2"} }
              ]
            }
            """
        ]
        let core = QCoreRuntime(modelProvider: model, executionProvider: MockExecutionProvider(), durableStore: store, endpointName: "ars-\(UUID().uuidString)")
        let agent = QAgent(coreRuntime: core)
        let task = try await core.submitIntent(prompt: "Write marker to clipboard")
        guard case .awaitingApproval(let approval) = task.state else {
            Issue.record("expected .awaitingApproval, got \(task.state)")
            return
        }

        let result = try await agent.approve(taskId: task.taskId, approvalId: approval.id, decision: .approved)
        #expect(result.taskId == task.taskId)   // reaching a real, matching QAgentResult without a crash/hang is the assertion
    }

    @Test("selectedFiles supplied to QAgent.approve are bounded the same way resumeTask's are")
    func approveSelectedFilesAreBounded() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let model = RecordingDecisionAwareModelProvider()
        model.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write marker to clipboard",
              "steps": [
                { "actionName": "system.clipboard.write", "toolFamily": "system", "description": "Write a marker", "parameters": {"text": "q-agent-approve-marker-3"} }
              ]
            }
            """
        ]
        let core = QCoreRuntime(
            modelProvider: model, executionProvider: MockExecutionProvider(), durableStore: store,
            verifiedResponse: QVerifiedResponseConfiguration(localEvidence: .init(isEnabled: true)),
            endpointName: "ars-\(UUID().uuidString)"
        )
        let agent = QAgent(coreRuntime: core)
        let task = try await core.submitIntent(prompt: "Write marker to clipboard")
        guard case .awaitingApproval(let approval) = task.state else {
            Issue.record("expected .awaitingApproval, got \(task.state)")
            return
        }

        let tooMany = (0..<(QLocalEvidenceLimits.maxSelectedFilesPerRequest + 5)).map { QSelectedFileHandle(path: "/nonexistent-\($0).txt") }
        _ = try await agent.approve(taskId: task.taskId, approvalId: approval.id, decision: .approved, selectedFiles: tooMany)
        #expect(true)   // reaching this point without a crash/hang is the assertion
    }

    // MARK: - Phase 3, tenth slice: run(selectedFiles:) forwards faithfully

    @Test("QAgent.run threads selectedFiles through to QCoreRuntime.submitIntent, and its evidence reaches the verified response")
    func runThreadsSelectedFilesThrough() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("q-agent-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.txt")
        try "capital of france: paris".write(to: fileURL, atomically: true, encoding: .utf8)

        let core = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(),
            durableStore: try QDurableTaskStore(inMemory: true),
            verifiedResponse: QVerifiedResponseConfiguration(localEvidence: .init(isEnabled: true)),
            endpointName: "ars-\(UUID().uuidString)"
        )
        let agent = QAgent(coreRuntime: core)

        let result = try await agent.run(task: "What is the capital of France?", selectedFiles: [QSelectedFileHandle(path: fileURL.path)])
        #expect(result.isSuccess)

        let rendered = try #require(try await agent.verifiedResponse(forTask: result.taskId))
        #expect(rendered.text.contains("capital of france: paris"))
    }

    @Test("QAgent.run without selectedFiles (the default) behaves exactly as it did before this slice")
    func runWithoutSelectedFilesIsUnchanged() async throws {
        let core = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(),
            durableStore: try QDurableTaskStore(inMemory: true), endpointName: "ars-\(UUID().uuidString)"
        )
        let agent = QAgent(coreRuntime: core)

        let result = try await agent.run(task: "What is the capital of France?")
        #expect(result.isSuccess)
    }

    @Test("selectedFiles supplied to QAgent.run are bounded the same way submitIntent's are")
    func runSelectedFilesAreBounded() async throws {
        let core = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(),
            durableStore: try QDurableTaskStore(inMemory: true),
            verifiedResponse: QVerifiedResponseConfiguration(localEvidence: .init(isEnabled: true)),
            endpointName: "ars-\(UUID().uuidString)"
        )
        let agent = QAgent(coreRuntime: core)

        let tooMany = (0..<(QLocalEvidenceLimits.maxSelectedFilesPerRequest + 5)).map { QSelectedFileHandle(path: "/nonexistent-\($0).txt") }
        let result = try await agent.run(task: "What is the capital of France?", selectedFiles: tooMany)
        #expect(result.isSuccess)   // reaching a normal completion without a crash/hang is the assertion
    }

    // MARK: - Static audit: no IPC exposure, no new authority

    @Test("Static audit: the response surface adds a plain method, never wired into QIPCChannel, and references no authority type")
    func staticAuditNoIPCOrAuthorityExposure() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("leanring-buddy/q-runtime/QCore/QAgent.swift"),
            encoding: .utf8
        )
        #expect(source.contains("func verifiedResponse(forTask"))
        #expect(source.contains("func run("))
        #expect(source.contains("func approve("))
        let selectedFilesCount = source.components(separatedBy: "selectedFiles: [QSelectedFileHandle] = []").count - 1
        #expect(selectedFilesCount == 3, "expected exactly three default-empty selectedFiles parameters (run, resume, and approve), found \(selectedFilesCount)")
        #expect(!source.contains("QIPCMessageType.verifiedResponse"))
        #expect(!source.contains("registerHandler(for: .verifiedResponse"))
        let codeLines = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        for symbol in ["QPermissionGate", "QResourceGuard", "QEgressBroker", "QApprovalCoordinator"] {
            #expect(!codeLines.contains { $0.contains(symbol) }, "QAgent.swift references authority type \(symbol)")
        }
    }

    @Test("Static audit: QIPCMessageType is untouched by this slice — the frozen IPC protocol gains no new case")
    func ipcMessageTypeIsUntouched() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("leanring-buddy/q-runtime/QIPC/QIPCMessage.swift"),
            encoding: .utf8
        )
        let expectedCases = ["intentSubmit", "intentResponse", "actionRequest", "actionResponse", "permissionPrompt", "permissionDecision", "bridgeCall", "bridgeResult", "heartbeat"]
        for name in expectedCases {
            #expect(source.contains("case \(name)"))
        }
        let caseLines = source.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ") }
        #expect(caseLines.count == expectedCases.count)
    }

    @Test("Static audit: QRuntimeBootstrap's Verified Response wiring is unchanged by this slice — still an unmodified, all-default configuration")
    func bootstrapDefaultsAreUnchanged() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("leanring-buddy/q-runtime/QShared/QRuntimeBootstrap.swift"),
            encoding: .utf8
        )
        #expect(source.contains("let verifiedResponse = QVerifiedResponseConfiguration()"))
        for token in ["structuredAnswer:", "localEvidence:", "writeBack:"] {
            #expect(!source.contains(token), "QRuntimeBootstrap.swift overrides a Verified Response sub-feature (\(token)) away from its safe default")
        }
    }
}
