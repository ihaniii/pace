//
//  PaceDurableConversationContent.swift
//  leanring-buddy
//
//  Decides what of a conversation turn may be written to DURABLE memory —
//  paceHistory (retrieval-index.json), the unified memory index (and its
//  Spotlight mirror), episodic facts, and the persisted thread-memory
//  snapshot and its rolling summary.
//
//  Policy (PR-b1): if a turn contains credential-shaped content — in the
//  user's words, the assistant's answer, or across the two — the WHOLE turn is
//  withheld from durable memory and replaced by a metadata-only descriptor (a
//  fixed label, the character count, and a SHA-256 digest). Nothing is
//  partially redacted: a turn is either persisted as-is or not at all, the
//  same "never carried, redacted or otherwise" rule QVerifiedMemoryContracts
//  applies to model-derived text.
//
//  QSecretRedactor is used here only as a DETECTOR (does redaction change the
//  text?), never as the transformer. It recognizes credential-SHAPED text
//  (API keys, tokens, bearer values, private keys, `password=` assignments);
//  a plain secret with no credential shape is NOT detected by this policy —
//  a known limit, to be narrowed by provenance-based gating in a follow-up.
//
//  Transient surfaces are unaffected: speech, the response overlay, the chat
//  session, PacePad delivery, and the in-session thread window (the next
//  prompt's context) all keep the original text.
//

import CryptoKit
import Foundation

enum PaceDurableConversationContent {

    /// A turn as it may be written to durable memory.
    struct DurableTurn: Equatable, Sendable {
        let userTranscript: String
        let assistantResponse: String
        /// True when the original turn was withheld and replaced by descriptors.
        let wasWithheld: Bool
    }

    static let withheldUserTextLabel = "user message"
    static let withheldAssistantTextLabel = "assistant response"

    /// Whether `text` contains credential-shaped content.
    static func containsCredentialShapedContent(_ text: String) -> Bool {
        QSecretRedactor.redact(text) != text
    }

    /// The durable form of a whole turn: unchanged when clean, otherwise both
    /// sides replaced by descriptors.
    static func durableTurn(userTranscript: String, assistantResponse: String) -> DurableTurn {
        let turnContainsCredentialShapedContent =
            containsCredentialShapedContent(userTranscript)
            || containsCredentialShapedContent(assistantResponse)
            || containsCredentialShapedContent("\(userTranscript)\n\(assistantResponse)")
        guard turnContainsCredentialShapedContent else {
            return DurableTurn(userTranscript: userTranscript, assistantResponse: assistantResponse, wasWithheld: false)
        }
        return DurableTurn(
            userTranscript: withheldDescriptor(label: withheldUserTextLabel, text: userTranscript),
            assistantResponse: withheldDescriptor(label: withheldAssistantTextLabel, text: assistantResponse),
            wasWithheld: true
        )
    }

    /// The durable form of a single text written outside a full turn (for
    /// example a barge-in prefix or a proactive nudge).
    static func durableText(_ text: String, label: String) -> String {
        containsCredentialShapedContent(text) ? withheldDescriptor(label: label, text: text) : text
    }

    /// The durable form of a thread turn pair (persisted snapshot, summarizer input).
    static func durableTurnPair(_ turnPair: PaceThreadTurnPair) -> PaceThreadTurnPair {
        let durable = durableTurn(userTranscript: turnPair.userText, assistantResponse: turnPair.assistantText)
        guard durable.wasWithheld else { return turnPair }
        return PaceThreadTurnPair(
            turnId: turnPair.turnId,
            userText: durable.userTranscript,
            assistantText: durable.assistantResponse,
            recordedAt: turnPair.recordedAt
        )
    }

    /// The durable form of a whole thread-memory snapshot: every verbatim
    /// pair and the rolling summary pass through the same policy. Only the
    /// persisted copy changes; the live in-session window is untouched.
    static func durableSnapshot(_ snapshot: PaceThreadMemorySnapshot) -> PaceThreadMemorySnapshot {
        PaceThreadMemorySnapshot(
            sessionId: snapshot.sessionId,
            summary: snapshot.summary.map { durableText($0, label: "conversation summary") },
            summaryVersion: snapshot.summaryVersion,
            nextSummaryVersionToAssign: snapshot.nextSummaryVersionToAssign,
            verbatimWindow: snapshot.verbatimWindow.map(durableTurnPair),
            lastTurnRecordedAt: snapshot.lastTurnRecordedAt,
            savedAt: snapshot.savedAt
        )
    }

    /// `[<label> withheld from durable memory — <N> chars, sha256=<64 hex>]`
    static func withheldDescriptor(label: String, text: String) -> String {
        let digestHex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02hhx", $0) }.joined()
        return "[\(label) withheld from durable memory — \(text.count) chars, sha256=\(digestHex)]"
    }
}
