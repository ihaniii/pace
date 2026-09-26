//
//  QArabicGoldenSetTests.swift
//  leanring-buddyTests
//
//  Phase 0 (Arabic/Palestinian quality): runs `QArabicGoldenSet` against CURRENT production
//  behaviour. Cases with a documented `knownGap` run inside `withKnownIssue`: they pass while
//  the gap exists and fail as soon as it is fixed, forcing the golden entry to be updated in
//  the same change that fixes it.
//

import Testing
import Foundation
@testable import Pace

/// Returns the scripted plan JSON on every call so app-name resolution can be observed
/// through the real parser/validator.
private final class GoldenScriptedPlannerBackend: QLocalModelBackend, @unchecked Sendable {
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

private final class GoldenExecutionRecorder: QExecutionProvider, @unchecked Sendable {
    private(set) var executedRequests: [QActionRequest] = []
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        executedRequests.append(request)
        return QActionResult(actionId: request.actionId, success: true, summary: "Executed \(request.toolName)")
    }
}

/// Runs `expectations` normally, or inside `withKnownIssue` when the case documents a gap.
private func expectGoldenBehaviour(
    knownGap: QArabicGoldenKnownGap?,
    _ expectations: () -> Void
) {
    if let knownGap {
        let scheduleDescription = knownGap.expectedToCloseInPhase.map { "phase \($0)" } ?? "unscheduled"
        withKnownIssue("Known gap (\(scheduleDescription)): \(knownGap.reason)") {
            expectations()
        }
    } else {
        expectations()
    }
}

@Suite("QArabicGoldenSetTests")
struct QArabicGoldenSetTests {

    // MARK: - Golden-set integrity

    @Test("Golden identifiers are unique and every known gap targets phases 1–4")
    func goldenSetIsWellFormed() {
        let identifiers = QArabicGoldenSet.utteranceCases.map(\.identifier)
            + QArabicGoldenSet.appNameCases.map(\.identifier)
            + QArabicGoldenSet.speechRouteCases.map(\.identifier)
            + QArabicGoldenSet.recordedAnswers.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)

        let knownGaps = QArabicGoldenSet.utteranceCases.compactMap(\.knownGap)
            + QArabicGoldenSet.appNameCases.compactMap(\.knownGap)
            + QArabicGoldenSet.speechRouteCases.compactMap(\.knownGap)
        for knownGap in knownGaps {
            if let expectedToCloseInPhase = knownGap.expectedToCloseInPhase {
                #expect((1...4).contains(expectedToCloseInPhase))
            }
        }
    }

    @Test("Every capability variant is present in both dialect and MSA/English forms")
    func capabilityVariantsCoverDialects() {
        let capabilityUtterances = QArabicGoldenSet.utteranceCases
            .filter { $0.semanticGroup == .capabilityQuestion }
            .map(\.utterance)
        for requiredVariant in ["شو ممكن تعمل؟", "شو فيك تعمل؟", "شو بتقدر تعمل؟", "شو بتعرف تعمل؟", "إيش ممكن تعمل؟", "شو الوظائف اللي بتعملها؟", "ما الذي تستطيع فعله؟", "What can you do?"] {
            #expect(capabilityUtterances.contains(requiredVariant), "Missing capability variant \(requiredVariant)")
        }
    }

    // MARK: - Deterministic routing

    /// Mirrors the authoritative routing in `QModelRouter.generateTurnPlan`.
    static func observedRouting(for task: QTask) -> QArabicGoldenRouting {
        let decision = QDeterministicDecisionEngine().decide(for: task)
        let hasExecutionIntent = QDeterministicDecisionEngine.containsExecutionIndicators(intent: task.intent)
        if !hasExecutionIntent && decision.isConversational {
            return .conversational
        }
        return decision.taskType == .criticalHighRisk ? .criticalHighRisk : .execution
    }

    @Test("Deterministic routing matches the golden expectation", arguments: QArabicGoldenSet.utteranceCases)
    func deterministicRoutingMatchesGolden(goldenCase: QArabicGoldenUtteranceCase) {
        let observedRouting = Self.observedRouting(for: QTask(intent: goldenCase.utterance))
        expectGoldenBehaviour(knownGap: goldenCase.knownGap) {
            #expect(observedRouting == goldenCase.expectedRouting)
        }
    }

    @Test(
        "Adversarial previous assistant text never changes routing",
        arguments: QArabicGoldenSet.utteranceCases.filter { $0.semanticGroup == .capabilityQuestion },
        QArabicGoldenSet.adversarialPreviousAssistantResponses
    )
    func adversarialHistoryDoesNotChangeRouting(goldenCase: QArabicGoldenUtteranceCase, previousAssistantResponse: String) {
        var contaminatedContext = QTaskContext(taskId: "golden-\(goldenCase.identifier)")
        contaminatedContext.append(content: previousAssistantResponse, provenance: .untrustedTool(toolName: "assistant_history"))
        let contaminatedTask = QTask(intent: goldenCase.utterance, context: contaminatedContext)

        #expect(Self.observedRouting(for: contaminatedTask) == Self.observedRouting(for: QTask(intent: goldenCase.utterance)))
    }

    // MARK: - Arabic app-name resolution

    @Test("Planner ui.open_app steps resolve to the real app name", arguments: QArabicGoldenSet.appNameCases)
    func appNameResolution(appNameCase: QArabicGoldenSet.AppNameCase) async throws {
        let router = QModelRouter(localOnly: true)
        router.clearBackends()
        router.registerBackend(GoldenScriptedPlannerBackend(
            scriptedResponse: #"{"responseMode": "action", "summary": "Open app", "steps": [\#(appNameCase.scriptedStepJSON)]}"#
        ))
        router.setPriorityOrder([.ollama])

        let result = try await router.generateTurnPlan(for: QTask(intent: appNameCase.utterance))
        guard case .plan(let plan) = result else {
            Issue.record("Expected a plan for \(appNameCase.utterance), got \(result)")
            return
        }
        let resolvedAppName = plan.steps.first?.action.arguments["appName"]
        expectGoldenBehaviour(knownGap: appNameCase.knownGap) {
            #expect(resolvedAppName == appNameCase.expectedAppName)
        }
    }

    // MARK: - TTS routing

    /// Mirrors how `CompanionManager+QAgent.executeQAgentTurn` derives the TTS turn locale from
    /// the USER transcript today. Phase 1 is expected to replace this with answer-based routing
    /// in a testable production function; update this helper then.
    @MainActor
    static func turnLocaleAsCompanionManagerComputesIt(fromTranscript transcript: String) -> String {
        PaceSpeechVoiceResolver.detectLanguage(for: transcript).flatMap { rawLanguage -> String? in
            let baseLanguage = rawLanguage.replacingOccurrences(of: "_", with: "-").lowercased()
                .split(separator: "-").first.map(String.init) ?? rawLanguage
            switch baseLanguage {
            case "en": return "en-US"
            case "sv": return "sv-SE"
            case "ar": return "ar"
            default: return rawLanguage
            }
        } ?? "en-US"
    }

    @Test("Spoken answers are routed to the voice matching the answer's language", arguments: QArabicGoldenSet.speechRouteCases)
    @MainActor
    func speechRouteMatchesAnswerLanguage(speechRouteCase: QArabicGoldenSet.SpeechRouteCase) {
        let turnLocale = Self.turnLocaleAsCompanionManagerComputesIt(fromTranscript: speechRouteCase.userTranscript)
        let observedRoute = PaceNeuralTTSClient.determineRoute(for: speechRouteCase.assistantAnswer, explicitLocale: turnLocale)
        expectGoldenBehaviour(knownGap: speechRouteCase.knownGap) {
            #expect(observedRoute == speechRouteCase.expectedRoute)
        }
    }

    // MARK: - Checker calibration

    @Test("Quality checkers agree with the native-review verdicts on recorded answers", arguments: QArabicGoldenSet.recordedAnswers)
    func checkersMatchRecordedVerdicts(recordedAnswer: QArabicGoldenSet.RecordedAnswer) {
        let hasContamination = QArabicAnswerQualityChecks.hasMixedScriptContamination(answer: recordedAnswer.answer, userQuestion: "")
        #expect(hasContamination == recordedAnswer.containsForeignScript)

        let registerProfile = QArabicAnswerQualityChecks.registerProfile(of: recordedAnswer.answer)
        #expect(
            registerProfile.dominantRegister == recordedAnswer.dominantRegister,
            "lev=\(registerProfile.levantineMarkerCount) msa=\(registerProfile.modernStandardMarkerCount) egy=\(registerProfile.egyptianMarkerCount)"
        )

        let ungroundedClaims = QArabicAnswerQualityChecks.ungroundedCapabilityClaims(in: recordedAnswer.answer)
        #expect(ungroundedClaims.isEmpty == !recordedAnswer.makesUngroundedCapabilityClaim, "claims: \(ungroundedClaims)")
        #expect(!QArabicAnswerQualityChecks.leaksActionMetadata(recordedAnswer.answer))
    }

    @Test("Script checker tolerates allow-listed and user-quoted Latin words")
    func scriptCheckerAllowsLegitimateLatin() {
        #expect(!QArabicAnswerQualityChecks.hasMixedScriptContamination(answer: "بفتحلك Calculator هلق.", userQuestion: "افتح Calculator"))
        #expect(!QArabicAnswerQualityChecks.hasMixedScriptContamination(answer: "الـ storage أبطأ من الـ RAM.", userQuestion: "شو الفرق بين RAM و storage؟"))
        #expect(QArabicAnswerQualityChecks.hasMixedScriptContamination(answer: "بقدر أساعدك بـ Smarty.", userQuestion: "شو ممكن تعمل؟"))
    }

    @Test("Capability-answer checkers catch denial, invention and misunderstanding (recorded qwen2.5:3b answers)")
    func capabilityAnswerCheckersCatchRecordedFailures() {
        let falseDenial = "أنا أستطيع مساعدةك في الإجابة على الأسئلة. ولكنني لا أستطيع فتح التطبيقات أو تشغيل البرامج أو الوصول إلى الملفات."
        #expect(QArabicAnswerQualityChecks.deniesRealCapability(falseDenial))

        let inventedNews = "يمكنني الإجابة على أسئلتك، تقديم معلومات، وإخبارك بأحدث الأخبار، وغيرها من المهام البسيطة."
        #expect(!QArabicAnswerQualityChecks.ungroundedCapabilityClaims(in: inventedNews).isEmpty)
        #expect(!QArabicAnswerQualityChecks.mentionsRealCapability(inventedNews))

        let inventedCommands = "I can help you with various tasks such as opening applications, managing files, running system commands, and more."
        #expect(!QArabicAnswerQualityChecks.ungroundedCapabilityClaims(in: inventedCommands).isEmpty)

        let misunderstoodAsHowAreYou = "أنا أعمل بشكل جيد، شكراً! كيف يمكنني مساعدتك اليوم؟"
        #expect(!QArabicAnswerQualityChecks.mentionsRealCapability(misunderstoodAsHowAreYou))

        let groundedPalestinian = "بفتح تطبيقات، بقرأ النص عالشاشة، بقرأ الحافظة، وبجاوب أسئلة. كل إشي بيغير الجهاز بيحتاج موافقتك."
        #expect(QArabicAnswerQualityChecks.mentionsRealCapability(groundedPalestinian))
        #expect(!QArabicAnswerQualityChecks.deniesRealCapability(groundedPalestinian))
        #expect(QArabicAnswerQualityChecks.ungroundedCapabilityClaims(in: groundedPalestinian).isEmpty)
    }

    // MARK: - Real local model baseline (qwen2.5:3b, existing model only)

    /// Quality expectations are recorded as intermittent known issues: they document the current
    /// baseline without gating the suite. Safety invariants are hard expectations.
    @Test("Real qwen2.5:3b baseline over the conversational golden set")
    func realModelConversationalBaseline() async throws {
        let ollamaBackend = QLocalhostHTTPBackend(
            capabilities: QModelCapabilities(backend: .ollama, modelIdentifier: "qwen2.5:3b", isLocalOnDevice: true),
            baseURL: URL(string: "http://127.0.0.1:11434")!
        )
        guard await ollamaBackend.isAvailable() else {
            print("ℹ️ Skipping Arabic golden baseline: Ollama not reachable on 127.0.0.1:11434")
            return
        }
        let router = QModelRouter(localOnly: true)
        router.clearBackends()
        router.registerBackend(ollamaBackend)
        router.setPriorityOrder([.ollama])
        let executionRecorder = GoldenExecutionRecorder()
        let agent = QAgent(coreRuntime: QCoreRuntime(
            modelProvider: router,
            executionProvider: executionRecorder,
            endpointName: "arabic-golden-baseline-\(UUID().uuidString)"
        ))

        let conversationalGroups: Set<QArabicGoldenSemanticGroup> = [.capabilityQuestion, .identityQuestion, .greeting, .openQuestion]
        let conversationalCases = QArabicGoldenSet.utteranceCases.filter {
            conversationalGroups.contains($0.semanticGroup) && $0.knownGap == nil
        }

        var arabicQuestionCount = 0
        var arabicAnswerCount = 0
        var cleanArabicAnswerCount = 0
        var levantineCount = 0
        var capabilityQuestionCount = 0
        var legitimateCapabilityAnswerCount = 0

        for goldenCase in conversationalCases {
            let result = try await agent.run(task: goldenCase.utterance)
            guard case .directAnswer(let answer) = result.status else {
                Issue.record("\(goldenCase.identifier): expected directAnswer, got \(result.status)")
                continue
            }
            #expect(!QArabicAnswerQualityChecks.leaksActionMetadata(answer), "\(goldenCase.identifier): \(answer)")

            let questionIsArabic = QArabicAnswerQualityChecks.isArabicDominant(goldenCase.utterance)
            let answerIsArabic = QArabicAnswerQualityChecks.isArabicDominant(answer)
            let isCleanScript = !QArabicAnswerQualityChecks.hasMixedScriptContamination(answer: answer, userQuestion: goldenCase.utterance)
            let registerProfile = QArabicAnswerQualityChecks.registerProfile(of: answer)
            let ungroundedClaims = QArabicAnswerQualityChecks.ungroundedCapabilityClaims(in: answer)

            if questionIsArabic {
                arabicQuestionCount += 1
                if answerIsArabic { arabicAnswerCount += 1 }
                if registerProfile.dominantRegister == .levantine { levantineCount += 1 }
                withKnownIssue("Baseline: qwen2.5:3b answer quality", isIntermittent: true) {
                    #expect(answerIsArabic, "\(goldenCase.identifier) answered in another language")
                    #expect(isCleanScript, "\(goldenCase.identifier) mixed script")
                    #expect(registerProfile.dominantRegister == .levantine, "\(goldenCase.identifier) register \(registerProfile.dominantRegister)")
                }
            }
            // Script purity is only meaningful for answers that are Arabic.
            if answerIsArabic && isCleanScript { cleanArabicAnswerCount += 1 }
            var isLegitimateCapabilityAnswer = true
            if goldenCase.semanticGroup == .capabilityQuestion {
                capabilityQuestionCount += 1
                let mentionsRealCapability = QArabicAnswerQualityChecks.mentionsRealCapability(answer)
                let deniesRealCapability = QArabicAnswerQualityChecks.deniesRealCapability(answer)
                isLegitimateCapabilityAnswer = mentionsRealCapability && !deniesRealCapability && ungroundedClaims.isEmpty
                if isLegitimateCapabilityAnswer { legitimateCapabilityAnswerCount += 1 }
                withKnownIssue("Baseline: capability answers are not grounded in real capabilities", isIntermittent: true) {
                    #expect(isLegitimateCapabilityAnswer, "\(goldenCase.identifier) real=\(mentionsRealCapability) denies=\(deniesRealCapability) invented=\(ungroundedClaims)")
                }
            }
            print("🧪 ARGOLD \(goldenCase.identifier) ar=\(answerIsArabic) clean=\(isCleanScript) register=\(registerProfile.dominantRegister.rawValue)(lev \(registerProfile.levantineMarkerCount)/msa \(registerProfile.modernStandardMarkerCount)/egy \(registerProfile.egyptianMarkerCount)) legitCapability=\(isLegitimateCapabilityAnswer) invented=\(ungroundedClaims) «\(goldenCase.utterance)» → \(answer.replacingOccurrences(of: "\n", with: " "))")
        }

        #expect(executionRecorder.executedRequests.isEmpty)
        print("🧪 ARGOLD SUMMARY cases=\(conversationalCases.count) arabicAnswersToArabicQuestions=\(arabicAnswerCount)/\(arabicQuestionCount) cleanScriptArabicAnswers=\(cleanArabicAnswerCount)/\(arabicAnswerCount) levantine=\(levantineCount)/\(arabicQuestionCount) legitimateCapabilityAnswers=\(legitimateCapabilityAnswerCount)/\(capabilityQuestionCount)")
    }

    @Test("Real qwen2.5:3b baseline: consecutive answers are not copied from history")
    func realModelHistoryEchoBaseline() async throws {
        let ollamaBackend = QLocalhostHTTPBackend(
            capabilities: QModelCapabilities(backend: .ollama, modelIdentifier: "qwen2.5:3b", isLocalOnDevice: true),
            baseURL: URL(string: "http://127.0.0.1:11434")!
        )
        guard await ollamaBackend.isAvailable() else {
            print("ℹ️ Skipping history-echo baseline: Ollama not reachable on 127.0.0.1:11434")
            return
        }
        let router = QModelRouter(localOnly: true)
        router.clearBackends()
        router.registerBackend(ollamaBackend)
        router.setPriorityOrder([.ollama])
        let agent = QAgent(coreRuntime: QCoreRuntime(
            modelProvider: router,
            executionProvider: GoldenExecutionRecorder(),
            endpointName: "arabic-golden-echo-\(UUID().uuidString)"
        ))

        var conversationHistory: [QConversationTurnSnippet] = []
        var previousAnswer: String?
        var echoedTurnCount = 0
        for transcript in ["مرحبا", "شو ممكن تعمل؟", "شو الوظائف اللي بتعملها؟", "ليش السما زرقا؟"] {
            let result = try await agent.run(
                task: transcript,
                turnContext: QAgentTurnContext(
                    turnId: "golden-echo-\(UUID().uuidString)",
                    transcript: transcript,
                    conversationHistory: conversationHistory
                )
            )
            guard case .directAnswer(let answer) = result.status else {
                Issue.record("\(transcript): expected directAnswer, got \(result.status)")
                continue
            }
            let isEcho = previousAnswer.map { answer.contains($0) } ?? false
            if isEcho { echoedTurnCount += 1 }
            withKnownIssue("Baseline: qwen2.5:3b copies the previous assistant answer", isIntermittent: true) {
                #expect(!isEcho, "«\(transcript)» repeated the previous answer")
            }
            print("🧪 ARGOLD-ECHO echo=\(isEcho) «\(transcript)» → \(answer.replacingOccurrences(of: "\n", with: " "))")
            conversationHistory.append(QConversationTurnSnippet(userTranscript: transcript, assistantResponse: answer))
            previousAnswer = answer
        }
        print("🧪 ARGOLD-ECHO SUMMARY echoedTurns=\(echoedTurnCount)/3")
    }
}
