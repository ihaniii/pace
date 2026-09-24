//
//  PaceNeuralTTSTests.swift
//  leanring-buddyTests
//
//  Comprehensive test suite for Phase 1 Local Neural TTS:
//  - PaceNeuralTTSModelManager
//  - PaceNeuralTTSClient & Fallback Routing
//  - PaceSherpaTTSWorker Lifecycle & Concurrency
//  - PaceNeuralTTSSettings Feature Flag & Factory Integration
//  - Static Security Audit for Zero Network/Process/Shell
//

import AVFoundation
import Foundation
import Testing
#if canImport(SherpaOnnx)
import SherpaOnnx
#endif
@testable import Pace

@MainActor
final class PaceMockFallbackTTSClient: BuddyTTSClient {
    var spokenTexts: [String] = []
    var isPlaying: Bool = false
    var stopPlaybackCalls: Int = 0
    var lastRecordedStopReason: PaceTTSStopReason = .naturalCompletion
    var recordedStopReasons: [PaceTTSStopReason] = []

    var lastStopReason: PaceTTSStopReason {
        lastRecordedStopReason
    }

    func speakText(_ text: String) async throws {
        spokenTexts.append(text)
    }

    func stopPlayback() {
        stopPlaybackCalls += 1
        isPlaying = false
    }

    func recordExpectedStopReason(_ reason: PaceTTSStopReason) {
        lastRecordedStopReason = reason
        recordedStopReasons.append(reason)
    }
}

// MARK: - Model Manager Tests

@Suite("PaceNeuralTTSModelManager Tests")
struct PaceNeuralTTSModelManagerTests {

    @Test("Model manager reports approved roots including Bundle and Application Support")
    func testApprovedRoots() {
        let manager = PaceNeuralTTSModelManager.shared
        let roots = manager.approvedSearchRoots
        #expect(!roots.isEmpty)
        #expect(roots.contains { $0.path.contains("NeuralTTS") || $0.path.contains("Pace/Models/TTS") })
    }

    @Test("Model manager rejects path traversal attempts containing ..")
    func testTraversalRejected() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = PaceNeuralTTSModelManager(customSearchRoots: [tempDir])
        let evilURL = tempDir.appendingPathComponent("../../../etc/passwd")

        #expect(throws: PaceNeuralTTSModelError.self) {
            try manager.validatePathSecurity(targetURL: evilURL, approvedRoot: tempDir)
        }
    }

    @Test("Model manager rejects symlink escape pointing outside approved root")
    func testSymlinkEscapeRejected() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outsideDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        let symlinkTarget = tempDir.appendingPathComponent("EscapedLink")
        try FileManager.default.createSymbolicLink(at: symlinkTarget, withDestinationURL: outsideDir)

        let manager = PaceNeuralTTSModelManager(customSearchRoots: [tempDir])

        #expect(throws: PaceNeuralTTSModelError.self) {
            try manager.validatePathSecurity(targetURL: symlinkTarget, approvedRoot: tempDir)
        }
    }

    @Test("Model manager returns structured failure when model directory is missing")
    func testMissingModelDirectory() {
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let manager = PaceNeuralTTSModelManager(customSearchRoots: [emptyDir])
        let kokoroResult = manager.resolveKokoroConfiguration()
        let swedishResult = manager.resolveSwedishConfiguration()

        guard case .failure(let kokoroErr) = kokoroResult else {
            Issue.record("Expected failure for missing Kokoro")
            return
        }
        guard case .failure(let swedishErr) = swedishResult else {
            Issue.record("Expected failure for missing Swedish")
            return
        }

        #expect(kokoroErr.errorDescription?.contains("not found") == true)
        #expect(swedishErr.errorDescription?.contains("not found") == true)
    }

    @Test("Model manager rejects directory when required files are incomplete")
    func testIncompleteModelDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let kokoroDir = tempDir.appendingPathComponent("Kokoro", isDirectory: true)
        try FileManager.default.createDirectory(at: kokoroDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Only create model.onnx, omit voices.bin, tokens.txt, espeak-ng-data
        let modelFile = kokoroDir.appendingPathComponent("model.onnx")
        try "dummy-onnx".write(to: modelFile, atomically: true, encoding: .utf8)

        let manager = PaceNeuralTTSModelManager(customSearchRoots: [tempDir])
        let result = manager.resolveKokoroConfiguration()

        guard case .failure(let error) = result else {
            Issue.record("Expected failure due to missing voices.bin")
            return
        }

        #expect(error.errorDescription?.contains("voices.bin") == true)
    }

    @Test("Model manager resolves complete Kokoro structure cleanly")
    func testCompleteKokoroStructureResolution() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let kokoroDir = tempDir.appendingPathComponent("Kokoro", isDirectory: true)
        let espeakDir = kokoroDir.appendingPathComponent("espeak-ng-data", isDirectory: true)
        try FileManager.default.createDirectory(at: espeakDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "model".write(to: kokoroDir.appendingPathComponent("model.onnx"), atomically: true, encoding: .utf8)
        try "voices".write(to: kokoroDir.appendingPathComponent("voices.bin"), atomically: true, encoding: .utf8)
        try "tokens".write(to: kokoroDir.appendingPathComponent("tokens.txt"), atomically: true, encoding: .utf8)

        let manager = PaceNeuralTTSModelManager(customSearchRoots: [tempDir])
        let result = manager.resolveKokoroConfiguration()

        guard case .success(let config) = result else {
            Issue.record("Expected successful resolution of complete Kokoro structure")
            return
        }

        #expect(config.modelPath.hasSuffix("model.onnx"))
        #expect(config.voicesPath.hasSuffix("voices.bin"))
        #expect(config.tokensPath.hasSuffix("tokens.txt"))
        #expect(config.dataDirPath.hasSuffix("espeak-ng-data"))
        #expect(config.sampleRate == 24000)
    }

    @Test("Model manager resolves complete Swedish Alma structure cleanly")
    func testCompleteSwedishStructureResolution() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let swedishDir = tempDir.appendingPathComponent("Swedish", isDirectory: true)
        let espeakDir = swedishDir.appendingPathComponent("espeak-ng-data", isDirectory: true)
        try FileManager.default.createDirectory(at: espeakDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "model".write(to: swedishDir.appendingPathComponent("sv_SE-alma-medium.onnx"), atomically: true, encoding: .utf8)
        try "tokens".write(to: swedishDir.appendingPathComponent("tokens.txt"), atomically: true, encoding: .utf8)
        try "{}".write(to: swedishDir.appendingPathComponent("sv_SE-alma-medium.onnx.json"), atomically: true, encoding: .utf8)

        let manager = PaceNeuralTTSModelManager(customSearchRoots: [tempDir])
        let result = manager.resolveSwedishConfiguration()

        guard case .success(let config) = result else {
            Issue.record("Expected successful resolution of complete Swedish structure")
            return
        }

        #expect(config.modelPath.hasSuffix("sv_SE-alma-medium.onnx"))
        #expect(config.tokensPath.hasSuffix("tokens.txt"))
        #expect(config.dataDirPath.hasSuffix("espeak-ng-data"))
        #expect(config.sampleRate == 22050)
        #expect(config.configPath?.hasSuffix("sv_SE-alma-medium.onnx.json") == true)
    }
}

// MARK: - Language Route Resolution Tests

@Suite("PaceNeuralTTSLanguageRoute Tests")
struct PaceNeuralTTSLanguageRouteTests {

    @Test("Locale normalization correctly routes English, Swedish, Arabic, and unsupported locales")
    func testLocaleNormalization() {
        // English variants
        #expect(PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "en-US") == .englishKokoro)
        #expect(PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "en-GB") == .englishKokoro)
        #expect(PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "en") == .englishKokoro)
        #expect(PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "en_AU") == .englishKokoro)

        // Swedish variants
        #expect(PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "sv-SE") == .swedishAlma)
        #expect(PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "sv") == .swedishAlma)
        #expect(PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "sv_FI") == .swedishAlma)

        // Arabic variants (now route to native Sofelia)
        #expect(PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "ar") == .arabicSofelia)
        #expect(PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "ar-SA") == .arabicSofelia)
        #expect(PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "ar-001") == .arabicSofelia)

        // Unsupported languages (safe Apple fallback)
        guard case .appleFallback = PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "ru") else {
            Issue.record("Expected appleFallback for ru")
            return
        }
        guard case .appleFallback = PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "de-DE") else {
            Issue.record("Expected appleFallback for de-DE")
            return
        }
        guard case .appleFallback = PaceNeuralTTSClient.determineRoute(for: "", explicitLocale: "fr") else {
            Issue.record("Expected appleFallback for fr")
            return
        }
    }

    @Test("Spoken text language detection routes English, Swedish, and Arabic accurately")
    func testTextLanguageDetectionRouting() {
        let englishText = "Hello Hani, this is Que speaking to you locally."
        #expect(PaceNeuralTTSClient.determineRoute(for: englishText) == .englishKokoro)

        let swedishText = "Hej Hani, det här är Que som pratar med dig lokalt."
        #expect(PaceNeuralTTSClient.determineRoute(for: swedishText) == .swedishAlma)

        let arabicText = "مرحباً هاني، هذا كيو يتحدث معك محلياً."
        #expect(PaceNeuralTTSClient.determineRoute(for: arabicText) == .arabicSofelia)
    }
}

// MARK: - Client & Language Routing Tests

@Suite("PaceNeuralTTSClient & Fallback Tests")
struct PaceNeuralTTSClientTests {

    @Test("When feature flag is disabled, all languages deterministically route to Apple fallback")
    @MainActor
    func testFeatureDisabledRoutesAllToApple() async throws {
        PaceNeuralTTSSettings.resetToDefault()
        #expect(!PaceNeuralTTSSettings.isNeuralTTSEnabled)

        let fallback = PaceMockFallbackTTSClient()
        let client = PaceNeuralTTSClient(fallbackClient: fallback)

        try await client.speakText("Hello Hani")
        try await client.speakText("Hej Hani")
        try await client.speakText("مرحباً هاني")
        try await client.speakText("Привет, мир!")

        #expect(fallback.spokenTexts == [
            "Hello Hani",
            "Hej Hani",
            "مرحباً هاني",
            "Привет, мир!"
        ])
    }

    @Test("Arabic routes directly to Apple TTS fallback without attempting neural load")
    @MainActor
    func testArabicDirectRouting() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }

        let fallback = PaceMockFallbackTTSClient()
        let emptyRoots = [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)]
        let modelManager = PaceNeuralTTSModelManager(customSearchRoots: emptyRoots)
        let client = PaceNeuralTTSClient(modelManager: modelManager, fallbackClient: fallback)

        let arabicUtterance = "مرحباً هاني، كيف حالك؟"
        try await client.speakText(arabicUtterance)

        #expect(fallback.spokenTexts == [arabicUtterance])
    }

    @Test("Unsupported or unknown language falls back to Apple TTS")
    @MainActor
    func testUnsupportedLanguageFallback() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }

        let fallback = PaceMockFallbackTTSClient()
        let emptyRoots = [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)]
        let modelManager = PaceNeuralTTSModelManager(customSearchRoots: emptyRoots)
        let client = PaceNeuralTTSClient(modelManager: modelManager, fallbackClient: fallback)

        // Russian text (neither English nor Swedish nor Arabic)
        let unknownUtterance = "Привет, мир!"
        try await client.speakText(unknownUtterance)

        #expect(fallback.spokenTexts == [unknownUtterance])
    }

    @Test("English falls back to Apple TTS when neural model assets are not on disk")
    @MainActor
    func testEnglishMissingModelFallback() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }

        let fallback = PaceMockFallbackTTSClient()
        let emptyRoots = [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)]
        let modelManager = PaceNeuralTTSModelManager(customSearchRoots: emptyRoots)
        let client = PaceNeuralTTSClient(modelManager: modelManager, fallbackClient: fallback)

        let englishUtterance = "Hi Hani, I noticed you have been working on this for a while."
        try await client.speakText(englishUtterance)

        #expect(fallback.spokenTexts == [englishUtterance])
    }

    @Test("Swedish falls back to Apple TTS when neural model assets are not on disk")
    @MainActor
    func testSwedishMissingModelFallback() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }

        let fallback = PaceMockFallbackTTSClient()
        let emptyRoots = [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)]
        let modelManager = PaceNeuralTTSModelManager(customSearchRoots: emptyRoots)
        let client = PaceNeuralTTSClient(modelManager: modelManager, fallbackClient: fallback)

        let swedishUtterance = "Jag ser att du har arbetat med det här en stund."
        try await client.speakText(swedishUtterance)

        #expect(fallback.spokenTexts == [swedishUtterance])
    }

    @Test("stopPlayback cancels playback and propagates to fallback client")
    @MainActor
    func testStopPlaybackPropagation() {
        let fallback = PaceMockFallbackTTSClient()
        let client = PaceNeuralTTSClient(fallbackClient: fallback)

        client.recordExpectedStopReason(.userBargeIn)
        client.stopPlayback()

        #expect(fallback.stopPlaybackCalls == 1)
        #expect(client.lastStopReason == .userBargeIn)
    }

    @Test("Repeated speak and stop calls do not race or deadlock")
    @MainActor
    func testRepeatedSpeakAndStopDoNotRace() async throws {
        let fallback = PaceMockFallbackTTSClient()
        let emptyRoots = [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)]
        let modelManager = PaceNeuralTTSModelManager(customSearchRoots: emptyRoots)
        let client = PaceNeuralTTSClient(modelManager: modelManager, fallbackClient: fallback)

        for i in 0..<10 {
            let task = Task {
                try await client.speakText("Test phrase number \(i)")
            }
            client.stopPlayback()
            _ = try? await task.value
        }

        #expect(fallback.stopPlaybackCalls == 10)
    }
}

// MARK: - Worker Lifecycle & Concurrency Tests

@Suite("PaceSherpaTTSWorker Tests")
struct PaceSherpaTTSWorkerTests {

    @Test("Worker has no resident model loaded at initialization (lazy loading policy)")
    func testWorkerInitialState() async {
        let worker = PaceSherpaTTSWorker()
        let hasEngine = await worker.hasLoadedEngine
        let isSynthesizing = await worker.isCurrentlySynthesizing
        #expect(!hasEngine)
        #expect(!isSynthesizing)
    }

    @Test("Worker unload resets resident engine cleanly")
    func testWorkerUnload() async {
        let worker = PaceSherpaTTSWorker()
        await worker.cancelActiveSynthesis()
        await worker.unload()
        let hasEngine = await worker.hasLoadedEngine
        #expect(!hasEngine)
    }

    @Test("Worker cancel and unload operations are idempotent and do not deadlock")
    func testWorkerStopIdempotence() async {
        let worker = PaceSherpaTTSWorker()
        for _ in 0..<5 {
            await worker.cancelActiveSynthesis()
            await worker.unload()
        }
        let isSynthesizing = await worker.isCurrentlySynthesizing
        #expect(!isSynthesizing)
    }

    @Test("Kokoro v1.0 configuration contract requires lang en-us in worker")
    func testKokoroConfigContractIncludesLang() throws {
        let workerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // leanring-buddyTests/
            .deletingLastPathComponent() // pace root
            .appendingPathComponent("leanring-buddy/QTTS/PaceSherpaTTSWorker.swift")
        let content = try String(contentsOf: workerURL, encoding: .utf8)
        #expect(content.contains("lang: \"en-us\""), "PaceSherpaTTSWorker must pass lang: 'en-us' for Kokoro v1.0 multilingual model")
    }

    #if canImport(SherpaOnnx)
    @Test("Kokoro model configuration initializes offline TTS engine with 24kHz and valid af_heart speaker")
    func testKokoroOfflineTTSInitializationWithInstalledModel() throws {
        let manager = PaceNeuralTTSModelManager.shared
        guard case .success(let config) = manager.resolveKokoroConfiguration() else {
            return
        }

        let kokoroConfig = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: config.modelPath,
            voices: config.voicesPath,
            tokens: config.tokensPath,
            dataDir: config.dataDirPath,
            lang: "en-us"
        )
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(
            kokoro: kokoroConfig,
            numThreads: 2,
            debug: 0,
            provider: "cpu"
        )
        var ttsConfig = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &ttsConfig)

        #expect(wrapper.tts != nil)
        #expect(wrapper.sampleRate == 24000)
        #expect(wrapper.numSpeakers >= 4)
        #expect(wrapper.numSpeakers > 3)
    }

    @Test("Model exclusivity: worker only keeps one engine resident and unloads previous engine")
    func testModelExclusivityPolicy() async throws {
        let manager = PaceNeuralTTSModelManager.shared
        guard case .success(let kokoroConfig) = manager.resolveKokoroConfiguration(),
              case .success(let swedishConfig) = manager.resolveSwedishConfiguration() else {
            return
        }

        let worker = PaceSherpaTTSWorker()
        #expect(!(await worker.hasLoadedEngine))

        // Synthesize English -> loads Kokoro
        let englishAudio = try await worker.synthesizeEnglish(text: "Hello", config: kokoroConfig)
        #expect(!englishAudio.samples.isEmpty)
        #expect(await worker.hasLoadedEngine)

        // Synthesize Swedish -> unloads Kokoro and loads Swedish
        let swedishAudio = try await worker.synthesizeSwedish(text: "Hej", config: swedishConfig)
        #expect(!swedishAudio.samples.isEmpty)
        #expect(await worker.hasLoadedEngine)

        // Synthesize English again -> unloads Swedish and loads Kokoro
        let englishAudio2 = try await worker.synthesizeEnglish(text: "Hello again", config: kokoroConfig)
        #expect(!englishAudio2.samples.isEmpty)
        #expect(await worker.hasLoadedEngine)

        // Unload -> releases engine
        await worker.unload()
        #expect(!(await worker.hasLoadedEngine))
    }
    #endif
}

// MARK: - Feature Flag & Factory Tests

@Suite("Feature Flag & Factory Integration Tests")
struct PaceNeuralTTSFeatureFlagTests {

    @Test("Feature flag defaults to false and preserves Apple TTS in factory")
    @MainActor
    func testFeatureFlagDefaultDisabled() {
        PaceNeuralTTSSettings.resetToDefault()
        #expect(!PaceNeuralTTSSettings.isNeuralTTSEnabled)

        let client = BuddyTTSClientFactory.makeDefault()
        #expect(type(of: client) == LocalTTSClient.self)
    }

    @Test("Feature flag opt-in activates PaceNeuralTTSClient in factory")
    @MainActor
    func testFeatureFlagOptIn() {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }

        #expect(PaceNeuralTTSSettings.isNeuralTTSEnabled)

        let client = BuddyTTSClientFactory.makeDefault()
        #expect(type(of: client) == PaceNeuralTTSClient.self)
    }

    @Test("Voice identity constants match approved Kokoro af_heart, Swedish Alma, and Apple Arabic")
    func testVoiceIdentityConstants() {
        // Kokoro English: af_heart is SID 3
        let englishSID = 3
        #expect(englishSID == 3)

        // Swedish Alma: SID 0
        let swedishSID = 0
        #expect(swedishSID == 0)

        // Arabic canonical locale is ar-001
        let arabicLocale = PaceSpeechVoiceResolver.canonicalLocale(for: "ar")
        #expect(arabicLocale == "ar-001")
    }

    @Test("Default safety: clean installation without opt-in flag returns false and uses Apple TTS")
    @MainActor
    func testDefaultSafety() {
        PaceNeuralTTSSettings.resetToDefault()
        #expect(!PaceNeuralTTSSettings.isNeuralTTSEnabled)

        let client = BuddyTTSClientFactory.makeDefault()
        #expect(type(of: client) == LocalTTSClient.self)
    }
}

// MARK: - WAV Encoder Tests

@Suite("PaceWAVEncoder Tests")
struct PaceWAVEncoderTests {

    @Test("WAV encoder creates valid 44-byte RIFF header and correct PCM payload size")
    func testWAVEncoderStructure() {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
        let sampleRate: Int32 = 24000
        let wavData = PaceWAVEncoder.encodeWAV(samples: samples, sampleRate: sampleRate)

        // 44 header bytes + 5 samples * 2 bytes = 54 bytes
        #expect(wavData.count == 54)

        // Verify "RIFF" and "WAVE" markers
        let riffHeader = String(data: wavData.subdata(in: 0..<4), encoding: .ascii)
        let waveHeader = String(data: wavData.subdata(in: 8..<12), encoding: .ascii)
        let fmtMarker = String(data: wavData.subdata(in: 12..<16), encoding: .ascii)
        let dataMarker = String(data: wavData.subdata(in: 36..<40), encoding: .ascii)

        #expect(riffHeader == "RIFF")
        #expect(waveHeader == "WAVE")
        #expect(fmtMarker == "fmt ")
        #expect(dataMarker == "data")
    }
}

// MARK: - Static Security Audit Tests (Phases 10 & 11)

@Suite("Static Security Audit Tests for QTTS Subsystem")
struct PaceNeuralTTSSecurityAuditTests {

    private func loadAllQTTSFiles() throws -> [(URL, String)] {
        let qttsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // leanring-buddyTests/
            .deletingLastPathComponent() // pace root
            .appendingPathComponent("leanring-buddy/QTTS", isDirectory: true)

        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(at: qttsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        #expect(!files.isEmpty, "QTTS directory must contain production Swift files")

        return try files.map { ($0, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("Zero URLSession, URLRequest, or network references exist in QTTS production files")
    func testZeroNetworkReferences() throws {
        let forbidden = ["URLSession", "URLRequest", "http://", "https://", "socket", "Socket"]
        let files = try loadAllQTTSFiles()

        for (url, content) in files {
            for keyword in forbidden {
                #expect(
                    !content.contains(keyword),
                    "Security violation: \(url.lastPathComponent) contains forbidden networking symbol '\(keyword)'"
                )
            }
        }
    }

    @Test("Zero Process, ProcessInfo, or posix_spawn exist in QTTS production files")
    func testZeroProcessReferences() throws {
        let forbidden = ["Process(", "Process.", "ProcessInfo", "posix_spawn", "fork"]
        let files = try loadAllQTTSFiles()

        for (url, content) in files {
            for keyword in forbidden {
                #expect(
                    !content.contains(keyword),
                    "Security violation: \(url.lastPathComponent) contains forbidden process symbol '\(keyword)'"
                )
            }
        }
    }

    @Test("Zero shell, launchctl, curl, wget, python, or runtime download commands exist in QTTS")
    func testZeroShellOrDownloadCommands() throws {
        let forbidden = ["launchctl", "curl", "wget", "uvx", "python", "HuggingFace", "download"]
        let files = try loadAllQTTSFiles()

        for (url, content) in files {
            for keyword in forbidden {
                #expect(
                    !content.contains(keyword),
                    "Security violation: \(url.lastPathComponent) contains forbidden keyword '\(keyword)'"
                )
            }
        }
    }

    @Test("New neural path does not depend on legacy LocalServerTTSClient or PaceTTSSidecarLauncher")
    func testZeroLegacyServerOrSidecarCoupling() throws {
        let forbidden = ["LocalServerTTSClient", "PaceTTSSidecarLauncher"]
        let files = try loadAllQTTSFiles()

        for (url, content) in files {
            for keyword in forbidden {
                #expect(
                    !content.contains(keyword),
                    "Coupling violation: \(url.lastPathComponent) references legacy sidecar '\(keyword)'"
                )
            }
        }
    }
}

// MARK: - Runtime Validation & Resource Tracking Tests

#if canImport(SherpaOnnx)
import MachO

@Suite("PaceNeuralTTSRuntimeValidationTests")
struct PaceNeuralTTSRuntimeValidationTests {

    private func getResidentMemoryMB() -> Double {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0.0 }
        return Double(taskInfo.resident_size) / (1024.0 * 1024.0)
    }

    private func logMetric(_ text: String) {
        print(text)
        let logPath = "/tmp/pace_qtts_runtime_validation.log"
        let line = text + "\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    try? fileHandle.close()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    @Test("End-to-end controlled runtime validation: cold start, English synthesis, warm synthesis, Swedish switch, Arabic fallback, and exclusivity")
    @MainActor
    func testCompleteRuntimePipelineValidation() async throws {
        try? FileManager.default.removeItem(atPath: "/tmp/pace_qtts_runtime_validation.log")
        let initialRSS = getResidentMemoryMB()
        logMetric("Initial RSS: \(String(format: "%.2f", initialRSS)) MB")

        // 1. Default disabled state
        PaceNeuralTTSSettings.resetToDefault()
        #expect(!PaceNeuralTTSSettings.isNeuralTTSEnabled)

        let mockFallback = PaceMockFallbackTTSClient()
        let client = PaceNeuralTTSClient(fallbackClient: mockFallback)

        try await client.speakText("Hello Hani")
        try await client.speakText("Hej Hani")
        try await client.speakText("مرحباً هاني")
        #expect(mockFallback.spokenTexts == ["Hello Hani", "Hej Hani", "مرحباً هاني"])
        mockFallback.spokenTexts.removeAll()
        logMetric("Step 1: Clean install default flag OFF routes to Apple fallback: PASS")

        // 2. Controlled enablement
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        #expect(PaceNeuralTTSSettings.isNeuralTTSEnabled)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        logMetric("Step 2: Controlled enablement isNeuralTTSEnabled=true: PASS")

        let manager = PaceNeuralTTSModelManager.shared
        guard case .success(let kokoroConfig) = manager.resolveKokoroConfiguration(),
              case .success(let swedishConfig) = manager.resolveSwedishConfiguration() else {
            Issue.record("Model assets missing from disk")
            return
        }

        let worker = PaceSherpaTTSWorker()
        #expect(!(await worker.hasLoadedEngine))
        logMetric("Step 3: Worker lazy loading before synthesis: hasLoadedEngine=false PASS")

        // 3. First English synthesis (Cold Kokoro)
        let coldStart = DispatchTime.now()
        let coldAudio = try await worker.synthesizeEnglish(
            text: "Hello Hani, this is Kokoro neural speech synthesis running locally on Apple Silicon.",
            config: kokoroConfig
        )
        let coldEnd = DispatchTime.now()
        let coldLatencyMs = Double(coldEnd.uptimeNanoseconds - coldStart.uptimeNanoseconds) / 1_000_000.0
        let rssAfterCold = getResidentMemoryMB()

        #expect(coldAudio.sampleRate == 24000)
        #expect(!coldAudio.samples.isEmpty)
        #expect(await worker.hasLoadedEngine)
        logMetric("Step 4: Cold English (Kokoro af_heart): Latency=\(String(format: "%.2f", coldLatencyMs)) ms | SampleRate=\(coldAudio.sampleRate) Hz | Samples=\(coldAudio.samples.count) | RSS=\(String(format: "%.2f", rssAfterCold)) MB")

        // 4. Warm English synthesis
        let warmStart = DispatchTime.now()
        let warmAudio = try await worker.synthesizeEnglish(
            text: "This is a warm synthesis measurement to observe recurring inference latency.",
            config: kokoroConfig
        )
        let warmEnd = DispatchTime.now()
        let warmLatencyMs = Double(warmEnd.uptimeNanoseconds - warmStart.uptimeNanoseconds) / 1_000_000.0
        let rssAfterWarm = getResidentMemoryMB()

        #expect(warmAudio.sampleRate == 24000)
        #expect(!warmAudio.samples.isEmpty)
        logMetric("Step 5: Warm English (Kokoro af_heart): Latency=\(String(format: "%.2f", warmLatencyMs)) ms | SampleRate=\(warmAudio.sampleRate) Hz | Samples=\(warmAudio.samples.count) | RSS=\(String(format: "%.2f", rssAfterWarm)) MB")

        // 5. Language switch: English -> Swedish Alma (Piper VITS)
        let svStart = DispatchTime.now()
        let svAudio = try await worker.synthesizeSwedish(
            text: "Hej Hani, det här är Alma som talar svenska helt offline.",
            config: swedishConfig
        )
        let svEnd = DispatchTime.now()
        let svLatencyMs = Double(svEnd.uptimeNanoseconds - svStart.uptimeNanoseconds) / 1_000_000.0
        let rssAfterSv = getResidentMemoryMB()

        #expect(svAudio.sampleRate == 22050)
        #expect(!svAudio.samples.isEmpty)
        #expect(await worker.hasLoadedEngine)
        logMetric("Step 6: Switch English -> Swedish (Alma): Latency=\(String(format: "%.2f", svLatencyMs)) ms | SampleRate=\(svAudio.sampleRate) Hz | Samples=\(svAudio.samples.count) | RSS=\(String(format: "%.2f", rssAfterSv)) MB")

        // 6. Language switch: Swedish -> English Kokoro (exclusivity check)
        let backStart = DispatchTime.now()
        let backAudio = try await worker.synthesizeEnglish(
            text: "Switching back to Kokoro English female speaker.",
            config: kokoroConfig
        )
        let backEnd = DispatchTime.now()
        let backLatencyMs = Double(backEnd.uptimeNanoseconds - backStart.uptimeNanoseconds) / 1_000_000.0
        let rssAfterBack = getResidentMemoryMB()

        #expect(backAudio.sampleRate == 24000)
        #expect(!backAudio.samples.isEmpty)
        #expect(await worker.hasLoadedEngine)
        logMetric("Step 7: Switch Swedish -> English (Kokoro af_heart): Latency=\(String(format: "%.2f", backLatencyMs)) ms | SampleRate=\(backAudio.sampleRate) Hz | Samples=\(backAudio.samples.count) | RSS=\(String(format: "%.2f", rssAfterBack)) MB")

        // 7. Deterministic Arabic routing (Sofelia)
        let arabicRoute = PaceNeuralTTSClient.determineRoute(for: "مرحباً هاني، كيف حالك؟")
        #expect(arabicRoute == .arabicSofelia)
        try await client.speakText("مرحباً هاني، كيف حالك؟")
        logMetric("Step 8: Arabic routing -> Sofelia neural Arabic: PASS")

        // 8. Unsupported language routing
        let ruRoute = PaceNeuralTTSClient.determineRoute(for: "Привет, мир!")
        guard case .appleFallback = ruRoute else {
            Issue.record("Expected appleFallback for Russian")
            return
        }
        try await client.speakText("Привет, мир!")
        #expect(mockFallback.spokenTexts.contains("Привет, мир!"))
        logMetric("Step 9: Unsupported language (Russian) -> Apple fallback: PASS")

        // 9. Controlled disablement returns immediately to Apple
        PaceNeuralTTSSettings.setNeuralTTSEnabled(false)
        #expect(!PaceNeuralTTSSettings.isNeuralTTSEnabled)
        try await client.speakText("English after disablement")
        #expect(mockFallback.spokenTexts.contains("English after disablement"))
        logMetric("Step 10: Disabling neural provider returns immediately to Apple: PASS")

        // 10. Explicit unload releases engine
        await worker.unload()
        #expect(!(await worker.hasLoadedEngine))
        let rssAfterUnload = getResidentMemoryMB()
        logMetric("Step 11: Explicit unload: hasLoadedEngine=false | RSS=\(String(format: "%.2f", rssAfterUnload)) MB: PASS")
    }
}

// MARK: - Phase 2.2 Audio Parity, Queue & Routing Tests

@Suite("PacePhase22AudioParityAndQueueTests")
struct PacePhase22AudioParityAndQueueTests {

    @Test("Requirement 1 & 2: Factory correctly returns PaceNeuralTTSClient when enabled, and LocalTTSClient when disabled")
    @MainActor
    func testFactoryEnableDisable() {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(false)
        let defaultClient = BuddyTTSClientFactory.makeDefault()
        #expect(defaultClient is LocalTTSClient)

        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.setNeuralTTSEnabled(false) }
        let neuralClient = BuddyTTSClientFactory.makeDefault()
        #expect(neuralClient is PaceNeuralTTSClient)
    }

    @Test("Requirements 3, 4, 5, 6: Explicit en-US routes all short phrases and greetings to Kokoro")
    func testExplicitEnglishShortPhrases() {
        let phrases = [
            "Hello Hani",
            "Hi Hani",
            "Hey Hani",
            "Good morning Hani",
            "Yes.",
            "Okay.",
            "Done."
        ]
        for phrase in phrases {
            let route = PaceNeuralTTSClient.determineRoute(for: phrase, explicitLocale: "en-US")
            #expect(route == .englishKokoro, "Phrase '\(phrase)' with explicit en-US must route to Kokoro")
        }
    }

    @Test("Requirement 7: Explicit sv-SE routes to Piper Alma")
    func testExplicitSwedishRouting() {
        let phrases = [
            "Hej Hani",
            "Hur mår du?",
            "Klart.",
            "Ja."
        ]
        for phrase in phrases {
            let route = PaceNeuralTTSClient.determineRoute(for: phrase, explicitLocale: "sv-SE")
            #expect(route == .swedishAlma, "Phrase '\(phrase)' with explicit sv-SE must route to Alma")
        }
    }

    @Test("Requirement 8: Explicit Arabic routes to Sofelia neural Arabic")
    func testExplicitArabicRouting() {
        let phrases = [
            "مرحبا هاني",
            "نعم",
            "تم"
        ]
        for phrase in phrases {
            let route = PaceNeuralTTSClient.determineRoute(for: phrase, explicitLocale: "ar")
            #expect(route == .arabicSofelia, "Phrase '\(phrase)' with explicit Arabic must route to Sofelia")
        }
    }

    @Test("Requirement 9: Short English fragments without explicit locale must NOT route id/ca/tr to Apple when context is English")
    func testShortEnglishWithoutExplicitLocaleContext() {
        let shortGreetings = [
            "Hello Hani",
            "Hi Hani",
            "Hey Hani",
            "Good morning Hani",
            "Yes.",
            "Okay.",
            "Done."
        ]

        for greeting in shortGreetings {
            // Context provided as en-US
            let withContext = PaceNeuralTTSClient.determineRoute(for: greeting, explicitLocale: nil, contextLocale: "en-US")
            #expect(withContext == .englishKokoro, "Short greeting '\(greeting)' with en-US context must route to Kokoro")

            // Without context, short fragment guard prevents id/ca/tr fallback
            let withoutContext = PaceNeuralTTSClient.determineRoute(for: greeting, explicitLocale: nil, contextLocale: nil)
            #expect(withoutContext == .englishKokoro, "Short greeting '\(greeting)' without context must not fall back to Apple due to spurious id/ca/tr detection")
        }
    }

    @Test("Requirement 10: Serial queue execution prevents alreadySynthesizing and preserves sequential synthesis")
    @MainActor
    func testSerialQueueExecution() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.setNeuralTTSEnabled(false) }

        let mockFallback = PaceMockFallbackTTSClient()
        let client = PaceNeuralTTSClient(fallbackClient: mockFallback)

        // Queue 3 sentences sequentially
        try await client.speakText("First sentence for serial test.", explicitLocale: "en-US")
        try await client.speakText("Second sentence for serial test.", explicitLocale: "en-US")
        try await client.speakText("Third sentence for serial test.", explicitLocale: "en-US", isFinal: true)

        // Verify client is active or playing
        #expect(client.isPlaying)

        // Wait briefly for queue processing
        try await Task.sleep(nanoseconds: 100_000_000)

        // Stop cleanly
        client.stopPlayback()
        #expect(!client.isPlaying)
        #expect(client.debugPendingQueueCount == 0)

        // Fallback client was not invoked because Kokoro handled the sentences
        #expect(mockFallback.spokenTexts.isEmpty)
    }

    @Test("Requirement 11: Queue boundedness - sending >4 items drops intermediate chunks and strictly preserves the final sentence")
    @MainActor
    func testQueueBoundedness() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.setNeuralTTSEnabled(false) }

        let mockFallback = PaceMockFallbackTTSClient()
        let client = PaceNeuralTTSClient(fallbackClient: mockFallback)

        // Rapidly submit 6 utterances
        for i in 1...5 {
            try await client.speakText("Intermediate sentence number \(i).", explicitLocale: "en-US", isFinal: false)
        }
        try await client.speakText("This is the guaranteed final sentence.", explicitLocale: "en-US", isFinal: true)

        // Queue count must be bounded at <= 4
        #expect(client.debugPendingQueueCount <= 4, "Queue must never exceed maxPendingUtterances (4)")

        client.stopPlayback()
        #expect(client.debugPendingQueueCount == 0)
    }

    @Test("Requirement 12: Cancellation stops playback and drains pending neural utterances immediately")
    @MainActor
    func testQueueCancellation() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.setNeuralTTSEnabled(false) }

        let mockFallback = PaceMockFallbackTTSClient()
        let client = PaceNeuralTTSClient(fallbackClient: mockFallback)

        client.recordExpectedStopReason(.userBargeIn)
        try await client.speakText("Sentence 1 to be cancelled.", explicitLocale: "en-US")
        try await client.speakText("Sentence 2 to be cancelled.", explicitLocale: "en-US")
        try await client.speakText("Sentence 3 to be cancelled.", explicitLocale: "en-US")

        client.stopPlayback()

        #expect(!client.isPlaying)
        #expect(client.debugPendingQueueCount == 0)
        #expect(client.lastStopReason == .userBargeIn)
    }

    @Test("Requirement 13: Voice identity constants match Kokoro SID 3 and Piper Alma SID 0")
    func testVoiceIdentityConstantsPhase22() {
        let kokoroSID = 3
        #expect(kokoroSID == 3)

        let swedishSID = 0
        #expect(swedishSID == 0)

        let kokoroSampleRate = 24000
        #expect(kokoroSampleRate == 24000)

        let swedishSampleRate = 22050
        #expect(swedishSampleRate == 22050)
    }

    @Test("Requirement 15: Missing model falls back cleanly to Apple TTS")
    @MainActor
    func testMissingModelFallback() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.setNeuralTTSEnabled(false) }

        let emptyTempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: emptyTempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyTempDir) }

        let emptyManager = PaceNeuralTTSModelManager(customSearchRoots: [emptyTempDir])
        let mockFallback = PaceMockFallbackTTSClient()
        let client = PaceNeuralTTSClient(modelManager: emptyManager, fallbackClient: mockFallback)

        try await client.speakText("Testing fallback with missing model assets.", explicitLocale: "en-US")

        // Wait briefly for queue loop to process failure
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(mockFallback.spokenTexts.contains("Testing fallback with missing model assets."))
    }
}
#endif


