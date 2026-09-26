//
//  PalestinianConversationalGoldenSet.swift
//  leanring-buddyTests
//
//  Foundation for the Palestinian Arabic conversational evaluation set. Test-only data.
//
//  The user is the native-language reviewer and final authority on Palestinian phrasing.
//  `userApprovedSeedPhrasings` holds the user's own seed examples verbatim; they are
//  evaluation examples, NOT production templates and NOT universal dialect rules. Every
//  other case carries only a user input and is marked as awaiting native review until the
//  user supplies a reference answer.
//

import Foundation
@testable import Pace

enum PalestinianGoldenCategory: String, CaseIterable, Sendable {
    case greeting
    case wellbeing
    case capabilities
    case helpHowTo
    case identity
    case casualConversation
    case technicalExplanation
    case executionResult
    case refusal
    case permission
    case approval
    case errorFailure
    case memoryRelated
    case mixedArabicEnglishTechnical
}

struct PalestinianGoldenCase: Sendable, CustomStringConvertible {
    let identifier: String
    let category: PalestinianGoldenCategory
    let userInput: String
    /// A user-approved reference answer, or nil while awaiting native review.
    let userApprovedReferenceAnswer: String?
    /// Terms any answer must keep verbatim (app names, paths, codes the result named).
    let protectedTerms: [String]
    var description: String { "\(identifier) «\(userInput)»" }
}

enum PalestinianConversationalGoldenSet {

    /// The user's seed examples, verbatim (approved style decision, preferred variant "هلأ").
    static let userApprovedSeedPhrasings: [String] = [
        "مرحبا، كيفك؟",
        "شو ممكن تعمل؟",
        "شو فيك تساعدني فيه؟",
        "شو بتقدر تعمل؟",
        "كيف بقدر أستخدمك؟",
        "كيفك اليوم؟",
        "هلأ بقدر أساعدك...",
        "تمام، فتحتلك Calculator."
    ]

    static let cases: [PalestinianGoldenCase] = [
        .init(identifier: "pal-greeting-01", category: .greeting, userInput: "مرحبا، كيفك؟", userApprovedReferenceAnswer: nil, protectedTerms: []),
        .init(identifier: "pal-wellbeing-01", category: .wellbeing, userInput: "كيفك اليوم؟", userApprovedReferenceAnswer: nil, protectedTerms: []),
        .init(identifier: "pal-capabilities-01", category: .capabilities, userInput: "شو ممكن تعمل؟", userApprovedReferenceAnswer: nil, protectedTerms: []),
        .init(identifier: "pal-capabilities-02", category: .capabilities, userInput: "شو بتقدر تعمل؟", userApprovedReferenceAnswer: nil, protectedTerms: []),
        .init(identifier: "pal-help-01", category: .helpHowTo, userInput: "شو فيك تساعدني فيه؟", userApprovedReferenceAnswer: "هلأ بقدر أساعدك...", protectedTerms: []),
        .init(identifier: "pal-help-02", category: .helpHowTo, userInput: "كيف بقدر أستخدمك؟", userApprovedReferenceAnswer: nil, protectedTerms: []),
        .init(identifier: "pal-identity-01", category: .identity, userInput: "مين إنت؟", userApprovedReferenceAnswer: nil, protectedTerms: []),
        .init(identifier: "pal-casual-01", category: .casualConversation, userInput: "شو رأيك بالقهوة؟", userApprovedReferenceAnswer: nil, protectedTerms: []),
        .init(identifier: "pal-technical-01", category: .technicalExplanation, userInput: "شو الفرق بين RAM و storage؟", userApprovedReferenceAnswer: nil, protectedTerms: ["RAM", "storage"]),
        .init(identifier: "pal-execution-01", category: .executionResult, userInput: "افتحلي Calculator", userApprovedReferenceAnswer: "تمام، فتحتلك Calculator.", protectedTerms: ["Calculator"]),
        .init(identifier: "pal-refusal-01", category: .refusal, userInput: "اقرأ ~/.ssh/id_rsa", userApprovedReferenceAnswer: nil, protectedTerms: ["~/.ssh/id_rsa"]),
        .init(identifier: "pal-permission-01", category: .permission, userInput: "اقرالي الحافظة", userApprovedReferenceAnswer: nil, protectedTerms: []),
        .init(identifier: "pal-approval-01", category: .approval, userInput: "سكّر Safari", userApprovedReferenceAnswer: nil, protectedTerms: ["Safari"]),
        .init(identifier: "pal-error-01", category: .errorFailure, userInput: "افتح تطبيق مش موجود", userApprovedReferenceAnswer: nil, protectedTerms: []),
        .init(identifier: "pal-memory-01", category: .memoryRelated, userInput: "شو قلتلك عن حالي؟", userApprovedReferenceAnswer: nil, protectedTerms: []),
        .init(identifier: "pal-mixed-01", category: .mixedArabicEnglishTechnical, userInput: "افتحلي Safari وروح على GitHub", userApprovedReferenceAnswer: nil, protectedTerms: ["Safari", "GitHub"])
    ]

    // MARK: - Style specification checks (test-side; from the discovery specification)

    /// Phrases that sound formal/translated in everyday conversation. A Palestinian
    /// conversational answer should not contain them.
    static let translatedRegisterPhrases: [String] = [
        "أنا هنا للمساعدة", "كيف يمكنني مساعدتك", "يبدو أنك تسأل", "هل هناك شيء محدد",
        "بكل سرور", "لا تتردد", "يسعدني", "أستطيع", "يمكنني", "ماذا", "لماذا", "الآن"
    ]

    /// Markers that pull toward other dialects (Egyptian / Gulf) rather than Palestinian.
    static let otherDialectDriftMarkers: [String] = ["إيه", "كده", "عايز", "وش", "أبغى", "زين"]

    /// The user chose "هلأ"; these alternates must not appear in approved Palestinian text.
    static let preferredNowVariant = "هلأ"
    static let nonPreferredNowVariants: [String] = ["هلق", "هسا", "هسّا"]
}
