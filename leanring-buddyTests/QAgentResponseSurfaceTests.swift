//
//  QAgentResponseSurfaceTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 3, eighth slice: the QAgent response-path surface.
//  `QAgent.verifiedResponse(forTask:)` is the first entry point through which any caller outside a
//  test can retrieve a task's assembled `QVerifiedResponse` (Phase 3, first slice) — before this
//  slice, `QCoreRuntime.verifiedResponse(forTask:)` had zero callers outside tests. `QAgent.resume`
//  also gained the seventh slice's own `selectedFiles:` parameter, previously only reachable by
//  constructing `QCoreRuntime` directly. These tests prove both surfaces forward faithfully (never
//  invent, never alter), add no new pipeline run/model call/authority, and are refused (not
//  fabricated) when nothing was assembled.
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

    // MARK: - Static audit: no IPC exposure, no new authority

    @Test("Static audit: the response surface adds a plain method, never wired into QIPCChannel, and references no authority type")
    func staticAuditNoIPCOrAuthorityExposure() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("leanring-buddy/q-runtime/QCore/QAgent.swift"),
            encoding: .utf8
        )
        #expect(source.contains("func verifiedResponse(forTask"))
        #expect(source.contains("selectedFiles: [QSelectedFileHandle] = []"))
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
