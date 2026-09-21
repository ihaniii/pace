//
//  QOutcomeLearningTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2E outcome-learning tests: the single outcome classification,
//  derivation from Phase 2C metadata / goal state / Phase 2B attempts, explicit user feedback,
//  duplicate/replay/conflict handling, and poisoning defenses.
//

import Testing
import Foundation
@testable import Pace

private enum LearningFixtures {
    static let now = CapabilityFixtures.now

    static func decisionPlan(taskType: QTaskType = .research, complexity: QTaskComplexity = .moderate, requirement: QVerificationRequirement = .independentVerification) -> QDecisionPlan {
        EvidenceFixtures.decisionPlan(taskType: taskType, complexity: complexity, requirement: requirement)
    }

    static func attempt(
        _ backend: QModelBackendType, _ outcome: QModelAttemptOutcome, index: Int = 0, taskId: String = "task-L",
        durationSeconds: Double = 0.25, finishedAt: Date = now
    ) -> QModelAttempt {
        QModelAttempt(
    attemptId: QModelAttemptID(rawValue: "\(taskId)-attempt-\(backend.rawValue)-\(index)"),
            taskId: taskId, candidateId: QModelCandidateID(backend: backend), backend: backend, outcome: outcome,
            startedAt: finishedAt.addingTimeInterval(-durationSeconds), finishedAt: finishedAt
        )
    }

    static func acceptedPlan(taskId: String = "task-L") -> QModelAttemptOutcome {
        .accepted(plan: QPlan(taskId: taskId, sessionId: "s", taskPrompt: "PROMPT-MUST-NOT-PERSIST-ZEBRA", steps: []))
    }

    /// Real Phase 2C metadata produced by the real pipeline.
    static func realMetadata(
        plan: QDecisionPlan, modelOutput: String? = nil, observedSubject: String = "goal.state", observedValue: String = "satisfied"
    ) async -> QEvidenceOutcomeMetadata {
        await QEvidencePipeline().run(
            QEvidencePipelineInput(
                taskId: "task-L", decisionPlan: plan,
                modelResults: modelOutput.map { [QEvidenceModelResult(backend: .ollama, outputText: $0)] } ?? [],
                observations: [QEvidenceObservation(sourceId: "goal-evaluator", subject: observedSubject, value: observedValue)]
            )
        ).metadata
    }

    static func metadata(
        requirement: String = "independentVerification", synthesisStatus: String = "sufficient", verificationStage: String = "completed",
        contradicted: Int = 0, contradictions: Int = 0, unresolvedContradictions: Int = 0, completeness: QEvidenceCompleteness = .complete
    ) -> QEvidenceOutcomeMetadata {
        QEvidenceOutcomeMetadata(
            taskType: "research", complexity: "moderate", requirement: requirement, synthesisStatus: synthesisStatus, uncertainty: "low",
            evidenceCompleteness: completeness, evidenceCount: 1, claimCount: 1, verifiedClaimCount: 0, unresolvedClaimCount: 0,
            contradictedClaimCount: contradicted, contradictionCount: contradictions, unresolvedContradictionCount: unresolvedContradictions,
            rejectedInputCount: 0, criticFindingCount: 0, draftViolationCount: 0, collectionStage: "skipped", verificationStage: verificationStage,
            criticStage: "completed", synthesisStage: "completed", candidateBackends: [], candidateVerificationStates: [:],
            resourceOutcome: "completed", userCorrection: "notObserved", isTainted: true
        )
    }

    static func input(
        attempts: [QModelAttempt], winner: QModelAttempt?, goalState: QGoalEvaluationState,
        metadata: QEvidenceOutcomeMetadata, plan: QDecisionPlan? = nil, taskId: String = "task-L"
    ) -> QOutcomeLearningInput {
        QOutcomeLearningInput(
            taskId: taskId, decisionPlan: plan ?? decisionPlan(), evidenceMetadata: metadata, attempts: attempts,
            winningAttemptId: winner?.attemptId, goalState: goalState
        )
    }
}

extension QOutcomeLearningService {
    /// Test clock: learning happens shortly after the fixture attempts finished.
    @discardableResult
    fileprivate func learn(_ input: QOutcomeLearningInput) -> QOutcomeLearningReport {
        learn(input, now: LearningFixtures.now.addingTimeInterval(10))
    }
}

@Suite("QOutcomeLearningTests")
struct QOutcomeLearningTests {

    private let now = LearningFixtures.now

    private func makeMemory() throws -> (QModelCapabilityMemory, QDurableTaskStore) {
        let store = try QDurableTaskStore(inMemory: true)
        return (QModelCapabilityMemory(store: store), store)
    }

    private func winnerOutcome(goalState: QGoalEvaluationState, metadata: QEvidenceOutcomeMetadata, attemptOutcome: QModelAttemptOutcome? = nil) throws -> QLearnedOutcome? {
        let (memory, _) = try makeMemory()
        let winner = LearningFixtures.attempt(.ollama, attemptOutcome ?? LearningFixtures.acceptedPlan())
        let report = QOutcomeLearningService(memory: memory).learn(LearningFixtures.input(attempts: [winner], winner: winner, goalState: goalState, metadata: metadata))
        return report.winnerOutcome
    }

    // MARK: - 15-23: outcome states

    @Test("15. success: goal satisfied + verified evidence → success")
    func success() throws {
        #expect(try winnerOutcome(goalState: .satisfied, metadata: LearningFixtures.metadata()) == .success)
    }

    @Test("16. failure: an unsatisfied goal is a failure, whatever the evidence pipeline said")
    func failure() throws {
        #expect(try winnerOutcome(goalState: .unsatisfied, metadata: LearningFixtures.metadata()) == .failure)
    }

    @Test("17. partial: a partially satisfied goal is partial")
    func partial() throws {
        #expect(try winnerOutcome(goalState: .partiallySatisfied, metadata: LearningFixtures.metadata()) == .partial)
    }

    @Test("18. cancelled: a cancelled attempt is cancelled — and is never counted as adverse")
    func cancelled() throws {
        let (memory, store) = try makeMemory()
        let loser = LearningFixtures.attempt(.llamaCpp, .cancelled, index: 1)
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan())
        QOutcomeLearningService(memory: memory).learn(LearningFixtures.input(attempts: [winner, loser], winner: winner, goalState: .satisfied, metadata: LearningFixtures.metadata()))

        let profile = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .llamaCpp), now: now.addingTimeInterval(10))
        #expect(profile.cancellationCount == 1)
        #expect(profile.adverseCount == 0)   // a race loser is not a failure of the model
    }

    @Test("19. timeout: a timed-out attempt is timedOut and adverse")
    func timeout() throws {
        let (memory, store) = try makeMemory()
        let slow = LearningFixtures.attempt(.mlx, .timedOut, durationSeconds: 30)
        QOutcomeLearningService(memory: memory).learn(LearningFixtures.input(attempts: [slow], winner: nil, goalState: .unknown, metadata: LearningFixtures.metadata()))
        let profile = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .mlx), now: now.addingTimeInterval(60))
        #expect(profile.timeoutCount == 1)
        #expect(profile.adverseCount == 1)
        #expect(profile.meanLatencyMilliseconds == 30_000)   // the REAL measured duration
    }

    @Test("20. denied: a blocked goal (security boundary) is denied — policy, not a capability failure")
    func denied() throws {
        #expect(try winnerOutcome(goalState: .blocked, metadata: LearningFixtures.metadata()) == .denied)
        let (memory, store) = try makeMemory()
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan())
        QOutcomeLearningService(memory: memory).learn(LearningFixtures.input(attempts: [winner], winner: winner, goalState: .blocked, metadata: LearningFixtures.metadata()))
        let profile = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now.addingTimeInterval(10))
        #expect(profile.deniedCount == 1)
        #expect(profile.adverseCount == 0)
    }

    @Test("21. verification failure: contradicted evidence beats a satisfied goal — negative verification always wins")
    func verificationFailure() throws {
        #expect(try winnerOutcome(goalState: .satisfied, metadata: LearningFixtures.metadata(contradicted: 1)) == .verificationFailed)
        #expect(try winnerOutcome(goalState: .satisfied, metadata: LearningFixtures.metadata(synthesisStatus: "sufficient", contradicted: 2, contradictions: 1)) == .verificationFailed)
    }

    @Test("22. unresolved: unverified evidence, lost verification stage, or an unresolved contradiction never yields success")
    func unresolved() throws {
        #expect(try winnerOutcome(goalState: .satisfied, metadata: LearningFixtures.metadata(synthesisStatus: "insufficient")) == .unresolved)
        #expect(try winnerOutcome(goalState: .satisfied, metadata: LearningFixtures.metadata(verificationStage: "timedOut")) == .unresolved)
        #expect(try winnerOutcome(goalState: .satisfied, metadata: LearningFixtures.metadata(requirement: "none", synthesisStatus: "contradictory", contradictions: 1, unresolvedContradictions: 1)) == .unresolved)
        // The authoritative judge could not decide: even perfectly verified evidence is not success.
        #expect(try winnerOutcome(goalState: .unknown, metadata: LearningFixtures.metadata()) == .unresolved)
    }

    @Test("requirement .none: a satisfied goal needs no extra verification (notRequired) and is a success")
    func successWithoutRequiredVerification() throws {
        #expect(try winnerOutcome(goalState: .satisfied, metadata: LearningFixtures.metadata(requirement: "none", synthesisStatus: "insufficient")) == .success)
    }

    @Test("A non-winning valid plan, an unavailable candidate, and 'needs verification' are unresolved (no evidence either way), never adverse")
    func attemptLevelNeutralOutcomes() throws {
        let (memory, store) = try makeMemory()
        let attempts = [
            LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan(), index: 0),
            LearningFixtures.attempt(.llamaCpp, .unavailable, index: 1),
            LearningFixtures.attempt(.mlx, .needsVerification, index: 2)
        ]
        QOutcomeLearningService(memory: memory).learn(LearningFixtures.input(attempts: attempts, winner: nil, goalState: .unknown, metadata: LearningFixtures.metadata()))
        for backend in [QModelBackendType.ollama, .llamaCpp, .mlx] {
            let profile = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: backend), now: now.addingTimeInterval(10))
            #expect(profile.unresolvedCount == 1)
            #expect(profile.adverseCount == 0)
        }
    }

    @Test("Attempt-level failures: schema-invalid output is a failure; an egress/policy rejection is denied; verificationFailed is a verification failure")
    func attemptLevelFailures() throws {
        let (memory, store) = try makeMemory()
        let attempts = [
            LearningFixtures.attempt(.ollama, .invalid(reason: "UNPARSEABLE-MODEL-OUTPUT-ZEBRA"), index: 0),
            LearningFixtures.attempt(.llamaCpp, .rejected(reason: "egress refused"), index: 1),
            LearningFixtures.attempt(.mlx, .verificationFailed(reason: "REASON-ZEBRA"), index: 2)
        ]
        QOutcomeLearningService(memory: memory).learn(LearningFixtures.input(attempts: attempts, winner: nil, goalState: .unknown, metadata: LearningFixtures.metadata()))
        func profile(_ backend: QModelBackendType) -> QModelCapabilityProfile {
            store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: backend), now: now.addingTimeInterval(10))
        }
        #expect(profile(.ollama).failureCount == 1)
        #expect(profile(.llamaCpp).deniedCount == 1)
        #expect(profile(.mlx).verifiedFailureCount == 1)
    }

    // MARK: - 23/24: user feedback

    @Test("23. Explicit user correction is recorded as evidence about the task's candidate and counts against it")
    func userCorrection() throws {
        let (memory, store) = try makeMemory()
        let service = QOutcomeLearningService(memory: memory)
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan())
        service.learn(LearningFixtures.input(attempts: [winner], winner: winner, goalState: .satisfied, metadata: LearningFixtures.metadata()))

        #expect(service.recordUserFeedback(taskId: "task-L", feedback: .correction, now: now) == [.recorded])
        let profile = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now.addingTimeInterval(10))
        #expect(profile.verifiedSuccessCount == 1)     // the execution really did verify
        #expect(profile.userCorrectionCount == 1)      // ...and the user explicitly corrected it
        #expect(profile.adverseCount == 1)
        #expect(profile.sampleCount == 1)              // feedback adds no sample weight of its own
    }

    @Test("Feedback is never fabricated: none for an unknown task, none implied by silence, and identical feedback is a duplicate")
    func feedbackIsNeverFabricated() throws {
        let (memory, store) = try makeMemory()
        let service = QOutcomeLearningService(memory: memory)
        #expect(service.recordUserFeedback(taskId: "never-seen", feedback: .correction, now: now) == [.rejected(.noMatchingTaskObservation)])

        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan())
        service.learn(LearningFixtures.input(attempts: [winner], winner: winner, goalState: .satisfied, metadata: LearningFixtures.metadata()))
        let key = QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama)
        let untouched = store.profile(for: key, now: now.addingTimeInterval(10))
        #expect(untouched.userCorrectionCount == 0 && untouched.userConfirmationCount == 0)   // learning alone never invents feedback

        #expect(service.recordUserFeedback(taskId: "task-L", feedback: .confirmation, now: now) == [.recorded])
        #expect(service.recordUserFeedback(taskId: "task-L", feedback: .confirmation, now: now) == [.duplicate])
        #expect(store.profile(for: key, now: now.addingTimeInterval(10)).userConfirmationCount == 1)
    }

    @Test("Explicit feedback is monotone: a correction supersedes an earlier confirmation, never the reverse")
    func feedbackIsMonotone() throws {
        let (memory, store) = try makeMemory()
        let service = QOutcomeLearningService(memory: memory)
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan())
        service.learn(LearningFixtures.input(attempts: [winner], winner: winner, goalState: .satisfied, metadata: LearningFixtures.metadata()))
        let key = QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama)

        #expect(service.recordUserFeedback(taskId: "task-L", feedback: .confirmation, now: now) == [.recorded])
        #expect(service.recordUserFeedback(taskId: "task-L", feedback: .correction, now: now) == [.upgraded])
        #expect(service.recordUserFeedback(taskId: "task-L", feedback: .confirmation, now: now) == [.conflictingDuplicate])
        let profile = store.profile(for: key, now: now.addingTimeInterval(10))
        #expect(profile.userCorrectionCount == 1)
        #expect(profile.userConfirmationCount == 0)
    }

    @Test("Feedback must match the observed task's key: a forged feedback row for a different task type is refused")
    func feedbackKeyMustMatch() throws {
        let (_, store) = try makeMemory()
        store.record(CapabilityFixtures.observation(taskType: .research), now: now)
        let forged = CapabilityFixtures.observation(source: .userFeedback, taskType: .coding, feedback: .correction)
        #expect(store.record(forged, now: now) == .rejected(.inconsistentFeedback))
    }

    // MARK: - 24/25: duplicate outcome, replay

    @Test("24. A duplicate outcome report adds nothing: the second identical learn() is all duplicates")
    func duplicateOutcome() throws {
        let (memory, store) = try makeMemory()
        let service = QOutcomeLearningService(memory: memory)
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan())
        let loser = LearningFixtures.attempt(.llamaCpp, .timedOut, index: 1)
        let input = LearningFixtures.input(attempts: [winner, loser], winner: winner, goalState: .satisfied, metadata: LearningFixtures.metadata())

        let first = service.learn(input)
        let second = service.learn(input)
        #expect(first.recorded == 2 && first.duplicates == 0)
        #expect(second.recorded == 0 && second.duplicates == 2)
        #expect(store.observationCount() == 2)
    }

    @Test("25. Replay across a restart is idempotent, and conflicting re-reports of the same attempt do not rewrite history")
    func replayAcrossRestartAndConflict() throws {
        let path = CapabilityFixtures.temporaryDatabasePath()
        defer { CapabilityFixtures.removeDatabase(at: path) }
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan())
        let successInput = LearningFixtures.input(attempts: [winner], winner: winner, goalState: .satisfied, metadata: LearningFixtures.metadata())

        do {
            let memory = QModelCapabilityMemory(store: try QDurableTaskStore(databasePath: path))
            #expect(QOutcomeLearningService(memory: memory).learn(successInput).recorded == 1)
        }
        let reopened = try QDurableTaskStore(databasePath: path)
        let memory = QModelCapabilityMemory(store: reopened)
        #expect(QOutcomeLearningService(memory: memory).learn(successInput).duplicates == 1)   // replay after restart

        // Same task+attempt reported again with a DIFFERENT result (a bad producer / replay attack).
        let conflicting = LearningFixtures.input(attempts: [winner], winner: winner, goalState: .unsatisfied, metadata: LearningFixtures.metadata())
        let conflictReport = QOutcomeLearningService(memory: memory).learn(conflicting)
        #expect(conflictReport.conflicts == 1)
        let profile = reopened.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now.addingTimeInterval(10))
        #expect(profile.verifiedSuccessCount == 1 && profile.failureCount == 0)   // first report stands
        #expect(reopened.observationCount() == 1)
    }

    @Test("Concurrent outcome recording for the same task records each attempt exactly once")
    func concurrentOutcomeRecording() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let memory = QModelCapabilityMemory(store: store)
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan())
        let loser = LearningFixtures.attempt(.llamaCpp, .timedOut, index: 1)
        let input = LearningFixtures.input(attempts: [winner, loser], winner: winner, goalState: .satisfied, metadata: LearningFixtures.metadata())

        let reports = await withTaskGroup(of: QOutcomeLearningReport.self, returning: [QOutcomeLearningReport].self) { group in
            for _ in 0..<12 { group.addTask { QOutcomeLearningService(memory: memory).learn(input) } }
            var collected: [QOutcomeLearningReport] = []
            for await report in group { collected.append(report) }
            return collected
        }
        #expect(reports.map { $0.recorded }.reduce(0, +) == 2)
        #expect(reports.map { $0.duplicates }.reduce(0, +) == 22)
        #expect(store.observationCount() == 2)
    }

    // MARK: - 26/27: integration with 2C and 2B

    @Test("26. Phase 2C ingestion: real evidence-pipeline metadata drives verification, contradiction, and completeness")
    func phase2CMetadataIngestion() async throws {
        let plan = LearningFixtures.decisionPlan()
        let verified = await LearningFixtures.realMetadata(plan: plan)
        #expect(QOutcomeDerivation.verification(from: verified) == .verified)
        #expect(QOutcomeDerivation.contradiction(from: verified) == .none)

        // Two models disagree, no evidence: unresolved contradiction.
        let disagree = await QEvidencePipeline().run(
            QEvidencePipelineInput(
                taskId: "task-L", decisionPlan: plan,
                modelResults: [
                    QEvidenceModelResult(backend: .ollama, outputText: "answer: X"),
                    QEvidenceModelResult(backend: .llamaCpp, outputText: "answer: Y")
                ]
            )
        ).metadata
        #expect(QOutcomeDerivation.contradiction(from: disagree) == .unresolved)
        #expect(QOutcomeDerivation.verification(from: disagree) == .unresolved)

        // A model claim contradicted by execution evidence → contradicted verification.
        let contradicted = await QEvidencePipeline().run(
            QEvidencePipelineInput(
                taskId: "task-L", decisionPlan: plan,
                modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "line count: 99")],
                observations: [QEvidenceObservation(sourceId: "exec", subject: "line count", value: "120")]
            )
        ).metadata
        #expect(QOutcomeDerivation.verification(from: contradicted) == .contradicted)

        // Completeness flows through to the persisted observation.
        let (memory, store) = try makeMemory()
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan())
        QOutcomeLearningService(memory: memory).learn(LearningFixtures.input(attempts: [winner], winner: winner, goalState: .satisfied, metadata: verified, plan: plan))
        let stored = store.observations(forTask: "task-L", now: now.addingTimeInterval(10)).observations
        #expect(stored.first?.evidenceCompleteness == verified.evidenceCompleteness)
    }

    @Test("27. Phase 2B ingestion: every candidate attempt becomes an observation with its backend, strategy, and measured latency")
    func phase2BCandidateObservation() throws {
        let (memory, store) = try makeMemory()
        let plan = LearningFixtures.decisionPlan()
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan(), index: 0, durationSeconds: 1.5)
        let loser = LearningFixtures.attempt(.llamaCpp, .cancelled, index: 1, durationSeconds: 0.75)
        QOutcomeLearningService(memory: memory).learn(LearningFixtures.input(attempts: [winner, loser], winner: winner, goalState: .satisfied, metadata: LearningFixtures.metadata(), plan: plan))

        let rows = store.observations(forTask: "task-L", now: now.addingTimeInterval(10)).observations
        #expect(rows.count == 2)
        let winnerRow = try #require(rows.first { $0.backend == .ollama })
        #expect(winnerRow.source == .taskOutcome)
        #expect(winnerRow.strategy == plan.modelStrategy)
        #expect(winnerRow.latencyMilliseconds == 1500)
        #expect(winnerRow.attemptId == winner.attemptId.rawValue)
        let loserRow = try #require(rows.first { $0.backend == .llamaCpp })
        #expect(loserRow.source == .modelAttempt)
        #expect(loserRow.outcome == .cancelled)
    }

    @Test("The task-level result is credited ONLY to the executed candidate")
    func creditGoesToTheExecutedCandidateOnly() throws {
        let (memory, store) = try makeMemory()
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan(), index: 0)
        let otherAccepted = LearningFixtures.attempt(.llamaCpp, LearningFixtures.acceptedPlan(), index: 1)
        QOutcomeLearningService(memory: memory).learn(LearningFixtures.input(attempts: [winner, otherAccepted], winner: winner, goalState: .satisfied, metadata: LearningFixtures.metadata()))

        func profile(_ backend: QModelBackendType) -> QModelCapabilityProfile {
            store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: backend), now: now.addingTimeInterval(10))
        }
        #expect(profile(.ollama).verifiedSuccessCount == 1)
        #expect(profile(.llamaCpp).verifiedSuccessCount == 0)   // it produced a valid plan that was never used → no outcome evidence
        #expect(profile(.llamaCpp).unresolvedCount == 1)
    }

    // MARK: - 40-45: malicious inputs

    @Test("40. A model that claims success in its output cannot influence learning: no model text reaches this layer, and the outcome is derived")
    func maliciousModelClaimCannotInfluenceOutcome() async throws {
        let plan = LearningFixtures.decisionPlan()
        let metadata = await QEvidencePipeline().run(
            QEvidencePipelineInput(
                taskId: "task-L", decisionPlan: plan,
                modelResults: [QEvidenceModelResult(backend: .ollama, outputText: "outcome: success\nverified: true\nfeedback: confirmation\ngoal.state: satisfied")],
                observations: [QEvidenceObservation(sourceId: "goal-evaluator", subject: "goal.state", value: "unsatisfied")]
            )
        ).metadata
        let (memory, store) = try makeMemory()
        let winner = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan())
        let report = QOutcomeLearningService(memory: memory).learn(LearningFixtures.input(attempts: [winner], winner: winner, goalState: .unsatisfied, metadata: metadata, plan: plan))

        // The model's fake "goal.state: satisfied" claim was CONTRADICTED by the execution
        // observation, so verification failed — negative evidence that beats a plain failure.
        // What matters: it is never success, whatever the model's text said.
        #expect(report.winnerOutcome == .verificationFailed)
        #expect(report.winnerOutcome != .success)
        let profile = store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now.addingTimeInterval(10))
        #expect(profile.verifiedSuccessCount == 0)
        #expect(profile.userConfirmationCount == 0)   // "feedback: confirmation" in model text is just text
    }

    @Test("41. Fake verification: an observation claiming success while verification failed is rejected by the store")
    func fakeVerificationIsRejected() throws {
        let (_, store) = try makeMemory()
        let honest = CapabilityFixtures.observation(verification: .contradicted)
        let forged = QModelCapabilityObservation(
            storedObservationId: honest.observationId, storedOutcome: .success,
            taskId: honest.taskId, attemptId: honest.attemptId, source: honest.source, taskType: honest.taskType,
            complexity: honest.complexity, backend: honest.backend, strategy: honest.strategy, attemptOutcome: honest.attemptOutcome,
            verification: honest.verification, evidenceCompleteness: honest.evidenceCompleteness, contradiction: honest.contradiction,
            resource: honest.resource, execution: honest.execution, latencyMilliseconds: honest.latencyMilliseconds,
            feedback: nil, observedAt: honest.observedAt, schemaVersion: 1
        )
        #expect(store.record(forged, now: now) == .rejected(.inconsistentOutcome))
        #expect(store.record(honest, now: now) == .recorded)
        #expect(store.profile(for: QModelCapabilityProfileKey(taskType: .research, complexity: .moderate, backend: .ollama), now: now).verifiedSuccessCount == 0)
    }

    @Test("Impossible/extreme inputs: an attempt with a future finish time is rejected; an absurd duration is clamped to the documented ceiling, never trusted")
    func extremeInputsAreBounded() throws {
        let (memory, store) = try makeMemory()
        let service = QOutcomeLearningService(memory: memory)

        let future = LearningFixtures.attempt(.llamaCpp, LearningFixtures.acceptedPlan(), index: 0, finishedAt: now.addingTimeInterval(86_400))
        let futureReport = service.learn(LearningFixtures.input(attempts: [future], winner: future, goalState: .satisfied, metadata: LearningFixtures.metadata()))
        #expect(futureReport.rejections[.futureTimestamp] == 1)
        #expect(futureReport.recorded == 0)

        let absurd = LearningFixtures.attempt(.ollama, LearningFixtures.acceptedPlan(), durationSeconds: 200_000)   // ~55 hours
        let report = service.learn(LearningFixtures.input(attempts: [absurd], winner: absurd, goalState: .satisfied, metadata: LearningFixtures.metadata()))
        #expect(report.recorded == 1)
        let row = try #require(store.observations(forTask: "task-L", now: now.addingTimeInterval(10)).observations.first)
        #expect(row.latencyMilliseconds == QModelCapabilityLimits.maxLatencyMilliseconds)
    }

    @Test("45. Classification is total and authoritative: negative evidence beats positive evidence in every combination")
    func classifierNegativeEvidenceWins() {
        for verification in QObservedVerification.allCases {
            for execution in QObservedExecution.allCases {
                let outcome = QOutcomeClassifier.classify(
                    source: .taskOutcome, attemptOutcome: .accepted, verification: verification, contradiction: .none,
                    resource: .completed, execution: execution, feedback: nil
                )
                if outcome == .success {
                    #expect(verification == .verified || verification == .notRequired)
                    #expect(execution == .succeeded)
                }
                // Denial (a blocked execution) is policy and takes precedence over everything below it.
                if execution == .blocked { #expect(outcome == .denied) }
                if verification == .contradicted && execution != .blocked { #expect(outcome == .verificationFailed) }
                if execution == .failed && verification != .contradicted { #expect(outcome == .failure) }
            }
        }
        // Timeouts/cancellations/denials are never success, even with perfect verification.
        for resource in [QObservedResource.timedOut, .cancelled, .failed] {
            #expect(QOutcomeClassifier.classify(source: .taskOutcome, attemptOutcome: .accepted, verification: .verified, contradiction: .none, resource: resource, execution: .succeeded, feedback: nil) != .success)
        }
        #expect(QOutcomeClassifier.classify(source: .taskOutcome, attemptOutcome: .rejected, verification: .verified, contradiction: .none, resource: .completed, execution: .succeeded, feedback: nil) == .denied)
        #expect(QOutcomeClassifier.classify(source: .taskOutcome, attemptOutcome: .accepted, verification: .verified, contradiction: .unresolved, resource: .completed, execution: .succeeded, feedback: nil) == .unresolved)
    }
}
