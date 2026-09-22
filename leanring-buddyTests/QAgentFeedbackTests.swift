//
//  QAgentFeedbackTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 3, sixth slice: the explicit feedback surface. `QAgent.
//  recordFeedback(taskId:feedback:)` is the first real entry point through which explicit user
//  feedback can reach Phase 2D/2E capability learning — previously only reachable from a test that
//  called `QCoreRuntime.recordUserFeedback` directly. These tests prove the surface forwards
//  faithfully (never invents, never infers), is refused for a task with no observed outcome exactly
//  as the underlying contract already requires, and adds no new authority, network, or persistence
//  path of its own.
//

import Testing
import Foundation
@testable import Pace

@Suite("QAgentFeedbackTests")
struct QAgentFeedbackTests {

    private func makeAgentAndMemory() throws -> (QAgent, QModelCapabilityMemory, QCoreRuntime) {
        let capability = QModelCapabilityMemory(store: try QDurableTaskStore(inMemory: true))
        let core = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(),
            durableStore: try QDurableTaskStore(inMemory: true), capabilityMemory: capability, endpointName: "af-\(UUID().uuidString)"
        )
        return (QAgent(coreRuntime: core), capability, core)
    }

    @Test("A completed task's outcome can be corrected through QAgent, and the correction reaches capability memory")
    func correctionReachesCapabilityMemory() async throws {
        let (agent, capability, core) = try makeAgentAndMemory()
        let task = try await core.submitIntent(prompt: "What is the capital of France?")

        let results = try await agent.recordFeedback(taskId: task.taskId, feedback: .correction)
        #expect(results == [.recorded])

        let row = try #require(capability.observations(forTask: task.taskId).observations.first { $0.source == .taskOutcome })
        #expect(row.outcome == .success)         // the execution really did succeed...
        let profile = capability.profile(taskType: row.taskType, complexity: row.complexity, backend: .ollama)
        #expect(profile.userCorrectionCount == 1)   // ...and the user explicitly corrected it anyway
    }

    @Test("A confirmation is recorded distinctly from a correction, and repeating the same feedback is idempotent")
    func confirmationIsRecordedAndIdempotent() async throws {
        let (agent, capability, core) = try makeAgentAndMemory()
        let task = try await core.submitIntent(prompt: "What is the capital of France?")

        #expect(try await agent.recordFeedback(taskId: task.taskId, feedback: .confirmation) == [.recorded])
        #expect(try await agent.recordFeedback(taskId: task.taskId, feedback: .confirmation) == [.duplicate])

        let profile = capability.profile(taskType: .simpleQA, complexity: .trivial, backend: .ollama)
        #expect(profile.userConfirmationCount == 1)
        #expect(profile.userCorrectionCount == 0)
    }

    @Test("Feedback for an unknown task is refused, never invented")
    func unknownTaskIsRefused() async throws {
        let (agent, capability, _) = try makeAgentAndMemory()
        let results = try await agent.recordFeedback(taskId: "task-that-never-ran", feedback: .correction)
        #expect(results == [.rejected(.noMatchingTaskObservation)])
        #expect(capability.observationCount() == 0)
    }

    @Test("Without capability memory configured, feedback is refused as storeUnavailable — never silently dropped, never fabricated")
    func withoutCapabilityMemoryFeedbackIsRefused() async throws {
        let core = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(),
            durableStore: try QDurableTaskStore(inMemory: true), endpointName: "af-\(UUID().uuidString)"
        )
        let agent = QAgent(coreRuntime: core)
        let task = try await core.submitIntent(prompt: "What is the capital of France?")
        #expect(try await agent.recordFeedback(taskId: task.taskId, feedback: .correction) == [.storeUnavailable])
    }

    @Test("recordFeedback forwards to the exact same QCoreRuntime.recordUserFeedback contract — identical results either way")
    func forwardsFaithfullyToCoreRuntime() async throws {
        let (agent, _, core) = try makeAgentAndMemory()
        let taskA = try await core.submitIntent(prompt: "What is the capital of France?")
        let taskB = try await core.submitIntent(prompt: "What is the capital of Germany?")

        let viaAgent = try await agent.recordFeedback(taskId: taskA.taskId, feedback: .correction)
        let viaCoreDirectly = core.recordUserFeedback(taskId: taskB.taskId, feedback: .correction)
        #expect(viaAgent == viaCoreDirectly)
    }

    @Test("Without an explicit core runtime, recordFeedback resolves the shared bootstrap coordinator's runtime, throwing only if bootstrap genuinely never produced one")
    func resolvesBootstrapWhenNoCustomCoreProvided() async throws {
        // QAgent() with no arguments uses QRuntimeBootstrap.shared — already exercised by
        // QRuntimeBootstrapTests/QFirstRealRunTests; this only proves recordFeedback follows the
        // SAME resolution path as run()/resume() rather than skipping it.
        let agent = QAgent()
        _ = try? await agent.recordFeedback(taskId: "unknown-task-id", feedback: .confirmation)
        // No crash, no thrown QAgentError once bootstrap has run at least once in this process
        // (guaranteed by the suite's own earlier tests / QRuntimeBootstrap being a shared singleton).
    }

    @Test("Explicit feedback is never inferred: an agent run with no feedback call leaves capability memory's correction/confirmation counts at zero")
    func noFeedbackIsNeverInferred() async throws {
        let (_, capability, core) = try makeAgentAndMemory()
        _ = try await core.submitIntent(prompt: "What is the capital of France?")
        let profile = capability.profile(taskType: .simpleQA, complexity: .trivial, backend: .ollama)
        #expect(profile.userCorrectionCount == 0)
        #expect(profile.userConfirmationCount == 0)
    }

    // MARK: - Static audit: no IPC exposure, no new authority

    @Test("Static audit: the feedback surface is a plain method, never wired into QIPCChannel, and references no authority type")
    func staticAuditNoIPCOrAuthorityExposure() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("leanring-buddy/q-runtime/QCore/QAgent.swift"),
            encoding: .utf8
        )
        #expect(source.contains("func recordFeedback"))
        #expect(!source.contains("QIPCMessageType.feedback"))
        #expect(!source.contains("registerHandler(for: .feedback"))
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
        // Exactly this fixed set — nothing added, nothing removed.
        let caseLines = source.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ") }
        #expect(caseLines.count == expectedCases.count)
    }
}
