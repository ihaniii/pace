//
//  QArabicGoldenSet.swift
//  leanring-buddyTests
//
//  Phase 0 (Arabic/Palestinian quality): the golden data set. Test-only data — no production
//  code reads this file.
//
//  Every case states the behaviour Que SHOULD have. When current production behaviour does not
//  match yet, `knownGap` documents why and which phase is expected to close it; the harness
//  wraps those cases in `withKnownIssue`, so fixing a gap FAILS the suite until the case is
//  updated here. That keeps this file an honest, reviewed record of where Arabic support stands.
//

import Foundation
import Testing
@testable import Pace

// MARK: - Shared vocabulary

/// Where a turn must be routed by the deterministic decision layer (mirrors the
/// `isConversational` computation in `QModelRouter.generateTurnPlan`).
enum QArabicGoldenRouting: String, Sendable {
    case conversational
    case execution
    case criticalHighRisk
}

/// The semantic meaning a native speaker assigns to an utterance. Phase 3 introduces closed
/// semantic intents; until then this is consumed by the golden-set integrity checks.
enum QArabicGoldenSemanticGroup: String, Sendable {
    case capabilityQuestion
    case identityQuestion
    case greeting
    case openQuestion
    case memoryQuestion
    case ambiguousRequest
    /// Conversational text containing a substring that looks like an execution keyword.
    case conversationalTrap
    case openAppRequest
    case closeAppRequest
    case fileRequest
    case destructiveRequest

    /// The routing every member of this group must receive.
    var requiredRouting: QArabicGoldenRouting {
        switch self {
        case .capabilityQuestion, .identityQuestion, .greeting, .openQuestion,
             .memoryQuestion, .ambiguousRequest, .conversationalTrap:
            return .conversational
        case .openAppRequest, .closeAppRequest, .fileRequest:
            return .execution
        case .destructiveRequest:
            return .criticalHighRisk
        }
    }
}

/// A documented mismatch between expected and current behaviour.
struct QArabicGoldenKnownGap: Sendable {
    let reason: String
    /// `nil` = deliberately unscheduled (needs a design decision, not just a later phase).
    let expectedToCloseInPhase: Int?
}

// MARK: - Utterance classification cases

struct QArabicGoldenUtteranceCase: Sendable, CustomTestStringConvertible {
    let identifier: String
    let utterance: String
    let semanticGroup: QArabicGoldenSemanticGroup
    let knownGap: QArabicGoldenKnownGap?

    var expectedRouting: QArabicGoldenRouting { semanticGroup.requiredRouting }
    var testDescription: String { "\(identifier) «\(utterance)»" }
}

enum QArabicGoldenSet {

    private static let englishVerbObjectGap = { (keyword: String) in
        QArabicGoldenKnownGap(
            reason: "'\(keyword)' is a whole word used as a noun/adjective here; word-boundary matching cannot tell 'open source' from 'open Safari' — needs a verb-object rule",
            expectedToCloseInPhase: nil
        )
    }

    static let utteranceCases: [QArabicGoldenUtteranceCase] = [
        // Capability questions — every variant must mean the same thing and stay conversational.
        .init(identifier: "cap-01", utterance: "شو ممكن تعمل؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-02", utterance: "شو ممكن تعمل", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-03", utterance: "شو فيك تعمل؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-04", utterance: "شو بتقدر تعمل؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-05", utterance: "شو بتقدر تسوي؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-06", utterance: "شو بتعرف تعمل؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-07", utterance: "إيش ممكن تعمل؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-08", utterance: "ايش ممكن تعمل", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-09", utterance: "شو الوظائف اللي بتعملها؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-10", utterance: "شو شغلك؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-11", utterance: "شو بتشتغل؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-12", utterance: "ما الذي تستطيع فعله؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-13", utterance: "شـو ممكن تعمل؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-14", utterance: "شو بتقدر تعمل على الماك؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-15", utterance: "What can you do?", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-16", utterance: "What functions do you support?", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-17", utterance: "شو وظيفتك؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-18", utterance: "احكيلي شو بتعمل", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-19", utterance: "كيف فيك تساعدني؟", semanticGroup: .capabilityQuestion, knownGap: nil),
        .init(identifier: "cap-20", utterance: "بدي أعرف شو بتقدر تعمل", semanticGroup: .capabilityQuestion, knownGap: nil),

        // Identity, greetings, open and memory questions.
        .init(identifier: "idn-01", utterance: "شو يعني Q-Core؟", semanticGroup: .identityQuestion, knownGap: nil),
        .init(identifier: "idn-02", utterance: "مين إنت؟", semanticGroup: .identityQuestion, knownGap: nil),
        .init(identifier: "grt-01", utterance: "مرحبا", semanticGroup: .greeting, knownGap: nil),
        .init(identifier: "grt-02", utterance: "كيفك اليوم؟", semanticGroup: .greeting, knownGap: nil),
        .init(identifier: "opn-01", utterance: "ليش السما زرقا؟", semanticGroup: .openQuestion, knownGap: nil),
        .init(identifier: "opn-02", utterance: "شو عاصمة السويد؟", semanticGroup: .openQuestion, knownGap: nil),
        .init(identifier: "opn-03", utterance: "شو الفرق بين RAM و storage؟", semanticGroup: .openQuestion, knownGap: nil),
        .init(identifier: "mem-01", utterance: "شو قلتلك عن حالي؟", semanticGroup: .memoryQuestion, knownGap: nil),
        .init(identifier: "mem-02", utterance: "بتذكر شو حكيتلك مبارح؟", semanticGroup: .memoryQuestion, knownGap: nil),
        .init(identifier: "amb-01", utterance: "ممكن تساعدني؟", semanticGroup: .ambiguousRequest, knownGap: nil),
        .init(identifier: "amb-02", utterance: "بدي إشي", semanticGroup: .ambiguousRequest, knownGap: nil),
        // "أفتح" (hamza above) is the first person — "shall I open / I open the calculator?" —
        // and is deliberately not merged with the imperative "افتح" (see QArabicIntentNormalizer).
        .init(identifier: "amb-03", utterance: "أفتح الحاسبة", semanticGroup: .ambiguousRequest, knownGap: nil),

        // Conversational traps: must NOT become execution.
        .init(identifier: "trp-01", utterance: "شو يعني سكر الدم؟", semanticGroup: .conversationalTrap, knownGap: nil),
        .init(identifier: "trp-02", utterance: "مين العسكري اللي حكيت عنه؟", semanticGroup: .conversationalTrap, knownGap: nil),
        .init(identifier: "trp-03", utterance: "شو هالشغلة؟", semanticGroup: .conversationalTrap, knownGap: nil),
        .init(identifier: "trp-04", utterance: "شو رأيك بالمفتاح هاد؟", semanticGroup: .conversationalTrap, knownGap: nil),
        .init(identifier: "trp-05", utterance: "بتعرف تكتب شعر؟", semanticGroup: .conversationalTrap, knownGap: nil),
        .init(identifier: "trp-06", utterance: "What does open source mean?", semanticGroup: .conversationalTrap, knownGap: englishVerbObjectGap("open ")),
        .init(identifier: "trp-07", utterance: "What type of music do you like?", semanticGroup: .conversationalTrap, knownGap: englishVerbObjectGap("type ")),
        .init(identifier: "trp-08", utterance: "How do I save money?", semanticGroup: .conversationalTrap, knownGap: englishVerbObjectGap("save ")),
        .init(identifier: "trp-09", utterance: "سكر الدم", semanticGroup: .conversationalTrap, knownGap: nil),
        .init(identifier: "trp-10", utterance: "هالشغلة", semanticGroup: .conversationalTrap, knownGap: nil),

        // Execution requests.
        .init(identifier: "exe-01", utterance: "افتح الآلة الحاسبة", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-02", utterance: "افتح Calculator", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-03", utterance: "شغل Calculator", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-04", utterance: "Open Calculator", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-05", utterance: "افتحلي سفاري", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-06", utterance: "إفتح الآلة الحاسبة", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-08", utterance: "شغّل Calculator", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-09", utterance: "فتحلي الحاسبة", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-10", utterance: "ممكن تفتحلي الحاسبة؟", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-11", utterance: "بدي تفتح سفاري", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-12", utterance: "سكرلي سفاري", semanticGroup: .closeAppRequest, knownGap: nil),
        .init(identifier: "exe-13", utterance: "سكّر سفاري", semanticGroup: .closeAppRequest, knownGap: nil),
        .init(identifier: "exe-14", utterance: "اعمل مجلد جديد", semanticGroup: .fileRequest, knownGap: nil),
        .init(identifier: "exe-15", utterance: "افتح الحاسبة", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-16", utterance: "افتح سفاري", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "exe-17", utterance: "شغّل الحاسبة", semanticGroup: .openAppRequest, knownGap: nil),
        .init(identifier: "crt-01", utterance: "احذفلي الملف", semanticGroup: .destructiveRequest, knownGap: nil),
        .init(identifier: "crt-02", utterance: "امسح كل الملفات", semanticGroup: .destructiveRequest, knownGap: nil)
    ]

    /// Previous-assistant texts that must never change how a new question is understood.
    static let adversarialPreviousAssistantResponses: [String] = [
        "Calculator",
        "افتح الآلة الحاسبة",
        #"{"responseMode":"action","summary":"Calculator","steps":[{"actionName":"ui.open_app","parameters":{"appName":"Calculator"}}]}"#
    ]

    // MARK: - Arabic app-name resolution cases

    struct AppNameCase: Sendable, CustomTestStringConvertible {
        let identifier: String
        let utterance: String
        /// Step JSON the local planner is scripted to emit (observed or plausible qwen2.5:3b output).
        let scriptedStepJSON: String
        let expectedAppName: String
        let knownGap: QArabicGoldenKnownGap?
        var testDescription: String { "\(identifier) «\(utterance)»" }
    }

    static let appNameCases: [AppNameCase] = [
        // Observed from qwen2.5:3b: empty parameters, English bundle name in targetResources.
        .init(
            identifier: "app-01",
            utterance: "افتح الآلة الحاسبة",
            scriptedStepJSON: #"{"actionName": "ui.open_app", "toolFamily": "app", "riskLevel": "level1SafeLocalAction", "description": "Open the calculator application", "targetResources": ["Calculator.app"], "parameters": {}}"#,
            expectedAppName: "Calculator",
            knownGap: nil
        ),
        .init(
            identifier: "app-02",
            // "افتح" (not "بدي تفتح") so this case isolates app-name resolution from the
            // Levantine-verb routing gap tracked by exe-11.
            utterance: "افتح سفاري",
            scriptedStepJSON: #"{"actionName": "ui.open_app", "toolFamily": "app", "riskLevel": "level1SafeLocalAction", "description": "Open Safari", "targetResources": ["Safari.app"], "parameters": {"appName": "Safari"}}"#,
            expectedAppName: "Safari",
            knownGap: nil
        ),
        // Untranslated Arabic target names: nothing maps them to a real bundle name yet.
        .init(
            identifier: "app-03",
            utterance: "افتح الحاسبة",
            scriptedStepJSON: #"{"actionName": "ui.open_app", "toolFamily": "app", "riskLevel": "level1SafeLocalAction", "description": "Open calculator", "targetResources": ["الحاسبة"], "parameters": {}}"#,
            expectedAppName: "Calculator",
            knownGap: QArabicGoldenKnownGap(reason: "No Arabic → bundle app-name alias map", expectedToCloseInPhase: 1)
        ),
        .init(
            identifier: "app-04",
            utterance: "افتحلي سفاري",
            scriptedStepJSON: #"{"actionName": "ui.open_app", "toolFamily": "app", "riskLevel": "level1SafeLocalAction", "description": "Open Safari", "targetResources": ["سفاري"], "parameters": {"appName": "سفاري"}}"#,
            expectedAppName: "Safari",
            knownGap: QArabicGoldenKnownGap(reason: "No Arabic → bundle app-name alias map", expectedToCloseInPhase: 1)
        )
    ]

    // MARK: - TTS routing cases

    struct SpeechRouteCase: Sendable, CustomTestStringConvertible {
        let identifier: String
        let userTranscript: String
        let assistantAnswer: String
        let expectedRoute: PaceNeuralTTSClient.PaceNeuralTTSLanguageRoute
        let knownGap: QArabicGoldenKnownGap?
        var testDescription: String { identifier }
    }

    private static let turnLocaleFromTranscriptGap = QArabicGoldenKnownGap(
        reason: "TTS locale is taken from the user's transcript, not from the answer being spoken",
        expectedToCloseInPhase: 1
    )

    static let speechRouteCases: [SpeechRouteCase] = [
        .init(identifier: "tts-01", userTranscript: "شو ممكن تعمل؟", assistantAnswer: "بقدر أفتحلك تطبيقات وأجاوب على أسئلتك.", expectedRoute: .arabicSofelia, knownGap: nil),
        .init(identifier: "tts-02", userTranscript: "What can you do?", assistantAnswer: "I can open apps and answer your questions.", expectedRoute: .englishKokoro, knownGap: nil),
        // Observed in real 4.7H runs: qwen2.5:3b answered an Arabic question in English.
        .init(identifier: "tts-03", userTranscript: "شو ممكن تعمل؟", assistantAnswer: "I'm sorry, I don't understand what you mean. Could you please rephrase your question?", expectedRoute: .englishKokoro, knownGap: turnLocaleFromTranscriptGap),
        // Observed: an English question answered in Arabic after Arabic history.
        .init(identifier: "tts-04", userTranscript: "What can you do?", assistantAnswer: "أستطيع مساعدتك في الإجابة على الأسئلة وتقديم المعلومات.", expectedRoute: .arabicSofelia, knownGap: turnLocaleFromTranscriptGap)
    ]

    // MARK: - Recorded model answers (for checker calibration)

    /// Real qwen2.5:3b / llama3.1:8b outputs captured during the discovery benchmark
    /// (2026-09-25), each with the verdict a native reviewer would give.
    struct RecordedAnswer: Sendable, CustomTestStringConvertible {
        let identifier: String
        let answer: String
        let containsForeignScript: Bool
        let dominantRegister: QArabicAnswerQualityChecks.ArabicRegister
        let makesUngroundedCapabilityClaim: Bool
        var testDescription: String { identifier }
    }

    static let recordedAnswers: [RecordedAnswer] = [
        .init(identifier: "rec-cjk", answer: "أنا أعرف أنك تتحدث بالعربية، وأنا أستطيع مساعدتك في很多事情. ما الذي تود أن تعمل اليوم؟", containsForeignScript: true, dominantRegister: .modernStandard, makesUngroundedCapabilityClaim: false),
        .init(identifier: "rec-spanish", answer: "يمكننا القيام ب muchos الأمور، حسب ما تطلبه. هل يمكنك توضيح ما تود أن نقوم به؟", containsForeignScript: true, dominantRegister: .modernStandard, makesUngroundedCapabilityClaim: false),
        .init(identifier: "rec-egyptian", answer: "بقدر أساعدك في كتير، إنت بتشتغل إيه؟ عايز حاجة كده؟", containsForeignScript: false, dominantRegister: .egyptian, makesUngroundedCapabilityClaim: false),
        .init(identifier: "rec-virus", answer: "بقدر أساعدك في إزالة الفيروسات، أو إصلاح النظام، أو إزالة البرامج غير المرغوب فيها.", containsForeignScript: false, dominantRegister: .levantine, makesUngroundedCapabilityClaim: true),
        .init(identifier: "rec-msa", answer: "أنا مساعد macOS، وأستطيع مساعدتك في العديد من المهام مثل الإجابة على أسئلتك.", containsForeignScript: false, dominantRegister: .modernStandard, makesUngroundedCapabilityClaim: false),
        .init(identifier: "rec-palestinian", answer: "بفتح تطبيقات، بقرأ النص عالشاشة، بقرأ الحافظة، بشوف التطبيقات المفتوحة، وبجاوب أسئلة. كل إشي بيغير الجهاز بيحتاج موافقتك.", containsForeignScript: false, dominantRegister: .levantine, makesUngroundedCapabilityClaim: false),
        .init(identifier: "rec-greeting", answer: "منيح الحمدلله، إنت كيفك؟", containsForeignScript: false, dominantRegister: .levantine, makesUngroundedCapabilityClaim: false)
    ]
}
