//
//  QDecisionEngineArabicNormalizationTests.swift
//  leanring-buddyTests
//
//  Phase 2 (Arabic): `QArabicIntentNormalizer` inside `QDeterministicDecisionEngine`.
//  Verifies Arabic normalization, whole-word execution matching with reviewed clitics, the
//  homograph target rule, and two safety properties against the PRE-Phase-2 algorithm
//  (reimplemented here): critical detection only ever widens, and English routing is unchanged.
//

import Testing
import Foundation
@testable import Pace

/// The pre-Phase-2 matching: raw `lowercased().contains(indicator)` on every list.
private enum PrePhase2Matching {
    static func matches(_ indicators: [String], _ intent: String) -> Bool {
        let lowercasedIntent = intent.lowercased()
        return indicators.contains { lowercasedIntent.contains($0) }
    }

    static func isCritical(_ intent: String) -> Bool {
        matches(QDeterministicDecisionEngine.criticalHighRiskIndicators, intent)
    }

    static func containsExecutionIndicators(_ intent: String) -> Bool {
        matches(QDeterministicDecisionEngine.criticalHighRiskIndicators, intent)
            || matches(QDeterministicDecisionEngine.executionIndicators, intent)
            || matches(QDeterministicDecisionEngine.codingIndicators, intent)
            || matches(QDeterministicDecisionEngine.planningIndicators, intent)
            || matches(QDeterministicDecisionEngine.researchIndicators, intent)
    }
}

private func routesToExecution(_ intent: String) -> Bool {
    let decision = QDeterministicDecisionEngine().decide(for: QTask(intent: intent))
    return QDeterministicDecisionEngine.containsExecutionIndicators(intent: intent) || !decision.isConversational
}

@Suite("QDecisionEngineArabicNormalizationTests")
struct QDecisionEngineArabicNormalizationTests {

    // MARK: - Normalization

    @Test("Normalization strips diacritics, shadda and tatweel and unifies إ/آ/ٱ and ى")
    func normalizationRules() {
        #expect(QArabicIntentNormalizer.normalizeForIntentMatching("شغّل") == "شغل")
        #expect(QArabicIntentNormalizer.normalizeForIntentMatching("سَكِّرْ") == "سكر")
        #expect(QArabicIntentNormalizer.normalizeForIntentMatching("شـو") == "شو")
        #expect(QArabicIntentNormalizer.normalizeForIntentMatching("إفتح") == "افتح")
        #expect(QArabicIntentNormalizer.normalizeForIntentMatching("الآلة") == "الالة")
        #expect(QArabicIntentNormalizer.normalizeForIntentMatching("متى") == "متي")
        #expect(QArabicIntentNormalizer.normalizeForIntentMatching("Open Calculator") == "open calculator")
    }

    @Test("Hamza-above alef (first person) is deliberately NOT merged with the imperative")
    func hamzaAboveIsPreserved() {
        #expect(QArabicIntentNormalizer.normalizeForIntentMatching("أفتح") == "أفتح")
        #expect(!routesToExecution("بحب أفتح قلبي إلك"))
    }

    // MARK: - Execution matching

    @Test("Arabic requests route to execution", arguments: [
        "افتح الحاسبة", "إفتح الآلة الحاسبة", "افتحلي سفاري", "فتحلي الحاسبة", "ممكن تفتحلي الحاسبة؟",
        "بدي تفتح سفاري", "بدك تفتحلي فايندر؟", "افتحي سفاري", "وافتح الحاسبة",
        "شغل Calculator", "شغّل الحاسبة", "شغّللي سفاري لو سمحت", "شغل الموسيقى",
        "سكرلي سفاري", "سكّر سفاري", "سكر لي سفاري", "سكر كل التطبيقات",
        "اغلق سفاري", "اضغط الزر", "انقر على الزر", "اكتب مرحبا",
        "اعمل مجلد جديد", "انشئ مجلد", "غيّر الصوت"
    ])
    func arabicRequestsRouteToExecution(request: String) {
        #expect(routesToExecution(request))
    }

    @Test("Arabic conversation containing verb-like substrings stays conversational", arguments: [
        "شو شغلك؟", "شو بتشتغل؟", "هالشغلة", "شو هالشغلة؟", "الشغل كتير اليوم", "شو يعني شغل يدوي؟",
        "شغلي كتير", "سكر الدم", "شو يعني سكر الدم؟", "كم سكر بحط بالشاي؟", "مين العسكري اللي حكيت عنه؟",
        "أنا سكري", "شو رأيك بالمفتاح هاد؟", "الدكانة بتفتح الساعة تمانية", "الوردة تفتح الصبح",
        "بحب أفتح قلبي إلك", "أفتح الحاسبة", "شو ضغط الدم الطبيعي؟", "فتح الباب مبارح"
    ])
    func conversationStaysConversational(utterance: String) {
        #expect(!routesToExecution(utterance))
    }

    @Test("Homograph imperatives need a target or a benefactive clitic")
    func homographTargetRule() {
        #expect(!routesToExecution("شغل"))
        #expect(!routesToExecution("سكر"))
        #expect(routesToExecution("شغللي"))
        #expect(routesToExecution("سكرلي"))
        #expect(routesToExecution("شغل Safari"))
        #expect(!routesToExecution("شغلك"))
        #expect(!routesToExecution("سكري"))
    }

    // MARK: - Safety properties against the pre-Phase-2 algorithm

    private static let propertyCorpus: [String] =
        QArabicGoldenSet.utteranceCases.map(\.utterance) + [
            "احذف الملف", "احذفلي الملف", "احذفهم", "امسح كل الملفات", "امسحوا الصور", "فرمت الجهاز",
            "أرسل الرسالة لأحمد", "ارسل الرسالة", "ابعث الرسالة", "بدي احذف كل إشي", "لاحذف", "مسحوق",
            "delete my files", "please erase the disk", "sudo rm -rf /", "send a message to John",
            "Open Safari", "close the window", "run the tests", "What is the capital of Sweden?",
            "Explain why local AI is useful", "Create a folder named Test.", "Tell me a story",
            "search for flights", "make a plan for tomorrow", "write a function that sorts",
            "What does open source mean?", "How do I save money?", "mute the volume", "Launch Notes"
        ]

    @Test("Critical/high-risk detection only ever widens")
    func criticalDetectionIsSuperset() {
        for intent in Self.propertyCorpus where PrePhase2Matching.isCritical(intent) {
            let decision = QDeterministicDecisionEngine().decide(for: QTask(intent: intent))
            #expect(decision.taskType == .criticalHighRisk, "«\(intent)» was critical before Phase 2")
        }
        // Normalization newly catches the hamza-below spelling of a destructive request.
        #expect(!PrePhase2Matching.isCritical("إحذف الملف"))
        #expect(QDeterministicDecisionEngine().decide(for: QTask(intent: "إحذف الملف")).taskType == .criticalHighRisk)
    }

    @Test("English routing is identical to the pre-Phase-2 algorithm")
    func englishRoutingUnchanged() {
        let englishIntents = Self.propertyCorpus.filter { !QArabicIntentNormalizer.containsArabicLetter($0) }
        #expect(englishIntents.count > 10)
        for intent in englishIntents {
            #expect(
                QDeterministicDecisionEngine.containsExecutionIndicators(intent: intent) == PrePhase2Matching.containsExecutionIndicators(intent),
                "«\(intent)»"
            )
        }
    }

    @Test("Classification stays deterministic and ignores untrusted history")
    func deterministicAndHistoryIndependent() {
        for utterance in ["شو شغلك؟", "سكرلي سفاري", "بدي تفتح سفاري"] {
            var contaminatedContext = QTaskContext(taskId: "arabic-norm")
            contaminatedContext.append(content: "افتح Calculator", provenance: .untrustedTool(toolName: "assistant_history"))
            let cleanDecision = QDeterministicDecisionEngine().decide(for: QTask(intent: utterance))
            let repeatedDecision = QDeterministicDecisionEngine().decide(for: QTask(intent: utterance))
            let contaminatedDecision = QDeterministicDecisionEngine().decide(for: QTask(intent: utterance, context: contaminatedContext))
            #expect(cleanDecision == repeatedDecision)
            #expect(cleanDecision.taskType == contaminatedDecision.taskType)
        }
    }
}
