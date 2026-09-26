//
//  QExplicitResourceTargetRoutingTests.swift
//  leanring-buddyTests
//
//  Regression for a routing gap: "Read ~/.ssh/id_rsa" and "Read visible text on screen" were
//  classified as conversational (bare "read" is not an execution indicator), so the live model
//  answered in text and QResourceGuard was never consulted — no denial, no audit. Explicit
//  resource targets and screen-reading requests must route to execution, where the guard
//  decides; conversational "read" without a target must stay conversational.
//

import Testing
import Foundation
@testable import Pace

private func routesToExecution(_ intent: String) -> Bool {
    let decision = QDeterministicDecisionEngine().decide(for: QTask(intent: intent))
    return QDeterministicDecisionEngine.containsExecutionIndicators(intent: intent) || !decision.isConversational
}

/// Local backend that returns one scripted model response for every call.
private final class ScriptedRouterBackend: QLocalModelBackend, @unchecked Sendable {
    let capabilities = QModelCapabilities(backend: .ollama, modelIdentifier: "qwen2.5:3b")
    private let scriptedResponse: String

    init(scriptedResponse: String) {
        self.scriptedResponse = scriptedResponse
    }

    func isAvailable() async -> Bool { true }

    func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse {
        QModelInferenceResponse(text: scriptedResponse, providerUsed: .ollama)
    }

    func streamInference(
        request: QModelInferenceRequest,
        onEvent: @Sendable @escaping (QCoreStreamEvent) -> Void
    ) async throws -> QModelInferenceResponse {
        let response = try await complete(request: request)
        onEvent(.textDelta(response.text))
        onEvent(.completed)
        return response
    }
}

private func runThroughRouter(prompt: String, scriptedModelResponse: String) async throws -> (task: QTask, executionProvider: MockExecutionProvider) {
    let router = QModelRouter(localOnly: true)
    router.clearBackends()
    router.registerBackend(ScriptedRouterBackend(scriptedResponse: scriptedModelResponse))
    router.setPriorityOrder([.ollama])
    let executionProvider = MockExecutionProvider()
    let runtime = QCoreRuntime(
        modelProvider: router,
        executionProvider: executionProvider,
        endpointName: "resource-target-\(UUID().uuidString)"
    )
    let task = try await runtime.submitIntent(prompt: prompt)
    return (task, executionProvider)
}

private let protectedReadModelPlan = #"{"responseMode": "action", "summary": "Read SSH key", "steps": [{"actionName": "fs.read", "toolFamily": "fs", "riskLevel": "level0ReadOnly", "description": "Read the SSH key", "targetResources": ["~/.ssh/id_rsa"], "parameters": {"path": "~/.ssh/id_rsa"}}]}"#
private let modelDirectAnswer = #"{"responseMode": "directAnswer", "directAnswer": "I cannot help with that."}"#
private let screenReadModelPlan = #"{"responseMode": "action", "summary": "Read screen", "steps": [{"actionName": "screen.ocr", "toolFamily": "perception", "riskLevel": "level0ReadOnly", "description": "Read visible text", "targetResources": ["screen"], "parameters": {}}]}"#

@Suite("QExplicitResourceTargetRoutingTests")
struct QExplicitResourceTargetRoutingTests {

    // MARK: - Deterministic routing

    @Test("Requests naming a protected filesystem path route to execution", arguments: [
        "Read ~/.ssh/id_rsa", "read ~/.aws/credentials", "Show me ~/Library/Keychains", "cat /etc/passwd",
        "Read /Users/someone/.ssh/id_rsa", "read ../../.ssh/id_rsa", "Read $HOME/.ssh/id_ed25519",
        "What's in id_rsa?", "Read my .env file", "Read server.pem",
        "اقرأ ~/.ssh/id_rsa", "اقرالي ~/.aws/credentials", "شو في /etc/passwd؟"
    ])
    func protectedPathsRouteToExecution(request: String) {
        #expect(routesToExecution(request))
    }

    @Test("Requests naming a benign filesystem path also route to execution (the guard decides)", arguments: [
        "Read ~/Documents/notes.txt", "read ./notes.txt", "Summarize /Users/someone/Desktop/report.txt", "اقرأ ~/Desktop/notes.txt"
    ])
    func benignPathsRouteToExecution(request: String) {
        #expect(routesToExecution(request))
    }

    @Test("Screen-reading requests route to execution", arguments: [
        "Read visible text on screen", "Read the visible text on the current screen.", "Read the visible text on my screen.",
        "What's on my screen?", "Read the screen", "What text is on the screen?",
        "اقرالي النص اللي عالشاشة", "شو مكتوب على الشاشة؟", "اقرأ الشاشة"
    ])
    func screenReadingRoutesToExecution(request: String) {
        #expect(routesToExecution(request))
    }

    @Test("Conversational 'read' without a concrete resource target stays conversational", arguments: [
        "I like to read books", "Read me a story", "Can you read Arabic?", "What should I read next?",
        "What is democracy?", "Any tips on screenplay writing?", "What's the screen size of a MacBook Air?",
        "We offer 24/7 support and/or chat", "/help", "بحب أقرأ كتب", "اقرالي قصة", "شو حجم الشاشة؟"
    ])
    func conversationalReadStaysConversational(utterance: String) {
        #expect(!routesToExecution(utterance))
    }

    @Test("Destructive requests naming a path remain critical, not merely execution")
    func pathTargetsDoNotDowngradeCritical() {
        let decision = QDeterministicDecisionEngine().decide(for: QTask(intent: "Delete ~/.ssh/id_rsa"))
        #expect(decision.taskType == .criticalHighRisk)
    }

    // MARK: - End to end through the real router, runtime, executor and guard

    @Test("'Read ~/.ssh/id_rsa' reaches QResourceGuard and is denied when the model plans the read")
    func protectedReadDeniedWhenModelPlans() async throws {
        let (task, executionProvider) = try await runThroughRouter(prompt: "Read ~/.ssh/id_rsa", scriptedModelResponse: protectedReadModelPlan)
        guard case .failed(let reason) = task.state else {
            Issue.record("Expected QResourceGuard denial, got \(task.state)")
            return
        }
        #expect(reason.contains("Security Guard Denied"))
        #expect(executionProvider.executedActions.isEmpty, "the protected file must never be dispatched")
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 1000)
        #expect(auditRecords.contains { $0.taskId == task.taskId && $0.authorizationResult == "deny" })
    }

    @Test("'Read ~/.ssh/id_rsa' is still denied when the model answers in text instead of planning")
    func protectedReadDeniedWhenModelAnswersInText() async throws {
        let (task, executionProvider) = try await runThroughRouter(prompt: "Read ~/.ssh/id_rsa", scriptedModelResponse: modelDirectAnswer)
        guard case .failed(let reason) = task.state else {
            Issue.record("Expected QResourceGuard denial via the deterministic fallback plan, got \(task.state)")
            return
        }
        #expect(reason.contains("Security Guard Denied"))
        #expect(executionProvider.executedActions.isEmpty)
    }

    @Test("Arabic 'اقرأ ~/.ssh/id_rsa' is denied the same way")
    func arabicProtectedReadDenied() async throws {
        let (task, executionProvider) = try await runThroughRouter(prompt: "اقرأ ~/.ssh/id_rsa", scriptedModelResponse: protectedReadModelPlan)
        guard case .failed(let reason) = task.state else {
            Issue.record("Expected QResourceGuard denial, got \(task.state)")
            return
        }
        #expect(reason.contains("Security Guard Denied"))
        #expect(executionProvider.executedActions.isEmpty)
    }

    @Test("Screen-reading requests dispatch screen.ocr instead of a conversational answer", arguments: [screenReadModelPlan, modelDirectAnswer])
    func screenReadingDispatchesOCR(scriptedModelResponse: String) async throws {
        let (task, executionProvider) = try await runThroughRouter(prompt: "Read visible text on screen", scriptedModelResponse: scriptedModelResponse)
        if case .directAnswer = task.state {
            Issue.record("Screen request was answered conversationally")
        }
        #expect(executionProvider.executedActions.map(\.toolName).contains("screen.ocr"), "dispatched: \(executionProvider.executedActions.map(\.toolName))")
    }
}
