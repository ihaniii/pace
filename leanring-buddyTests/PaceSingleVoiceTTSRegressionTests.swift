//
//  PaceSingleVoiceTTSRegressionTests.swift
//  leanring-buddyTests
//
//  Regression for a dogfood defect: one Arabic Q-Core answer was heard in TWO
//  voices at once (Apple AVSpeechSynthesizer + Sofelia) and partly repeated.
//  Root causes, each pinned here:
//   1. A cancellation recorded on an idle Sofelia worker (every turn starts with
//      `stopPlayback()`) made the next turn's first synthesis throw `.cancelled`.
//   2. The neural queue treated `.cancelled` as a synthesis failure and fell back
//      to the Apple voice.
//   3. The Apple fallback returns as soon as the utterance is queued, so the next
//      neural sentence started while the Apple voice was still speaking.
//   4. The streaming pipeline advanced its dispatch cursor only AFTER `speakText`
//      returned, so a concurrent flush re-dispatched text already in flight.
//   5. The final direct answer was spoken again, in full, outside the pipeline.
//

import Foundation
import Testing
@testable import Pace

// MARK: - Test doubles

/// Behaves like `LocalTTSClient`: `speakText` returns immediately and the voice
/// keeps "speaking" for `simulatedUtteranceSeconds`, reported through `isPlaying`.
@MainActor
private final class TimedAppleVoiceMock: BuddyTTSClient {
    private let simulatedUtteranceSeconds: TimeInterval
    private(set) var spokenTexts: [String] = []
    private(set) var speakStartTimes: [Date] = []
    private var speakingUntil: Date = .distantPast
    private(set) var lastStopReason: PaceTTSStopReason = .naturalCompletion

    init(simulatedUtteranceSeconds: TimeInterval = 0) {
        self.simulatedUtteranceSeconds = simulatedUtteranceSeconds
    }

    var isPlaying: Bool { Date() < speakingUntil }

    func speakText(_ text: String) async throws {
        spokenTexts.append(text)
        speakStartTimes.append(Date())
        speakingUntil = Date().addingTimeInterval(simulatedUtteranceSeconds)
    }

    func stopPlayback() {
        speakingUntil = .distantPast
        lastStopReason = .manualStop
    }

    func recordExpectedStopReason(_ reason: PaceTTSStopReason) {}
}

/// Stands in for Kokoro/Alma/Sofelia synthesis + playback. Outcomes are consumed
/// in order; the last one repeats.
@MainActor
private final class ScriptedNeuralRenderer {
    enum Outcome {
        case succeed(playbackSeconds: TimeInterval)
        case fail(Error)
    }

    private let outcomes: [Outcome]
    weak var appleVoice: TimedAppleVoiceMock?
    private(set) var attemptCount = 0
    private(set) var playedTexts: [String] = []
    private(set) var neuralStartsWhileAppleVoiceSpeaking = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func render(_ utterance: PaceNeuralTTSClient.QueuedUtterance) async throws {
        attemptCount += 1
        switch outcomes[min(attemptCount - 1, outcomes.count - 1)] {
        case .fail(let error):
            throw error
        case .succeed(let playbackSeconds):
            if appleVoice?.isPlaying == true {
                neuralStartsWhileAppleVoiceSpeaking += 1
            }
            utterance.onPlaybackStarted?()
            playedTexts.append(utterance.text)
            if playbackSeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(playbackSeconds * 1_000_000_000))
            }
        }
    }
}

/// Records every dispatched chunk and holds the FIRST `speakText` call suspended
/// until released — reproducing neural synthesis latency before playback starts.
@MainActor
private final class FirstCallGatedTTSClient: BuddyTTSClient {
    private(set) var spokenTexts: [String] = []
    private var firstCallGate: CheckedContinuation<Void, Never>?
    private var hasGatedFirstCall: Bool
    private(set) var lastStopReason: PaceTTSStopReason = .naturalCompletion

    init(gatesFirstCall: Bool = true) {
        hasGatedFirstCall = !gatesFirstCall
    }

    var isFirstCallSuspended: Bool { firstCallGate != nil }
    var isPlaying: Bool { false }

    func speakText(_ text: String) async throws {
        spokenTexts.append(text)
        if !hasGatedFirstCall {
            hasGatedFirstCall = true
            await withCheckedContinuation { continuation in
                firstCallGate = continuation
            }
        }
    }

    func releaseFirstCall() {
        firstCallGate?.resume()
        firstCallGate = nil
    }

    func stopPlayback() {
        lastStopReason = .manualStop
        releaseFirstCall()
    }

    func recordExpectedStopReason(_ reason: PaceTTSStopReason) {}
}

@MainActor
private func makeNeuralClient(renderer: ScriptedNeuralRenderer, appleVoice: TimedAppleVoiceMock) -> PaceNeuralTTSClient {
    renderer.appleVoice = appleVoice
    return PaceNeuralTTSClient(
        fallbackClient: appleVoice,
        neuralUtteranceRenderer: { utterance in
            try await renderer.render(utterance)
        }
    )
}

@MainActor
private func waitUntilIdle(_ client: PaceNeuralTTSClient, timeoutSeconds: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while client.isPlaying && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
private func waitUntilFirstCallSuspended(_ client: FirstCallGatedTTSClient) async {
    for _ in 0..<2_000 where !client.isFirstCallSuspended {
        await Task.yield()
    }
}

private let arabicFirstSentence = "أهلين يا صديقي."
private let arabicSecondSentence = "بقدر أفتحلك تطبيقات وأقرألك الشاشة."
private let arabicFullAnswer = "\(arabicFirstSentence) \(arabicSecondSentence)"

// MARK: - Tests

@Suite("PaceSingleVoiceTTSRegressionTests", .serialized)
@MainActor
struct PaceSingleVoiceTTSRegressionTests {

    // MARK: 1. Idle Sofelia cancellation

    @Test("1. Cancelling an idle Sofelia worker records nothing that could fail the next synthesis")
    func idleSofeliaCancellationIsNoOp() async throws {
        let worker = PaceArabicSofeliaONNXWorker()
        await worker.cancelActiveSynthesis()
        #expect(await worker.hasPendingCancellation == false)

        // On a machine with the Sofelia model and ONNX runtime, prove the next real
        // synthesis succeeds right after an idle cancellation (the dogfood sequence).
        guard case .success(let config) = PaceNeuralTTSModelManager.shared.resolveSofeliaConfiguration() else {
            print("ℹ️ Sofelia model not installed; real-synthesis half of test 1 not applicable here")
            return
        }
        do {
            let audio = try await worker.synthesizeArabic(text: "مرحبا، كيفك اليوم؟", config: config)
            #expect(!audio.samples.isEmpty)
        } catch PaceSofeliaTTSError.runtimeUnavailable {
            print("ℹ️ ONNX runtime not linked; real-synthesis half of test 1 not applicable here")
        }
    }

    // MARK: 2. Cancelled synthesis never falls back to Apple

    @Test("2a. A cancelled Sofelia synthesis never triggers the Apple voice")
    func cancelledSofeliaNeverFallsBackToApple() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleVoice = TimedAppleVoiceMock()
        let renderer = ScriptedNeuralRenderer(outcomes: [.fail(PaceSofeliaTTSError.cancelled)])
        let client = makeNeuralClient(renderer: renderer, appleVoice: appleVoice)

        try await client.speakText(arabicFirstSentence, explicitLocale: "ar", isFinal: true)
        await waitUntilIdle(client)

        #expect(appleVoice.spokenTexts.isEmpty)
        // One stale-cancellation retry on the neural voice, then dropped.
        #expect(renderer.attemptCount == 2)
    }

    @Test("2b. A cancelled Kokoro synthesis never triggers the Apple voice (English preserved)")
    func cancelledKokoroNeverFallsBackToApple() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleVoice = TimedAppleVoiceMock()
        let renderer = ScriptedNeuralRenderer(outcomes: [.fail(PaceSherpaTTSError.cancelled)])
        let client = makeNeuralClient(renderer: renderer, appleVoice: appleVoice)

        try await client.speakText("Hello there, my friend.", explicitLocale: "en-US", isFinal: true)
        await waitUntilIdle(client)

        #expect(appleVoice.spokenTexts.isEmpty)
    }

    @Test("2c. stopPlayback during neural playback (barge-in) drops the utterance without the Apple voice")
    func bargeInDuringNeuralPlaybackNeverFallsBackToApple() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleVoice = TimedAppleVoiceMock()
        let renderer = ScriptedNeuralRenderer(outcomes: [.succeed(playbackSeconds: 2)])
        let client = makeNeuralClient(renderer: renderer, appleVoice: appleVoice)

        try await client.speakText(arabicFirstSentence, explicitLocale: "ar", isFinal: false)
        let secondSentence = Task { try await client.speakText(arabicSecondSentence, explicitLocale: "ar", isFinal: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        client.stopPlayback()
        _ = try? await secondSentence.value
        await waitUntilIdle(client)

        #expect(appleVoice.spokenTexts.isEmpty)
        #expect(renderer.playedTexts == [arabicFirstSentence])
    }

    @Test("2d. A contention retry that is itself cancelled never triggers the Apple voice")
    func cancelledContentionRetryNeverFallsBackToApple() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleVoice = TimedAppleVoiceMock()
        let renderer = ScriptedNeuralRenderer(outcomes: [
            .fail(PaceSofeliaTTSError.alreadySynthesizing),
            .fail(PaceSofeliaTTSError.cancelled)
        ])
        let client = makeNeuralClient(renderer: renderer, appleVoice: appleVoice)

        try await client.speakText(arabicFirstSentence, explicitLocale: "ar", isFinal: true)
        await waitUntilIdle(client)

        #expect(appleVoice.spokenTexts.isEmpty)
        #expect(renderer.attemptCount == 2)
    }

    @Test("2e. A stale-cancellation retry that fails genuinely follows the normal failure policy")
    func staleCancellationRetryGenuineFailureUsesFailurePolicy() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleVoice = TimedAppleVoiceMock()
        let renderer = ScriptedNeuralRenderer(outcomes: [
            .fail(PaceSofeliaTTSError.cancelled),
            .fail(PaceSofeliaTTSError.synthesisFailed(reason: "model missing"))
        ])
        let client = makeNeuralClient(renderer: renderer, appleVoice: appleVoice)

        try await client.speakText(arabicFirstSentence, explicitLocale: "ar", isFinal: true)
        await waitUntilIdle(client)

        // Nothing neural has played this turn, so the Apple voice may carry it.
        #expect(appleVoice.spokenTexts == [arabicFirstSentence])
        #expect(client.activeVoicePathForTurn == .apple)
    }

    // MARK: 3. One voice path per turn; no overlap

    @Test("3a. Once the neural voice is speaking, a later failed chunk is dropped, not spoken by Apple")
    func neuralTurnNeverSwitchesToApple() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleVoice = TimedAppleVoiceMock(simulatedUtteranceSeconds: 0.3)
        let renderer = ScriptedNeuralRenderer(outcomes: [
            .succeed(playbackSeconds: 0.05),
            .fail(PaceSofeliaTTSError.synthesisFailed(reason: "Frontend produced empty token sequence."))
        ])
        let client = makeNeuralClient(renderer: renderer, appleVoice: appleVoice)

        try await client.speakText(arabicFirstSentence, explicitLocale: "ar", isFinal: false)
        try await client.speakText("RAM.", explicitLocale: "ar", isFinal: true)
        await waitUntilIdle(client)

        #expect(appleVoice.spokenTexts.isEmpty)
        #expect(renderer.playedTexts == [arabicFirstSentence])
        #expect(client.activeVoicePathForTurn == .neural)
    }

    @Test("3b. A turn that starts on the Apple voice stays on it, sequentially, never overlapping")
    func appleTurnStaysAppleAndWaitsForEachUtterance() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleUtteranceSeconds: TimeInterval = 0.3
        let appleVoice = TimedAppleVoiceMock(simulatedUtteranceSeconds: appleUtteranceSeconds)
        let renderer = ScriptedNeuralRenderer(outcomes: [
            .fail(PaceSofeliaTTSError.synthesisFailed(reason: "model missing")),
            .succeed(playbackSeconds: 0.05)
        ])
        let client = makeNeuralClient(renderer: renderer, appleVoice: appleVoice)

        async let firstChunk: Void = client.speakText(arabicFirstSentence, explicitLocale: "ar", isFinal: false)
        async let secondChunk: Void = client.speakText(arabicSecondSentence, explicitLocale: "ar", isFinal: true)
        _ = try await (firstChunk, secondChunk)
        await waitUntilIdle(client)

        #expect(appleVoice.spokenTexts.count == 2)
        #expect(renderer.attemptCount == 1, "the second chunk must not try the neural voice mid-turn")
        #expect(renderer.neuralStartsWhileAppleVoiceSpeaking == 0)
        if appleVoice.speakStartTimes.count == 2 {
            let gap = appleVoice.speakStartTimes[1].timeIntervalSince(appleVoice.speakStartTimes[0])
            #expect(gap >= appleUtteranceSeconds * 0.9, "second Apple utterance started \(gap)s after the first")
        }
    }

    @Test("3c. The next turn (after stopPlayback) can use the neural voice again, never while Apple speaks")
    func nextTurnResetsVoicePath() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleVoice = TimedAppleVoiceMock(simulatedUtteranceSeconds: 0.3)
        let renderer = ScriptedNeuralRenderer(outcomes: [
            .fail(PaceSofeliaTTSError.synthesisFailed(reason: "transient")),
            .succeed(playbackSeconds: 0.05)
        ])
        let client = makeNeuralClient(renderer: renderer, appleVoice: appleVoice)

        try await client.speakText(arabicFirstSentence, explicitLocale: "ar", isFinal: true)
        #expect(client.activeVoicePathForTurn == .apple)

        client.stopPlayback()  // next turn begins
        #expect(client.activeVoicePathForTurn == .none)
        try await client.speakText(arabicSecondSentence, explicitLocale: "ar", isFinal: true)
        await waitUntilIdle(client)

        #expect(renderer.playedTexts == [arabicSecondSentence])
        #expect(renderer.neuralStartsWhileAppleVoiceSpeaking == 0)
    }

    @Test("3d. A language only Apple supports is still spoken during a neural turn — after the neural audio, never over it")
    func unsupportedLanguageSpokenSeriallyDuringNeuralTurn() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleVoice = TimedAppleVoiceMock(simulatedUtteranceSeconds: 0.2)
        let renderer = ScriptedNeuralRenderer(outcomes: [.succeed(playbackSeconds: 0.3)])
        let client = makeNeuralClient(renderer: renderer, appleVoice: appleVoice)

        let neuralStartedAt = Date()
        try await client.speakText(arabicFirstSentence, explicitLocale: "ar", isFinal: false)
        try await client.speakText("Привет, мир!", explicitLocale: nil, isFinal: true)
        await waitUntilIdle(client)

        #expect(appleVoice.spokenTexts == ["Привет, мир!"])
        if let appleStartedAt = appleVoice.speakStartTimes.first {
            #expect(appleStartedAt.timeIntervalSince(neuralStartedAt) >= 0.27, "Apple voice started before the neural sentence finished")
        }
    }

    @Test("3e. The failure lock resets after an idle gap, so later speech outside the turn is not silenced")
    func voicePathResetsAfterIdleGap() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleVoice = TimedAppleVoiceMock()
        let renderer = ScriptedNeuralRenderer(outcomes: [
            .succeed(playbackSeconds: 0.02),
            .fail(PaceSherpaTTSError.synthesisFailed(reason: "model missing"))
        ])
        renderer.appleVoice = appleVoice
        let client = PaceNeuralTTSClient(
            fallbackClient: appleVoice,
            neuralUtteranceRenderer: { utterance in try await renderer.render(utterance) },
            voicePathIdleResetSeconds: 0.1
        )

        try await client.speakText(arabicFirstSentence, explicitLocale: "ar", isFinal: true)
        await waitUntilIdle(client)
        try await Task.sleep(nanoseconds: 200_000_000)  // idle longer than the reset gap
        try await client.speakText("Reminder: stand up and stretch.", explicitLocale: "en-US", isFinal: true)
        await waitUntilIdle(client)

        #expect(appleVoice.spokenTexts == ["Reminder: stand up and stretch."])
    }

    // MARK: 4. Streaming dispatch race

    @Test("4. Text already in flight is never dispatched again by a concurrent flush or final answer")
    func streamingDispatchRaceDispatchesEachPortionOnce() async throws {
        let ttsClient = FirstCallGatedTTSClient()
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: ttsClient)
        pipeline.resetForNewTurn(locale: "ar")
        pipeline.markIntentCommitted()

        let firstDispatch = Task { await pipeline.acceptStreamedText("\(arabicFirstSentence) بقدر") }
        await waitUntilFirstCallSuspended(ttsClient)
        try #require(ttsClient.isFirstCallSuspended)

        // While the first sentence is still waiting for playback to start:
        await pipeline.flushFinal(finalSpokenText: arabicFullAnswer)
        await pipeline.speakFinalAnswerIfNeeded(arabicFullAnswer)

        ttsClient.releaseFirstCall()
        await firstDispatch.value

        #expect(ttsClient.spokenTexts == [arabicFirstSentence, arabicSecondSentence])
    }

    // MARK: 5. Final-answer deduplication

    @Test("5a. A fully streamed answer is not spoken again by the final-answer path")
    func streamedAnswerIsNotRepeated() async {
        let ttsClient = FirstCallGatedTTSClient(gatesFirstCall: false)
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: ttsClient)
        pipeline.resetForNewTurn(locale: "ar")
        pipeline.markIntentCommitted()

        await pipeline.acceptStreamedText("\(arabicFirstSentence) ")
        await pipeline.acceptStreamedText(arabicFullAnswer)
        await pipeline.flushFinal(finalSpokenText: arabicFullAnswer)
        await pipeline.speakFinalAnswerIfNeeded(arabicFullAnswer)

        #expect(ttsClient.spokenTexts == [arabicFirstSentence, arabicSecondSentence])
    }

    @Test("5b. A non-streamed final answer is spoken exactly once")
    func nonStreamedAnswerSpokenOnce() async {
        let ttsClient = FirstCallGatedTTSClient(gatesFirstCall: false)
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: ttsClient)
        pipeline.resetForNewTurn(locale: "ar")
        pipeline.markIntentCommitted()

        await pipeline.speakFinalAnswerIfNeeded(arabicFullAnswer)
        await pipeline.speakFinalAnswerIfNeeded(arabicFullAnswer)

        #expect(ttsClient.spokenTexts == [arabicFullAnswer])
    }

    @Test("5c. Mute, barge-in and a diverged stream suppress the final answer")
    func finalAnswerRespectsMuteBargeInAndDivergence() async {
        let mutedClient = FirstCallGatedTTSClient(gatesFirstCall: false)
        let mutedPipeline = StreamingSentenceTTSPipeline(ttsClient: mutedClient)
        mutedPipeline.resetForNewTurn(locale: "ar")
        mutedPipeline.setMutedForCurrentTurn(true)
        await mutedPipeline.speakFinalAnswerIfNeeded(arabicFullAnswer)
        #expect(mutedClient.spokenTexts.isEmpty)

        let bargeInClient = FirstCallGatedTTSClient(gatesFirstCall: false)
        let bargeInPipeline = StreamingSentenceTTSPipeline(ttsClient: bargeInClient)
        bargeInPipeline.resetForNewTurn(locale: "ar")
        bargeInPipeline.markIntentCommitted()
        bargeInPipeline.drainQueueAndStopForBargeIn()
        await bargeInPipeline.speakFinalAnswerIfNeeded(arabicFullAnswer)
        #expect(bargeInClient.spokenTexts.isEmpty)

        let divergedClient = FirstCallGatedTTSClient(gatesFirstCall: false)
        let divergedPipeline = StreamingSentenceTTSPipeline(ttsClient: divergedClient)
        divergedPipeline.resetForNewTurn(locale: "en-US")
        divergedPipeline.markIntentCommitted()
        await divergedPipeline.acceptStreamedText("Hello there, friend. ")
        await divergedPipeline.speakFinalAnswerIfNeeded("A completely different committed answer.")
        #expect(divergedClient.spokenTexts == ["Hello there, friend."])
    }

    @Test("5d. CompanionManager's direct-answer path does not re-speak text the stream already queued")
    func companionDirectAnswerPathDeduplicates() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleVoiceTTS-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = CompanionManager()
        manager.activityGoalPersistenceStore = PaceActivityGoalPersistenceStore(
            fileURL: tempDir.appendingPathComponent("activity-goal-model.json")
        )
        let ttsClient = FirstCallGatedTTSClient()
        manager.ttsClient = ttsClient
        manager.streamingSentenceTTSPipeline = StreamingSentenceTTSPipeline(ttsClient: ttsClient)
        manager.streamingSentenceTTSPipeline.resetForNewTurn(locale: "ar")
        manager.streamingSentenceTTSPipeline.markIntentCommitted()

        let streamedFirstSentence = Task {
            await manager.streamingSentenceTTSPipeline.acceptStreamedText("\(arabicFirstSentence) ")
        }
        await waitUntilFirstCallSuspended(ttsClient)
        try #require(ttsClient.isFirstCallSuspended)

        let directResult = QAgentResult(
            taskId: "single-voice-5d",
            sessionId: "single-voice-session",
            intent: "شو بتقدر تعمل؟",
            status: .directAnswer(text: arabicFullAnswer),
            summary: arabicFullAnswer
        )
        await manager.handleQAgentTurnResult(directResult, transcript: "شو بتقدر تعمل؟", detectedTurnLocale: "ar")

        ttsClient.releaseFirstCall()
        await streamedFirstSentence.value

        #expect(ttsClient.spokenTexts == [arabicFirstSentence, arabicSecondSentence])
    }

    // MARK: 6. Turn-start Arabic integration

    @Test("6a. Turn start (stopPlayback) followed by an Arabic turn: all chunks neural, zero Apple")
    func turnStartArabicTurnStaysNeural() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        let appleVoice = TimedAppleVoiceMock(simulatedUtteranceSeconds: 0.3)
        // The first synthesis of the turn is hit by a cancellation aimed at the
        // previous turn (the exact dogfood race); it must retry on Sofelia.
        let renderer = ScriptedNeuralRenderer(outcomes: [
            .fail(PaceSofeliaTTSError.cancelled),
            .succeed(playbackSeconds: 0.02)
        ])
        let client = makeNeuralClient(renderer: renderer, appleVoice: appleVoice)

        client.stopPlayback()  // what every PTT / typed / planner turn does first
        try await client.speakText(arabicFirstSentence, explicitLocale: "ar", isFinal: false)
        try await client.speakText(arabicSecondSentence, explicitLocale: "ar", isFinal: true)
        await waitUntilIdle(client)

        #expect(appleVoice.spokenTexts.isEmpty)
        #expect(renderer.playedTexts == [arabicFirstSentence, arabicSecondSentence])
    }

    @Test("6b. Real Sofelia worker: turn-start stopPlayback does not poison the next Arabic synthesis")
    func realSofeliaWorkerSurvivesTurnStartStop() async throws {
        PaceNeuralTTSSettings.setNeuralTTSEnabled(true)
        defer { PaceNeuralTTSSettings.resetToDefault() }
        guard case .success(let config) = PaceNeuralTTSModelManager.shared.resolveSofeliaConfiguration() else {
            print("ℹ️ Sofelia model not installed; test 6b not applicable here")
            return
        }
        let sofeliaWorker = PaceArabicSofeliaONNXWorker()
        let appleVoice = TimedAppleVoiceMock()
        var synthesizedChunkCount = 0
        // Real worker synthesis (the component that held the sticky flag); playback
        // is skipped so the test makes no sound.
        let client = PaceNeuralTTSClient(
            sofeliaWorker: sofeliaWorker,
            fallbackClient: appleVoice,
            neuralUtteranceRenderer: { utterance in
                let audio = try await sofeliaWorker.synthesizeArabic(text: utterance.text, config: config)
                if !audio.samples.isEmpty { synthesizedChunkCount += 1 }
                utterance.onPlaybackStarted?()
            }
        )

        client.stopPlayback()
        // Let the fire-and-forget worker cancellation from stopPlayback run first.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await sofeliaWorker.hasPendingCancellation == false)

        do {
            try await client.speakText("مرحبا، كيفك اليوم؟", explicitLocale: "ar", isFinal: true)
        } catch {
            Issue.record("speakText threw \(error)")
        }
        await waitUntilIdle(client, timeoutSeconds: 20)

        if (try? await sofeliaWorker.synthesizeArabic(text: "اختبار", config: config)) == nil {
            print("ℹ️ ONNX runtime not linked; synthesis half of test 6b not applicable here")
            return
        }
        #expect(appleVoice.spokenTexts.isEmpty)
        #expect(synthesizedChunkCount == 1)
    }
}
