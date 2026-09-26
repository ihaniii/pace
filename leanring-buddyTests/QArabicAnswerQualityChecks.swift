//
//  QArabicAnswerQualityChecks.swift
//  leanring-buddyTests
//
//  Phase 0 (Arabic/Palestinian quality): deterministic, test-only answer checks. They are
//  heuristics for flagging regressions and ranking candidate changes — NOT a substitute for a
//  native speaker's review. Calibrated against `QArabicGoldenSet.recordedAnswers`.
//

import Foundation

enum QArabicAnswerQualityChecks {

    // MARK: - Script purity

    /// Latin words allowed inside an Arabic answer: product and app names users say in English.
    static let allowedLatinWordsInArabicAnswer: Set<String> = [
        "q", "core", "q-core", "que", "pace", "mac", "macos", "macbook", "iphone", "ipad",
        "calculator", "safari", "notes", "finder", "mail", "music", "xcode", "terminal",
        "api", "ram", "ssd", "cpu", "gpu", "ai", "wifi", "wi-fi", "bluetooth", "ok"
    ]

    /// Characters from scripts that must never appear in an Arabic answer (CJK, Cyrillic, etc.).
    static func foreignScriptCharacters(in answer: String) -> [Character] {
        answer.filter { character in
            character.unicodeScalars.contains { scalar in
                let value = scalar.value
                let isCJK = (0x3040...0x30FF).contains(value) || (0x3400...0x9FFF).contains(value)
                    || (0xAC00...0xD7AF).contains(value)
                let isCyrillic = (0x0400...0x04FF).contains(value)
                let isDevanagari = (0x0900...0x097F).contains(value)
                return isCJK || isCyrillic || isDevanagari
            }
        }
    }

    /// Latin words in an Arabic answer that are neither allow-listed nor present in the user's
    /// own question (quoting the user's English term back is fine; inventing one is not).
    static func unexpectedLatinWords(in answer: String, userQuestion: String) -> [String] {
        let questionWords = Set(latinWords(in: userQuestion))
        return latinWords(in: answer).filter { word in
            !allowedLatinWordsInArabicAnswer.contains(word) && !questionWords.contains(word)
        }
    }

    static func isArabicDominant(_ text: String) -> Bool {
        let arabicLetterCount = text.unicodeScalars.filter { (0x0600...0x06FF).contains($0.value) }.count
        let latinLetterCount = text.unicodeScalars.filter { $0.isASCII && CharacterSet.letters.contains($0) }.count
        return arabicLetterCount > latinLetterCount
    }

    /// True when an Arabic answer contains foreign-script characters or invented Latin words.
    static func hasMixedScriptContamination(answer: String, userQuestion: String) -> Bool {
        !foreignScriptCharacters(in: answer).isEmpty
            || !unexpectedLatinWords(in: answer, userQuestion: userQuestion).isEmpty
    }

    private static func latinWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.lowercaseLetters.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { word in
                word.unicodeScalars.allSatisfy { $0.isASCII }
                    && word.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            }
    }

    // MARK: - Register / dialect

    enum ArabicRegister: String, Sendable {
        case levantine
        case modernStandard
        case egyptian
        case undetermined
    }

    struct RegisterProfile: Sendable {
        let levantineMarkerCount: Int
        let modernStandardMarkerCount: Int
        let egyptianMarkerCount: Int

        /// Egyptian markers win on any presence: a Palestinian persona must never produce them.
        var dominantRegister: ArabicRegister {
            if egyptianMarkerCount > 0 { return .egyptian }
            if levantineMarkerCount == 0 && modernStandardMarkerCount == 0 { return .undetermined }
            return levantineMarkerCount > modernStandardMarkerCount ? .levantine : .modernStandard
        }
    }

    static let levantineMarkers: Set<String> = [
        "بقدر", "بتقدر", "بدك", "بدي", "هيك", "شو", "كتير", "منيح", "هلق", "هلأ", "إشي", "اشي",
        "لسا", "لسه", "عشان", "مش", "فيني", "فيك", "بعرف", "بتعرف", "إلك", "الك", "تاني", "هاد",
        "هاي", "هدول", "كمان", "ليش", "وين", "مين", "بحكي", "بتحكي", "بفتح", "بقرأ", "بشوف",
        "بجاوب", "بساعدك", "إنت", "انت", "إحنا", "احنا", "هون", "كيفك", "عالشاشة", "بيغير", "بيحتاج"
    ]

    static let modernStandardMarkers: Set<String> = [
        "أستطيع", "استطيع", "يمكنني", "يمكنك", "يمكننا", "سوف", "الذي", "التي", "ماذا", "لماذا",
        "لكن", "لكنني", "أيضاً", "أيضا", "حيث", "هل", "لدي", "لديك", "إنني", "الآن", "هذا",
        "هذه", "ذلك", "تود", "أود", "أقوم", "نقوم", "العديد"
    ]

    static let egyptianMarkers: Set<String> = [
        "إيه", "ايه", "كده", "كدا", "حاجة", "حاجه", "بتاع", "بتاعة", "معايا", "عايز", "عاوز",
        "دلوقتي", "ازاي", "إزاي", "ليا", "هأقدر", "هقدر", "مفيش"
    ]

    static func registerProfile(of answer: String) -> RegisterProfile {
        let words = arabicWords(in: answer)
        func count(_ markers: Set<String>) -> Int {
            words.filter { word in
                // Tolerate the attached conjunction و ("and"): "وبقدر" counts as "بقدر".
                markers.contains(word) || (word.hasPrefix("و") && markers.contains(String(word.dropFirst())))
            }.count
        }
        return RegisterProfile(
            levantineMarkerCount: count(levantineMarkers),
            modernStandardMarkerCount: count(modernStandardMarkers),
            egyptianMarkerCount: count(egyptianMarkers)
        )
    }

    private static func arabicWords(in text: String) -> [String] {
        let arabicLetters = CharacterSet(charactersIn: Unicode.Scalar(0x0621)!...Unicode.Scalar(0x064A)!)
            .union(CharacterSet(charactersIn: "آأإؤئ"))
        return text.components(separatedBy: arabicLetters.inverted).filter { !$0.isEmpty }
    }

    // MARK: - Capability grounding

    /// Stems of capabilities Que does NOT have. An answer claiming them is ungrounded.
    /// Heuristic: review flagged answers manually.
    static let ungroundedCapabilityStems: [String] = [
        "الفيروس", "فيروسات", "إيميل", "ايميل", "البريد الإلكتروني", "رسائل إلكترونية",
        "جدولك", "التقويم", "تنصيب", "تثبيت البرامج", "إدارة الشبكة", "إصلاح النظام",
        "تعديل الصور", "تحليل الفيديو", "الأخبار", "أوامر النظام",
        "virus", "email", "calendar", "system commands", "news"
    ]

    static func ungroundedCapabilityClaims(in answer: String) -> [String] {
        let lowercasedAnswer = answer.lowercased()
        return ungroundedCapabilityStems.filter { lowercasedAnswer.contains($0) }
    }

    /// Stems naming capabilities Que really has (see `QModelPlanSchema` registered actions).
    /// A capability answer that names none of them did not actually answer the question.
    static let realCapabilityStems: [String] = [
        "تطبيق", "التطبيقات", "الحافظة", "الشاشة", "ملفات", "الملفات", "بفتح", "أفتح", "افتح",
        "open app", "opening app", "applications", "clipboard", "screen", "files"
    ]

    static func mentionsRealCapability(_ answer: String) -> Bool {
        let lowercasedAnswer = answer.lowercased()
        return realCapabilityStems.contains { lowercasedAnswer.contains($0) }
    }

    /// Phrases that falsely deny a capability Que has (opening apps, reading files/screen).
    static let deniedRealCapabilityPhrases: [String] = [
        "لا أستطيع فتح", "لا يمكنني فتح", "لا أستطيع القيام بأشياء مثل تشغيل التطبيقات",
        "مش قادر أفتح", "ما بقدر أفتح", "cannot open", "can't open", "cannot perform actions"
    ]

    static func deniesRealCapability(_ answer: String) -> Bool {
        let lowercasedAnswer = answer.lowercased()
        return deniedRealCapabilityPhrases.contains { lowercasedAnswer.contains($0) }
    }

    // MARK: - Action-metadata leakage (Phase 4.7H invariant)

    static let actionMetadataMarkers = ["ui.open_app", "responseMode", "actionName", "taskPrompt", "\"steps\"", "{"]

    static func leaksActionMetadata(_ answer: String) -> Bool {
        actionMetadataMarkers.contains { answer.contains($0) }
    }
}
