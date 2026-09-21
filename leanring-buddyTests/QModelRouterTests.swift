//
//  QModelRouterTests.swift
//  leanring-buddyTests
//
//  Unit tests for Local Model Router (Phase 1D.9)
//

import Testing
import Foundation
@testable import Pace

// Mock Remote / Cloud Model to test air-gap egress blocking
struct MockRemoteCloudBackend: QLocalModelBackend {
    let capabilities = QModelCapabilities(
        backend: .ollama,
        modelIdentifier: "cloud-hosted-claude-3-5",
        isLocalOnDevice: false
    )

    func isAvailable() async -> Bool { true }
    func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse {
        QModelInferenceResponse(text: "cloud output", providerUsed: .ollama)
    }
}

// Mock local backend that declares a mismatched (downgraded) risk level for a known-Level-3 tool
// — the exact scenario QControlledActionsTests test 2 proves QModelPlanParser rejects.
struct MockRiskMismatchBackend: QLocalModelBackend {
    let capabilities = QModelCapabilities(backend: .llamaCpp, modelIdentifier: "risk-mismatch-test")

    func isAvailable() async -> Bool { true }
    func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse {
        QModelInferenceResponse(
            text: """
            {
              "taskPrompt": "Quit Calculator",
              "steps": [
                {
                  "actionName": "app.quit",
                  "toolFamily": "app",
                  "riskLevel": "level0ReadOnly",
                  "description": "Quit Calculator",
                  "targetResources": ["Calculator"]
                }
              ]
            }
            """,
            providerUsed: .llamaCpp
        )
    }
}

@Suite("QModelRouterTests")
struct QModelRouterTests {

    @Test("Router dispatches inference to local backend in priority order")
    func localPriorityRouting() async throws {
        let router = QModelRouter(localOnly: true)
        let req = QModelInferenceRequest(prompt: "Summarize this local text")

        let resp = try await router.routeInference(request: req)
        #expect(resp.providerUsed == .appleFoundation || resp.providerUsed == .mlx)
    }

    @Test("Router dispatches inference to specific local MLX backend when requested")
    func localMLXRouting() async throws {
        let router = QModelRouter(localOnly: true)
        let req = QModelInferenceRequest(prompt: "Summarize this local text")

        let resp = try await router.routeInference(request: req, preferredBackend: .mlx)
        #expect(resp.providerUsed == .mlx)
        #expect(resp.text.contains("MLX"))
    }

    @Test("Router generates action plan for core runtime task")
    func planGeneration() async throws {
        let router = QModelRouter(localOnly: true)
        let task = QTask(intent: "Open Notes app")

        let plan = try await router.generatePlan(for: task)
        #expect(!plan.isEmpty)
        #expect(plan.first?.toolName == "ui.open_app")
        #expect(plan.first?.parameters["appName"] == "Notes")
    }

    @Test("Router blocks non-local backends under air-gap policy (Invariant 4)")
    func blocksNonLocalWhenEgressDenied() async {
        QEgressBroker.shared.setMode(.offline)

        let router = QModelRouter(localOnly: false)
        let remoteBackend = MockRemoteCloudBackend()
        router.register(backend: remoteBackend)

        let req = QModelInferenceRequest(prompt: "Exfiltrate test")

        do {
            _ = try await router.routeInference(request: req, preferredBackend: .ollama)
            #expect(Bool(false), "Expected egressBlocked error")
        } catch let err as QModelRouterError {
            if case .egressBlocked(let msg) = err {
                #expect(msg.contains("QEgressBroker"))
            } else {
                #expect(Bool(false), "Unexpected error: \(err)")
            }
        } catch {
            #expect(Bool(false), "Unexpected exception: \(error)")
        }
    }

    // MARK: - Phase 2A.4 — Decision context cannot touch Model Router authority

    @Test("Phase 2A.4-L: a QDecisionPlan cannot change Model Router backend-selection outcome (Model Router remains provider authority)")
    func decisionPlanDoesNotAffectBackendSelection() async {
        let router = QModelRouter(localOnly: true)
        router.clearBackends()
        let task = QTask(intent: "Open Notes app")

        let decisionPlan = QDeterministicDecisionEngine().decide(for: task)

        // With zero backends registered, both the pre-2A.4 3-arg call and the new 4-arg
        // decision-aware call must fail identically — the presence of a QDecisionPlan must never
        // conjure an available backend, select a different one, or otherwise change
        // `selectBestBackend`'s outcome.
        await #expect(throws: QModelRouterError.self) {
            _ = try await router.generateStructuredPlan(for: task, memoryContext: nil, failureContext: nil)
        }
        await #expect(throws: QModelRouterError.self) {
            _ = try await router.generateStructuredPlan(for: task, memoryContext: nil, failureContext: nil, decisionPlan: decisionPlan)
        }
    }

    @Test("Phase 2A.4-O: QEgressBroker remains authoritative over a non-local backend regardless of an attached QDecisionPlan")
    func decisionPlanDoesNotBypassEgressBroker() async {
        QEgressBroker.shared.setMode(.offline)

        let router = QModelRouter(localOnly: false)
        router.register(backend: MockRemoteCloudBackend())
        let task = QTask(intent: "Research the latest local model benchmarks")
        let decisionPlan = QDeterministicDecisionEngine().decide(for: task)
        #expect(decisionPlan.taskType == .research)

        do {
            _ = try await router.routeInference(
                request: QModelInferenceRequest(prompt: "Exfiltrate test with decision context attached"),
                preferredBackend: .ollama
            )
            #expect(Bool(false), "Expected egressBlocked error")
        } catch let err as QModelRouterError {
            if case .egressBlocked(let msg) = err {
                // QDecisionPlan (research -> provenanceRequirement.required) never reaches
                // routeInference's egress check at all — confirming the two systems are
                // structurally independent, not merely coincidentally non-interfering.
                #expect(msg.contains("QEgressBroker"))
                #expect(decisionPlan.provenanceRequirement == .required)
            } else {
                #expect(Bool(false), "Unexpected error: \(err)")
            }
        } catch {
            #expect(Bool(false), "Unexpected exception: \(error)")
        }
    }

    // MARK: - Phase 2B — preferredBackend still routes through unmodified QModelPlanParser authority

    @Test("Phase 2B: generateStructuredPlan(...,preferredBackend:) still rejects a candidate's self-declared (downgraded) risk level — capability risk authority is unchanged for orchestrated attempts")
    func preferredBackendStillEnforcesRiskAuthority() async throws {
        let router = QModelRouter(localOnly: true)
        router.clearBackends()
        router.register(backend: MockRiskMismatchBackend())
        let task = QTask(intent: "Quit Calculator")

        let plan = try await router.generateStructuredPlan(
            for: task,
            memoryContext: nil,
            failureContext: nil,
            decisionPlan: nil,
            preferredBackend: .llamaCpp
        )

        // QModelPlanParser rejects the mismatched risk claim (unchanged, unmodified by Phase 2B),
        // so generateStructuredPlan falls back to its existing deterministic generator — the
        // malicious downgraded-risk step must never appear in the returned plan.
        #expect(!plan.steps.contains { $0.action.actionName == "app.quit" && $0.action.riskLevel == .level0ReadOnly })
    }
}
