//
//  PalestinianStyleInvariants.swift
//  leanring-buddy
//
//  Deterministic meaning checks for the presentation-only Palestinian style layer
//  (`PalestinianConversationalStyler`). A style transformation may change HOW something is
//  said, never WHAT was decided or done. Any violation keeps the original text.
//
//  Protected verbatim: numbers (Arabic-Indic digits normalized), Latin-script tokens (app
//  names, technical terms, file paths, URLs, error codes, tool names), quoted text, and
//  caller-supplied protected terms.
//  Protected by meaning: refusal/denial, approval/permission requirement and failure must
//  survive; a completion claim may never be introduced; no plan/JSON syntax may appear.
//
//  Pure: no I/O, no model, no access to plans, permissions or execution.
//

import Foundation

enum PalestinianStyleInvariants {

    enum Violation: Equatable {
        case emptiedText
        case numbersChanged
        case latinTokensChanged
        case quotedTextChanged
        case protectedTermRemoved(String)
        case refusalRemoved
        case approvalRequirementRemoved
        case failureRemoved
        case completionClaimIntroduced
        case structuredSyntaxIntroduced
        case lengthExceeded
    }

    /// A styled unit may grow a little (dialect phrasing can be longer) but never enough to
    /// carry hidden context or raw model output.
    static let maximumGrowthFactor = 2
    static let maximumGrowthAllowanceCharacters = 24

    static func violations(original: String, styled: String, protectedTerms: [String] = []) -> [Violation] {
        var violations: [Violation] = []
        let originalIsBlank = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !originalIsBlank && styled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.emptiedText)
        }
        if numberTokens(in: original) != numberTokens(in: styled) {
            violations.append(.numbersChanged)
        }
        if latinTokens(in: original) != latinTokens(in: styled) {
            violations.append(.latinTokensChanged)
        }
        if quotedSegments(in: original) != quotedSegments(in: styled) {
            violations.append(.quotedTextChanged)
        }
        for term in protectedTerms where !term.isEmpty && original.contains(term) && !styled.contains(term) {
            violations.append(.protectedTermRemoved(term))
        }
        if expresses(.refusal, original) && !expresses(.refusal, styled) {
            violations.append(.refusalRemoved)
        }
        if expresses(.approvalRequirement, original) && !expresses(.approvalRequirement, styled) {
            violations.append(.approvalRequirementRemoved)
        }
        if expresses(.failure, original) && !expresses(.failure, styled) {
            violations.append(.failureRemoved)
        }
        if !expresses(.completion, original) && expresses(.completion, styled) {
            violations.append(.completionClaimIntroduced)
        }
        if structuredSyntaxCount(in: styled) > structuredSyntaxCount(in: original) {
            violations.append(.structuredSyntaxIntroduced)
        }
        if styled.count > original.count * maximumGrowthFactor + maximumGrowthAllowanceCharacters {
            violations.append(.lengthExceeded)
        }
        return violations
    }

    // MARK: - Verbatim facts

    /// Digit runs, with Arabic-Indic and Eastern Arabic-Indic digits normalized to ASCII so
    /// "٣" and "3" are the same number. Sorted multiset.
    static func numberTokens(in text: String) -> [String] {
        var numbers: [String] = []
        var currentNumber = ""
        for scalar in text.unicodeScalars {
            if let asciiDigit = asciiDigit(for: scalar) {
                currentNumber.append(asciiDigit)
            } else if !currentNumber.isEmpty {
                numbers.append(currentNumber)
                currentNumber = ""
            }
        }
        if !currentNumber.isEmpty {
            numbers.append(currentNumber)
        }
        return numbers.sorted()
    }

    private static func asciiDigit(for scalar: Unicode.Scalar) -> Character? {
        switch scalar.value {
        case 0x30...0x39: return Character(scalar)
        case 0x0660...0x0669: return Character(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
        case 0x06F0...0x06F9: return Character(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
        default: return nil
        }
    }

    /// Whitespace-separated tokens containing a Latin letter (app names, technical terms,
    /// paths, URLs, error codes, tool names), with surrounding sentence punctuation removed.
    /// Sorted multiset.
    static func latinTokens(in text: String) -> [String] {
        let surroundingPunctuation = CharacterSet(charactersIn: ".,;:!?؟،؛\"'«»“”‘’()[]")
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: surroundingPunctuation) }
            .filter { token in token.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) } }
            .sorted()
    }

    /// Text inside "…", “…”, «…». Order-preserving.
    static func quotedSegments(in text: String) -> [String] {
        let quotePairs: [(open: Character, close: Character)] = [("\"", "\""), ("“", "”"), ("«", "»")]
        var segments: [String] = []
        for quotePair in quotePairs {
            var isInsideQuote = false
            var currentSegment = ""
            for character in text {
                if !isInsideQuote && character == quotePair.open {
                    isInsideQuote = true
                    currentSegment = ""
                } else if isInsideQuote && character == quotePair.close {
                    isInsideQuote = false
                    segments.append(currentSegment)
                } else if isInsideQuote {
                    currentSegment.append(character)
                }
            }
        }
        return segments
    }

    // MARK: - Meaning markers

    enum MeaningCategory {
        case refusal
        case approvalRequirement
        case failure
        case completion
    }

    /// Whole-word markers per meaning, in formal Arabic and Palestinian Arabic. Matching is on
    /// whole normalized words, so "تم" never matches "تمام".
    static let arabicMarkerWords: [MeaningCategory: Set<String>] = [
        .refusal: ["ممنوع", "مرفوض", "رفضت", "رفض", "بقدرش", "مقدرش"],
        .approvalRequirement: ["موافقة", "موافقتك", "بموافقتك", "الموافقة", "اذن", "اذنك", "باذنك", "الاذن", "تسمحلي"],
        .failure: ["فشل", "فشلت", "خطا", "الخطا", "غلط", "مشكلة"],
        .completion: ["تم", "تمت", "فتحت", "فتحتلك", "سكرت", "سكرتلك", "خلصت", "نفذت", "نفذتلك", "كتبت", "كتبتلك"]
    ]

    /// Multi-word markers, matched on whole normalized words.
    static let arabicMarkerPhrases: [MeaningCategory: [String]] = [
        .refusal: ["لا استطيع", "لا يمكنني", "ما بقدر", "مش قادر", "مش مسموح", "غير مسموح", "ما رح اقدر"],
        .failure: ["ما زبط", "ما نجح", "ما نجحت", "لم ينجح", "لم اتمكن", "ما قدرت"]
    ]

    /// English markers: single words or multi-word phrases, matched on whole words.
    static let englishMarkerPhrases: [MeaningCategory: [String]] = [
        .refusal: ["denied", "cannot", "can't", "not allowed", "refuse", "refused", "blocked", "won't"],
        .approvalRequirement: ["approval", "approve", "permission", "allow"],
        .failure: ["failed", "failure", "error", "couldn't", "could not", "unable"],
        .completion: ["done", "opened", "closed", "completed", "successfully", "succeeded"]
    ]

    /// Words that negate the verb right after them. A negated completion verb
    /// ("ما فتحت" — "I did not open") is not a completion claim.
    static let arabicNegationWords: Set<String> = ["ما", "مش", "لم", "لا", "لن", "مو"]

    static func expresses(_ category: MeaningCategory, _ text: String) -> Bool {
        let arabicWords = normalizedArabicWords(in: text)
        if let markerWords = arabicMarkerWords[category] {
            for (wordIndex, word) in arabicWords.enumerated() where markerWords.contains(word) {
                let isNegated = wordIndex > 0 && arabicNegationWords.contains(arabicWords[wordIndex - 1])
                if category == .completion && isNegated { continue }
                return true
            }
        }
        if let phrases = arabicMarkerPhrases[category], containsWholeWordPhrase(phrases, in: arabicWords) {
            return true
        }
        if let phrases = englishMarkerPhrases[category], containsWholeWordPhrase(phrases, in: englishWords(in: text)) {
            return true
        }
        return false
    }

    private static func containsWholeWordPhrase(_ phrases: [String], in words: [String]) -> Bool {
        let joinedWords = " " + words.joined(separator: " ") + " "
        return phrases.contains { joinedWords.contains(" \($0) ") }
    }

    /// Lowercased English words (letters and apostrophes).
    static func englishWords(in text: String) -> [String] {
        let wordCharacters = CharacterSet.letters.union(CharacterSet(charactersIn: "'’"))
        return text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: wordCharacters.inverted)
            .filter { !$0.isEmpty }
    }

    /// Arabic words with diacritics/tatweel stripped and alef/hamza forms unified, so marker
    /// matching does not depend on spelling.
    static func normalizedArabicWords(in text: String) -> [String] {
        var normalizedScalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640:
                continue
            case 0x0622, 0x0623, 0x0625, 0x0671:
                normalizedScalars.append(Unicode.Scalar(0x0627)!)
            case 0x0649:
                normalizedScalars.append(Unicode.Scalar(0x064A)!)
            default:
                normalizedScalars.append(scalar)
            }
        }
        return String(normalizedScalars)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    // MARK: - Structured syntax

    /// Characters and markers of plans/JSON/tool calls. Presentation text may never gain them.
    static func structuredSyntaxCount(in text: String) -> Int {
        let structuralCharacters: Set<Character> = ["{", "}", "[", "]", "<", ">", "`"]
        let characterCount = text.filter { structuralCharacters.contains($0) }.count
        let markerCount = ["responseMode", "actionName", "tool_calls", "\"steps\""].reduce(0) { total, marker in
            total + text.components(separatedBy: marker).count - 1
        }
        return characterCount + markerCount
    }
}
