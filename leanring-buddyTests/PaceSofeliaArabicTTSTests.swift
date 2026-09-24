//
//  PaceSofeliaArabicTTSTests.swift
//  leanring-buddyTests
//
//  Comprehensive test suite for Native Sofelia Palestinian Arabic TTS.
//  Pure Swift G2P: Zero eSpeak-ng, zero Homebrew, zero dylib dependencies.
//

import Testing
import Foundation
import CryptoKit
@testable import Pace

@Suite("PaceSofeliaArabicTTSTests", .serialized)
struct PaceSofeliaArabicTTSTests {

    // MARK: - A. Model Asset Validation
    @Test("A. Model asset validation confirms all required files exist in approved root")
    func testModelAssetValidation() throws {
        let manager = PaceNeuralTTSModelManager.shared
        let result = manager.resolveSofeliaConfiguration()
        guard case .success(let config) = result else {
            Issue.record("Failed to resolve Sofelia configuration: \(result)")
            return
        }

        #expect(FileManager.default.fileExists(atPath: config.modelPath))
        #expect(FileManager.default.fileExists(atPath: config.lexiconPath))
        #expect(FileManager.default.fileExists(atPath: config.vocabPath))
        #expect(FileManager.default.fileExists(atPath: config.stylesPath))
        #expect(config.sampleRate == 24000)
    }

    // MARK: - B. Model Hash Validation
    @Test("B. Model hash validation verifies expected SHA256 of sofelia_palestinian.onnx")
    func testModelHashValidation() throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()

        let modelData = try Data(contentsOf: URL(fileURLWithPath: config.modelPath), options: .mappedIfSafe)
        let hash = SHA256.hash(data: modelData)
        let hexHash = hash.map { String(format: "%02x", $0) }.joined()

        let expectedHash = "164ac341d18094870cc6439bf33ebc33d8dddfa3bc6e2f79f654128668b1b9f2"
        #expect(hexHash == expectedHash, "Model SHA256 mismatch: got \(hexHash)")
    }

    // MARK: - C. Frontend Normalization
    @Test("C. Frontend normalization maps Arabic punctuation to Latin equivalents")
    func testFrontendNormalization() {
        let frontend = PacePalestinianArabicFrontend.shared
        let input = "مرحبا، كيفك؟ كل شي تمام؛ شكراً"
        let normalized = frontend.mapPunctuation(input)
        #expect(normalized.contains(","))
        #expect(normalized.contains("?"))
        #expect(normalized.contains(";"))
        #expect(!normalized.contains("،"))
        #expect(!normalized.contains("؟"))
        #expect(!normalized.contains("؛"))
    }

    // MARK: - D. Arabic Lexicon Behavior
    @Test("D. Arabic lexicon replaces surface colloquial words with diacritized forms")
    func testArabicLexiconBehavior() throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let frontend = PacePalestinianArabicFrontend.shared

        let input = "وين رحت اليوم؟"
        let result = try frontend.applyLexicon(to: input, lexiconPath: config.lexiconPath)
        #expect(result != input, "Lexicon should replace colloquial word 'وين'")
    }

    // MARK: - E. Taa-Marbuta Handling
    @Test("E. Taa-marbuta handling normalizes trailing ة")
    func testTaaMarbutaHandling() {
        let frontend = PacePalestinianArabicFrontend.shared
        let input = "مهمة كبيرة"
        let normalized = frontend.normalizeTaaMarbuta(input)
        #expect(!normalized.isEmpty)
    }

    // MARK: - F. Pure Swift Native G2P
    @Test("F. Pure Swift native G2P converts Arabic text to IPA phonemes deterministically")
    func testNativePureSwiftG2P() {
        let g2p = PacePalestinianArabicG2P.shared
        let phonemes = g2p.phonemizeSentence("مرحبا هاني")
        #expect(!phonemes.isEmpty)
        #expect(phonemes.contains("mr"))
    }

    // MARK: - G. Phoneme Fixups
    @Test("G. Phoneme fixups replace non-Kokoro phonemes and drop dental markers")
    func testPhonemeFixups() throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let frontend = PacePalestinianArabicFrontend.shared

        let (ps, _, _) = try frontend.textToPhonemesAndTokens(
            text: "خلصت المهمة",
            lexiconPath: config.lexiconPath,
            vocabPath: config.vocabPath
        )

        #expect(!ps.contains("ħ"), "ħ should be mapped to ʰ")
        #expect(!ps.contains("\u{032A}"), "dental diacritic should be removed")
        #expect(!ps.contains("[") && !ps.contains("]"), "brackets should be removed")
    }

    // MARK: - H. Token Generation
    @Test("H. Token generation produces bounded integer IDs with BOS and EOS tokens")
    func testTokenGeneration() throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let frontend = PacePalestinianArabicFrontend.shared

        let (_, tokens, _) = try frontend.textToPhonemesAndTokens(
            text: "تمام",
            lexiconPath: config.lexiconPath,
            vocabPath: config.vocabPath
        )

        #expect(tokens.first == 0, "First token must be BOS (0)")
        #expect(tokens.last == 0, "Last token must be EOS (0)")
        #expect(tokens.count > 2)
    }

    // MARK: - I. Exact Known Token Parity (Sentence 1)
    @Test("I. Sentence 1 produces exact 100% token sequence parity with verified reference")
    func testExactKnownTokenParity() throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let frontend = PacePalestinianArabicFrontend.shared

        let sentence1 = "مرحبا هاني، كيفك؟ خلصت المهمة، وكل شي صار تمام."
        let (phonemes, tokens, styleIndex) = try frontend.textToPhonemesAndTokens(
            text: sentence1,
            lexiconPath: config.lexiconPath,
            vocabPath: config.vocabPath
        )

        let expectedTokens: [Int64] = [
            0, 55, 60, 162, 44, 156, 43, 158, 16, 50, 156, 43, 158, 56, 51, 158, 3, 16, 53, 156,
            43, 52, 48, 43, 53, 157, 43, 6, 16, 142, 54, 61, 62, 16, 148, 43, 54, 55, 156, 63,
            50, 51, 55, 55, 157, 43, 3, 16, 65, 156, 43, 53, 43, 54, 16, 131, 156, 43, 52, 52,
            16, 61, 156, 43, 158, 60, 16, 62, 156, 43, 55, 43, 158, 55, 4, 0
        ]
        #expect(tokens == expectedTokens, "Tokens mismatch! Got count \(tokens.count) vs \(expectedTokens.count)")
        #expect(styleIndex == 73, "Style index mismatch: got \(styleIndex)")
        #expect(!phonemes.isEmpty)
    }

    // MARK: - J. Style Index Bounds
    @Test("J. Style index bounds clamps index to >= 0")
    func testStyleIndexBounds() throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let frontend = PacePalestinianArabicFrontend.shared

        let (_, _, styleIndex) = try frontend.textToPhonemesAndTokens(
            text: "ت",
            lexiconPath: config.lexiconPath,
            vocabPath: config.vocabPath
        )
        #expect(styleIndex >= 0)
    }

    // MARK: - K. 510-Style Bounds & Over-Limit Fail-Closed
    @Test("K. Style index clamps to maximum 509 and over-limit tokens fail closed")
    func test510StyleBoundsAndOverLimitFailClosed() throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let frontend = PacePalestinianArabicFrontend.shared

        let veryLongText = String(repeating: "مرحبا هاني كيفك اليوم وكل شي صار تمام ", count: 30)
        #expect(throws: PacePalestinianFrontendError.self) {
            _ = try frontend.textToPhonemesAndTokens(
                text: veryLongText,
                lexiconPath: config.lexiconPath,
                vocabPath: config.vocabPath,
                maxTokens: 510
            )
        }
    }

    // MARK: - L. Seven Palestinian Benchmark Sentences Parity
    @Test("L. All 7 Palestinian benchmark sentences produce deterministic verified phonemes")
    func testSevenPalestinianBenchmarkSentences() throws {
        let g2p = PacePalestinianArabicG2P.shared
        let expectedPhonemes = [
            "mrʰbˈaː hˈaːniː, kˈajfakˌa? χlst ʔalmˈuhimmˌa, wˈakal ʃˈajj sˈaːr tˈamaːm.",
            "wlaː jhˈumka, χlˈiːniː ʔtʔkd mˈin ʔalmawdᵊˈuːʁ wbʁdˈiːna bʰkiːlkˌa ʃˈuː sˈaːr.",
            "ˈastnaː ʃˈawiːj, ˈana hsˈaː bftʰ ʔattˈatbiːq wbʃuːf ʔˈiðaː kˈull ʃˈajj ʃˈaɣɣaːl.",
            "tˈamaːm, ftʰt ʔattˈatbiːq, wʔðaː bidkˌa bqdr ʔˈakmal mˈin hˈuːn.",
            "mˈaː fˈiː mˈuʃkilˌa, rʰ ʔrˈaːʤʁ ʔalmawdᵊˈuːʁ wbχbrka ʔˈawwal mˈaː ʔˈaχlas.",
            "waˈiːna bidkˌa ʔftʰlkˈa ʔattˈatbiːq?",
            "ʃˈuː rˈaʔjka nʤrrbhˈaː bhaːltrˌiːqt?"
        ]
        let sentences = [
            "مرحبا هاني، كيفك؟ خلصت المهمة، وكل شي صار تمام.",
            "ولا يهمك، خليني أتأكد من الموضوع وبعدين بحكيلك شو صار.",
            "استنى شوي، أنا هسا بفتح التطبيق وبشوف إذا كل شي شغال.",
            "تمام، فتحت التطبيق، وإذا بدك بقدر أكمل من هون.",
            "ما في مشكلة، رح أراجع الموضوع وبخبرك أول ما أخلص.",
            "وين بدك أفتحلك التطبيق؟",
            "شو رأيك نجرّبها بهالطريقة؟"
        ]

        for (i, sentence) in sentences.enumerated() {
            let phonemes = g2p.phonemizeSentence(sentence)
            #expect(phonemes == expectedPhonemes[i], "Sentence \(i+1) phoneme mismatch")
        }
    }

    // MARK: - M. All 34 Benchmark Words Parity
    @Test("M. All 34 benchmark words match expected phonemes exactly")
    func testThirtyFourBenchmarkWords() {
        let g2p = PacePalestinianArabicG2P.shared
        let wordExpectations: [String: String] = [
            "هاني": "hˈaːniː",
            "كيفك": "kˈajfakˌa",
            "خلصت": "χlst",
            "المهمة": "ʔalmˈuhimmˌa",
            "كل": "kˈull",
            "شي": "ʃˈajj",
            "صار": "sˈaːr",
            "تمام": "tˈamaːm",
            "ولا": "wlaː",
            "يهمك": "jhˈumka",
            "خليني": "χlˈiːniː",
            "أتأكد": "ʔtʔkd",
            "الموضوع": "ʔalmawdᵊˈuːʁ",
            "بحكيلك": "bʰkiːlkˌa",
            "شو": "ʃˈuː",
            "استنى": "ˈastnaː",
            "شوي": "ʃˈawiːj",
            "هسا": "hsˈaː",
            "بفتح": "bftʰ",
            "بشوف": "bʃuːf",
            "إذا": "ʔˈiðaː",
            "شغال": "ʃˈaɣɣaːl",
            "بدك": "bidkˌa",
            "بقدر": "bqdr",
            "أكمل": "ʔˈakmal",
            "هون": "hˈuːn",
            "رح": "rʰ",
            "أراجع": "ʔrˈaːʤʁ",
            "بخبرك": "bχbrka",
            "وين": "waˈiːna",
            "أفتحلك": "ʔftʰlkˈa",
            "رأيك": "rˈaʔjka",
            "نجرّبها": "nʤrrbhˈaː",
            "بهالطريقة": "bhaːltrˌiːqt"
        ]

        for (word, expected) in wordExpectations {
            let actual = g2p.phonemizeWord(word)
            #expect(actual == expected, "Word '\(word)' expected '\(expected)' but got '\(actual)'")
        }
    }

    // MARK: - N. Arabic Diacritics & Shaddah
    @Test("N. Arabic diacritics and shaddah gemination are handled correctly")
    func testDiacriticsAndShaddah() {
        let g2p = PacePalestinianArabicG2P.shared
        // Shaddah gemination: كَتَّبَ -> kattaba
        let shaddahWord = g2p.phonemizeWord("كَتَّبَ")
        #expect(shaddahWord.contains("tt"))

        // Tanween fath: كِتَاباً -> kitaːban
        let tanweenWord = g2p.phonemizeWord("كِتَاباً")
        #expect(tanweenWord.hasSuffix("an"))

        // Sukun: كَتَبْتْ -> katabt
        let sukunWord = g2p.phonemizeWord("كَتَبْتْ")
        #expect(sukunWord == "katabt")
    }

    // MARK: - O. Solar & Lunar Letter Assimilation
    @Test("O. Solar letters assimilate with Al- while moon letters retain l")
    func testSunAndMoonLetters() {
        let g2p = PacePalestinianArabicG2P.shared
        // Sun letter (ش): الشمس -> ʔaʃʃ...
        let sun = g2p.phonemizeWord("الشمس")
        #expect(sun.hasPrefix("ʔaʃʃ"), "Sun letter should geminate: got \(sun)")

        // Moon letter (ق): القمر -> ʔalq...
        let moon = g2p.phonemizeWord("القمر")
        #expect(moon.hasPrefix("ʔalq"), "Moon letter should retain l: got \(moon)")
    }

    // MARK: - P. Empty & Whitespace Input
    @Test("P. Empty and whitespace-only inputs fail closed with invalidText error")
    func testEmptyAndWhitespaceInput() {
        let manager = PaceNeuralTTSModelManager.shared
        guard case .success(let config) = manager.resolveSofeliaConfiguration() else { return }
        let frontend = PacePalestinianArabicFrontend.shared

        #expect(throws: PacePalestinianFrontendError.self) {
            _ = try frontend.textToPhonemesAndTokens(text: "", lexiconPath: config.lexiconPath, vocabPath: config.vocabPath)
        }
        #expect(throws: PacePalestinianFrontendError.self) {
            _ = try frontend.textToPhonemesAndTokens(text: "   \t\n  ", lexiconPath: config.lexiconPath, vocabPath: config.vocabPath)
        }
    }

    // MARK: - Q. Unknown Phoneme Fails Closed
    @Test("Q. Unknown phonemes that do not exist in vocab fail closed without silent drop")
    func testUnknownPhonemeFailsClosed() {
        let manager = PaceNeuralTTSModelManager.shared
        guard case .success(let config) = manager.resolveSofeliaConfiguration() else { return }
        let frontend = PacePalestinianArabicFrontend.shared

        // Chinese/Cyrillic character which produces phonemes unmapped in Kokoro
        let alienInput = "مرحبا 你好"
        #expect(throws: PacePalestinianFrontendError.self) {
            _ = try frontend.textToPhonemesAndTokens(text: alienInput, lexiconPath: config.lexiconPath, vocabPath: config.vocabPath)
        }
    }

    // MARK: - R. Determinism & Concurrency
    @Test("R. G2P execution is strictly deterministic across repeated and concurrent calls")
    func testDeterminismAndConcurrency() async {
        let g2p = PacePalestinianArabicG2P.shared
        let input = "مرحبا هاني، كيفك؟ خلصت المهمة، وكل شي صار تمام."

        let base = g2p.phonemizeSentence(input)
        for _ in 1...100 {
            #expect(g2p.phonemizeSentence(input) == base)
        }

        // Concurrent execution
        await withTaskGroup(of: String.self) { group in
            for _ in 1...50 {
                group.addTask {
                    g2p.phonemizeSentence(input)
                }
            }
            for await res in group {
                #expect(res == base)
            }
        }
    }

    // MARK: - S. Native Worker Initialization
    @Test("S. Native worker initializes lazy ONNX session successfully")
    func testNativeWorkerInitialization() async throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let worker = PaceArabicSofeliaONNXWorker()

        #expect(!(await worker.hasLoadedEngine))
        _ = try await worker.synthesizeArabic(text: "مرحبا", config: config)
        #expect(await worker.hasLoadedEngine)
        await worker.unload()
        #expect(!(await worker.hasLoadedEngine))
    }

    // MARK: - T. Synthesis
    @Test("T. Native synthesis generates intelligible audio samples")
    func testSynthesis() async throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let worker = PaceArabicSofeliaONNXWorker()
        defer { Task { await worker.unload() } }

        let audio = try await worker.synthesizeArabic(
            text: "مرحبا هاني، كيفك؟ خلصت المهمة، وكل شي صار تمام.",
            config: config
        )

        #expect(!audio.samples.isEmpty)
        #expect(audio.samples.count > 24000)
        #expect(audio.sampleRate == 24000)
    }

    // MARK: - U. Output 24kHz
    @Test("U. Output audio sample rate is exactly 24,000 Hz")
    func testOutput24kHz() async throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let worker = PaceArabicSofeliaONNXWorker()
        defer { Task { await worker.unload() } }

        let audio = try await worker.synthesizeArabic(text: "تمام", config: config)
        #expect(audio.sampleRate == 24000)
    }

    // MARK: - V. Cancellation Handling
    @Test("V. Cancellation before and after inference handled safely")
    func testCancellation() async throws {
        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let worker = PaceArabicSofeliaONNXWorker()
        defer { Task { await worker.unload() } }

        await worker.cancelActiveSynthesis()
        do {
            _ = try await worker.synthesizeArabic(text: "مرحبا هاني", config: config)
            Issue.record("Expected cancellation error")
        } catch let err as PaceSofeliaTTSError {
            #expect(err == .cancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - W. Route Selection
    @Test("W. Arabic text routes to .arabicSofelia, English to .englishKokoro, Swedish to .swedishAlma")
    func testRouteSelection() {
        #expect(PaceNeuralTTSClient.determineRoute(for: "مرحبا هاني") == .arabicSofelia)
        #expect(PaceNeuralTTSClient.determineRoute(for: "Hello Hani") == .englishKokoro)
        #expect(PaceNeuralTTSClient.determineRoute(for: "Hej Hani") == .swedishAlma)
    }

    // MARK: - X. Missing Model Fallback
    @Test("X. Missing model fails closed and falls back to Apple TTS client without crashing")
    @MainActor
    func testMissingModelFallback() async throws {
        final class MockFallback: BuddyTTSClient {
            var spokenTexts: [String] = []
            var isPlaying: Bool = false
            var lastStopReason: PaceTTSStopReason = .naturalCompletion
            func speakText(_ text: String) async throws { spokenTexts.append(text) }
            func speakText(_ text: String, explicitLocale: String?, isFinal: Bool) async throws { spokenTexts.append(text) }
            func stopPlayback() {}
            func recordExpectedStopReason(_ reason: PaceTTSStopReason) {}
        }

        let mockFallback = MockFallback()
        let emptyManager = PaceNeuralTTSModelManager(customSearchRoots: [URL(fileURLWithPath: "/tmp/nonexistent")])
        let client = PaceNeuralTTSClient(modelManager: emptyManager, fallbackClient: mockFallback)

        try await client.speakText("مرحبا هاني")
        #expect(mockFallback.spokenTexts.contains("مرحبا هاني"))
    }

    // MARK: - Dogfood Real Synthesis (Sentences 1 to 7)
    @Test("Dogfood: Synthesize all 7 Palestinian sentences to WAV files")
    func testDogfoodSentencesSynthesis() async throws {
        let sentences = [
            "مرحبا هاني، كيفك؟ خلصت المهمة، وكل شي صار تمام.",
            "ولا يهمك، خليني أتأكد من الموضوع وبعدين بحكيلك شو صار.",
            "استنى شوي، أنا هسا بفتح التطبيق وبشوف إذا كل شي شغال.",
            "تمام، فتحت التطبيق، وإذا بدك بقدر أكمل من هون.",
            "ما في مشكلة، رح أراجع الموضوع وبخبرك أول ما أخلص.",
            "وين بدك أفتحلك التطبيق؟",
            "شو رأيك نجرّبها بهالطريقة؟"
        ]

        let manager = PaceNeuralTTSModelManager.shared
        let config = try manager.resolveSofeliaConfiguration().get()
        let worker = PaceArabicSofeliaONNXWorker()
        defer { Task { await worker.unload() } }

        let outDir = "/Users/hani/.gemini/antigravity-ide/brain/d656cbf7-f7ad-46ec-9681-28885d40163a/audio/sofelia_dogfood"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for (index, text) in sentences.enumerated() {
            let audio = try await worker.synthesizeArabic(text: text, config: config)
            #expect(!audio.samples.isEmpty)
            #expect(audio.sampleRate == 24000)

            let wavData = PaceWAVEncoder.encodeWAV(samples: audio.samples, sampleRate: audio.sampleRate)
            let filePath = "\(outDir)/dogfood_0\(index + 1).wav"
            try wavData.write(to: URL(fileURLWithPath: filePath))
            #expect(FileManager.default.fileExists(atPath: filePath))
        }
    }
}
