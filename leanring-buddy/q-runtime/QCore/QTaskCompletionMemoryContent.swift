//
//  QTaskCompletionMemoryContent.swift
//  leanring-buddy
//
//  Durable-memory content for a task's `task_completion:<taskId>` record.
//
//  Security boundary: the text handed to the memory store at task completion is
//  model-generated (a grounded summary or a direct answer) or built from raw
//  goal evidence, and the model's prompt can contain raw screen/Accessibility
//  reads, the user's selected text, and prior turns. Model output is
//  untrusted, so none of that text is ever persisted here — only a
//  deterministic, metadata-only descriptor: a fixed label, the text's
//  character count, and its SHA-256 digest. This deliberately does NOT rely on
//  QSecretRedactor, which only removes credential-SHAPED substrings and would
//  let a plain password or other sensitive prose through.
//
//  The user-visible answer is unaffected: it still flows transiently through
//  the task state and QAgentResult.summary. Only the durable memory copy is
//  reduced to metadata, using the same hash/length evidence shape as
//  QAuditRecord.safeDescriptor.
//

import Foundation
import CryptoKit

nonisolated enum QTaskCompletionMemoryContent {

    /// Which completion path produced the text. The raw value is the fixed,
    /// content-free label written into the descriptor.
    enum CompletionKind: String, Sendable, CaseIterable {
        case completionSummary = "task completion summary"
        case directAnswer = "direct answer"
        case failureReason = "task failure reason"
    }

    /// The only content ever persisted for a task completion:
    /// `[<label> omitted from durable memory — <N> chars, sha256=<64 hex>]`.
    static func durableDescriptor(for completionKind: CompletionKind, completionText: String) -> String {
        let digest = SHA256.hash(data: Data(completionText.utf8))
        let digestHex = digest.map { String(format: "%02hhx", $0) }.joined()
        return "[\(completionKind.rawValue) omitted from durable memory — \(completionText.count) chars, sha256=\(digestHex)]"
    }
}
