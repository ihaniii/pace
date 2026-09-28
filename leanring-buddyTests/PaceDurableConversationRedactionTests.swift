//
//  PaceDurableConversationRedactionTests.swift
//  leanring-buddyTests
//
//  Proves a conversation turn containing credential-shaped content never
//  reaches DURABLE conversation memory — paceHistory, the unified memory
//  index, episodic facts, the persisted thread-memory snapshot, or the
//  thread summarizer's input — while transient surfaces (the chat session and
//  the in-session thread window) keep the original text, and clean turns are
//  persisted unchanged.
//
//  Runs on a bare CompanionManager in the test host, whose stores are all
//  isolated temp files (PaceTestHostDataIsolation). Only synthetic sentinels
//  are used; persisted-content checks report presence/absence only.
//

import CryptoKit
import Foundation
import Testing
@testable import Pace

/// Captures every summarizer input instead of calling a model.
private final class RecordingThreadSummarizerClient: PaceThreadSummarizerClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInputs: [PaceThreadSummarizerInput] = []
    var inputs: [PaceThreadSummarizerInput] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInputs
    }
    func updatedSummary(for input: PaceThreadSummarizerInput) async throws -> String {
        lock.lock()
        recordedInputs.append(input)
        lock.unlock()
        return "Synthetic rolling summary."
    }
}

@MainActor
@Suite("Durable conversation memory withholds credential-shaped turns", .serialized)
struct PaceDurableConversationRedactionTests {

    private static let secretSentinel = "TEST_SECRET_SENTINEL_9F31"
    private static let passwordSentinel = "TEST_PASSWORD_SENTINEL_7A42"

    private static func expectedWithheldDescriptor(label: String, text: String) -> String {
        let digestHex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02hhx", $0) }.joined()
        return "[\(label) withheld from durable memory — \(text.count) chars, sha256=\(digestHex)]"
    }

    private static func persistedTexts(_ companionManager: CompanionManager) -> [String] {
        var texts: [String] = []
        texts += companionManager.localRetriever.documents(forSource: .paceHistory).map(\.text)
        texts += companionManager.memoryIndex.allEntries().map(\.text)
        texts += companionManager.episodicFactStore.allFacts.map { "\($0)" }
        if let persistedSnapshot = companionManager.threadMemoryStore.load() {
            texts += persistedSnapshot.verbatimWindow.flatMap { [$0.userText, $0.assistantText] }
            if let summary = persistedSnapshot.summary { texts.append(summary) }
        }
        return texts
    }

    private static func anyContains(_ texts: [String], _ needle: String) -> Bool {
        texts.contains { $0.contains(needle) }
    }

    // MARK: - Credential-shaped content in the assistant answer

    @Test("A credential-shaped assistant answer is withheld from every durable sink; transient surfaces keep it")
    func credentialShapedAnswerIsWithheldFromDurableMemory() throws {
        let companionManager = CompanionManager()
        let userTranscript = "What does the config field say? \(UUID().uuidString)"
        let assistantResponse = "It says api_key=\(Self.secretSentinel)."

        companionManager.recordConversationTurn(userTranscript: userTranscript, assistantResponse: assistantResponse)

        let persisted = Self.persistedTexts(companionManager)
        #expect(!Self.anyContains(persisted, Self.secretSentinel))
        #expect(!Self.anyContains(persisted, "api_key"))
        // The whole turn — user text included — is replaced, not partially redacted.
        #expect(!Self.anyContains(persisted, userTranscript))
        let paceHistoryTexts = companionManager.localRetriever.documents(forSource: .paceHistory).map(\.text)
        #expect(Self.anyContains(paceHistoryTexts, Self.expectedWithheldDescriptor(label: "assistant response", text: assistantResponse)))
        #expect(Self.anyContains(paceHistoryTexts, Self.expectedWithheldDescriptor(label: "user message", text: userTranscript)))

        // Transient: the chat session and the in-session thread window keep the original answer.
        #expect(companionManager.chatSession.messages.contains { $0.body.contains(Self.secretSentinel) })
        #expect(companionManager.threadMemory.snapshot(now: Date()).verbatimWindow.contains { $0.assistantText == assistantResponse })
    }

    // MARK: - Credential-shaped content in the user's own words

    @Test("A credential-shaped user message is withheld from every durable sink too")
    func credentialShapedUserMessageIsWithheldFromDurableMemory() throws {
        let companionManager = CompanionManager()
        let userTranscript = "Remember my token=\(Self.secretSentinel) please"
        let assistantResponse = "Okay, noted. \(UUID().uuidString)"

        companionManager.recordConversationTurn(userTranscript: userTranscript, assistantResponse: assistantResponse)

        let persisted = Self.persistedTexts(companionManager)
        #expect(!Self.anyContains(persisted, Self.secretSentinel))
        #expect(!Self.anyContains(persisted, assistantResponse))
        #expect(Self.anyContains(
            companionManager.localRetriever.documents(forSource: .paceHistory).map(\.text),
            Self.expectedWithheldDescriptor(label: "user message", text: userTranscript)
        ))
    }

    // MARK: - Clean turns are unchanged

    @Test("A clean turn is persisted unchanged, so conversational recall is preserved")
    func cleanTurnIsPersistedUnchanged() throws {
        let companionManager = CompanionManager()
        let marker = UUID().uuidString
        let userTranscript = "What time is it? \(marker)"
        let assistantResponse = "It is noon. \(marker)"

        companionManager.recordConversationTurn(userTranscript: userTranscript, assistantResponse: assistantResponse)

        let paceHistoryTexts = companionManager.localRetriever.documents(forSource: .paceHistory).map(\.text)
        #expect(Self.anyContains(paceHistoryTexts, assistantResponse))
        let persistedSnapshot = try #require(companionManager.threadMemoryStore.load())
        #expect(persistedSnapshot.verbatimWindow.contains { $0.userText == userTranscript && $0.assistantText == assistantResponse })
        #expect(companionManager.memoryIndex.allEntries().contains { $0.text.contains(assistantResponse) })
    }

    // MARK: - Persisted thread snapshot vs in-session window

    @Test("The persisted thread snapshot holds descriptors while the in-session window keeps the original turn")
    func persistedSnapshotIsSanitizedButLiveWindowIsNot() throws {
        let companionManager = CompanionManager()
        let userTranscript = "Read it back \(UUID().uuidString)"
        let assistantResponse = "Bearer abcdefghijklmnopqrstuvwxyz0123 \(Self.secretSentinel)"

        companionManager.recordConversationTurn(userTranscript: userTranscript, assistantResponse: assistantResponse)

        let persistedSnapshot = try #require(companionManager.threadMemoryStore.load())
        #expect(!persistedSnapshot.verbatimWindow.contains { $0.assistantText.contains(Self.secretSentinel) || $0.userText == userTranscript })
        #expect(persistedSnapshot.verbatimWindow.contains {
            $0.assistantText == Self.expectedWithheldDescriptor(label: "assistant response", text: assistantResponse)
        })
        #expect(companionManager.threadMemory.snapshot(now: Date()).verbatimWindow.contains { $0.assistantText == assistantResponse })
    }

    // MARK: - Summarizer input

    @Test("The thread summarizer never receives a credential-shaped turn")
    func summarizerReceivesOnlyDurableSafeInput() async throws {
        let companionManager = CompanionManager()
        let recordingSummarizer = RecordingThreadSummarizerClient()
        companionManager.threadSummarizerClient = recordingSummarizer
        let sentinelAssistantResponse = "It says password=\(Self.secretSentinel)"

        // The window holds 4 turns; the 5th displaces the first (the sentinel turn) into the summarizer.
        companionManager.recordConversationTurn(userTranscript: "First question \(UUID().uuidString)", assistantResponse: sentinelAssistantResponse)
        for turnNumber in 2...5 {
            companionManager.recordConversationTurn(userTranscript: "Question \(turnNumber) \(UUID().uuidString)", assistantResponse: "Answer \(turnNumber).")
        }

        var waitedIterations = 0
        while recordingSummarizer.inputs.isEmpty && waitedIterations < 40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waitedIterations += 1
        }
        let summarizerInputs = recordingSummarizer.inputs
        #expect(!summarizerInputs.isEmpty)
        #expect(!summarizerInputs.contains {
            $0.displacedTurnPair.assistantText.contains(Self.secretSentinel)
                || ($0.priorSummary ?? "").contains(Self.secretSentinel)
        })
        #expect(summarizerInputs.contains {
            $0.displacedTurnPair.assistantText == Self.expectedWithheldDescriptor(label: "assistant response", text: sentinelAssistantResponse)
        })
    }

    // MARK: - Bypass writers (barge-in prefix, proactive nudge, failure narration)

    @Test("Single-text durable writes withhold credential-shaped text and pass clean text through")
    func singleTextWritesUseTheSamePolicy() {
        for label in ["interrupted assistant speech", "proactive nudge", "failure narration"] {
            let credentialShapedText = "Your key is sk-\(Self.secretSentinel)abcdefghijk"
            #expect(PaceDurableConversationContent.durableText(credentialShapedText, label: label)
                == Self.expectedWithheldDescriptor(label: label, text: credentialShapedText))
            let cleanText = "You have a meeting at 3."
            #expect(PaceDurableConversationContent.durableText(cleanText, label: label) == cleanText)
        }
    }

    // MARK: - Known limit (recorded explicitly)

    @Test("Known limit of PR-b1: a plain password with no credential shape is NOT detected")
    func plainPasswordIsAKnownLimit() throws {
        let companionManager = CompanionManager()
        let assistantResponse = "The password is \(Self.passwordSentinel)"

        companionManager.recordConversationTurn(userTranscript: "What is it? \(UUID().uuidString)", assistantResponse: assistantResponse)

        // Documented gap: credential-shape detection cannot recognize this. Provenance-based gating
        // (a follow-up) is required to withhold plain secrets derived from observations.
        #expect(!PaceDurableConversationContent.containsCredentialShapedContent(assistantResponse))
        #expect(Self.anyContains(companionManager.localRetriever.documents(forSource: .paceHistory).map(\.text), Self.passwordSentinel))
    }
}
