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

// MARK: - Client & Language Routing Tests

@Suite("PaceNeuralTTSClient & Fallback Tests")
struct PaceNeuralTTSClientTests {

    @Test("Arabic routes directly to Apple TTS fallback without attempting neural load")
    @MainActor
    func testArabicDirectRouting() async throws {
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
