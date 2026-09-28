//
//  QTaskCompletionMemoryRedactionTests.swift
//  leanring-buddyTests
//
//  Proves the model's final answer never reaches durable memory: every
//  `task_completion:<taskId>` record holds only a metadata descriptor (label,
//  character count, SHA-256), on the success, model-failure fallback,
//  direct-answer, and failure paths — while the transient, user-visible
//  answer is unchanged.
//
//  The sentinels below are synthetic and non-sensitive. One is
//  credential-shaped (QSecretRedactor would catch it); the other is a plain
//  password-like word that pattern redaction cannot catch — which is why the
//  durable copy must be metadata-only rather than redacted prose.
//  Persisted-content checks report presence/absence only.
//

import CryptoKit
import Foundation
import Testing
@testable import Pace

private struct SyntheticGroundedSummaryFailure: Error {}

/// Plans through MockAutonomousModelProvider; returns a chosen grounded summary,
/// or throws to force the runtime's non-model fallback summary.
private final class SentinelSummaryModelProvider: QStructuredModelProvider, @unchecked Sendable {
    private let planner = MockAutonomousModelProvider()
    private let groundedSummary: String?

    init(groundedSummary: String?, structuredPlans: [String]) {
        self.groundedSummary = groundedSummary
        planner.structuredPlansToReturn = structuredPlans
    }
    func generatePlan(for task: QTask) async throws -> [QActionRequest] {
        try await planner.generatePlan(for: task)
    }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
        try await planner.generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext)
    }
    func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String {
        guard let groundedSummary else { throw SyntheticGroundedSummaryFailure() }
        return groundedSummary
    }
}

/// Answers every turn directly with a chosen text.
private final class SentinelDirectAnswerModelProvider: QConversationalModelProvider, @unchecked Sendable {
    private let planner = MockAutonomousModelProvider()
    private let directAnswerText: String

    init(directAnswerText: String) {
        self.directAnswerText = directAnswerText
    }
    func generatePlan(for task: QTask) async throws -> [QActionRequest] {
        try await planner.generatePlan(for: task)
    }
    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
        try await planner.generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext)
    }
    func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String {
        directAnswerText
    }
    func generateTurnPlan(
        for task: QTask,
        memoryContext: String?,
        failureContext: String?,
        decisionPlan: QDecisionPlan?,
        streamHandler: (@Sendable (QCoreStreamEvent) -> Void)?
    ) async throws -> QParsedPlanResult {
        .directAnswer(QDirectAnswerResult(text: directAnswerText))
    }
}

@MainActor
@Suite("task_completion durable memory is metadata-only", .serialized)
struct QTaskCompletionMemoryRedactionTests {

    private static let secretSentinel = "TEST_SECRET_SENTINEL_9F31"
    private static let passwordSentinel = "TEST_PASSWORD_SENTINEL_7A42"
    /// Model prose carrying both sentinels: one credential-shaped, one plain.
    private static let sentinelModelProse = "Done. The field shows api_key=\(secretSentinel) and the password is \(passwordSentinel)."

    private static let noopPlanJSON = """
    {
      "taskPrompt": "Synthetic task",
      "steps": [
        { "actionName": "test.noop", "toolFamily": "test", "description": "No-op" }
      ]
    }
    """

    // MARK: - Helpers

    private static func taskCompletionRecord(in memoryStore: QSQLiteMemoryStore, task: QTask) throws -> QMemoryRecord? {
        try memoryStore.getByKey("task_completion:\(task.taskId)", sessionId: task.sessionId)
    }

    /// True when `content` is exactly the metadata-only descriptor shape and nothing else.
    private static func isMetadataOnlyDescriptor(_ content: String, label: String) -> Bool {
        let pattern = #"^\[\#(NSRegularExpression.escapedPattern(for: label)) omitted from durable memory — [0-9]+ chars, sha256=[0-9a-f]{64}\]$"#
        return content.range(of: pattern, options: .regularExpression) != nil
    }

    /// Independently computed descriptor fields, so the test does not trust the helper.
    private static func expectedDescriptor(label: String, text: String) -> String {
        let digestHex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02hhx", $0) }.joined()
        return "[\(label) omitted from durable memory — \(text.count) chars, sha256=\(digestHex)]"
    }

    private static func expectNoSentinel(in content: String) {
        #expect(!content.contains(secretSentinel))
        #expect(!content.contains(passwordSentinel))
        #expect(!content.contains("api_key"))
        #expect(!content.lowercased().contains("password is"))
    }

    // MARK: - 1/2/3/7/9. Success path (model grounded summary)

    @Test("1/2/3/7/9. A grounded model summary never reaches task_completion; the transient answer is unchanged")
    func groundedSummaryIsMetadataOnlyInDurableMemory() async throws {
        let memoryStore = try QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: SentinelSummaryModelProvider(groundedSummary: Self.sentinelModelProse, structuredPlans: [Self.noopPlanJSON]),
            memoryProvider: memoryStore,
            executionProvider: MockFailingExecutionProvider(),
            endpointName: "task-completion-success-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Run the synthetic task")

        // 7. The transient, user-visible answer is the model's prose, unchanged.
        guard case .completed(let transientSummary) = task.state else {
            Issue.record("expected a completed task, got \(task.state)")
            return
        }
        #expect(transientSummary == Self.sentinelModelProse)

        // 1/2. Neither sentinel is persisted.
        let record = try #require(try Self.taskCompletionRecord(in: memoryStore, task: task))
        Self.expectNoSentinel(in: record.content)

        // 3. Only the metadata descriptor, matching independently computed fields.
        #expect(Self.isMetadataOnlyDescriptor(record.content, label: "task completion summary"))
        #expect(record.content == Self.expectedDescriptor(label: "task completion summary", text: transientSummary))

        // 9. Reader compatibility: same key, provenance, and task/session identity.
        #expect(record.key == "task_completion:\(task.taskId)")
        #expect(record.taskId == task.taskId)
        #expect(record.sessionId == task.sessionId)
        #expect(record.provenanceSource == "core_runtime")
        #expect(record.provenanceKind == QProvenanceKind.untrustedTool(toolName: "model_summary").rawTag)
    }

    // MARK: - 6. Model-call failure → non-model fallback summary

    @Test("6. The non-model fallback summary (built from the intent and evidence) never reaches task_completion")
    func fallbackSummaryIsMetadataOnlyInDurableMemory() async throws {
        let memoryStore = try QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: SentinelSummaryModelProvider(groundedSummary: nil, structuredPlans: [Self.noopPlanJSON]),
            memoryProvider: memoryStore,
            executionProvider: MockFailingExecutionProvider(),
            endpointName: "task-completion-fallback-\(UUID().uuidString)"
        )

        // The fallback summary embeds the intent verbatim, so put the sentinels there.
        let task = try await runtime.submitIntent(prompt: "Store api_key=\(Self.secretSentinel) and \(Self.passwordSentinel)")

        guard case .completed(let transientSummary) = task.state else {
            Issue.record("expected a completed task, got \(task.state)")
            return
        }
        // The transient fallback text does carry the intent (unchanged behavior)…
        #expect(transientSummary.contains(Self.passwordSentinel))
        // …but the durable record never does.
        let record = try #require(try Self.taskCompletionRecord(in: memoryStore, task: task))
        Self.expectNoSentinel(in: record.content)
        #expect(record.content == Self.expectedDescriptor(label: "task completion summary", text: transientSummary))
    }

    // MARK: - 4. Direct-answer path

    @Test("4. A direct conversational answer never reaches task_completion; the transient answer is unchanged")
    func directAnswerIsMetadataOnlyInDurableMemory() async throws {
        let memoryStore = try QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: SentinelDirectAnswerModelProvider(directAnswerText: Self.sentinelModelProse),
            memoryProvider: memoryStore,
            executionProvider: MockFailingExecutionProvider(),
            endpointName: "task-completion-direct-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "What does the field say?")

        guard case .directAnswer(let transientAnswer) = task.state else {
            Issue.record("expected a direct answer, got \(task.state)")
            return
        }
        #expect(transientAnswer == Self.sentinelModelProse)
        let record = try #require(try Self.taskCompletionRecord(in: memoryStore, task: task))
        Self.expectNoSentinel(in: record.content)
        #expect(record.content == Self.expectedDescriptor(label: "direct answer", text: transientAnswer))
    }

    // MARK: - 5. Unsatisfied / replan-denied failure path

    @Test("5. The replan-denied failure path persists only a metadata descriptor")
    func failurePathIsMetadataOnlyInDurableMemory() async throws {
        let memoryStore = try QSQLiteMemoryStore(inMemory: true)
        let failingExecution = MockFailingExecutionProvider()
        failingExecution.alwaysFail = true
        let runtime = QCoreRuntime(
            modelProvider: SentinelSummaryModelProvider(
                groundedSummary: Self.sentinelModelProse,
                structuredPlans: [Self.noopPlanJSON, Self.noopPlanJSON, Self.noopPlanJSON]
            ),
            memoryProvider: memoryStore,
            executionProvider: failingExecution,
            endpointName: "task-completion-failure-\(UUID().uuidString)"
        )

        let task = try await runtime.submitIntent(prompt: "Fail with api_key=\(Self.secretSentinel) \(Self.passwordSentinel)")

        guard case .failed = task.state else {
            Issue.record("expected a failed task, got \(task.state)")
            return
        }
        let record = try #require(try Self.taskCompletionRecord(in: memoryStore, task: task))
        Self.expectNoSentinel(in: record.content)
        #expect(!record.content.hasPrefix("Failed:"))
        #expect(Self.isMetadataOnlyDescriptor(record.content, label: "task failure reason"))
    }

    // MARK: - 8. Retrieval

    @Test("8. queryContext cannot retrieve either sentinel from the new task_completion record")
    func retrievalCannotSurfaceSentinels() async throws {
        let memoryStore = try QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: SentinelSummaryModelProvider(groundedSummary: Self.sentinelModelProse, structuredPlans: [Self.noopPlanJSON]),
            memoryProvider: memoryStore,
            executionProvider: MockFailingExecutionProvider(),
            endpointName: "task-completion-retrieval-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Run the synthetic task")
        _ = try #require(try Self.taskCompletionRecord(in: memoryStore, task: task))

        for query in [Self.secretSentinel, Self.passwordSentinel, "api_key", "password"] {
            let retrieved = try await memoryStore.queryContext(for: query, limit: 50)
            #expect(!retrieved.contains { $0.contains(Self.secretSentinel) || $0.contains(Self.passwordSentinel) })
        }
    }

    // MARK: - 10. Audit unchanged

    @Test("10. The completion audit record keeps its existing metadata-only shape")
    func completionAuditRecordIsUnchanged() async throws {
        let memoryStore = try QSQLiteMemoryStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: SentinelSummaryModelProvider(groundedSummary: Self.sentinelModelProse, structuredPlans: [Self.noopPlanJSON]),
            memoryProvider: memoryStore,
            executionProvider: MockFailingExecutionProvider(),
            endpointName: "task-completion-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Run the synthetic task")

        let completionAuditRecord = try #require(
            QAuditLogger.shared.getRecentRecords(limit: 1000).last { $0.taskId == task.taskId && $0.tool == "agent.completed" }
        )
        let auditSummary = try #require(completionAuditRecord.executionSummary)
        #expect(auditSummary == QAuditRecord.safeDescriptor(omittedContent: Self.sentinelModelProse, label: "model response text"))
        Self.expectNoSentinel(in: auditSummary)
    }
}
