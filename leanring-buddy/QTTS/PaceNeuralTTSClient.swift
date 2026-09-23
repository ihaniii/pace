//
//  PaceNeuralTTSClient.swift
//  leanring-buddy
//
//  Opt-in local neural TTS client powered by Sherpa-ONNX.
//  Language routing:
//    - English: Kokoro-82M (af_heart)
//    - Swedish: Piper VITS (sv_SE-alma-medium)
//    - Arabic / unsupported: Apple AVSpeechSynthesizer fallback
//  Failure posture:
//    - Any model or synthesis failure falls back to LocalTTSClient.
//  Zero network, zero external processes.
//

import AVFoundation
import Foundation

@MainActor
final class PaceNeuralTTSClient: NSObject, BuddyTTSClient {
    private let modelManager: PaceNeuralTTSModelManager
    private let worker: PaceSherpaTTSWorker
    private let fallbackClient: any BuddyTTSClient

    private var audioPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    private var isCurrentlySpeakingOrPending: Bool = false
    private var internalLastStopReason: PaceTTSStopReason = .naturalCompletion
    private var pendingStopReason: PaceTTSStopReason?

    init(
        modelManager: PaceNeuralTTSModelManager = .shared,
        worker: PaceSherpaTTSWorker = .shared,
        fallbackClient: (any BuddyTTSClient)? = nil
    ) {
        self.modelManager = modelManager
        self.worker = worker
        self.fallbackClient = fallbackClient ?? LocalTTSClient()
        super.init()
    }

    // MARK: - BuddyTTSClient Protocol

    var isPlaying: Bool {
        if isCurrentlySpeakingOrPending {
            return true
        }
        if let player = audioPlayer, player.isPlaying {
            return true
        }
        return fallbackClient.isPlaying
    }

    var lastStopReason: PaceTTSStopReason {
        if fallbackClient.isPlaying {
            return fallbackClient.lastStopReason
        }
        return internalLastStopReason
    }

    func recordExpectedStopReason(_ reason: PaceTTSStopReason) {
        pendingStopReason = reason
        fallbackClient.recordExpectedStopReason(reason)
    }

    func stopPlayback() {
        internalLastStopReason = pendingStopReason ?? .manualStop
        pendingStopReason = nil

        // Cancel worker synthesis
        Task {
            await worker.cancelActiveSynthesis()
        }

        // Stop current audio player
        if let player = audioPlayer, player.isPlaying {
            player.stop()
        }
        audioPlayer = nil
        isCurrentlySpeakingOrPending = false

        playbackContinuation?.resume()
        playbackContinuation = nil

        // Propagate stop to fallback client
        fallbackClient.stopPlayback()
    }

    // MARK: - Deterministic Language Routing

    public enum PaceNeuralTTSLanguageRoute: Equatable, Sendable {
        case englishKokoro
        case swedishAlma
        case appleFallback(reason: String)
    }

    /// Deterministically routes an utterance to a neural engine or Apple fallback based on
    /// locale metadata or on-device language detection.
    nonisolated public static func determineRoute(for text: String, explicitLocale: String? = nil) -> PaceNeuralTTSLanguageRoute {
        let rawTarget = explicitLocale ?? PaceSpeechVoiceResolver.detectLanguage(for: text)
        guard let raw = rawTarget?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            // Default to English Kokoro if language is undetermined
            return .englishKokoro
        }

        let normalized = raw.replacingOccurrences(of: "_", with: "-").lowercased()
        let baseLanguage = normalized.split(separator: "-").first.map(String.init) ?? normalized

        switch baseLanguage {
        case "en":
            return .englishKokoro
        case "sv":
            return .swedishAlma
        case "ar":
            return .appleFallback(reason: "Arabic routed to Apple TTS (Maged/Majed)")
        default:
            return .appleFallback(reason: "Unsupported neural language '\(raw)'; falling back to Apple TTS")
        }
    }

    func speakText(_ text: String) async throws {
        try await speakText(text, explicitLocale: nil)
    }

    func speakText(_ text: String, explicitLocale: String?) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // If neural feature flag is not enabled, deterministically route to Apple fallback
        guard PaceNeuralTTSSettings.isNeuralTTSEnabled else {
            try await fallbackClient.speakText(trimmed)
            return
        }

        let route = Self.determineRoute(for: trimmed, explicitLocale: explicitLocale)
        switch route {
        case .englishKokoro:
            do {
                try await speakWithKokoro(trimmed)
            } catch {
                print("🔊 Neural TTS: Kokoro failed (\(error.localizedDescription)). Falling back to Apple TTS.")
                try await fallbackClient.speakText(trimmed)
            }

        case .swedishAlma:
            do {
                try await speakWithSwedish(trimmed)
            } catch {
                print("🔊 Neural TTS: Swedish Piper failed (\(error.localizedDescription)). Falling back to Apple TTS.")
                try await fallbackClient.speakText(trimmed)
            }

        case .appleFallback(let reason):
            print("🔊 Neural TTS: \(reason)")
            try await fallbackClient.speakText(trimmed)
        }
    }

    // MARK: - Private Neural Synthesis & Playback

    private func speakWithKokoro(_ text: String) async throws {
        let configResult = modelManager.resolveKokoroConfiguration()
        guard case .success(let config) = configResult else {
            if case .failure(let err) = configResult {
                throw err
            }
            throw PaceNeuralTTSModelError.approvedRootNotFound
        }

        isCurrentlySpeakingOrPending = true
        defer { isCurrentlySpeakingOrPending = false }

        let synthesized = try await worker.synthesizeEnglish(text: text, config: config, speakerId: 3)
        let wavData = PaceWAVEncoder.encodeWAV(samples: synthesized.samples, sampleRate: synthesized.sampleRate)

        try await playAudioData(wavData)
    }

    private func speakWithSwedish(_ text: String) async throws {
        let configResult = modelManager.resolveSwedishConfiguration()
        guard case .success(let config) = configResult else {
            if case .failure(let err) = configResult {
                throw err
            }
            throw PaceNeuralTTSModelError.approvedRootNotFound
        }

        isCurrentlySpeakingOrPending = true
        defer { isCurrentlySpeakingOrPending = false }

        let synthesized = try await worker.synthesizeSwedish(text: text, config: config)
        let wavData = PaceWAVEncoder.encodeWAV(samples: synthesized.samples, sampleRate: synthesized.sampleRate)

        try await playAudioData(wavData)
    }

    private func playAudioData(_ data: Data) async throws {
        let player = try AVAudioPlayer(data: data)
        audioPlayer = player
        player.delegate = self
        player.prepareToPlay()

        guard player.play() else {
            audioPlayer = nil
            throw PaceSherpaTTSError.synthesisFailed(reason: "AVAudioPlayer failed to start playback.")
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playbackContinuation = continuation
        }

        audioPlayer = nil
    }
}

// MARK: - AVAudioPlayerDelegate

extension PaceNeuralTTSClient: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.internalLastStopReason = .naturalCompletion
            self.playbackContinuation?.resume()
            self.playbackContinuation = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.internalLastStopReason = .manualStop
            self.playbackContinuation?.resume()
            self.playbackContinuation = nil
        }
    }
}
