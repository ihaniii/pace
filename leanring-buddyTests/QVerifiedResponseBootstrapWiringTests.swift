//
//  QVerifiedResponseBootstrapWiringTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 3, slice 5: bootstrap wiring. `QRuntimeBootstrap` now passes a
//  `QVerifiedResponseConfiguration()` (every sub-feature at its default — OFF) into `QCoreRuntime`,
//  so the assembly step (slice 1) runs for real for the first time outside a test that builds
//  `QCoreRuntime` directly. These tests prove that wiring is genuinely inert for anything but the
//  new lifecycle event and the in-memory response cache: the user-visible summary, task outcome,
//  authorities, and model-call count are all identical to the pre-slice-5 (unconfigured) wiring.
//

import Testing
import Foundation
@testable import Pace

@Suite("QVerifiedResponseBootstrapWiringTests")
struct QVerifiedResponseBootstrapWiringTests {

    private static let prompt = "What is the capital of France?"

    private func makeRuntime(wired: Bool, eventStore: QDurableTaskStore, provider: FakeModelCandidateProvider = FakeModelCandidateProvider(backends: [.ollama]), execution: QExecutionProvider = MockExecutionProvider()) -> QCoreRuntime {
        QCoreRuntime(
            modelProvider: provider, executionProvider: execution, durableStore: eventStore,
            // Mirrors exactly what `QRuntimeBootstrap` now passes vs. what it passed before slice 5.
            verifiedResponse: wired ? QVerifiedResponseConfiguration() : nil,
            endpointName: "vrbw-\(UUID().uuidString)"
        )
    }

    @Test("The default (all-off) configuration is genuinely all off: no structured answer, no local evidence, no write-back")
    func defaultConfigurationIsAllOff() {
        let configuration = QVerifiedResponseConfiguration()
        #expect(configuration.structuredAnswer.isEnabled == false)
        #expect(configuration.localEvidence.isEnabled == false)
        #expect(configuration.writeBack.isEnabled == false)
    }

    @Test("The user-visible task summary and terminal state are byte-identical whether or not the Verified Response path is wired")
    func userVisibleOutcomeIsUnchanged() async throws {
        let unwired = try await makeRuntime(wired: false, eventStore: QDurableTaskStore(inMemory: true)).submitIntent(prompt: Self.prompt)
        let wired = try await makeRuntime(wired: true, eventStore: QDurableTaskStore(inMemory: true)).submitIntent(prompt: Self.prompt)
        guard case .completed(let unwiredSummary) = unwired.state, case .completed(let wiredSummary) = wired.state else {
            Issue.record("expected both tasks to complete, got \(unwired.state) / \(wired.state)")
            return
        }
        #expect(unwiredSummary == wiredSummary)
    }

    @Test("No extra model call: the candidate attempt count is identical whether or not the Verified Response path is wired")
    func noExtraModelCall() async throws {
        let unwiredProvider = FakeModelCandidateProvider(backends: [.ollama])
        let wiredProvider = FakeModelCandidateProvider(backends: [.ollama])
        _ = try await makeRuntime(wired: false, eventStore: try QDurableTaskStore(inMemory: true), provider: unwiredProvider).submitIntent(prompt: Self.prompt)
        _ = try await makeRuntime(wired: true, eventStore: try QDurableTaskStore(inMemory: true), provider: wiredProvider).submitIntent(prompt: Self.prompt)
        #expect(unwiredProvider.attemptCount.values.reduce(0, +) == wiredProvider.attemptCount.values.reduce(0, +))
    }

    @Test("Wiring genuinely changes something observable: a task.response.assembled event now exists (and only now), with every sub-feature reporting off")
    func wiringAddsExactlyOneContentFreeEvent() async throws {
        let unwiredStore = try QDurableTaskStore(inMemory: true)
        let unwiredTask = try await makeRuntime(wired: false, eventStore: unwiredStore).submitIntent(prompt: Self.prompt)
        #expect(try unwiredStore.listEvents(taskId: unwiredTask.taskId).filter { $0.eventType == .responseAssembled }.isEmpty)

        let wiredStore = try QDurableTaskStore(inMemory: true)
        let wiredRuntime = makeRuntime(wired: true, eventStore: wiredStore)
        let wiredTask = try await wiredRuntime.submitIntent(prompt: Self.prompt)
        let event = try #require(try wiredStore.listEvents(taskId: wiredTask.taskId).first { $0.eventType == .responseAssembled })

        #expect(event.payload["structuredAnswer"] == "notConfigured")
        #expect(event.payload["localEvidenceEnabled"] == "false")
        #expect(event.payload["writeBackEnabled"] == "false")
        #expect(event.payload["collectedEvidenceCount"] == "0")
        #expect(event.payload["answerClaimCount"] == "0")
        #expect(wiredRuntime.verifiedResponse(forTask: wiredTask.taskId) != nil)
    }

    @Test("No pipeline is re-run for a genuinely inert configuration: the reused primary pool is reflected as-is, and no evidence collection stage runs")
    func reusesThePrimaryPoolWithoutARerun() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = makeRuntime(wired: true, eventStore: store)
        let task = try await runtime.submitIntent(prompt: Self.prompt)
        let responseEvent = try #require(try store.listEvents(taskId: task.taskId).first { $0.eventType == .responseAssembled })
        let evidenceEvent = try #require(try store.listEvents(taskId: task.taskId).first { $0.eventType == .evidenceEvaluated })
        // Both events describe the SAME (reused) pool: claim/evidence counts agree.
        #expect(responseEvent.payload["statementCount"] == evidenceEvent.payload["claimCount"])
    }

    @Test("Authorities are unaffected by the wiring: a Level 2 step still halts at .awaitingApproval")
    func permissionGateStillHalts() async throws {
        let model = RecordingDecisionAwareModelProvider()
        model.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write marker to clipboard",
              "steps": [
                { "actionName": "system.clipboard.write", "toolFamily": "system", "description": "Write a marker", "parameters": {"text": "q-vrbw-marker"} }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: model, executionProvider: QExecutionService.shared,
            verifiedResponse: QVerifiedResponseConfiguration(), endpointName: "vrbw-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Write marker to clipboard")
        guard case .awaitingApproval = task.state else {
            Issue.record("expected .awaitingApproval, got \(task.state)")
            return
        }
    }

    @Test("Static audit: QRuntimeBootstrap wires an unmodified QVerifiedResponseConfiguration() — no sub-feature override, hence genuinely all off")
    func bootstrapSourceWiresGenuineDefaults() throws {
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

    @Test("High-risk stays fail-closed before any model call, with the bootstrap-style wiring in place")
    func highRiskStaysFailClosed() async throws {
        let provider = FakeModelCandidateProvider(backends: [.ollama, .llamaCpp])
        let runtime = makeRuntime(wired: true, eventStore: try QDurableTaskStore(inMemory: true), provider: provider)
        let task = try await runtime.submitIntent(prompt: "Delete the temporary project file")
        guard case .failed(let reason) = task.state else {
            Issue.record("expected fail-closed, got \(task.state)")
            return
        }
        #expect(reason.contains("failing closed"))
        #expect(provider.attemptCount.isEmpty)
    }
}
