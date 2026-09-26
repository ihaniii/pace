//
//  PaceNeuralTTSClient.swift
//  leanring-buddy
//
//  Opt-in local neural TTS client powered by Sherpa-ONNX.
//  Language routing:
//    - English: Kokoro-82M (af_heart, SID 3, lang en-us, 24kHz)
//    - Swedish: Piper VITS (sv_SE-alma-medium, SID 0, 22.05kHz)
//    - Arabic: Sofelia Palestinian (ONNX); unsupported languages: Apple AVSpeechSynthesizer
//  Failure posture:
//    - Never two voices at once: the queue is serial and Apple speech is awaited
//      to completion before the next utterance starts.
//    - One voice per turn for FAILURES (a turn begins at `stopPlayback()` or after
//      an idle gap): once a neural voice has started speaking, a later failed
//      chunk is dropped rather than switched to the Apple voice, and a turn that
//      fell back to the Apple voice (e.g. model missing) stays on it. A language
//      only the Apple voice supports is still spoken — serially, never overlapping.
//    - A cancelled neural synthesis NEVER falls back to Apple TTS.
//    - Concurrency contention serializes through a bounded FIFO queue.
//  Zero network, zero external processes.
//

import AVFoundation
import Foundation

@MainActor
final class PaceNeuralTTSClient: NSObject, BuddyTTSClient {
    private let modelManager: PaceNeuralTTSModelManager
    private let worker: PaceSherpaTTSWorker
    private let sofeliaWorker: PaceArabicSofeliaONNXWorker
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
        /// `playbackGeneration` at enqueue time; a later `stopPlayback()`
        /// makes the utterance stale.
        let playbackGeneration: Int
        let onPlaybackStarted: (@MainActor () -> Void)?
        let onCompletedOrFailed: (@MainActor () -> Void)?
    }

    private var pendingQueue: [QueuedUtterance] = []
    private let maxPendingUtterances: Int = 4
    private var queueProcessingTask: Task<Void, Never>?

    // MARK: - One Voice Path Per Turn

    enum ActiveVoicePath: Equatable {
        case none
        case neural
        case apple
    }

    /// Which voice this turn is speaking with. Reset by `stopPlayback()`, which
    /// every new turn calls, and after the queue has been idle for
    /// `voicePathIdleResetSeconds` (speech outside a turn — reminders, briefs —
    /// must not inherit a lock from an earlier conversation).
    private(set) var activeVoicePathForTurn: ActiveVoicePath = .none
    private var voicePathIdleSince: Date?
    private let voicePathIdleResetSeconds: TimeInterval

    /// Incremented by every `stopPlayback()`. Distinguishes a legitimate stop
    /// from a stale worker cancellation that raced into the next turn.
    private var playbackGeneration: Int = 0

    /// Upper bound on waiting for the Apple voice to finish one utterance, so
    /// a synthesizer that never reports completion cannot wedge the queue.
    static let appleVoiceCompletionWaitLimitSeconds: TimeInterval = 120

    /// Synthesizes and plays one neural utterance. Defaults to the real
    /// Kokoro/Alma/Sofelia path; tests inject a renderer to drive the queue
    /// without models or audio hardware.
    typealias NeuralUtteranceRenderer = @MainActor (QueuedUtterance) async throws -> Void
    private let injectedNeuralUtteranceRenderer: NeuralUtteranceRenderer?

    #if DEBUG
    var debugPendingQueueCount: Int {
        pendingQueue.count
    }
    #endif

    init(
        modelManager: PaceNeuralTTSModelManager = .shared,
        worker: PaceSherpaTTSWorker = .shared,
        sofeliaWorker: PaceArabicSofeliaONNXWorker = .shared,
        fallbackClient: (any BuddyTTSClient)? = nil,
        neuralUtteranceRenderer: NeuralUtteranceRenderer? = nil,
        voicePathIdleResetSeconds: TimeInterval = 10
    ) {
        self.voicePathIdleResetSeconds = voicePathIdleResetSeconds
        self.modelManager = modelManager
        self.worker = worker
        self.sofeliaWorker = sofeliaWorker
        self.fallbackClient = fallbackClient ?? LocalTTSClient()
        self.injectedNeuralUtteranceRenderer = neuralUtteranceRenderer
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
        playbackGeneration += 1
        activeVoicePathForTurn = .none
        voicePathIdleSince = nil

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
            await sofeliaWorker.cancelActiveSynthesis()
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
        case arabicSofelia
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
            return .arabicSofelia
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
            return .arabicSofelia
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
            return .arabicSofelia
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
        case .appleFallback:
            // Queued like every other utterance: speaking it directly here
            // bypassed the queue and could overlap a neural sentence.
            break

        case .englishKokoro:
            print("[TTS] provider=neural locale=en-US engine=kokoro speaker=af_heart sid=3")

        case .swedishAlma:
            print("[TTS] provider=neural locale=sv-SE engine=piper-alma sid=0")

        case .arabicSofelia:
            print("[TTS] provider=neural locale=ar engine=sofelia-palestinian")
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
                playbackGeneration: playbackGeneration,
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
            resetVoicePathAfterIdleGapIfNeeded()

            if case .appleFallback(let reason) = utterance.route {
                // A deliberate language route, not a failure: the Apple voice is
                // the only voice for this language. Spoken serially.
                await speakWithAppleVoice(utterance, reason: reason, isFailureFallback: false)
                utterance.onCompletedOrFailed?()
                continue
            }
            if activeVoicePathForTurn == .apple {
                await speakWithAppleVoice(utterance, reason: "turn fell back to the Apple voice", isFailureFallback: true)
                utterance.onCompletedOrFailed?()
                continue
            }

            do {
                try await renderNeuralUtterance(utterance)
                print("[TTS] queue complete id=\(idPrefix)")
                utterance.onCompletedOrFailed?()
            } catch {
                if Task.isCancelled {
                    print("[TTS] queue cancelled id=\(idPrefix)")
                    utterance.onCompletedOrFailed?()
                    break
                }

                if Self.isNeuralCancellation(error) {
                    // Cancellation is never a reason to switch to the Apple voice.
                    if utterance.playbackGeneration == playbackGeneration {
                        // No stop happened since this utterance was queued, so the
                        // cancellation was aimed at an earlier turn's synthesis and
                        // raced into this one. Retry once on the neural voice.
                        print("⚠️ [TTS] stale cancellation hit id=\(idPrefix); retrying neural synthesis once")
                        do {
                            try await renderNeuralUtterance(utterance)
                            print("[TTS] queue complete id=\(idPrefix) (after stale-cancellation retry)")
                        } catch {
                            await handleFailedNeuralRetry(utterance, retryError: error)
                        }
                    } else {
                        print("[TTS] queue cancelled id=\(idPrefix)")
                    }
                } else if Self.isNeuralContention(error) {
                    print("⚠️ [TTS] worker concurrency race detected; retrying in serialized queue...")
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    do {
                        try await renderNeuralUtterance(utterance)
                        print("[TTS] queue complete id=\(idPrefix) (after retry)")
                    } catch {
                        await handleFailedNeuralRetry(utterance, retryError: error)
                    }
                } else {
                    await speakWithAppleVoice(
                        utterance,
                        reason: "neural synthesis failed (\(error.localizedDescription))",
                        isFailureFallback: true
                    )
                }
                utterance.onCompletedOrFailed?()
            }
        }

        queueProcessingTask = nil
        if pendingQueue.isEmpty && audioPlayer?.isPlaying != true {
            isCurrentlySpeakingOrPending = false
            voicePathIdleSince = Date()
        }
    }

    /// A retry's own error decides what happens next: a cancellation is dropped
    /// (never the Apple voice); a genuine failure follows the one-voice-per-turn
    /// failure policy.
    private func handleFailedNeuralRetry(_ utterance: QueuedUtterance, retryError: Error) async {
        let idPrefix = String(utterance.id.uuidString.prefix(8))
        if Self.isNeuralCancellation(retryError) || Task.isCancelled {
            print("🔇 [TTS] dropping id=\(idPrefix): retry was cancelled; no Apple fallback for a cancelled synthesis")
            return
        }
        await speakWithAppleVoice(
            utterance,
            reason: "neural retry failed (\(retryError.localizedDescription))",
            isFailureFallback: true
        )
    }

    private func resetVoicePathAfterIdleGapIfNeeded() {
        defer { voicePathIdleSince = nil }
        guard let idleSince = voicePathIdleSince,
              Date().timeIntervalSince(idleSince) >= voicePathIdleResetSeconds else { return }
        activeVoicePathForTurn = .none
    }

    /// Renders one neural utterance and marks the turn's voice path as neural
    /// the moment its playback starts.
    private func renderNeuralUtterance(_ utterance: QueuedUtterance) async throws {
        let voicePathTrackingUtterance = QueuedUtterance(
            id: utterance.id,
            text: utterance.text,
            explicitLocale: utterance.explicitLocale,
            isFinal: utterance.isFinal,
            route: utterance.route,
            playbackGeneration: utterance.playbackGeneration,
            onPlaybackStarted: { [weak self] in
                if let self, utterance.playbackGeneration == self.playbackGeneration {
                    self.activeVoicePathForTurn = .neural
                }
                utterance.onPlaybackStarted?()
            },
            onCompletedOrFailed: utterance.onCompletedOrFailed
        )
        if let injectedNeuralUtteranceRenderer {
            try await injectedNeuralUtteranceRenderer(voicePathTrackingUtterance)
        } else {
            try await synthesizeAndPlay(voicePathTrackingUtterance)
        }
    }

    /// Speaks `utterance` with the Apple voice and waits for it to finish, so the
    /// next queued utterance cannot overlap it. A FAILURE fallback is refused
    /// when the neural voice is already speaking this turn (the chunk is dropped
    /// instead of switching voices mid-answer) and otherwise locks the turn to
    /// the Apple voice.
    private func speakWithAppleVoice(_ utterance: QueuedUtterance, reason: String, isFailureFallback: Bool) async {
        let idPrefix = String(utterance.id.uuidString.prefix(8))
        guard utterance.playbackGeneration == playbackGeneration else {
            print("[TTS] queue cancelled id=\(idPrefix)")
            return
        }
        if isFailureFallback {
            guard activeVoicePathForTurn != .neural else {
                print("🔇 [TTS] dropping id=\(idPrefix) (\(reason)): the neural voice is already speaking this turn")
                return
            }
            activeVoicePathForTurn = .apple
        }
        print("[TTS] fallback reason=\(reason)")
        try? await fallbackClient.speakText(utterance.text, explicitLocale: utterance.explicitLocale, isFinal: utterance.isFinal)
        await waitUntilAppleVoiceFinishes(playbackGenerationAtStart: utterance.playbackGeneration)
    }

    /// `LocalTTSClient.speakText` returns as soon as the utterance is handed to
    /// AVSpeechSynthesizer; without this wait the queue started the next neural
    /// sentence while the Apple voice was still speaking.
    private func waitUntilAppleVoiceFinishes(playbackGenerationAtStart: Int) async {
        let deadline = Date().addingTimeInterval(Self.appleVoiceCompletionWaitLimitSeconds)
        while fallbackClient.isPlaying
            && playbackGenerationAtStart == playbackGeneration
            && !Task.isCancelled
            && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func isNeuralCancellation(_ error: Error) -> Bool {
        (error as? PaceSofeliaTTSError) == .cancelled
            || (error as? PaceSherpaTTSError) == .cancelled
            || error is CancellationError
    }

    static func isNeuralContention(_ error: Error) -> Bool {
        (error as? PaceSofeliaTTSError) == .alreadySynthesizing
            || (error as? PaceSherpaTTSError) == .alreadySynthesizing
    }

    private func synthesizeAndPlay(_ utterance: QueuedUtterance) async throws {
        let wavData: Data

        switch utterance.route {
        case .englishKokoro:
            await sofeliaWorker.unload()
            let configResult = modelManager.resolveKokoroConfiguration()
            guard case .success(let config) = configResult else {
                if case .failure(let err) = configResult { throw err }
                throw PaceNeuralTTSModelError.approvedRootNotFound
            }
            let synthesized = try await worker.synthesizeEnglish(text: utterance.text, config: config, speakerId: 3)
            wavData = PaceWAVEncoder.encodeWAV(samples: synthesized.samples, sampleRate: synthesized.sampleRate)

        case .swedishAlma:
            await sofeliaWorker.unload()
            let configResult = modelManager.resolveSwedishConfiguration()
            guard case .success(let config) = configResult else {
                if case .failure(let err) = configResult { throw err }
                throw PaceNeuralTTSModelError.approvedRootNotFound
            }
            let synthesized = try await worker.synthesizeSwedish(text: utterance.text, config: config)
            wavData = PaceWAVEncoder.encodeWAV(samples: synthesized.samples, sampleRate: synthesized.sampleRate)

        case .arabicSofelia:
            await worker.unload()
            let configResult = modelManager.resolveSofeliaConfiguration()
            guard case .success(let config) = configResult else {
                if case .failure(let err) = configResult { throw err }
                throw PaceNeuralTTSModelError.approvedRootNotFound
            }
            let synthesized = try await sofeliaWorker.synthesizeArabic(text: utterance.text, config: config)
            wavData = PaceWAVEncoder.encodeWAV(samples: synthesized.samples, sampleRate: synthesized.sampleRate)

        case .appleFallback:
            // Handled by the queue loop before rendering, so the Apple voice is
            // subject to the one-voice-per-turn rule.
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
