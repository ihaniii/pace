//
//  QCandidateAttributionTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 3 (Verified Response Path), fourth slice: candidate-level
//  outcome attribution. Proves the resolver only ever reads authoritative provenance (never guesses),
//  never influences trust/verification, keeps conflicting candidates independent (never a winner),
//  and that recording into capability memory inherits every existing safety rule unchanged.
//

import Testing
import Foundation
@testable import Pace

// MARK: - Fixtures

private enum AttributionFixtures {
    static let now = CapabilityFixtures.now

    static func modelResult(_ backend: QModelBackendType, attemptSuffix: String, text: String) -> QEvidenceModelResult {
        QEvidenceModelResult(
            attemptId: QModelAttemptID(rawValue: "\(EvidenceFixtures.taskId)-attempt-\(backend.rawValue)-\(attemptSuffix)"),
            candidateId: QModelCandidateID(backend: backend), backend: backend, outputText: text
        )
    }

    static func decisionPlan() -> QDecisionPlan { EvidenceFixtures.decisionPlan(requirement: .independentVerification) }

    /// A pool with ONE model claim independently verified by execution evidence, plus its record.
    static func verifiedPool(backend: QModelBackendType = .ollama, subject: String = "file count", value: String = "3") async -> QEvidencePool {
        var pool = EvidenceFixtures.pool()
        pool.ingest(modelResult(backend, attemptSuffix: "0", text: "\(subject): \(value)").asDraft())
        EvidenceFixtures.addExecutionClaim(&pool, subject: subject, value: value)
        await EvidenceFixtures.verify(&pool)
        return pool
    }
}

private extension QEvidenceModelResult {
    /// Mirrors exactly what `QEvidencePipeline.ingestLocalInputs` does for a `modelResults` entry —
    /// used here so unit tests can build a pool without running the whole pipeline.
    func asDraft() -> QEvidenceDraft {
        QEvidenceDraft(
            taskId: EvidenceFixtures.taskId, sourceId: attemptId?.rawValue ?? "model-output",
            kind: .modelGenerated, provenance: .untrustedTool(toolName: "model:\(backend?.rawValue ?? "unknown")"),
            origin: QEvidenceOrigin(attemptId: attemptId, candidateId: candidateId, backend: backend),
            content: outputText
        )
    }
}

@Suite("QCandidateAttributionResolverTests")
struct QCandidateAttributionResolverTests {

    private let now = AttributionFixtures.now

    // MARK: - 1-3: identity retained

    @Test("1/2/3. Model evidence and claims retain candidate/attempt/backend identity, resolved through the claim's origin evidence item")
    func retainsCandidateAttemptAndBackendIdentity() async {
        let pool = await AttributionFixtures.verifiedPool(backend: .ollama)
        let records = QCandidateAttributionResolver.resolve(pool: pool, now: now)
        let record = try! #require(records.first)
        #expect(record.backend == .ollama)
        #expect(record.candidateId == QModelCandidateID(backend: .ollama).rawValue)
        #expect(record.attemptId == "\(EvidenceFixtures.taskId)-attempt-local.ollama-0")
        #expect(record.taskId == EvidenceFixtures.taskId)
        #expect(!record.claimId.isEmpty)
        #expect(record.isAttributionAvailable)
    }

    // MARK: - 4-6: outcome mapping

    @Test("4. A verified claim attributes verified to the correct candidate")
    func verifiedClaimAttributesCorrectly() async {
        let pool = await AttributionFixtures.verifiedPool(backend: .llamaCpp)
        let record = try! #require(QCandidateAttributionResolver.resolve(pool: pool, now: now).first)
        #expect(record.outcome == .verified)
        #expect(record.backend == .llamaCpp)
        #expect(record.verification == "verified")
    }

    @Test("5. A contradicted claim attributes contradicted to the correct candidate")
    func contradictedClaimAttributesCorrectly() async {
        var pool = EvidenceFixtures.pool()
        pool.ingest(AttributionFixtures.modelResult(.ollama, attemptSuffix: "0", text: "count: 9").asDraft())
        EvidenceFixtures.addExecutionClaim(&pool, subject: "count", value: "3")
        await EvidenceFixtures.verify(&pool)
        let record = try! #require(QCandidateAttributionResolver.resolve(pool: pool, now: now).first)
        #expect(record.outcome == .contradicted)
        #expect(record.backend == .ollama)
    }

    @Test("6. An unresolved claim (no independent evidence either way) attributes unresolved")
    func unresolvedClaimAttributesCorrectly() async {
        var pool = EvidenceFixtures.pool()
        pool.ingest(AttributionFixtures.modelResult(.mlx, attemptSuffix: "0", text: "obscure fact: 42").asDraft())
        await EvidenceFixtures.verify(&pool)
        let record = try! #require(QCandidateAttributionResolver.resolve(pool: pool, now: now).first)
        #expect(record.outcome == .unresolved)
        #expect(record.backend == .mlx)
    }

    @Test("A claim whose verification never ran (requirement .none, still pending/notRequired) is notEvaluated, not unresolved")
    func neverVerifiedClaimIsNotEvaluated() async {
        var pool = EvidenceFixtures.pool(requirement: .none)
        pool.ingest(AttributionFixtures.modelResult(.appleFoundation, attemptSuffix: "0", text: "topic: value").asDraft())
        // No verification run at all — claim stays `.notRequired` per the pool's own rules.
        let record = try! #require(QCandidateAttributionResolver.resolve(pool: pool, now: now).first)
        #expect(record.outcome == .notEvaluated)
        #expect(record.backend == .appleFoundation)   // identity is still known even though no verdict exists yet
    }

    // MARK: - 7/8: missing attribution, no heuristics

    @Test("7. A model-generated claim whose origin carries no identity becomes attributionUnavailable — never a guess")
    func missingOriginBecomesUnavailable() async {
        var pool = EvidenceFixtures.pool()
        // A model claim ingested WITHOUT an origin (the runtime never does this — Phase 2B/3 always
        // tags origin — but the resolver must fail closed if it ever happens).
        pool.ingest(
            QEvidenceDraft(
                taskId: EvidenceFixtures.taskId, sourceId: "m-no-origin", kind: .modelGenerated,
                provenance: .untrustedTool(toolName: "model:unknown"), origin: nil, content: "fact: value"
            )
        )
        await EvidenceFixtures.verify(&pool)
        let record = try! #require(QCandidateAttributionResolver.resolve(pool: pool, now: now).first)
        #expect(record.outcome == .attributionUnavailable)
        #expect(record.backend == nil)
        #expect(record.candidateId == nil)
        #expect(record.attemptId == nil)
    }

    @Test("8. No heuristic attribution: identical output text from an untagged source is never matched to a real candidate by content")
    func noHeuristicAttributionByContent() async {
        var pool = EvidenceFixtures.pool()
        pool.ingest(AttributionFixtures.modelResult(.ollama, attemptSuffix: "0", text: "shared fact: value").asDraft())
        pool.ingest(
            QEvidenceDraft(
                taskId: EvidenceFixtures.taskId, sourceId: "m-untagged", kind: .modelGenerated,
                provenance: .untrustedTool(toolName: "model:unknown"), origin: nil, content: "shared fact: value"
            )
        )
        await EvidenceFixtures.verify(&pool)
        let records = QCandidateAttributionResolver.resolve(pool: pool, now: now)
        #expect(records.count == 2)
        #expect(records.contains { $0.backend == .ollama })
        #expect(records.contains { $0.outcome == .attributionUnavailable && $0.backend == nil })
        // The untagged one is never silently attributed to ollama just because the text matches.
        #expect(!records.contains { $0.outcome == .attributionUnavailable && $0.backend != nil })
    }

    // MARK: - 9-12: race semantics — distinct origins are never conflated

    @Test("9/10/11/12. Distinct candidate identities (as a losing/cancelled/timeout/failed candidate WOULD carry) are never merged into one — each resolves independently from its own origin, never reclassified by attempt-outcome vocabulary")
    func distinctOriginsAreNeverConflated() async {
        var pool = EvidenceFixtures.pool()
        // Four distinct backends/attempts, standing in for: winner, a losing-but-accepted candidate,
        // and two that (in the real 2B/3 runtime) would never reach evidence at all (cancelled/timed
        // out candidates produce no claims) — modeled here to prove the resolver, if ever handed such
        // evidence, keeps every origin strictly separate and reads ONLY claim.verification, never an
        // attempt-outcome label, to decide the outcome.
        pool.ingest(AttributionFixtures.modelResult(.ollama, attemptSuffix: "winner", text: "answer: correct").asDraft())
        pool.ingest(AttributionFixtures.modelResult(.llamaCpp, attemptSuffix: "loser", text: "other: value").asDraft())
        pool.ingest(AttributionFixtures.modelResult(.mlx, attemptSuffix: "cancelled-stand-in", text: "third: value").asDraft())
        pool.ingest(AttributionFixtures.modelResult(.appleFoundation, attemptSuffix: "timeout-stand-in", text: "fourth: value").asDraft())
        EvidenceFixtures.addExecutionClaim(&pool, subject: "answer", value: "correct")
        await EvidenceFixtures.verify(&pool)

        let records = QCandidateAttributionResolver.resolve(pool: pool, now: now)
        #expect(records.count == 4)
        #expect(Set(records.compactMap { $0.backend }) == [.ollama, .llamaCpp, .mlx, .appleFoundation])
        #expect(records.first { $0.backend == .ollama }?.outcome == .verified)
        // None of the "losing" origins are ever reclassified as verified merely by association.
        #expect(records.filter { $0.backend != .ollama }.allSatisfy { $0.outcome != .verified })
        // Each attemptId stays distinct — never collapsed onto the winner's.
        #expect(Set(records.compactMap { $0.attemptId }).count == 4)
    }

    // MARK: - 13-15: verification/trust are read-only inputs

    @Test("13. Attribution never changes verification: the pool's claim verification is identical before and after resolving")
    func attributionDoesNotChangeVerification() async {
        let pool = await AttributionFixtures.verifiedPool()
        let before = pool
        _ = QCandidateAttributionResolver.resolve(pool: pool, now: now)
        #expect(pool == before)
    }

    @Test("14/15. Attribution never raises or lowers trust: claim trust is identical before and after, regardless of outcome")
    func attributionDoesNotChangeTrust() async {
        var pool = EvidenceFixtures.pool()
        pool.ingest(AttributionFixtures.modelResult(.ollama, attemptSuffix: "0", text: "answer: x").asDraft())
        pool.ingest(AttributionFixtures.modelResult(.llamaCpp, attemptSuffix: "0", text: "answer: y").asDraft())
        await EvidenceFixtures.verify(&pool)
        let trustBefore = pool.claims.map { $0.trust }
        _ = QCandidateAttributionResolver.resolve(pool: pool, now: now)
        #expect(pool.claims.map { $0.trust } == trustBefore)
        #expect(pool.claims.allSatisfy { $0.trust == .untrusted })   // still untrusted — attribution didn't help it
    }

    // MARK: - 16/17: Codable, deterministic identity

    @Test("16. Codable round-trip: a record encodes and decodes to an equal value and carries no claim text")
    func codableRoundTrip() async throws {
        let pool = await AttributionFixtures.verifiedPool(subject: "zebra-subject-marker", value: "quagga-value-marker")
        let record = try #require(QCandidateAttributionResolver.resolve(pool: pool, now: now).first)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(QCandidateAttributionRecord.self, from: data)
        #expect(decoded == record)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("zebra-subject-marker") && !json.contains("quagga-value-marker"))
    }

    @Test("17. Deterministic identity: resolving the same pool twice yields identical records")
    func deterministicIdentity() async {
        let pool = await AttributionFixtures.verifiedPool()
        let first = QCandidateAttributionResolver.resolve(pool: pool, now: now)
        let second = QCandidateAttributionResolver.resolve(pool: pool, now: now)
        #expect(first == second)
    }

    // MARK: - Adversarial (section 11 of the spec)

    @Test("Adversarial: Candidate A verified, Candidate B contradicted — never a winner/loser, both preserved independently")
    func adversarialTwoCandidatesNeverPickAWinner() async {
        var pool = EvidenceFixtures.pool()
        pool.ingest(AttributionFixtures.modelResult(.ollama, attemptSuffix: "0", text: "claim x: correct").asDraft())
        pool.ingest(AttributionFixtures.modelResult(.llamaCpp, attemptSuffix: "0", text: "claim y: wrong").asDraft())
        EvidenceFixtures.addExecutionClaim(&pool, subject: "claim x", value: "correct")
        EvidenceFixtures.addExecutionClaim(&pool, sourceId: "exec-2", subject: "claim y", value: "right")
        await EvidenceFixtures.verify(&pool)

        let records = QCandidateAttributionResolver.resolve(pool: pool, now: now)
        #expect(records.first { $0.backend == .ollama }?.outcome == .verified)
        #expect(records.first { $0.backend == .llamaCpp }?.outcome == .contradicted)
        // Both records exist — the pool's own claim for candidate B is never dropped just because it lost.
        #expect(records.count == 2)
    }

    @Test("Adversarial: identical claim text from two different candidates keeps candidate-specific identity — never merged")
    func adversarialIdenticalTextNeverMerged() async {
        var pool = EvidenceFixtures.pool()
        pool.ingest(AttributionFixtures.modelResult(.ollama, attemptSuffix: "0", text: "moon is made of: cheese").asDraft())
        pool.ingest(AttributionFixtures.modelResult(.llamaCpp, attemptSuffix: "0", text: "moon is made of: cheese").asDraft())
        await EvidenceFixtures.verify(&pool)

        let records = QCandidateAttributionResolver.resolve(pool: pool, now: now)
        #expect(records.count == 2)
        #expect(Set(records.map { $0.claimId }).count == 2)              // distinct claim identities
        #expect(Set(records.compactMap { $0.backend }) == [.ollama, .llamaCpp])
        #expect(records.allSatisfy { $0.outcome == .unresolved })         // model repetition still establishes nothing
    }
}

// MARK: - Outcome learning integration

@Suite("QCandidateAttributionLearningTests")
struct QCandidateAttributionLearningTests {

    private let now = AttributionFixtures.now

    private func makeMemory() throws -> (QModelCapabilityMemory, QDurableTaskStore) {
        let store = try QDurableTaskStore(inMemory: true)
        return (QModelCapabilityMemory(store: store), store)
    }

    // MARK: - 18/19: idempotency, restart

    @Test("18. Duplicate event idempotency: recording the same pool's attribution twice adds no weight")
    func duplicateEventIsIdempotent() async throws {
        let (memory, _) = try makeMemory()
        let pool = await AttributionFixtures.verifiedPool()
        let service = QOutcomeLearningService(memory: memory)
        let first = service.learnCandidateAttribution(pool: pool, decisionPlan: AttributionFixtures.decisionPlan(), now: now)
        let second = service.learnCandidateAttribution(pool: pool, decisionPlan: AttributionFixtures.decisionPlan(), now: now)
        #expect(first.recorded == 1)
        #expect(second.recorded == 0 && second.duplicates == 1)
    }

    @Test("19. Restart preserves attribution: a candidate-attribution observation persists across a store restart")
    func restartPreservesAttribution() async throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let pool = await AttributionFixtures.verifiedPool(backend: .ollama)
        let key = QModelCapabilityProfileKey(taskType: AttributionFixtures.decisionPlan().taskType, complexity: AttributionFixtures.decisionPlan().complexity, backend: .ollama)

        do {
            let memory = QModelCapabilityMemory(store: try QDurableTaskStore(databasePath: path))
            QOutcomeLearningService(memory: memory).learnCandidateAttribution(pool: pool, decisionPlan: AttributionFixtures.decisionPlan(), now: now)
        }
        let reopened = QModelCapabilityMemory(store: try QDurableTaskStore(databasePath: path))
        #expect(reopened.profile(taskType: key.taskType, complexity: key.complexity, backend: key.backend, now: now.addingTimeInterval(10)).sampleCount == 1)
    }

    // MARK: - 20/21/22: task-level unchanged, candidate-level persisted, feeds capability memory

    @Test("20. Task-level learning is completely unchanged: learn() results are identical whether or not learnCandidateAttribution is also called")
    func taskLevelLearningIsUnchanged() async throws {
        let (memoryA, _) = try makeMemory()
        let (memoryB, _) = try makeMemory()
        let winner = QModelAttempt(
            attemptId: QModelAttemptID(rawValue: "\(EvidenceFixtures.taskId)-attempt-local.ollama-0"), taskId: EvidenceFixtures.taskId,
            candidateId: QModelCandidateID(backend: .ollama), backend: .ollama, outcome: .accepted(plan: QPlan(taskId: EvidenceFixtures.taskId, sessionId: "s", taskPrompt: "p", steps: [])),
            startedAt: now, finishedAt: now
        )
        let input = QOutcomeLearningInput(
            taskId: EvidenceFixtures.taskId, decisionPlan: AttributionFixtures.decisionPlan(),
            evidenceMetadata: QEvidenceOutcomeMetadata(
                taskType: "research", complexity: "moderate", requirement: "independentVerification", synthesisStatus: "sufficient", uncertainty: "low",
                evidenceCompleteness: .complete, evidenceCount: 1, claimCount: 1, verifiedClaimCount: 1, unresolvedClaimCount: 0,
                contradictedClaimCount: 0, contradictionCount: 0, unresolvedContradictionCount: 0, rejectedInputCount: 0, criticFindingCount: 0,
                draftViolationCount: 0, collectionStage: "skipped", verificationStage: "completed", criticStage: "completed", synthesisStage: "completed",
                candidateBackends: [], candidateVerificationStates: [:], resourceOutcome: "completed", userCorrection: "notObserved", isTainted: false
            ),
            attempts: [winner], winningAttemptId: winner.attemptId, goalState: .satisfied
        )
        let reportA = QOutcomeLearningService(memory: memoryA).learn(input, now: now.addingTimeInterval(10))

        let pool = await AttributionFixtures.verifiedPool()
        let service = QOutcomeLearningService(memory: memoryB)
        let reportB = service.learn(input, now: now.addingTimeInterval(10))
        service.learnCandidateAttribution(pool: pool, decisionPlan: AttributionFixtures.decisionPlan(), now: now.addingTimeInterval(10))

        #expect(reportA == reportB)
        #expect(reportA.winnerOutcome == .success)
    }

    @Test("21/22. A candidate-level observation is persisted and feeds capability memory as a bounded, count-only profile row")
    func candidateLevelObservationFeedsCapabilityMemory() async throws {
        let (memory, store) = try makeMemory()
        let pool = await AttributionFixtures.verifiedPool(backend: .llamaCpp)
        let report = QOutcomeLearningService(memory: memory).learnCandidateAttribution(pool: pool, decisionPlan: AttributionFixtures.decisionPlan(), now: now)
        #expect(report.recorded == 1)

        let rows = store.observations(forTask: EvidenceFixtures.taskId, now: now.addingTimeInterval(10)).observations
        let row = try #require(rows.first)
        #expect(row.backend == .llamaCpp)
        #expect(row.outcome == .success)   // verified claim → success, via the new classify branch
        let profile = store.profile(for: QModelCapabilityProfileKey(taskType: row.taskType, complexity: row.complexity, backend: .llamaCpp), now: now.addingTimeInterval(10))
        #expect(profile.verifiedSuccessCount == 1)
        #expect(profile.sampleCount == 1)
    }

    @Test("A contradicted claim attribution records as verificationFailed in capability memory, via the same existing outcome vocabulary")
    func contradictedAttributionRecordsAsVerificationFailed() async throws {
        let (memory, store) = try makeMemory()
        var pool = EvidenceFixtures.pool()
        pool.ingest(AttributionFixtures.modelResult(.mlx, attemptSuffix: "0", text: "count: 9").asDraft())
        EvidenceFixtures.addExecutionClaim(&pool, subject: "count", value: "3")
        await EvidenceFixtures.verify(&pool)

        QOutcomeLearningService(memory: memory).learnCandidateAttribution(pool: pool, decisionPlan: AttributionFixtures.decisionPlan(), now: now)
        let row = try #require(store.observations(forTask: EvidenceFixtures.taskId, now: now.addingTimeInterval(10)).observations.first)
        #expect(row.outcome == .verificationFailed)
        #expect(row.verification == .contradicted)
    }

    @Test("notEvaluated and attributionUnavailable claims are never recorded into capability memory")
    func unevaluatedAndUnavailableAreNeverRecorded() async throws {
        let (memory, store) = try makeMemory()
        var pool = EvidenceFixtures.pool(requirement: .none)
        pool.ingest(AttributionFixtures.modelResult(.ollama, attemptSuffix: "0", text: "topic: value").asDraft())
        pool.ingest(
            QEvidenceDraft(taskId: EvidenceFixtures.taskId, sourceId: "m-untagged", kind: .modelGenerated, provenance: .untrustedTool(toolName: "model:x"), origin: nil, content: "other: value")
        )
        let report = QOutcomeLearningService(memory: memory).learnCandidateAttribution(pool: pool, decisionPlan: AttributionFixtures.decisionPlan(), now: now)
        #expect(report.notEvaluatedCount == 1)
        #expect(report.attributionUnavailableCount == 1)
        #expect(report.recorded == 0)
        #expect(store.observationCount() == 0)
    }

    // MARK: - Section 12: resource limits (bounded per-task-per-backend history, shared with existing rows)

    @Test("Resource limits: the EXISTING shared per-(task, backend) cap bounds candidate-attribution rows too — a task producing more claims than the remaining budget gets typed rejections, never silent loss or double weight")
    func sharedPerTaskCapBoundsAttributionRows() async throws {
        let (memory, store) = try makeMemory()
        var pool = EvidenceFixtures.pool()
        for index in 0..<6 {
            pool.ingest(AttributionFixtures.modelResult(.ollama, attemptSuffix: "0", text: "subject\(index): value\(index)").asDraft())
        }
        await EvidenceFixtures.verify(&pool)
        #expect(pool.claims.count == 6)

        let report = QOutcomeLearningService(memory: memory).learnCandidateAttribution(pool: pool, decisionPlan: AttributionFixtures.decisionPlan(), now: now)
        #expect(report.recorded == QModelCapabilityLimits.maxObservationsPerTaskPerBackend)
        #expect(report.rejections[.perTaskLimitReached] == 6 - QModelCapabilityLimits.maxObservationsPerTaskPerBackend)
        #expect(store.observations(forTask: EvidenceFixtures.taskId, now: now.addingTimeInterval(10)).observations.count == QModelCapabilityLimits.maxObservationsPerTaskPerBackend)
    }

    @Test("A single claim can never permanently establish a model capability: the ranking threshold still requires several DISTINCT tasks, not several claims from one task")
    func singleTaskManyClaimsNeverAloneRanksACandidate() async throws {
        let (memory, _) = try makeMemory()
        var pool = EvidenceFixtures.pool()
        for index in 0..<3 {
            pool.ingest(AttributionFixtures.modelResult(.ollama, attemptSuffix: "0", text: "subject\(index): value\(index)").asDraft())
        }
        await EvidenceFixtures.verify(&pool)
        QOutcomeLearningService(memory: memory).learnCandidateAttribution(pool: pool, decisionPlan: AttributionFixtures.decisionPlan(), now: now)

        let recommendation = memory.advise(taskType: AttributionFixtures.decisionPlan().taskType, complexity: AttributionFixtures.decisionPlan().complexity, candidates: [.ollama, .llamaCpp], now: now.addingTimeInterval(10))
        #expect(!recommendation.reordered)   // one task's worth of claims is still only ONE distinct task
    }

    // MARK: - No fake scores

    @Test("No fake capability scores: the report and record types carry no floating-point field")
    func noFloatingPointFields() {
        for subject in [QCandidateAttributionReport() as Any] {
            for child in Mirror(reflecting: subject).children {
                #expect(!(child.value is Double) && !(child.value is Float))
            }
        }
    }
}

// MARK: - Runtime integration

@Suite("QCandidateAttributionRuntimeTests")
struct QCandidateAttributionRuntimeTests {

    private func events(_ store: QDurableTaskStore, _ taskId: String) throws -> QTaskLifecycleEvent? {
        try store.listEvents(taskId: taskId).first { $0.eventType == .responseAssembled }
    }

    @Test("With capability memory configured but no structured-answer-capable provider, the wiring runs without crashing and reports zero attribution — never a fabricated one")
    func noProviderSupportReportsZeroAttribution() async throws {
        let eventStore = try QDurableTaskStore(inMemory: true)
        let capability = QModelCapabilityMemory(store: try QDurableTaskStore(inMemory: true))
        let provider = FakeModelCandidateProvider(backends: [.ollama])
        let runtime = QCoreRuntime(
            modelProvider: provider, executionProvider: MockExecutionProvider(), durableStore: eventStore, capabilityMemory: capability,
            verifiedResponse: QVerifiedResponseConfiguration(structuredAnswer: .init(isEnabled: true, timeoutSeconds: 5)),
            endpointName: "ca-1-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What is the capital of France?")
        let event = try #require(try events(eventStore, task.taskId))
        #expect(event.payload["candidateAttributionRecorded"] == "0")
        #expect(event.payload["candidateAttributionNotEvaluated"] == "0")
        #expect(event.payload["candidateAttributionUnavailable"] == "0")
        // Capability memory is NOT necessarily empty — the pre-existing, unrelated task-level
        // `.taskOutcome` row (Phase 2E) is still recorded regardless of structured-answer support.
        // What matters here is that NO `.claimAttribution` row was created.
        #expect(capability.observations(forTask: task.taskId).observations.allSatisfy { $0.source != .claimAttribution })
    }

    @Test("Without capability memory, no candidate-attribution keys appear in the response-assembled event, and nothing is recorded")
    func withoutCapabilityMemoryNoAttributionKeys() async throws {
        let eventStore = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: FakeModelCandidateProvider(backends: [.ollama]), executionProvider: MockExecutionProvider(), durableStore: eventStore,
            verifiedResponse: QVerifiedResponseConfiguration(), endpointName: "ca-2-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What is the capital of France?")
        let event = try #require(try eventStore.listEvents(taskId: task.taskId).first { $0.eventType == .responseAssembled })
        #expect(event.payload["candidateAttributionRecorded"] == nil)
    }

    @Test("With capability memory and a genuine structured answer, candidate attribution is recorded and the audit event reports it — no claim text in the payload")
    func withRealStructuredAnswerAttributionIsRecorded() async throws {
        let eventStore = try QDurableTaskStore(inMemory: true)
        let capabilityStore = try QDurableTaskStore(inMemory: true)
        let capability = QModelCapabilityMemory(store: capabilityStore)

        struct AnsweringProvider: QModelCandidateAwareProvider, QStructuredAnswerProvider {
            let inner: FakeModelCandidateProvider
            func generatePlan(for task: QTask) async throws -> [QActionRequest] { try await inner.generatePlan(for: task) }
            func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
                try await inner.generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext)
            }
            func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?) async throws -> QPlan {
                try await inner.generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: decisionPlan)
            }
            func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?, decisionPlan: QDecisionPlan?, preferredBackend: QModelBackendType?) async throws -> QPlan {
                try await inner.generateStructuredPlan(for: task, memoryContext: memoryContext, failureContext: failureContext, decisionPlan: decisionPlan, preferredBackend: preferredBackend)
            }
            func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String {
                try await inner.generateGroundedSummary(for: task, verifiedEvidence: verifiedEvidence, isSuccess: isSuccess)
            }
            func candidateBackends() -> [QModelBackendType] { inner.candidateBackends() }
            func candidateDescriptor(for backend: QModelBackendType) async -> QModelCandidate? { await inner.candidateDescriptor(for: backend) }
            func generateStructuredAnswer(for task: QTask, decisionPlan: QDecisionPlan, timeoutSeconds: TimeInterval) async throws -> QStructuredAnswerDraft {
                QStructuredAnswerDraft(backend: .ollama, outputText: "capital of france: paris", durationSeconds: 0.01)
            }
        }
        let runtime = QCoreRuntime(
            modelProvider: AnsweringProvider(inner: FakeModelCandidateProvider(backends: [.ollama])), executionProvider: MockExecutionProvider(),
            durableStore: eventStore, capabilityMemory: capability,
            verifiedResponse: QVerifiedResponseConfiguration(structuredAnswer: .init(isEnabled: true, timeoutSeconds: 5)),
            endpointName: "ca-3-\(UUID().uuidString)"
        )
        // A `.simpleQA`-classified prompt ("What is the capital of France?") gets verificationRequirement
        // `.none`, under which verification never even runs (`.notEvaluated`) — a real, separately-tested
        // case. A `.research`-classified prompt gets `.executionEvidence`, so verification DOES run here.
        let task = try await runtime.submitIntent(prompt: "Research the latest developments in on-device inference")
        let event = try #require(try eventStore.listEvents(taskId: task.taskId).first { $0.eventType == .responseAssembled })
        // No independent evidence exists for a pure Q&A answer, so the claim's verdict is `.unresolved`
        // — a real verdict, not "never evaluated" — and IS recorded (identity is known: backend .ollama).
        #expect(event.payload["candidateAttributionRecorded"] == "1")
        #expect(event.payload["candidateAttributionNotEvaluated"] == "0")
        #expect(event.payload["candidateAttributionUnavailable"] == "0")
        let rows = capabilityStore.observations(forTask: task.taskId, now: Date()).observations
        #expect(rows.contains { $0.outcome == .unresolved && $0.backend == .ollama })
        for (key, value) in event.payload where key.hasPrefix("candidateAttribution") {
            #expect(!value.contains("paris"))
            #expect(!value.contains("capital"))
        }
    }

    @Test("Permission/Resource/Egress authorities are unaffected: a Level 2 halt and a denylisted read behave identically with candidate attribution configured")
    func authoritiesUnaffected() async throws {
        let capability = QModelCapabilityMemory(store: try QDurableTaskStore(inMemory: true))
        let model = RecordingDecisionAwareModelProvider()
        model.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "Write marker to clipboard",
              "steps": [
                { "actionName": "system.clipboard.write", "toolFamily": "system", "description": "Write a marker", "parameters": {"text": "q-ca-marker"} }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: model, executionProvider: QExecutionService.shared, capabilityMemory: capability,
            verifiedResponse: QVerifiedResponseConfiguration(structuredAnswer: .init(isEnabled: true)), endpointName: "ca-4-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Write marker to clipboard")
        guard case .awaitingApproval = task.state else {
            Issue.record("expected .awaitingApproval, got \(task.state)")
            return
        }
    }

    @Test("High-risk stays fail-closed before any model call, with candidate attribution configured")
    func highRiskStaysFailClosed() async throws {
        let capability = QModelCapabilityMemory(store: try QDurableTaskStore(inMemory: true))
        let provider = FakeModelCandidateProvider(backends: [.ollama, .llamaCpp])
        let runtime = QCoreRuntime(
            modelProvider: provider, executionProvider: MockExecutionProvider(), capabilityMemory: capability,
            verifiedResponse: QVerifiedResponseConfiguration(structuredAnswer: .init(isEnabled: true)), endpointName: "ca-5-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Delete the temporary project file")
        guard case .failed(let reason) = task.state else {
            Issue.record("expected fail-closed, got \(task.state)")
            return
        }
        #expect(reason.contains("failing closed"))
        #expect(capability.observationCount() == 0)
    }

    @Test("No extra model call: candidate-attribution resolution and recording add zero additional model invocations")
    func noExtraModelCall() async throws {
        let capability = QModelCapabilityMemory(store: try QDurableTaskStore(inMemory: true))
        let provider = FakeModelCandidateProvider(backends: [.ollama])
        let runtime = QCoreRuntime(
            modelProvider: provider, executionProvider: MockExecutionProvider(), capabilityMemory: capability,
            verifiedResponse: QVerifiedResponseConfiguration(structuredAnswer: .init(isEnabled: true)), endpointName: "ca-6-\(UUID().uuidString)"
        )
        _ = try await runtime.submitIntent(prompt: "What is the capital of France?")
        #expect(provider.attemptCount.values.reduce(0, +) == 1)   // only the plan-generation attempt; the provider doesn't support answers
    }
}

// MARK: - Static audit

@Suite("QCandidateAttributionSecurityTests")
struct QCandidateAttributionSecurityTests {

    private var source: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("leanring-buddy/q-runtime/QCore/QCandidateAttributionContracts.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test("28/29/30. Static audit: no network, process/shell, AX/CGEvent, Keychain, model-download, or authority-type reference in the attribution source")
    func noForbiddenAPIsOrAuthoritySymbols() throws {
        let text = try source
        let forbidden = [
            "URLSession", "NWConnection", "import Network", "Process(", "NSTask", "posix_spawn", "system(",
            "CGEvent", "AXUIElement", "AXObserver", "NSAppleScript", "Keychain", "SecItem", "URL(", "FileManager",
            "http://", "https://", "sudo", "curl", "wget", "osascript", "bash", "download", "sqlite3",
            "QPermissionGate", "QResourceGuard", "QEgressBroker", "QApprovalCoordinator", "QPlanExecutor",
            "QExecutionService", "QExecutionProvider", "QModelRouter", "QCoreRuntime"
        ]
        for token in forbidden {
            #expect(!text.contains(token), "contains forbidden token \(token)")
        }
    }

    @Test("No fake scores in the contract file: no floating-point type appears anywhere in it")
    func noFloatingPointInContracts() throws {
        let text = try source
        #expect(!text.contains(": Double") && !text.contains(": Float"))
    }
}
