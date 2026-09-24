//
//  QTurnExecutionRouter.swift
//  leanring-buddy
//
//  Phase 4.1: Q-Core Production Integration Foundation.
//  Provides a deterministic, turn-bound execution boundary between the legacy
//  planner/executor and the hardened Q-Core runtime.
//
//  Security Invariants:
//  - Engine mode is selected ONCE at turn creation and is strictly immutable.
//  - Q-Core failure MUST NEVER fall back to legacy execution (fail-closed).
//  - Legacy failure MUST NEVER fall back to Q-Core execution.
//  - No model output or classifier can alter engine selection.
//  - Context bridge preserves provenance and does not persist raw screen/OCR bytes.
//

import Foundation

// MARK: - Engine Mode Contract

public enum QExecutionEngineMode: String, Codable, Sendable, Equatable {
    case legacyAuthoritative = "legacyAuthoritative"
    case qCoreAuthoritative = "qCoreAuthoritative"
}

// MARK: - Context Parity Types

public struct QConversationTurnSnippet: Sendable, Codable, Equatable {
    public let userTranscript: String
    public let assistantResponse: String

    public init(userTranscript: String, assistantResponse: String) {
        self.userTranscript = userTranscript
        self.assistantResponse = assistantResponse
    }
}

public struct QAgentTurnContext: Sendable, Equatable {
    /// Phase 4.4: Maximum characters of active selection context ingested into planning.
    /// Bounded to fit cleanly within local model context windows without truncation risk.
    public static let maxActiveSelectionCharacters: Int = 2_000

    public let turnId: String
    public let transcript: String
    public let conversationHistory: [QConversationTurnSnippet]
    public let activeApplicationBundleId: String?
    public let activeApplicationName: String?
    public let hasScreenshot: Bool
    public let selectionText: String?

    public init(
        turnId: String,
        transcript: String,
        conversationHistory: [QConversationTurnSnippet] = [],
        activeApplicationBundleId: String? = nil,
        activeApplicationName: String? = nil,
        hasScreenshot: Bool = false,
        selectionText: String? = nil
    ) {
        self.turnId = turnId
        self.transcript = transcript
        self.conversationHistory = conversationHistory
        self.activeApplicationBundleId = activeApplicationBundleId
        self.activeApplicationName = activeApplicationName
        self.hasScreenshot = hasScreenshot
        self.selectionText = selectionText
    }
}

// MARK: - Turn Execution Request

public struct QTurnExecutionRequest: Sendable {
    public let turnId: String
    public let transcript: String
    public let engineMode: QExecutionEngineMode
    public let context: QAgentTurnContext
    public let createdAt: Date

    public init(
        turnId: String,
        transcript: String,
        engineMode: QExecutionEngineMode,
        context: QAgentTurnContext,
        createdAt: Date = Date()
    ) {
        self.turnId = turnId
        self.transcript = transcript
        self.engineMode = engineMode
        self.context = context
        self.createdAt = createdAt
    }
}

// MARK: - Turn Execution Result

public enum QTurnExecutionResult: Sendable, Codable, Equatable {
    case success(summary: String)
    case directAnswer(text: String)
    case failure(reason: String)
    case blocked(reason: String)
    case awaitingApproval(actionDescription: String)
    case cancelled(reason: String)

    public var summary: String {
        switch self {
        case .success(let s): return s
        case .directAnswer(let text): return text
        case .failure(let r): return "Failed: \(r)"
        case .blocked(let r): return "Blocked: \(r)"
        case .awaitingApproval(let d): return "Awaiting approval: \(d)"
        case .cancelled(let r): return "Cancelled: \(r)"
        }
    }

    public var isSuccess: Bool {
        switch self {
        case .success, .directAnswer:
            return true
        default:
            return false
        }
    }
}

// MARK: - Turn Execution Router

public struct QTurnExecutionRouter: Sendable {
    public init() {}

    /// Dispatches a turn to exactly one engine determined by `request.engineMode`.
    /// Invariant: Under no circumstance will a failure or rejection in one engine
    /// invoke the other engine for that turn.
    public func routeTurn(
        request: QTurnExecutionRequest,
        legacyEngine: @Sendable () async throws -> QTurnExecutionResult,
        qCoreEngine: @Sendable () async throws -> QTurnExecutionResult
    ) async -> QTurnExecutionResult {
        if Task.isCancelled {
            return .cancelled(reason: "Turn cancelled before execution")
        }

        switch request.engineMode {
        case .legacyAuthoritative:
            do {
                return try await legacyEngine()
            } catch {
                if Task.isCancelled {
                    return .cancelled(reason: "Legacy turn cancelled")
                }
                // Fail closed: No fallback to Q-Core
                return .failure(reason: "Legacy execution failed: \(error.localizedDescription)")
            }

        case .qCoreAuthoritative:
            do {
                return try await qCoreEngine()
            } catch {
                if Task.isCancelled {
                    return .cancelled(reason: "Q-Core turn cancelled")
                }
                // Fail closed: No fallback to legacy engine
                return .failure(reason: "Q-Core execution failed: \(error.localizedDescription)")
            }
        }
    }
}
