//
//  QArabicConversationalRoutingTests.swift
//  leanring-buddyTests
//
//  Phase 4.7H: a model-generated ACTION PLAN must never have its summary, target, step
//  description, or tool name promoted into a conversational answer.
//
//  Dogfood defect: "شو ممكن تعمل" was deterministically conversational, qwen2.5:3b emitted
//  {"responseMode":"action","summary":"Calculator","steps":[ui.open_app Calculator]}, the router
//  correctly refused to execute it, but extractConversationalAnswer() returned `summary`, so the
//  user saw (and history persisted) "Calculator".
//

import Testing
import Foundation
@testable import Pace

/// Scripted local backend: returns `scriptedResponses[callIndex]` (repeating the last one once
/// exhausted), records every request, and streams each response as small chunks so streaming
/// leakage is observable.
private final class ScriptedLocalBackend: QLocalModelBackend, @unchecked Sendable {
    let capabilities = QModelCapabilities(backend: .ollama, modelIdentifier: "qwen2.5:3b")
    private let scriptedResponses: [String]
    private(set) var receivedRequests: [QModelInferenceRequest] = []

    init(scriptedResponses: [String]) {
        self.scriptedResponses = scriptedResponses
    }

    var callCount: Int { receivedRequests.count }

    func isAvailable() async -> Bool { true }

    func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse {
        let responseIndex = min(receivedRequests.count, scriptedResponses.count - 1)
        receivedRequests.append(request)
        return QModelInferenceResponse(text: scriptedResponses[responseIndex], providerUsed: .ollama)
    }

    func streamInference(
        request: QModelInferenceRequest,
        onEvent: @Sendable @escaping (QCoreStreamEvent) -> Void
    ) async throws -> QModelInferenceResponse {
        let response = try await complete(request: request)
        var remainingText = Substring(response.text)
        while !remainingText.isEmpty {
            let chunk = remainingText.prefix(7)
            onEvent(.textDelta(String(chunk)))
            remainingText = remainingText.dropFirst(chunk.count)
        }
        onEvent(.completed)
        return response
    }
}

private final class TrackingExecutionProvider: QExecutionProvider, @unchecked Sendable {
    private(set) var executedRequests: [QActionRequest] = []
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        executedRequests.append(request)
        return QActionResult(actionId: request.actionId, success: true, summary: "Executed \(request.toolName)")
    }
}

private final class StreamedTextRecorder: @unchecked Sendable {
    private(set) var streamedText = ""
    func record(_ event: QCoreStreamEvent) {
        if case .textDelta(let delta) = event {
            streamedText.append(delta)
        }
    }
}

private func makeIsolatedRouter(backend: any QLocalModelBackend) -> QModelRouter {
    let router = QModelRouter(localOnly: true)
    router.clearBackends()
    router.registerBackend(backend)
    router.setPriorityOrder([backend.capabilities.backend])
    return router
}

/// The exact action plan qwen2.5:3b emitted for "شو ممكن تعمل" in production dogfood.
private let observedCalculatorActionPlan = """
{
  "responseMode": "action",
  "directAnswer": null,
  "taskPrompt": "شو ممكن تعمل",
  "summary": "Calculator",
  "steps": [
    {
      "actionName": "ui.open_app",
      "toolFamily": "app",
      "riskLevel": "level1SafeLocalAction",
      "description": "Open Calculator app",
      "targetResources": ["Calculator"],
      "parameters": {"appName": "Calculator"}
    }
  ]
}
"""

private let actionMetadataMarkers = ["Calculator", "ui.open_app", "Open Calculator app", "taskPrompt", "responseMode", "{"]

private func containsActionMetadata(_ text: String) -> Bool {
    actionMetadataMarkers.contains { text.contains($0) }
}

private let arabicCapabilityQuestions = [
    "شو ممكن تعمل",
    "شو الوظائف اللي بتعملها",
    "شو بتقدر تعمل؟",
    "شو بتقدر تسوي؟",
    "ما الذي تستطيع فعله؟",
    "شو يعني Q-Core؟"
]

private let englishCapabilityQuestions = [
    "What can you do?",
    "What functions do you support?"
]

private let executionRequests = [
    "Open Calculator",
    "افتح الآلة الحاسبة",
    "شغل Calculator"
]

@Suite("QArabicConversationalRoutingTests")
struct QArabicConversationalRoutingTests {

    // MARK: - Parser semantics

    @Test("Observed Calculator action plan is never extracted as a conversational answer")
    func observedActionPlanIsNotAConversationalAnswer() {
        #expect(QModelRouter.extractConversationalAnswer(from: observedCalculatorActionPlan) == nil)
        #expect(QModelRouter.extractConversationalAnswer(from: "```json\n\(observedCalculatorActionPlan)\n```") == nil)
    }

    @Test("Action plan without responseMode but with steps is never extracted")
    func stepsWithoutResponseModeAreNotAnAnswer() {
        let json = """
        {"summary": "Calculator", "steps": [{"actionName": "ui.open_app", "description": "Open Calculator", "targetResources": ["Calculator"]}]}
        """
        #expect(QModelRouter.extractConversationalAnswer(from: json) == nil)
    }

    @Test("Action plan carrying a directAnswer field is still an action plan")
    func actionModeWithDirectAnswerIsNotAnAnswer() {
        let json = """
        {"responseMode": "action", "directAnswer": "Calculator", "summary": "Calculator", "steps": []}
        """
        #expect(QModelRouter.extractConversationalAnswer(from: json) == nil)
    }

    @Test("A lone summary field is planner metadata, never an answer")
    func summaryAloneIsNotAnAnswer() {
        #expect(QModelRouter.extractConversationalAnswer(from: #"{"summary": "Calculator"}"#) == nil)
        #expect(QModelRouter.extractConversationalAnswer(from: #"{"responseMode": "directAnswer", "directAnswer": null, "summary": "Calculator"}"#) == nil)
    }

    @Test("Explicit conversational answer fields and plain prose are still extracted")
    func explicitConversationalAnswerIsExtracted() {
        #expect(QModelRouter.extractConversationalAnswer(from: #"{"responseMode": "directAnswer", "directAnswer": "بقدر أساعدك بأسئلة كثيرة.", "summary": "Calculator"}"#) == "بقدر أساعدك بأسئلة كثيرة.")
        #expect(QModelRouter.extractConversationalAnswer(from: #"{"answer": "I can answer questions."}"#) == "I can answer questions.")
        #expect(QModelRouter.extractConversationalAnswer(from: #"{"response": "I can answer questions."}"#) == "I can answer questions.")
        #expect(QModelRouter.extractConversationalAnswer(from: "بقدر أجاوب على أسئلتك.") == "بقدر أجاوب على أسئلتك.")
    }

    @Test("Brace-less schema lines (observed from qwen2.5:3b) are not accepted as prose")
    func braceLessSchemaLinesAreNotProse() {
        #expect(QModelRouter.extractConversationalAnswer(from: "responseMode: directAnswer\ndirectAnswer: أهلا") == nil)
        #expect(QModelRouter.extractConversationalAnswer(from: "responseMode: action\nsummary: Calculator\nactionName: ui.open_app") == nil)
    }

    @Test("Streaming extractor never surfaces the key after a null directAnswer")
    func streamingExtractorIgnoresNullDirectAnswer() {
        var streamedPrefix = ""
        for character in observedCalculatorActionPlan {
            streamedPrefix.append(character)
            let visibleText = QModelPlanParser.extractStreamingDirectAnswer(from: streamedPrefix)
            #expect(visibleText.isEmpty, "Leaked while streaming: \(visibleText)")
        }
        // A genuine string directAnswer still streams.
        #expect(QModelPlanParser.extractStreamingDirectAnswer(from: #"{"responseMode": "directAnswer", "directAnswer":  "أهلا"#) == "أهلا")
    }

    // MARK: - Deterministic classification

    @Test("Arabic and English capability questions are deterministically conversational", arguments: arabicCapabilityQuestions + englishCapabilityQuestions)
    func capabilityQuestionsAreConversational(question: String) {
        let decision = QDeterministicDecisionEngine().decide(for: QTask(intent: question))
        #expect(decision.isConversational == true)
        #expect(!QDeterministicDecisionEngine.containsExecutionIndicators(intent: question))
    }

    @Test("Execution requests remain deterministically execution", arguments: executionRequests)
    func executionRequestsRemainExecution(request: String) {
        let decision = QDeterministicDecisionEngine().decide(for: QTask(intent: request))
        #expect(decision.isConversational == false)
        #expect(QDeterministicDecisionEngine.containsExecutionIndicators(intent: request))
    }

    // MARK: - Router recovery

    @Test("Conversational action plan triggers one bounded retry whose prose answer is returned", arguments: arabicCapabilityQuestions + englishCapabilityQuestions)
    func actionPlanRecoversThroughBoundedRetry(question: String) async throws {
        let retryProse = "بقدر أجاوب على أسئلتك وأساعدك بمهام على الماك بعد موافقتك."
        let backend = ScriptedLocalBackend(scriptedResponses: [observedCalculatorActionPlan, retryProse])
        let router = makeIsolatedRouter(backend: backend)
        let streamRecorder = StreamedTextRecorder()

        let result = try await router.generateTurnPlan(
            for: QTask(intent: question),
            streamHandler: { event in streamRecorder.record(event) }
        )

        guard case .directAnswer(let answer) = result else {
            Issue.record("Expected directAnswer, got: \(result)")
            return
        }
        #expect(answer.text == retryProse)
        #expect(answer.provenance == "untrusted:model_output")
        #expect(backend.callCount == 2)
        #expect(!containsActionMetadata(streamRecorder.streamedText), "Streamed: \(streamRecorder.streamedText)")
        #expect(streamRecorder.streamedText == retryProse)
        // The retry prompt must forbid action plans and carry the deterministic classification.
        let retrySystemPrompt = backend.receivedRequests[1].systemPrompt ?? ""
        #expect(retrySystemPrompt.contains("already determined this request is conversational"))
        #expect(retrySystemPrompt.contains("Do not output JSON, action plans, tool calls"))
    }

    @Test("First-pass prompt carries the conversational classification; execution prompt does not")
    func firstPassPromptCarriesConversationalClassification() async throws {
        let conversationalBackend = ScriptedLocalBackend(scriptedResponses: [#"{"responseMode": "directAnswer", "directAnswer": "أهلا"}"#])
        _ = try await makeIsolatedRouter(backend: conversationalBackend).generateTurnPlan(for: QTask(intent: "شو ممكن تعمل"))
        #expect(conversationalBackend.receivedRequests[0].prompt.contains("Deterministic classification: conversational"))

        let executionBackend = ScriptedLocalBackend(scriptedResponses: [observedCalculatorActionPlan])
        _ = try await makeIsolatedRouter(backend: executionBackend).generateTurnPlan(for: QTask(intent: "Open Calculator"))
        #expect(!executionBackend.receivedRequests[0].prompt.contains("Deterministic classification: conversational"))
    }

    @Test("Retry that still emits an action plan fails safe without leaking action metadata")
    func persistentActionPlanFailsSafe() async throws {
        let backend = ScriptedLocalBackend(scriptedResponses: [observedCalculatorActionPlan])
        let router = makeIsolatedRouter(backend: backend)
        let streamRecorder = StreamedTextRecorder()

        let result = try await router.generateTurnPlan(
            for: QTask(intent: "شو ممكن تعمل"),
            streamHandler: { event in streamRecorder.record(event) }
        )

        guard case .directAnswer(let answer) = result else {
            Issue.record("Expected safe directAnswer, got: \(result)")
            return
        }
        #expect(answer.provenance == "system:fallback")
        #expect(!containsActionMetadata(answer.text))
        #expect(streamRecorder.streamedText.isEmpty, "Streamed: \(streamRecorder.streamedText)")
        // Exactly one bounded retry — no loop.
        #expect(backend.callCount == 2)
    }

    @Test("directAnswer mode with null directAnswer does not surface its summary")
    func nullDirectAnswerDoesNotSurfaceSummary() async throws {
        let backend = ScriptedLocalBackend(scriptedResponses: [
            #"{"responseMode": "directAnswer", "directAnswer": null, "summary": "Calculator"}"#,
            "بقدر أساعدك."
        ])
        let result = try await makeIsolatedRouter(backend: backend).generateTurnPlan(for: QTask(intent: "شو ممكن تعمل"))
        guard case .directAnswer(let answer) = result else {
            Issue.record("Expected directAnswer, got: \(result)")
            return
        }
        #expect(answer.text == "بقدر أساعدك.")
        #expect(backend.callCount == 2)
    }

    // MARK: - Execution isolation

    @Test("Execution requests still receive the model plan (not a direct answer)", arguments: executionRequests)
    func executionRequestsStillPlan(request: String) async throws {
        let backend = ScriptedLocalBackend(scriptedResponses: [observedCalculatorActionPlan])
        let result = try await makeIsolatedRouter(backend: backend).generateTurnPlan(for: QTask(intent: request))
        guard case .plan(let plan) = result else {
            Issue.record("Expected plan for execution request, got: \(result)")
            return
        }
        #expect(plan.steps.first?.action.actionName == "ui.open_app")
        #expect(backend.callCount == 1)
    }

    @Test("Model action plan cannot execute during a conversational turn")
    func actionPlanCannotExecuteDuringConversationalTurn() async throws {
        let backend = ScriptedLocalBackend(scriptedResponses: [observedCalculatorActionPlan])
        let executionProvider = TrackingExecutionProvider()
        let runtime = QCoreRuntime(
            modelProvider: makeIsolatedRouter(backend: backend),
            executionProvider: executionProvider,
            endpointName: "test-47h-noexec-\(UUID().uuidString)"
        )
        let result = try await QAgent(coreRuntime: runtime).run(task: "شو ممكن تعمل")

        #expect(executionProvider.executedRequests.isEmpty)
        guard case .directAnswer(let answerText) = result.status else {
            Issue.record("Expected directAnswer status, got: \(result.status)")
            return
        }
        #expect(!containsActionMetadata(answerText))
        #expect(!containsActionMetadata(result.summary))
    }

    // MARK: - History contamination

    @Test("Observed three-turn sequence never answers or persists Calculator")
    func observedSequenceDoesNotContaminateHistory() async throws {
        let turn2Answer = "بقدر أجاوب على أسئلتك وأساعدك بمهام بسيطة على الماك."
        let turn3Answer = "بقدر أشرح أشياء، أجاوب أسئلة، وأفتح تطبيقات بعد موافقتك."
        let backend = ScriptedLocalBackend(scriptedResponses: [
            #"{"responseMode": "directAnswer", "directAnswer": "أهلا! كيف بقدر أساعدك؟"}"#,
            observedCalculatorActionPlan,
            turn2Answer,
            observedCalculatorActionPlan,
            turn3Answer
        ])
        let executionProvider = TrackingExecutionProvider()
        let runtime = QCoreRuntime(
            modelProvider: makeIsolatedRouter(backend: backend),
            executionProvider: executionProvider,
            endpointName: "test-47h-history-\(UUID().uuidString)"
        )
        let agent = QAgent(coreRuntime: runtime)

        // Mirrors CompanionManager: the persisted assistant turn is the directAnswer status text.
        var conversationHistory: [QConversationTurnSnippet] = []
        func runTurn(_ transcript: String) async throws -> String {
            let turnContext = QAgentTurnContext(
                turnId: "turn-47h-\(UUID().uuidString)",
                transcript: transcript,
                conversationHistory: conversationHistory
            )
            #expect(QDeterministicDecisionEngine().decide(for: QTask(intent: transcript)).isConversational)
            let result = try await agent.run(task: transcript, turnContext: turnContext)
            guard case .directAnswer(let answerText) = result.status else {
                Issue.record("Expected directAnswer for \(transcript), got: \(result.status)")
                return ""
            }
            conversationHistory.append(QConversationTurnSnippet(userTranscript: transcript, assistantResponse: answerText))
            return answerText
        }

        _ = try await runTurn("مرحبا")
        let turn2Result = try await runTurn("شو ممكن تعمل")
        let turn3Result = try await runTurn("شو الوظائف اللي بتعملها")

        #expect(turn2Result == turn2Answer)
        #expect(turn3Result == turn3Answer)
        #expect(!conversationHistory.contains { $0.assistantResponse.contains("Calculator") })
        #expect(executionProvider.executedRequests.isEmpty)

        // Turn 3's prompt carries the genuine turn-2 answer, still labelled as untrusted history.
        let turn3PlanningPrompt = backend.receivedRequests[3].prompt
        #expect(turn3PlanningPrompt.contains("Previous Assistant (untrusted reference only): \(turn2Answer)"))
        #expect(!turn3PlanningPrompt.contains("Calculator"))
    }

    @Test("Adversarial previous assistant 'Calculator' cannot cause tool selection")
    func previousAssistantCalculatorCannotSelectTool() async throws {
        var contaminatedContext = QTaskContext(taskId: "task-47h-adversarial")
        contaminatedContext.append(content: "Calculator", provenance: .untrustedTool(toolName: "assistant_history"))
        let contaminatedTask = QTask(intent: "شو ممكن تعمل", context: contaminatedContext)
        #expect(QDeterministicDecisionEngine().decide(for: contaminatedTask).isConversational == true)

        // Even if the model follows the contaminated history and emits the plan every time,
        // nothing executes and nothing action-shaped reaches the user.
        let backend = ScriptedLocalBackend(scriptedResponses: [observedCalculatorActionPlan])
        let executionProvider = TrackingExecutionProvider()
        let runtime = QCoreRuntime(
            modelProvider: makeIsolatedRouter(backend: backend),
            executionProvider: executionProvider,
            endpointName: "test-47h-adversarial-\(UUID().uuidString)"
        )
        let turnContext = QAgentTurnContext(
            turnId: "turn-47h-adv-\(UUID().uuidString)",
            transcript: "شو ممكن تعمل",
            conversationHistory: [QConversationTurnSnippet(userTranscript: "شو ممكن تعمل", assistantResponse: "Calculator")]
        )
        let result = try await QAgent(coreRuntime: runtime).run(task: "شو ممكن تعمل", turnContext: turnContext)

        #expect(executionProvider.executedRequests.isEmpty)
        guard case .directAnswer(let answerText) = result.status else {
            Issue.record("Expected directAnswer status, got: \(result.status)")
            return
        }
        #expect(!containsActionMetadata(answerText))
        // Historical assistant text stays labelled untrusted in the prompt.
        #expect(backend.receivedRequests[0].prompt.contains("Previous Assistant (untrusted reference only): Calculator"))
    }

    // MARK: - Real Ollama (qwen2.5:3b on 127.0.0.1:11434)

    @Test("Real Ollama: capability questions receive genuine conversational answers")
    func realOllamaCapabilityQuestions() async throws {
        let ollamaBackend = QLocalhostHTTPBackend(
            capabilities: QModelCapabilities(backend: .ollama, modelIdentifier: "qwen2.5:3b", isLocalOnDevice: true),
            baseURL: URL(string: "http://127.0.0.1:11434")!
        )
        guard await ollamaBackend.isAvailable() else {
            print("ℹ️ Skipping real Ollama 4.7H validation: Ollama not reachable on 127.0.0.1:11434")
            return
        }
        let router = makeIsolatedRouter(backend: ollamaBackend)
        let executionProvider = TrackingExecutionProvider()
        let runtime = QCoreRuntime(
            modelProvider: router,
            executionProvider: executionProvider,
            endpointName: "test-47h-real-\(UUID().uuidString)"
        )
        let agent = QAgent(coreRuntime: runtime)

        let realQuestions = [
            "شو ممكن تعمل",
            "شو الوظائف اللي بتعملها",
            "شو بتقدر تعمل؟",
            "ما الذي تستطيع فعله؟",
            "What can you do?"
        ]
        var conversationHistory: [QConversationTurnSnippet] = []
        for question in realQuestions {
            let streamRecorder = StreamedTextRecorder()
            let turnContext = QAgentTurnContext(
                turnId: "turn-47h-real-\(UUID().uuidString)",
                transcript: question,
                conversationHistory: conversationHistory
            )
            let result = try await agent.run(
                task: question,
                turnContext: turnContext,
                streamHandler: { event in streamRecorder.record(event) }
            )
            guard case .directAnswer(let answerText) = result.status else {
                Issue.record("\(question): expected directAnswer, got \(result.status)")
                continue
            }
            print("🧪 4.7H REAL [\(question)] lang=\(PaceSpeechVoiceResolver.detectLanguage(for: answerText) ?? "nil") answer=\(answerText)")
            #expect(!containsActionMetadata(answerText), "\(question): \(answerText)")
            #expect(!containsActionMetadata(streamRecorder.streamedText), "\(question) streamed: \(streamRecorder.streamedText)")
            // A legitimate answer, not the safe fallback.
            #expect(answerText != "I am unable to answer this question right now.", "\(question) fell back")
            #expect(answerText.count > 15, "\(question): \(answerText)")
            conversationHistory.append(QConversationTurnSnippet(userTranscript: question, assistantResponse: answerText))
        }
        #expect(executionProvider.executedRequests.isEmpty)

        // Execution isolation against the real model: still planned, never a direct answer.
        let executionResult = try await router.generateTurnPlan(for: QTask(intent: "افتح Calculator"))
        print("🧪 4.7H REAL [افتح Calculator] result=\(executionResult)")
        if case .directAnswer = executionResult {
            Issue.record("Execution request became a direct answer")
        }
    }
}
