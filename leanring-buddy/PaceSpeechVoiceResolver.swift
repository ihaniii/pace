//
//  PaceSpeechVoiceResolver.swift
//  leanring-buddy
//
//  Centralized voice resolver for Apple AVSpeechSynthesizer.
//  Selects the best installed Apple system voice following strict deterministic priority:
//    1. Female voice
//    2. Exact requested locale
//    3. Same-language fallback
//    4. Enhanced / premium / high-quality voice
//    5. Default Apple voice as final fallback
//

import AVFoundation
import Foundation
import NaturalLanguage

/// Abstraction allowing voice selection logic to be evaluated against either real
/// `AVSpeechSynthesisVoice` instances or test-injected descriptors.
public protocol PaceSpeechVoiceDescribing {
    var identifier: String { get }
    var name: String { get }
    var language: String { get }
    var gender: AVSpeechSynthesisVoiceGender { get }
    var quality: AVSpeechSynthesisVoiceQuality { get }
}

extension AVSpeechSynthesisVoice: PaceSpeechVoiceDescribing {}

/// Lightweight descriptor for unit tests and deterministic simulation without
/// depending on specific physical voices installed on a host Mac.
public struct PaceMockSpeechVoice: PaceSpeechVoiceDescribing, Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let language: String
    public let gender: AVSpeechSynthesisVoiceGender
    public let quality: AVSpeechSynthesisVoiceQuality

    public init(
        identifier: String,
        name: String,
        language: String,
        gender: AVSpeechSynthesisVoiceGender,
        quality: AVSpeechSynthesisVoiceQuality = .default
    ) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.gender = gender
        self.quality = quality
    }
}

public enum PaceSpeechVoiceResolver {

    // MARK: - Language Detection

    /// Detects the dominant language of the provided text using local on-device NaturalLanguage.
    /// Returns the ISO language code (e.g., "en", "sv", "ar") or nil if undetermined.
    public static func detectLanguage(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        return dominant.rawValue
    }

    /// Maps a language code or locale string to a canonical target locale identifier.
    public static func canonicalLocale(for languageCodeOrLocale: String?) -> String {
        guard let input = languageCodeOrLocale?.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.isEmpty else {
            return "en-US"
        }

        let normalized = input.replacingOccurrences(of: "_", with: "-").lowercased()
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized

        switch base {
        case "sv":
            return "sv-SE"
        case "ar":
            return "ar-001"
        case "en":
            return normalized.contains("-") ? input : "en-US"
        default:
            return input
        }
    }

    // MARK: - Generic Selection Algorithm

    /// Selects the best candidate voice from a given collection according to the 5-priority policy:
    ///   1. Female voice preferred
    ///   2. Exact requested locale match
    ///   3. Same-language fallback
    ///   4. High quality (premium > enhanced > compact)
    ///   5. Deterministic tie-breaking (non-super-compact, name, identifier)
    public static func selectBestVoice<V: PaceSpeechVoiceDescribing>(
        from voices: [V],
        targetLocale: String = "en-US",
        preferredVoiceIdentifier: String? = nil
    ) -> V? {
        guard !voices.isEmpty else { return nil }

        let normalizedTarget = targetLocale.replacingOccurrences(of: "_", with: "-").lowercased()
        let targetBaseLang = normalizedTarget.split(separator: "-").first.map(String.init) ?? normalizedTarget

        // 1. Filter voices for the requested language (exact locale or same base language)
        let sameLanguageVoices = voices.filter { v in
            let vNorm = v.language.replacingOccurrences(of: "_", with: "-").lowercased()
            let vBase = vNorm.split(separator: "-").first.map(String.init) ?? vNorm
            return vNorm == normalizedTarget || vBase == targetBaseLang
        }

        // If no voices exist in the requested language, fall back to the entire voice pool
        let candidatePool: [V] = !sameLanguageVoices.isEmpty ? sameLanguageVoices : voices

        // 2. Priority 1: Female voice preferred
        let femaleVoices = candidatePool.filter { $0.gender == .female }
        let eligiblePool: [V] = !femaleVoices.isEmpty ? femaleVoices : candidatePool

        // 3. Sort eligible candidates by remaining priorities
        let sorted = eligiblePool.sorted { a, b in
            // Priority 1: Female gender first (within pool, in case of mixed fallbacks)
            if a.gender != b.gender {
                if a.gender == .female { return true }
                if b.gender == .female { return false }
            }

            // Explicit preferred voice match (if valid and in eligible pool)
            if let preferredVoiceIdentifier {
                let aPref = a.identifier == preferredVoiceIdentifier
                let bPref = b.identifier == preferredVoiceIdentifier
                if aPref != bPref {
                    return aPref
                }
            }

            // Priority 2: Exact requested locale
            let aNorm = a.language.replacingOccurrences(of: "_", with: "-").lowercased()
            let bNorm = b.language.replacingOccurrences(of: "_", with: "-").lowercased()
            let aExact = aNorm == normalizedTarget
            let bExact = bNorm == normalizedTarget
            if aExact != bExact {
                return aExact
            }

            // Priority 4: Quality (premium > enhanced > compact/default)
            let aQual = a.quality.rawValue
            let bQual = b.quality.rawValue
            if aQual != bQual {
                return aQual > bQual
            }

            // Package tier: standard compact > super-compact
            let aSuper = a.identifier.contains("super-compact")
            let bSuper = b.identifier.contains("super-compact")
            if aSuper != bSuper {
                return !aSuper
            }

            // Deterministic tie-breaker
            if a.name != b.name {
                return a.name < b.name
            }
            return a.identifier < b.identifier
        }

        return sorted.first
    }

    // MARK: - Public AVSpeechSynthesisVoice APIs

    /// Resolves the best installed Apple system voice for a given locale string (e.g. "en-US", "sv-SE", "ar-001").
    public static func bestAvailableVoice(
        locale: String? = nil,
        preferredVoiceIdentifier: String? = nil,
        voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
    ) -> AVSpeechSynthesisVoice? {
        let target = canonicalLocale(for: locale)
        if let selected = selectBestVoice(
            from: voices,
            targetLocale: target,
            preferredVoiceIdentifier: preferredVoiceIdentifier
        ) {
            return selected
        }

        // Final safe Apple fallback
        return AVSpeechSynthesisVoice(language: target) ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Resolves the best installed Apple system voice for arbitrary spoken text, detecting language
    /// automatically when possible.
    public static func bestAvailableVoice(
        forText text: String,
        preferredVoiceIdentifier: String? = nil,
        voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
    ) -> AVSpeechSynthesisVoice? {
        let detected = detectLanguage(for: text)
        let targetLocale = canonicalLocale(for: detected)
        return bestAvailableVoice(
            locale: targetLocale,
            preferredVoiceIdentifier: preferredVoiceIdentifier,
            voices: voices
        )
    }
}
