//
//  PaceNeuralTTSClient.swift
//  leanring-buddy
//
//  Opt-in local neural TTS client powered by Sherpa-ONNX.
//  Language routing:
//    - English: Kokoro-82M (af_heart, SID 3, lang en-us, 24kHz)
//    - Swedish: Piper VITS (sv_SE-alma-medium, SID 0, 22.05kHz)
//    - Arabic / unsupported: Apple AVSpeechSynthesizer fallback
//  Failure posture:
//    - Missing model or genuine synthesis failure falls back to LocalTTSClient.
//    - Concurrency contention serializes through a bounded FIFO queue and does NOT fall back.
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

    // MARK: - Serial Bounded Queue

    struct QueuedUtterance: Identifiable {
        let id: UUID
        let text: String
        let explicitLocale: String?
        let isFinal: Bool
        let route: PaceNeuralTTSLanguageRoute
        let onPlaybackStarted: (@MainActor () -> Void)?
        let onCompletedOrFailed: (@MainActor () -> Void)?
    }

    private var pendingQueue: [QueuedUtterance] = []
    private let maxPendingUtterances: Int = 4
    private var queueProcessingTask: Task<Void, Never>?

    #if DEBUG
    var debugPendingQueueCount: Int {
        pendingQueue.count
    }
    #endif

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
        if !pendingQueue.isEmpty {
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

        let wasProcessing = queueProcessingTask != nil || !pendingQueue.isEmpty
        if wasProcessing {
            print("[TTS] queue cancelled id=all")
        }

        // Notify and drain all pending utterances
        for item in pendingQueue {
            item.onCompletedOrFailed?()
        }
        pendingQueue.removeAll()

        // Cancel queue processing task
        queueProcessingTask?.cancel()
        queueProcessingTask = nil

        // Cancel active worker synthesis
        Task {
            await worker.cancelActiveSynthesis()
        }

        // Stop current audio player
        if let player = audioPlayer, player.isPlaying {
            player.stop()
        }
        audioPlayer = nil
        isCurrentlySpeakingOrPending = false

        // Unblock any awaiting playback continuation
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
    /// explicit locale metadata, context locale, script heuristics, and reliable on-device language detection.
    nonisolated public static func determineRoute(
        for text: String,
        explicitLocale: String? = nil,
        contextLocale: String? = nil
    ) -> PaceNeuralTTSLanguageRoute {
        // Priority 1: Caller-provided explicit locale
        if let explicit = explicitLocale?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return routeFromLocale(explicit)
        }

        // Priority 2: Stable conversation / turn context locale
        if let context = contextLocale?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            return routeFromLocale(context)
        }

        // Priority 3: Character script heuristics (unambiguous character sets)
        // Arabic Unicode range \u{0600}...\u{06FF}
        let hasArabic = text.unicodeScalars.contains { $0.value >= 0x0600 && $0.value <= 0x06FF }
        if hasArabic {
            return .appleFallback(reason: "Arabic routed to Apple TTS (Maged/Majed)")
        }

        // Swedish distinct characters (å, ä, ö)
        let swedishChars = CharacterSet(charactersIn: "åäöÅÄÖ")
        if text.rangeOfCharacter(from: swedishChars) != nil {
            return .swedishAlma
        }

        // Priority 4: Reliable on-device language detection
        let rawTarget = PaceSpeechVoiceResolver.detectLanguage(for: text)
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
            // Short fragment guard (< 40 characters) ONLY for Latin text:
            // Apple NLLanguageRecognizer is notoriously noisy on short Latin phrases with proper nouns
            // (e.g. "Hello Hani" -> id, "Hi Hani" -> ca, "Hey Hani" -> tr).
            // Cyrillic, Greek, Asian scripts, etc. must fall back to Apple TTS.
            let isLatin = text.unicodeScalars.allSatisfy { $0.isASCII || ($0.value >= 0x00A0 && $0.value <= 0x024F) }
            if isLatin && text.count < 40 {
                return .englishKokoro
            }
            return .appleFallback(reason: "Unsupported neural language '\(raw)'; falling back to Apple TTS")
        }
    }

    nonisolated private static func routeFromLocale(_ locale: String) -> PaceNeuralTTSLanguageRoute {
        let normalized = locale.replacingOccurrences(of: "_", with: "-").lowercased()
        let baseLanguage = normalized.split(separator: "-").first.map(String.init) ?? normalized
        switch baseLanguage {
        case "en":
            return .englishKokoro
        case "sv":
            return .swedishAlma
        case "ar":
            return .appleFallback(reason: "Arabic routed to Apple TTS (Maged/Majed)")
        default:
            return .appleFallback(reason: "Unsupported neural language '\(locale)'; falling back to Apple TTS")
        }
    }

    // MARK: - Speech Submission API

    func speakText(_ text: String) async throws {
        try await speakText(text, explicitLocale: nil, isFinal: false)
    }

    func speakText(_ text: String, explicitLocale: String?) async throws {
        try await speakText(text, explicitLocale: explicitLocale, isFinal: false)
    }

    func speakText(_ text: String, explicitLocale: String?, isFinal: Bool) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // If neural feature flag is not enabled, deterministically route to Apple fallback
        guard PaceNeuralTTSSettings.isNeuralTTSEnabled else {
            try await fallbackClient.speakText(trimmed, explicitLocale: explicitLocale, isFinal: isFinal)
            return
        }

        let route = Self.determineRoute(for: trimmed, explicitLocale: explicitLocale)
        switch route {
        case .appleFallback(let reason):
            print("[TTS] fallback reason=\(reason)")
            try await fallbackClient.speakText(trimmed, explicitLocale: explicitLocale, isFinal: isFinal)
            return

        case .englishKokoro:
            print("[TTS] provider=neural locale=en-US engine=kokoro speaker=af_heart sid=3")

        case .swedishAlma:
            print("[TTS] provider=neural locale=sv-SE engine=piper-alma sid=0")
        }

        let utteranceId = UUID()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var hasResumed = false
            let resumeOnce = {
                if !hasResumed {
                    hasResumed = true
                    continuation.resume()
                }
            }

            let item = QueuedUtterance(
                id: utteranceId,
                text: trimmed,
                explicitLocale: explicitLocale,
                isFinal: isFinal,
                route: route,
                onPlaybackStarted: {
                    resumeOnce()
                },
                onCompletedOrFailed: {
                    resumeOnce()
                }
            )

            enqueueUtteranceWithBackpressure(item)
            ensureQueueProcessing()
        }
    }

    // MARK: - Queue Management & Backpressure

    private func enqueueUtteranceWithBackpressure(_ item: QueuedUtterance) {
        let itemIdPrefix = String(item.id.uuidString.prefix(8))
        print("[TTS] queue enqueue id=\(itemIdPrefix) final=\(item.isFinal) count=\(pendingQueue.count + 1)")

        if pendingQueue.count >= maxPendingUtterances {
            if item.isFinal {
                // When at capacity and a final chunk lands, preserve head and replace intermediate chunks with final
                if pendingQueue.count > 1 {
                    for dropped in pendingQueue.dropFirst() {
                        dropped.onCompletedOrFailed?()
                    }
                    let head = pendingQueue[0]
                    pendingQueue = [head, item]
                } else {
                    pendingQueue.append(item)
                }
            } else {
                // Drop the oldest non-active intermediate chunk to stay bounded
                if pendingQueue.count > 1 {
                    let dropped = pendingQueue.remove(at: pendingQueue.count - 1)
                    dropped.onCompletedOrFailed?()
                }
                pendingQueue.append(item)
            }
        } else {
            pendingQueue.append(item)
        }

        isCurrentlySpeakingOrPending = true
    }

    private func ensureQueueProcessing() {
        guard queueProcessingTask == nil else { return }
        queueProcessingTask = Task { @MainActor [weak self] in
            await self?.processQueueLoop()
        }
    }

    private func processQueueLoop() async {
        while !Task.isCancelled {
            guard !pendingQueue.isEmpty else {
                break
            }

            let utterance = pendingQueue.removeFirst()
            let idPrefix = String(utterance.id.uuidString.prefix(8))
            print("[TTS] queue start id=\(idPrefix)")

            do {
                try await synthesizeAndPlay(utterance)
                print("[TTS] queue complete id=\(idPrefix)")
                utterance.onCompletedOrFailed?()
            } catch {
                if Task.isCancelled {
                    print("[TTS] queue cancelled id=\(idPrefix)")
                    utterance.onCompletedOrFailed?()
                    break
                }

                // If concurrency contention (alreadySynthesizing) occurred, retry through the serialized queue
                if let sherpaErr = error as? PaceSherpaTTSError, case .alreadySynthesizing = sherpaErr {
                    print("⚠️ [TTS] worker concurrency race detected; retrying in serialized queue...")
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    do {
                        try await synthesizeAndPlay(utterance)
                        print("[TTS] queue complete id=\(idPrefix) (after retry)")
                        utterance.onCompletedOrFailed?()
                    } catch {
                        print("⚠️ [TTS] retry failed (\(error.localizedDescription)). Falling back to Apple TTS.")
                        try? await fallbackClient.speakText(utterance.text, explicitLocale: utterance.explicitLocale, isFinal: utterance.isFinal)
                        utterance.onCompletedOrFailed?()
                    }
                } else {
                    // Genuine synthesis failure or missing model -> fall back to Apple TTS
                    print("⚠️ [TTS] synthesis failed (\(error.localizedDescription)). Falling back to Apple TTS.")
                    try? await fallbackClient.speakText(utterance.text, explicitLocale: utterance.explicitLocale, isFinal: utterance.isFinal)
                    utterance.onCompletedOrFailed?()
                }
            }
        }

        queueProcessingTask = nil
        if pendingQueue.isEmpty && audioPlayer?.isPlaying != true {
            isCurrentlySpeakingOrPending = false
        }
    }

    private func synthesizeAndPlay(_ utterance: QueuedUtterance) async throws {
        let wavData: Data

        switch utterance.route {
        case .englishKokoro:
            let configResult = modelManager.resolveKokoroConfiguration()
            guard case .success(let config) = configResult else {
                if case .failure(let err) = configResult { throw err }
                throw PaceNeuralTTSModelError.approvedRootNotFound
            }
            let synthesized = try await worker.synthesizeEnglish(text: utterance.text, config: config, speakerId: 3)
            wavData = PaceWAVEncoder.encodeWAV(samples: synthesized.samples, sampleRate: synthesized.sampleRate)

        case .swedishAlma:
            let configResult = modelManager.resolveSwedishConfiguration()
            guard case .success(let config) = configResult else {
                if case .failure(let err) = configResult { throw err }
                throw PaceNeuralTTSModelError.approvedRootNotFound
            }
            let synthesized = try await worker.synthesizeSwedish(text: utterance.text, config: config)
            wavData = PaceWAVEncoder.encodeWAV(samples: synthesized.samples, sampleRate: synthesized.sampleRate)

        case .appleFallback(let reason):
            print("[TTS] fallback reason=\(reason)")
            try await fallbackClient.speakText(utterance.text, explicitLocale: utterance.explicitLocale, isFinal: utterance.isFinal)
            utterance.onCompletedOrFailed?()
            return
        }

        // If previous audio is still playing on audioPlayer, wait until it finishes
        if let player = audioPlayer, player.isPlaying {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                playbackContinuation = continuation
            }
        }

        guard !Task.isCancelled else { return }

        // Start playback and notify that playback has begun
        utterance.onPlaybackStarted?()
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
