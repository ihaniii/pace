//
//  PacePalestinianArabicFrontend.swift
//  leanring-buddy
//
//  Deterministic Palestinian Arabic Text-to-Phoneme & Tokenizer Frontend.
//  Strictly offline: zero network, zero process execution, bounded input.
//  Pure Swift: zero dynamic libraries, zero C dependencies.
//

import Foundation

public enum PacePalestinianFrontendError: LocalizedError, Equatable {
    case lexiconNotFound(path: String)
    case vocabNotFound(path: String)
    case invalidText(reason: String)
    case tokenLimitExceeded(count: Int, limit: Int)
    case unsupportedPhoneme(Character)

    public var errorDescription: String? {
        switch self {
        case .lexiconNotFound(let path):
            return "Palestinian lexicon file not found at \(path)"
        case .vocabNotFound(let path):
            return "Sofelia vocab file not found at \(path)"
        case .invalidText(let reason):
            return "Invalid input text: \(reason)"
        case .tokenLimitExceeded(let count, let limit):
            return "Generated tokens count (\(count)) exceeds maximum allowed limit (\(limit))"
        case .unsupportedPhoneme(let char):
            return "Encountered unsupported phoneme character '\(char)'"
        }
    }
}

// MARK: - Palestinian Lexicon & Normalizer
public final class PacePalestinianArabicFrontend: Sendable {
    public static let shared = PacePalestinianArabicFrontend()

    private static let punctMap: [Character: Character] = [
        "،": ",",
        "؛": ";",
        "؟": "?"
    ]

    private static let phonemeFixups: [(String, String)] = [
        ("ħ", "ʰ"),
        ("ʕ", "ʁ"),
        ("ˤ", "ᵊ"),
        ("dʒ", "ʤ"),
        ("\u{032A}", ""), // dental diacritic
        ("[", ""),
        ("]", "")
    ]

    private let g2p: PacePalestinianArabicG2P

    public init(g2p: PacePalestinianArabicG2P = .shared) {
        self.g2p = g2p
    }

    // MARK: - Normalization

    /// Maps Arabic punctuation to Latin equivalents (pause/intonation cues).
    public func mapPunctuation(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            if let mapped = Self.punctMap[ch] {
                result.append(mapped)
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// Replaces colloquial Palestinian surface words with phonetic diacritized rewrites from ar_lexicon.json.
    public func applyLexicon(to text: String, lexiconPath: String) throws -> String {
        guard FileManager.default.fileExists(atPath: lexiconPath) else {
            throw PacePalestinianFrontendError.lexiconNotFound(path: lexiconPath)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: lexiconPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
        let sortedKeys = json.keys.filter { !$0.hasPrefix("_") }.sorted(by: { $0.count > $1.count })

        if sortedKeys.isEmpty {
            return text
        }

        var result = text
        for key in sortedKeys {
            if let replacement = json[key] {
                let escapedKey = NSRegularExpression.escapedPattern(for: key)
                let pat = "(?<![\\u0620-\\u064A\\u0640])(\(escapedKey))(?![\\u0620-\\u064A\\u0640])"
                if let regex = try? NSRegularExpression(pattern: pat) {
                    let range = NSRange(location: 0, length: (result as NSString).length)
                    result = regex.stringByReplacingMatches(
                        in: result,
                        options: [],
                        range: range,
                        withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
                    )
                }
            }
        }
        return result
    }

    /// Normalizes out-of-lexicon words ending with ة.
    public func normalizeTaaMarbuta(_ text: String) -> String {
        let pattern = "([\\u0620-\\u064A\\u0640]+ة)(?![\\u0620-\\u064A])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let wordRange = match.range(at: 1)
            let word = nsString.substring(with: wordRange)
            let ph = g2p.phonemizeWord(word)
            let trimmed = ph.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if trimmed.hasSuffix("t") {
                let fixed = String(word.dropLast()) + "َ"
                if let range = Range(wordRange, in: result) {
                    result.replaceSubrange(range, with: fixed)
                }
            }
        }
        return result
    }

    /// Full Palestinian text normalization.
    public func normalizeArabicText(_ text: String, lexiconPath: String) throws -> String {
        let punctMapped = mapPunctuation(text)
        let lexiconApplied = try applyLexicon(to: punctMapped, lexiconPath: lexiconPath)
        return normalizeTaaMarbuta(lexiconApplied)
    }

    // MARK: - Phonemization & Tokenization

    /// Full pipeline: Text -> Phonemes -> Kokoro-compatible Token IDs.
    public func textToPhonemesAndTokens(
        text: String,
        lexiconPath: String,
        vocabPath: String,
        maxTokens: Int = 510
    ) throws -> (phonemes: String, tokens: [Int64], styleIndex: Int) {
        let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            throw PacePalestinianFrontendError.invalidText(reason: "Input text cannot be empty or whitespace only")
        }

        let normalized = try normalizeArabicText(text, lexiconPath: lexiconPath)
        var ps = g2p.phonemizeSentence(normalized)

        // Apply Kokoro phoneme fixups
        for (old, new) in Self.phonemeFixups {
            ps = ps.replacingOccurrences(of: old, with: new)
        }
        ps = ps.trimmingCharacters(in: .whitespacesAndNewlines)

        // Load vocab
        guard FileManager.default.fileExists(atPath: vocabPath) else {
            throw PacePalestinianFrontendError.vocabNotFound(path: vocabPath)
        }
        let vocabData = try Data(contentsOf: URL(fileURLWithPath: vocabPath))
        let vocabJson = try JSONSerialization.jsonObject(with: vocabData) as? [String: Int] ?? [:]
        var vocabMap: [Character: Int64] = [:]
        for (k, v) in vocabJson {
            if let ch = k.first, k.count == 1 {
                vocabMap[ch] = Int64(v)
            }
        }

        // Validate all phonemes against vocab: FAIL CLOSED on unknown phoneme
        for ch in ps {
            if vocabMap[ch] == nil {
                throw PacePalestinianFrontendError.unsupportedPhoneme(ch)
            }
        }

        // Generate tokens: [0] + IDs + [0]
        var tokens: [Int64] = [0] // BOS
        for ch in ps {
            guard let id = vocabMap[ch] else {
                throw PacePalestinianFrontendError.unsupportedPhoneme(ch)
            }
            tokens.append(id)
        }
        tokens.append(0) // EOS

        // Enforce maximum token bound: FAIL CLOSED if exceeded
        if tokens.count > maxTokens {
            throw PacePalestinianFrontendError.tokenLimitExceeded(count: tokens.count, limit: maxTokens)
        }

        let styleIndex = max(0, min(509, ps.count - 1))
        return (phonemes: ps, tokens: tokens, styleIndex: styleIndex)
    }
}
