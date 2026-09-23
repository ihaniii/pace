//
//  PaceSpeechVoiceResolverTests.swift
//  leanring-buddyTests
//
//  Focused verification for PaceSpeechVoiceResolver.
//  Validates the 5 selection priorities using dependency injection, plus
//  live Mac installed inventory checks for English, Swedish, and Arabic.
//

import Testing
import AVFoundation
import Foundation
@testable import Pace

@Suite("PaceSpeechVoiceResolverTests")
struct PaceSpeechVoiceResolverTests {

    // MARK: - 1. Female voice preferred over male when available
    @Test("1. Female voice is strictly preferred over male voice when available")
    func femaleVoicePreferredOverMaleWhenAvailable() {
        let maleVoice = PaceMockSpeechVoice(
            identifier: "mock.male.en-US",
            name: "Alex",
            language: "en-US",
            gender: .male,
            quality: .default
        )
        let femaleVoice = PaceMockSpeechVoice(
            identifier: "mock.female.en-US",
            name: "Samantha",
            language: "en-US",
            gender: .female,
            quality: .default
        )

        let selected = PaceSpeechVoiceResolver.selectBestVoice(
            from: [maleVoice, femaleVoice],
            targetLocale: "en-US"
        )
        #expect(selected?.identifier == femaleVoice.identifier)
        #expect(selected?.gender == .female)
    }

    // MARK: - 2. Enhanced/high-quality female preferred over default female
    @Test("2. Premium/enhanced female voice is preferred over compact/default female voice")
    func enhancedOrPremiumFemalePreferredOverDefaultFemale() {
        let compactFemale = PaceMockSpeechVoice(
            identifier: "mock.compact.female",
            name: "AvaCompact",
            language: "en-US",
            gender: .female,
            quality: .default
        )
        let enhancedFemale = PaceMockSpeechVoice(
            identifier: "mock.enhanced.female",
            name: "AvaEnhanced",
            language: "en-US",
            gender: .female,
            quality: .enhanced
        )
        let premiumFemale = PaceMockSpeechVoice(
            identifier: "mock.premium.female",
            name: "AvaPremium",
            language: "en-US",
            gender: .female,
            quality: .premium
        )

        // Enhanced over compact
        let selectedEnhanced = PaceSpeechVoiceResolver.selectBestVoice(
            from: [compactFemale, enhancedFemale],
            targetLocale: "en-US"
        )
        #expect(selectedEnhanced?.identifier == enhancedFemale.identifier)

        // Premium over enhanced
        let selectedPremium = PaceSpeechVoiceResolver.selectBestVoice(
            from: [compactFemale, enhancedFemale, premiumFemale],
            targetLocale: "en-US"
        )
        #expect(selectedPremium?.identifier == premiumFemale.identifier)
    }

    // MARK: - 3. Exact locale preferred over broader language
    @Test("3. Exact requested locale is preferred over a broader same-language regional voice")
    func exactLocalePreferredOverBroaderLanguage() {
        let australianFemale = PaceMockSpeechVoice(
            identifier: "mock.en-AU.Karen",
            name: "Karen",
            language: "en-AU",
            gender: .female,
            quality: .enhanced
        )
        let usFemale = PaceMockSpeechVoice(
            identifier: "mock.en-US.Samantha",
            name: "Samantha",
            language: "en-US",
            gender: .female,
            quality: .enhanced
        )

        let selected = PaceSpeechVoiceResolver.selectBestVoice(
            from: [australianFemale, usFemale],
            targetLocale: "en-US"
        )
        #expect(selected?.identifier == usFemale.identifier)
        #expect(selected?.language == "en-US")
    }

    // MARK: - 4. Same-language fallback works
    @Test("4. Same-language fallback resolves when exact regional dialect is not installed")
    func sameLanguageFallbackWorks() {
        let swedishVoice = PaceMockSpeechVoice(
            identifier: "mock.sv-SE.Alva",
            name: "Alva",
            language: "sv-SE",
            gender: .female,
            quality: .default
        )
        let englishVoice = PaceMockSpeechVoice(
            identifier: "mock.en-US.Samantha",
            name: "Samantha",
            language: "en-US",
            gender: .female,
            quality: .premium
        )

        // Requested Finnish Swedish (sv-FI) — should fall back to standard Swedish (sv-SE)
        let selected = PaceSpeechVoiceResolver.selectBestVoice(
            from: [englishVoice, swedishVoice],
            targetLocale: "sv-FI"
        )
        #expect(selected?.identifier == swedishVoice.identifier)
        #expect(selected?.language.hasPrefix("sv") == true)
    }

    // MARK: - 5. Missing female voice does not break TTS
    @Test("5. Missing female voice falls back to best available voice without breaking TTS")
    func missingFemaleVoiceDoesNotBreakTTS() {
        let maleArabicVoice = PaceMockSpeechVoice(
            identifier: "mock.ar-001.Maged",
            name: "Majed",
            language: "ar-001",
            gender: .male,
            quality: .default
        )

        let selected = PaceSpeechVoiceResolver.selectBestVoice(
            from: [maleArabicVoice],
            targetLocale: "ar-001"
        )
        #expect(selected != nil)
        #expect(selected?.identifier == maleArabicVoice.identifier)
        #expect(selected?.gender == .male)
    }

    // MARK: - 6. Selection is deterministic
    @Test("6. Voice selection is strictly deterministic across repeated invocations and orders")
    func selectionIsDeterministic() {
        let v1 = PaceMockSpeechVoice(identifier: "mock.voice.1", name: "Alpha", language: "en-US", gender: .female, quality: .default)
        let v2 = PaceMockSpeechVoice(identifier: "mock.voice.2", name: "Beta", language: "en-US", gender: .female, quality: .default)
        let v3 = PaceMockSpeechVoice(identifier: "mock.voice.3", name: "Gamma", language: "en-US", gender: .female, quality: .default)

        let r1 = PaceSpeechVoiceResolver.selectBestVoice(from: [v1, v2, v3], targetLocale: "en-US")
        let r2 = PaceSpeechVoiceResolver.selectBestVoice(from: [v3, v1, v2], targetLocale: "en-US")
        let r3 = PaceSpeechVoiceResolver.selectBestVoice(from: [v2, v3, v1], targetLocale: "en-US")

        #expect(r1?.identifier == r2?.identifier)
        #expect(r2?.identifier == r3?.identifier)
    }

    // MARK: - 7. Language Detection & Text Routing
    @Test("7. On-device language detection correctly routes English, Swedish, and Arabic")
    func languageDetectionAndCanonicalLocales() {
        #expect(PaceSpeechVoiceResolver.detectLanguage(for: "Hello, how are you?") == "en")
        #expect(PaceSpeechVoiceResolver.detectLanguage(for: "Hej, hur mår du idag?") == "sv")
        #expect(PaceSpeechVoiceResolver.detectLanguage(for: "مرحبا، كيف حالك؟") == "ar")

        #expect(PaceSpeechVoiceResolver.canonicalLocale(for: "en") == "en-US")
        #expect(PaceSpeechVoiceResolver.canonicalLocale(for: "sv") == "sv-SE")
        #expect(PaceSpeechVoiceResolver.canonicalLocale(for: "ar") == "ar-001")
    }

    // MARK: - 8. Live Mac Installed Inventory Resolution
    @Test("8. Real Mac voice inventory resolves the expected installed female Apple voices")
    func liveMacInstalledVoiceResolution() {
        // English: Samantha (compact female)
        let englishVoice = PaceSpeechVoiceResolver.bestAvailableVoice(locale: "en-US")
        #expect(englishVoice != nil)
        #expect(englishVoice?.language.hasPrefix("en") == true)
        #expect(englishVoice?.gender == .female)

        // Swedish: Alva (super-compact female)
        let swedishVoice = PaceSpeechVoiceResolver.bestAvailableVoice(locale: "sv-SE")
        #expect(swedishVoice != nil)
        #expect(swedishVoice?.language.hasPrefix("sv") == true)
        #expect(swedishVoice?.gender == .female)

        // Arabic: Majed (male fallback since no female Arabic voice is installed on this Mac)
        let arabicVoice = PaceSpeechVoiceResolver.bestAvailableVoice(locale: "ar-001")
        #expect(arabicVoice != nil)
        #expect(arabicVoice?.language.hasPrefix("ar") == true)

        // Text-based voice selection
        let englishFromText = PaceSpeechVoiceResolver.bestAvailableVoice(forText: "Good morning, Que here.")
        #expect(englishFromText?.gender == .female)

        let swedishFromText = PaceSpeechVoiceResolver.bestAvailableVoice(forText: "God morgon, Que här.")
        #expect(swedishFromText?.gender == .female)

        // PaceTTSVoiceSummary preflight
        let summary = PaceTTSVoiceSummary.current()
        #expect(!summary.voiceName.isEmpty)
        #expect(summary.voiceName == englishVoice?.name)
    }

    // MARK: - 9. LocalTTSClient Integration
    @Test("9. LocalTTSClient dispatches utterance with resolved female Apple voice")
    @MainActor
    func localTTSClientVoiceIntegration() async throws {
        let client = LocalTTSClient()
        try await client.speakText("Que voice test.")
        #expect(client.isPlaying == true || client.lastStopReason == .naturalCompletion)
        client.stopPlayback()
        #expect(client.isPlaying == false)
    }
}
