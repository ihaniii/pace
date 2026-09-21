//
//  QEvidencePipelineTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2C pipeline tests: per-task-type integration, empty/partial
//  evidence, stage failure isolation, timeouts, cancellation (with proof nothing is abandoned),
//  bounds, the Phase 2B bridge, and the audit-safe outcome metadata.
//

import Testing
import Foundation
@testable import Pace

@Suite("QEvidencePipelineTests")
struct QEvidencePipelineTests {

    private func decisionPlan(for prompt: String) -> QDecisionPlan {
        QDeterministicDecisionEngine().decide(for: QTask(intent: prompt))
    }

    private func input(
        plan: QDecisionPlan = EvidenceFixtures.decisionPlan(),
        modelResults: [QEvidenceModelResult] = [],
        attempts: [QModelAttempt] = [],
        observations: [QEvidenceObservation] = [],
        userFacts: [QUserProvidedFact] = [],
        collector: (any QEvidenceCollector)? = nil
    ) -> QEvidencePipelineInput {
        QEvidencePipelineInput(
            taskId: EvidenceFixtures.taskId,
            decisionPlan: plan,
            modelResults: modelResults,
            candidateAttempts: attempts,
            observations: observations,
            userFacts: userFacts,
            collector: collector
        )
    }

    // MARK: - Integration per task type

    @Test(
        "Per-task-type integration: an execution-verified claim is sufficient; a model-only claim never is",
        arguments: [
            ("What is the capital of France?", QTaskType.simpleQA),
            ("Why do the trade-offs favor this approach considering the pros and cons?", QTaskType.reasoning),
            ("Write a function to sort a list", QTaskType.coding),
            ("Research the latest developments in on-device inference", QTaskType.research),
            ("Make a plan for the product launch", QTaskType.planning),
            ("Open Notes for me", QTaskType.execution),
            ("Delete the temporary project file", QTaskType.criticalHighRisk)
        ]
    )
    func integrationAcrossTaskTypes(prompt: String, expectedType: QTaskType) async {
        let plan = decisionPlan(for: prompt)
        #expect(plan.taskType == expectedType)

        let verified = await QEvidencePipeline().run(
            input(
                plan: plan,
                modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "result: 42")],
                observations: [QEvidenceObservation(sourceId: "exec-1", subject: "result", value: "42")]
            )
        )
        #expect(verified.synthesis?.status == .sufficient)
        #expect(verified.synthesis?.isFullyTraceable == true)
        #expect(verified.pool.requirement == QEvidenceRequirementPolicy.effectiveRequirement(for: plan))

        let modelOnly = await QEvidencePipeline().run(
            input(plan: plan, modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "result: 42")])
        )
        #expect(modelOnly.synthesis?.status != .sufficient)
        #expect(modelOnly.pool.claims.allSatisfy { $0.trust == .untrusted })

        if expectedType == .criticalHighRisk {
            #expect(verified.pool.requirement == .independentVerification)
        }
    }

    @Test("The pipeline is deterministic: identical input yields an identical synthesized result")
    func pipelineIsDeterministic() async {
        let pipelineInput = input(
            modelResults: [
                QEvidenceModelResult(backend: .ollama, outputText: "a: 1\nb: 2"),
                QEvidenceModelResult(backend: .llamaCpp, outputText: "a: 1\nb: 3")
            ],
            observations: [QEvidenceObservation(sourceId: "exec", subject: "a", value: "1")]
        )
        let first = await QEvidencePipeline().run(pipelineInput)
        let second = await QEvidencePipeline().run(pipelineInput)
        #expect(first.synthesis == second.synthesis)
        #expect(first.findings == second.findings)
        #expect(first.metadata == second.metadata)
    }

    // MARK: - Empty / partial evidence

    @Test("Zero evidence: insufficient, completeness none, no fabricated statements, all stages ran safely")
    func zeroEvidence() async {
        let result = await QEvidencePipeline().run(input())
        #expect(result.synthesis?.status == .insufficient)
        #expect(result.synthesis?.statements.isEmpty == true)
        #expect(result.metadata.evidenceCompleteness == .none)
        #expect(result.stages.synthesis == .completed)
        #expect(result.findings.contains { $0.kind == .missingEvidence })
    }

    @Test("One evidence item, one claim: reported with its true standing, not upgraded")
    func singleEvidenceItem() async {
        let result = await QEvidencePipeline().run(input(userFacts: [QUserProvidedFact(sourceId: "user", subject: "favourite colour", value: "green")]))
        #expect(result.pool.items.count == 1)
        #expect(result.synthesis?.statements.first?.disposition == .observed)   // stated by the user; not "verified"
        #expect(result.pool.claims[0].trust == .observed)
    }

    @Test("Conflicting evidence end to end: both preserved, contradictory, verification required")
    func conflictingEvidenceEndToEnd() async {
        let result = await QEvidencePipeline().run(
            input(modelResults: [
                QEvidenceModelResult(backend: .ollama, outputText: "answer: X"),
                QEvidenceModelResult(backend: .llamaCpp, outputText: "answer: Y")
            ])
        )
        #expect(result.synthesis?.status == .contradictory)
        #expect(result.synthesis?.statements.count == 2)
        #expect(result.metadata.unresolvedContradictionCount == 1)
        #expect(result.pool.claims.allSatisfy { $0.verificationRequired })
    }

    @Test("Model A correct / Model B incorrect, settled by independent evidence end to end")
    func modelCorrectnessSettledByEvidence() async {
        let result = await QEvidencePipeline().run(
            input(
                modelResults: [
                    QEvidenceModelResult(backend: .ollama, outputText: "line count: 120"),
                    QEvidenceModelResult(backend: .llamaCpp, outputText: "line count: 99")
                ],
                observations: [QEvidenceObservation(sourceId: "exec", subject: "line count", value: "120")]
            )
        )
        #expect(result.synthesis?.status == .sufficient)
        #expect(result.metadata.verifiedClaimCount == 1)
        #expect(result.metadata.contradictedClaimCount == 1)
        #expect(result.metadata.unresolvedContradictionCount == 0)
        #expect(result.metadata.contradictionCount == 1)
    }

    @Test("Unavailable source: a throwing collector yields collection=unavailable and a partial, non-sufficient result")
    func unavailableSource() async {
        let result = await QEvidencePipeline().run(
            input(
                modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "result: 1")],
                observations: [QEvidenceObservation(sourceId: "exec", subject: "result", value: "1")],
                collector: ThrowingCollector()
            )
        )
        #expect(result.stages.collection == .unavailable)
        #expect(result.synthesis?.status == .partial)
        #expect(result.synthesis?.caveats.contains(.collectionIncomplete) == true)
    }

    @Test("Malformed sources from a collector are rejected and counted; good ones still count")
    func malformedSourcesFromCollector() async {
        let good = EvidenceFixtures.retrievedDraft(sourceId: "doc-good", content: "fact: ok")
        let malformed = [
            EvidenceFixtures.retrievedDraft(sourceId: "", content: "a: b"),
            EvidenceFixtures.retrievedDraft(sourceId: "empty", content: ""),
            QEvidenceDraft(taskId: "other-task", sourceId: "x", kind: .retrievedExternal, provenance: .untrustedWeb(url: nil), content: "a: b"),
            QEvidenceDraft(taskId: EvidenceFixtures.taskId, sourceId: "forged", kind: .executionObserved, provenance: .untrustedWeb(url: nil), content: "a: b")
        ]
        let result = await QEvidencePipeline().run(input(collector: StubCollector(drafts: malformed + [good])))
        #expect(result.stages.collection == .completed)
        #expect(result.pool.items.count == 1)
        #expect(result.metadata.rejectedInputCount == 4)
    }

    @Test("Verification unavailable: with no verifier, nothing is verified and the result says so")
    func verificationUnavailable() async {
        let pipeline = QEvidencePipeline(verificationService: QIndependentVerificationService(backends: []))
        let result = await pipeline.run(
            input(
                modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "result: 1")],
                observations: [QEvidenceObservation(sourceId: "exec", subject: "result", value: "1")]
            )
        )
        #expect(result.pool.claims.filter { $0.originKind == .modelGenerated }.allSatisfy { $0.verification == .unavailable })
        #expect(result.synthesis?.status != .sufficient)
        #expect(result.synthesis?.caveats.contains(.verificationUnavailable) == true)
        #expect(result.metadata.verifiedClaimCount == 0)
    }

    @Test("Critic unavailable: the run completes, findings are empty, and an otherwise-sufficient result is capped at partial")
    func criticUnavailable() async {
        let result = await QEvidencePipeline(critic: ThrowingCritic()).run(
            input(
                modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "result: 1")],
                observations: [QEvidenceObservation(sourceId: "exec", subject: "result", value: "1")]
            )
        )
        #expect(result.stages.critic == .unavailable)
        #expect(result.findings.isEmpty)
        #expect(result.synthesis?.status == .partial)
        #expect(result.synthesis?.caveats.contains(.criticUnavailable) == true)
    }

    @Test("Synthesis unavailable: status unavailable, no statements, nothing fabricated")
    func synthesisUnavailable() async {
        let result = await QEvidencePipeline(synthesizer: ThrowingSynthesizer()).run(
            input(
                modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "result: 1")],
                observations: [QEvidenceObservation(sourceId: "exec", subject: "result", value: "1")]
            )
        )
        #expect(result.stages.synthesis == .unavailable)
        #expect(result.synthesis?.status == .unavailable)
        #expect(result.synthesis?.statements.isEmpty == true)
        #expect(result.synthesis?.caveats.contains(.synthesisUnavailable) == true)
        #expect(result.metadata.synthesisStatus == "unavailable")
    }

    @Test("A model failure during verification yields a partial result — the pipeline does not crash or verify by default")
    func modelFailureDuringVerification() async {
        let pipeline = QEvidencePipeline(verificationService: QIndependentVerificationService(backends: [ThrowingVerificationBackend()]))
        let result = await pipeline.run(input(modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "result: 1")]))
        #expect(result.stages.verification == .completed)
        #expect(result.pool.claims[0].verification == .unavailable)
        #expect(result.synthesis?.status == .insufficient)
        #expect(result.stages.synthesis == .completed)
    }

    // MARK: - Timeouts

    @Test("Stage timeouts are enforced and isolated: each slow stage times out, the run continues, resourceOutcome=timedOut")
    func stageTimeouts() async {
        let collectorProbe = EvidenceProbe()
        let collectionResult = await QEvidencePipeline(collectionTimeout: 0.1).run(
            input(modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "a: 1")], collector: SleepingCollector(probe: collectorProbe))
        )
        #expect(collectionResult.stages.collection == .timedOut)
        #expect(collectionResult.synthesis != nil)
        #expect(collectionResult.metadata.resourceOutcome == "timedOut")
        #expect(collectorProbe.sawCancellation && collectorProbe.finished)

        let verificationProbe = EvidenceProbe()
        let verificationResult = await QEvidencePipeline(
            verificationService: QIndependentVerificationService(backends: [SleepingVerificationBackend(probe: verificationProbe)], perCallTimeout: 60),
            verificationTimeout: 0.1
        ).run(input(modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "a: 1")]))
        #expect(verificationResult.stages.verification == .timedOut)
        #expect(verificationResult.synthesis?.status != .sufficient)
        #expect(verificationProbe.sawCancellation && verificationProbe.finished)

        let criticProbe = EvidenceProbe()
        let criticResult = await QEvidencePipeline(critic: SleepingCritic(probe: criticProbe), criticTimeout: 0.1).run(input())
        #expect(criticResult.stages.critic == .timedOut)
        #expect(criticResult.synthesis?.caveats.contains(.criticUnavailable) == true)
        #expect(criticProbe.sawCancellation && criticProbe.finished)

        let synthesisProbe = EvidenceProbe()
        let synthesisResult = await QEvidencePipeline(synthesizer: SleepingSynthesizer(probe: synthesisProbe), synthesisTimeout: 0.1).run(input())
        #expect(synthesisResult.stages.synthesis == .timedOut)
        #expect(synthesisResult.synthesis?.status == .unavailable)
        #expect(synthesisProbe.sawCancellation && synthesisProbe.finished)
    }

    // MARK: - Cancellation

    private func assertCancelledPromptly(_ started: Date, _ probe: EvidenceProbe) {
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(probe.started)
        #expect(probe.sawCancellation)
        #expect(probe.finished)   // nothing is left running after the pipeline returns
    }

    @Test("Cancelling during evidence collection: collection cancelled, later stages skipped, no synthesis, backend unwound")
    func cancelDuringCollection() async {
        let probe = EvidenceProbe()
        let pipelineInput = input(collector: SleepingCollector(probe: probe))
        let task = Task { await QEvidencePipeline().run(pipelineInput) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let started = Date()
        let result = await task.value

        #expect(result.stages.collection == .cancelled)
        #expect(result.stages.verification == .skipped)
        #expect(result.stages.critic == .skipped)
        #expect(result.stages.synthesis == .skipped)
        #expect(result.synthesis == nil)
        #expect(result.metadata.resourceOutcome == "cancelled")
        #expect(result.metadata.synthesisStatus == "cancelled")
        assertCancelledPromptly(started, probe)
    }

    @Test("Cancelling during verification: verification cancelled, critic and synthesis skipped, backend unwound")
    func cancelDuringVerification() async {
        let probe = EvidenceProbe()
        let pipeline = QEvidencePipeline(verificationService: QIndependentVerificationService(backends: [SleepingVerificationBackend(probe: probe)], perCallTimeout: 60), verificationTimeout: 60)
        let pipelineInput = input(modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "a: 1")])
        let task = Task { await pipeline.run(pipelineInput) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let started = Date()
        let result = await task.value

        #expect(result.stages.verification == .cancelled)
        #expect(result.stages.critic == .skipped)
        #expect(result.synthesis == nil)
        #expect(result.pool.claims.allSatisfy { $0.trust != .independentlyVerified })
        assertCancelledPromptly(started, probe)
    }

    @Test("Cancelling during the critic: critic cancelled, synthesis skipped, critic unwound")
    func cancelDuringCritic() async {
        let probe = EvidenceProbe()
        let pipeline = QEvidencePipeline(critic: SleepingCritic(probe: probe), criticTimeout: 60)
        let task = Task { await pipeline.run(input()) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let started = Date()
        let result = await task.value

        #expect(result.stages.critic == .cancelled)
        #expect(result.stages.synthesis == .skipped)
        #expect(result.synthesis == nil)
        assertCancelledPromptly(started, probe)
    }

    @Test("Cancelling during synthesis: synthesis cancelled, no result manufactured, synthesizer unwound")
    func cancelDuringSynthesis() async {
        let probe = EvidenceProbe()
        let pipeline = QEvidencePipeline(synthesizer: SleepingSynthesizer(probe: probe), synthesisTimeout: 60)
        let task = Task { await pipeline.run(input()) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let started = Date()
        let result = await task.value

        #expect(result.stages.synthesis == .cancelled)
        #expect(result.synthesis == nil)
        #expect(result.metadata.resourceOutcome == "cancelled")
        assertCancelledPromptly(started, probe)
    }

    // MARK: - Bounds

    @Test("A collector returning far more than the limit cannot overflow the pool")
    func collectorCannotOverflowPool() async {
        let drafts = (0..<200).map { EvidenceFixtures.retrievedDraft(sourceId: "doc-\($0)", content: "k\($0): v\($0)") }
        let result = await QEvidencePipeline().run(input(collector: StubCollector(drafts: drafts)))
        #expect(result.pool.items.count == QEvidenceLimits.maxEvidenceItems)
        #expect(result.pool.claims.count <= QEvidenceLimits.maxClaims)
        #expect(result.findings.count <= QEvidenceLimits.maxCriticFindings)
        #expect(result.synthesis?.statements.count ?? 0 <= QEvidenceLimits.maxStatements)
    }

    @Test("Bounds are single-shot: exactly one critic pass and one synthesis attempt")
    func singleCriticPassAndSynthesisAttempt() {
        #expect(QEvidenceLimits.maxCriticPasses == 1)
        #expect(QEvidenceLimits.maxSynthesisAttempts == 1)
    }

    // MARK: - Phase 2B bridge

    @Test("Phase 2B attempts feed the pool as identity/outcome-only items, kept separate from claims")
    func phase2BAttemptsBridge() async {
        let now = Date()
        func attempt(_ backend: QModelBackendType, _ outcome: QModelAttemptOutcome, _ index: Int) -> QModelAttempt {
            QModelAttempt(
                attemptId: QModelAttemptID(rawValue: "\(EvidenceFixtures.taskId)-attempt-\(backend.rawValue)-\(index)"),
                taskId: EvidenceFixtures.taskId,
                candidateId: QModelCandidateID(backend: backend),
                backend: backend,
                outcome: outcome,
                startedAt: now,
                finishedAt: now
            )
        }
        let plan = QPlan(taskId: EvidenceFixtures.taskId, sessionId: "s", taskPrompt: "SENSITIVE-PLAN-PROMPT-ZEBRA", steps: [])
        let attempts = [
            attempt(.ollama, .accepted(plan: plan), 0),
            attempt(.llamaCpp, .timedOut, 1),
            attempt(.mlx, .verificationFailed(reason: "SENSITIVE-REASON-ZEBRA"), 2),
            attempt(.appleFoundation, .needsVerification, 3)
        ]

        let result = await QEvidencePipeline().run(input(attempts: attempts))

        #expect(result.pool.items.count == 4)
        #expect(result.pool.claims.isEmpty)   // an attempt is not a claim
        #expect(result.pool.items.allSatisfy { $0.source.kind == .modelGenerated && $0.trust == .untrusted })
        let states = result.metadata.candidateVerificationStates
        #expect(states[QModelBackendType.ollama.rawValue] == "pending")
        #expect(states[QModelBackendType.llamaCpp.rawValue] == "unavailable")
        #expect(states[QModelBackendType.mlx.rawValue] == "contradicted")
        #expect(states[QModelBackendType.appleFoundation.rawValue] == "pending")
        #expect(Set(result.metadata.candidateBackends) == Set(QModelBackendType.allCases.map { $0.rawValue }))
        #expect(!String(describing: result.pool).contains("SENSITIVE-PLAN-PROMPT-ZEBRA"))
        #expect(!String(describing: result.metadata).contains("SENSITIVE-REASON-ZEBRA"))
        #expect(result.synthesis?.status == .insufficient)
    }

    // MARK: - Outcome metadata (Phase 2D/2E extension point)

    @Test("Outcome metadata exposes candidate, task type, verification/result state, completeness, contradiction, user correction, resource outcome")
    func outcomeMetadataShape() async {
        let plan = decisionPlan(for: "Research the latest developments in on-device inference")
        let result = await QEvidencePipeline().run(
            QEvidencePipelineInput(
                taskId: EvidenceFixtures.taskId,
                decisionPlan: plan,
                modelResults: [
                    QEvidenceModelResult(candidateId: QModelCandidateID(backend: .ollama), backend: .ollama, outputText: "a: 1"),
                    QEvidenceModelResult(candidateId: QModelCandidateID(backend: .llamaCpp), backend: .llamaCpp, outputText: "a: 2")
                ],
                userCorrectionObserved: true
            )
        )
        let metadata = result.metadata
        #expect(metadata.taskType == plan.taskType.rawValue)
        #expect(metadata.candidateBackends.sorted() == [QModelBackendType.llamaCpp.rawValue, QModelBackendType.ollama.rawValue])
        #expect(metadata.synthesisStatus == "contradictory")
        #expect(metadata.evidenceCompleteness == .partial)
        #expect(metadata.unresolvedContradictionCount == 1)
        #expect(metadata.userCorrection == "observed")
        #expect(metadata.resourceOutcome == "completed")
    }

    @Test("Outcome metadata is audit-safe: every payload value is a short enum/number/boolean token, and it round-trips as Codable")
    func outcomeMetadataIsAuditSafe() async throws {
        let result = await QEvidencePipeline().run(
            input(
                modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "secret-topic-zebra: classified-value-zebra\napi_key: sk-abcdefghijklmnopqrstuvwxyz123456")],
                userFacts: [QUserProvidedFact(sourceId: "user", subject: "my-password-hint", value: "private-value-zebra")]
            )
        )
        let payload = result.metadata.auditPayload
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._,-")
        for (key, value) in payload {
            #expect(value.count <= 64, "payload value for \(key) is too long to be a token")
            #expect(value.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }, "payload value for \(key) is not a plain token: \(value)")
            #expect(!value.contains("zebra"))
            #expect(!value.contains("sk-"))
        }

        let encoded = try JSONEncoder().encode(result.metadata)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("zebra"))
        #expect(!json.contains("abcdefghijklmnopqrstuvwxyz123456"))
        let decoded = try JSONDecoder().decode(QEvidenceOutcomeMetadata.self, from: encoded)
        #expect(decoded == result.metadata)
    }
}
