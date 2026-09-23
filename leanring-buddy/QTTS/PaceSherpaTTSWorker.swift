//
//  PaceSherpaTTSWorker.swift
//  leanring-buddy
//
//  Actor-isolated worker managing Sherpa-ONNX model lifecycle, lazy loading,
//  synthesis serialization, and cancellation.
//  Strictly offline: zero network, zero shell, zero background daemons.
//

import Foundation

#if canImport(SherpaOnnx)
import SherpaOnnx
#endif

public enum PaceSherpaTTSError: LocalizedError, Equatable {
    case runtimeUnavailable
    case alreadySynthesizing
    case modelInitializationFailed(reason: String)
    case synthesisFailed(reason: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "SherpaOnnx runtime is not linked or unavailable."
        case .alreadySynthesizing:
            return "Another synthesis operation is already active."
        case .modelInitializationFailed(let reason):
            return "Failed to initialize Sherpa-ONNX model: \(reason)"
        case .synthesisFailed(let reason):
            return "Sherpa-ONNX synthesis failed: \(reason)"
        case .cancelled:
            return "Synthesis was cancelled by barge-in or stop."
        }
    }
}

public struct PaceSynthesizedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int32

    public nonisolated init(samples: [Float], sampleRate: Int32) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public actor PaceSherpaTTSWorker {
    public static let shared = PaceSherpaTTSWorker()

    private enum ActiveEngine {
        case none
        #if canImport(SherpaOnnx)
        case kokoro(SherpaOnnxOfflineTtsWrapper)
        case swedish(SherpaOnnxOfflineTtsWrapper)
        #endif
    }

    private var activeEngine: ActiveEngine = .none
    private var isSynthesizing: Bool = false
    private var isCancelled: Bool = false

    public init() {}

    // MARK: - State Inspection

    public var hasLoadedEngine: Bool {
        switch activeEngine {
        case .none:
            return false
        default:
            return true
        }
    }

    public var isCurrentlySynthesizing: Bool {
        isSynthesizing
    }

    // MARK: - English (Kokoro-82M / af_heart)

    /// Synthesizes English text using Kokoro-82M.
    /// Default speaker ID 3 maps to `af_heart`.
    public func synthesizeEnglish(
        text: String,
        config: PaceKokoroModelConfiguration,
        speakerId: Int = 3,
        speed: Float = 1.0
    ) throws -> PaceSynthesizedAudio {
        #if canImport(SherpaOnnx)
        guard !isSynthesizing else {
            throw PaceSherpaTTSError.alreadySynthesizing
        }

        isSynthesizing = true
        isCancelled = false
        defer { isSynthesizing = false }

        let tts = try resolveOrLoadKokoro(config: config)

        if isCancelled {
            throw PaceSherpaTTSError.cancelled
        }

        var genConfig = SherpaOnnxGenerationConfigSwift()
        genConfig.sid = speakerId
        genConfig.speed = speed
        genConfig.silenceScale = 0.2

        let audio = tts.generateWithConfig(
            text: text,
            config: genConfig,
            callback: nil,
            arg: nil
        )

        if isCancelled {
            throw PaceSherpaTTSError.cancelled
        }

        let samples = audio.samples
        guard !samples.isEmpty else {
            throw PaceSherpaTTSError.synthesisFailed(reason: "Kokoro generated empty audio buffer.")
        }

        return PaceSynthesizedAudio(samples: samples, sampleRate: audio.sampleRate)
        #else
        throw PaceSherpaTTSError.runtimeUnavailable
        #endif
    }

    // MARK: - Swedish (Piper / sv_SE-alma-medium)

    /// Synthesizes Swedish text using Piper Alma VITS.
    /// Speaker ID 0 maps to Alma (single-speaker model).
    public func synthesizeSwedish(
        text: String,
        config: PaceSwedishModelConfiguration,
        speed: Float = 1.0
    ) throws -> PaceSynthesizedAudio {
        #if canImport(SherpaOnnx)
        guard !isSynthesizing else {
            throw PaceSherpaTTSError.alreadySynthesizing
        }

        isSynthesizing = true
        isCancelled = false
        defer { isSynthesizing = false }

        let tts = try resolveOrLoadSwedish(config: config)

        if isCancelled {
            throw PaceSherpaTTSError.cancelled
        }

        var genConfig = SherpaOnnxGenerationConfigSwift()
        genConfig.sid = 0
        genConfig.speed = speed
        genConfig.silenceScale = 0.2

        let audio = tts.generateWithConfig(
            text: text,
            config: genConfig,
            callback: nil,
            arg: nil
        )

        if isCancelled {
            throw PaceSherpaTTSError.cancelled
        }

        let samples = audio.samples
        guard !samples.isEmpty else {
            throw PaceSherpaTTSError.synthesisFailed(reason: "Piper Swedish generated empty audio buffer.")
        }

        return PaceSynthesizedAudio(samples: samples, sampleRate: audio.sampleRate)
        #else
        throw PaceSherpaTTSError.runtimeUnavailable
        #endif
    }

    // MARK: - Engine Lifecycle & Lazy Switching

    #if canImport(SherpaOnnx)
    private func resolveOrLoadKokoro(config: PaceKokoroModelConfiguration) throws -> SherpaOnnxOfflineTtsWrapper {
        if case .kokoro(let wrapper) = activeEngine {
            return wrapper
        }

        // Unload Swedish engine if resident before loading Kokoro to cap RAM
        activeEngine = .none

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
        guard wrapper.tts != nil else {
            throw PaceSherpaTTSError.modelInitializationFailed(
                reason: "SherpaOnnxOfflineTtsWrapper failed to initialize Kokoro engine."
            )
        }

        activeEngine = .kokoro(wrapper)
        return wrapper
    }

    private func resolveOrLoadSwedish(config: PaceSwedishModelConfiguration) throws -> SherpaOnnxOfflineTtsWrapper {
        if case .swedish(let wrapper) = activeEngine {
            return wrapper
        }

        // Unload Kokoro engine if resident before loading Swedish to cap RAM
        activeEngine = .none

        let vitsConfig = sherpaOnnxOfflineTtsVitsModelConfig(
            model: config.modelPath,
            lexicon: "",
            tokens: config.tokensPath,
            dataDir: config.dataDirPath
        )
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(
            vits: vitsConfig,
            numThreads: 2,
            debug: 0,
            provider: "cpu"
        )
        var ttsConfig = sherpaOnnxOfflineTtsConfig(model: modelConfig)

        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &ttsConfig)
        guard wrapper.tts != nil else {
            throw PaceSherpaTTSError.modelInitializationFailed(
                reason: "SherpaOnnxOfflineTtsWrapper failed to initialize Swedish engine."
            )
        }

        activeEngine = .swedish(wrapper)
        return wrapper
    }
    #endif

    // MARK: - Cancellation & Teardown

    /// Cancels any currently active synthesis.
    public func cancelActiveSynthesis() {
        isCancelled = true
    }

    /// Unloads all resident models and releases memory back to the OS.
    public func unload() {
        activeEngine = .none
        isCancelled = false
        isSynthesizing = false
    }
}
