//
//  QModelOrchestrationContractsTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2B Model Orchestration Contracts Tests.
//

import Testing
import Foundation
@testable import Pace

@Suite("QModelOrchestrationContractsTests")
struct QModelOrchestrationContractsTests {

    // MARK: - Candidate identity is deterministic

    @Test("1. QModelCandidateID derived from a backend type is stable and repeatable")
    func candidateIDIsDeterministic() {
        let first = QModelCandidateID(backend: .ollama)
        let second = QModelCandidateID(backend: .ollama)
        #expect(first == second)
        #expect(first.rawValue == "local.ollama")
    }

    @Test("2. Different backends produce different candidate IDs")
    func differentBackendsProduceDifferentCandidateIDs() {
        #expect(QModelCandidateID(backend: .appleFoundation) != QModelCandidateID(backend: .mlx))
    }

    // MARK: - QModelCandidate carries no fabricated fields

    @Test("3. QModelCandidate carries only capability/availability facts already known to QModelRouter — no score, no ranking field")
    func candidateHasNoFabricatedFields() {
        let mirror = Mirror(reflecting: QModelCandidate(
            backend: .mlx,
            capabilities: QModelCapabilities(backend: .mlx, modelIdentifier: "test"),
            isAvailable: true
        ))
        let fieldNames = Set(mirror.children.compactMap { $0.label })
        #expect(fieldNames == ["id", "backend", "capabilities", "isAvailable", "isLocalOnDevice"])
        for forbidden in ["score", "quality", "confidence", "rank", "rating"] {
            #expect(!fieldNames.contains { $0.localizedCaseInsensitiveContains(forbidden) })
        }
    }

    // MARK: - Attempt outcome vocabulary

    @Test("4. QModelAttemptOutcome.isAccepted is true only for .accepted")
    func isAcceptedOnlyTrueForAccepted() {
        let plan = QPlan(taskId: "t", sessionId: "s", taskPrompt: "p", steps: [])
        #expect(QModelAttemptOutcome.accepted(plan: plan).isAccepted)
        #expect(!QModelAttemptOutcome.rejected(reason: "x").isAccepted)
        #expect(!QModelAttemptOutcome.invalid(reason: "x").isAccepted)
        #expect(!QModelAttemptOutcome.timedOut.isAccepted)
        #expect(!QModelAttemptOutcome.cancelled.isAccepted)
        #expect(!QModelAttemptOutcome.unavailable.isAccepted)
        #expect(!QModelAttemptOutcome.verificationFailed(reason: "x").isAccepted)
        #expect(!QModelAttemptOutcome.needsVerification.isAccepted)
    }

    @Test("5. auditLabel never leaks associated reason/plan content — only the bounded case name")
    func auditLabelNeverLeaksContent() {
        let secretMarker = "q-2b-secret-\(UUID().uuidString)"
        let outcomes: [QModelAttemptOutcome] = [
            .rejected(reason: secretMarker),
            .invalid(reason: secretMarker),
            .verificationFailed(reason: secretMarker)
        ]
        for outcome in outcomes {
            #expect(!outcome.auditLabel.contains(secretMarker))
        }
        #expect(QModelAttemptOutcome.rejected(reason: secretMarker).auditLabel == "rejected")
        #expect(QModelAttemptOutcome.invalid(reason: secretMarker).auditLabel == "invalid")
    }

    // MARK: - Attempt duration

    @Test("6. QModelAttempt.durationSeconds reflects started/finished timestamps")
    func attemptDurationIsComputedCorrectly() {
        let start = Date()
        let end = start.addingTimeInterval(2.5)
        let attempt = QModelAttempt(
            attemptId: QModelAttemptID(rawValue: "a"),
            taskId: "t",
            candidateId: QModelCandidateID(backend: .ollama),
            backend: .ollama,
            outcome: .timedOut,
            startedAt: start,
            finishedAt: end
        )
        #expect(abs(attempt.durationSeconds - 2.5) < 0.001)
    }

    // MARK: - Orchestration result

    @Test("7. QModelOrchestrationResult.isSuccess reflects winningPlan presence only")
    func orchestrationResultSuccessReflectsWinningPlan() {
        let plan = QPlan(taskId: "t", sessionId: "s", taskPrompt: "p", steps: [])
        let success = QModelOrchestrationResult(winningPlan: plan, attempts: [], earlyExitReason: .singleCandidateOnly, didRace: false)
        let failure = QModelOrchestrationResult(winningPlan: nil, attempts: [], earlyExitReason: .allCandidatesExhausted, didRace: false)
        #expect(success.isSuccess)
        #expect(!failure.isSuccess)
    }

    // MARK: - Security: no authority anywhere in these contracts

    @Test("8. Security: none of the Phase 2B contract types carry a permission/capability/credential/approval field")
    func noSecurityAuthorityInContracts() {
        let plan = QPlan(taskId: "t", sessionId: "s", taskPrompt: "p", steps: [])
        let attempt = QModelAttempt(
            attemptId: QModelAttemptID(rawValue: "a"),
            taskId: "t",
            candidateId: QModelCandidateID(backend: .ollama),
            backend: .ollama,
            outcome: .accepted(plan: plan),
            startedAt: Date(),
            finishedAt: Date()
        )
        let result = QModelOrchestrationResult(winningPlan: plan, attempts: [attempt], earlyExitReason: .firstSchemaValidPlanAccepted, didRace: true)

        let forbiddenSubstrings = ["permission", "capability", "credential", "approval", "authoriz", "egress", "secret", "token"]
        for mirror in [Mirror(reflecting: attempt), Mirror(reflecting: result)] {
            for child in mirror.children {
                guard let label = child.label else { continue }
                for forbidden in forbiddenSubstrings {
                    #expect(!label.localizedCaseInsensitiveContains(forbidden), "\(label) unexpectedly resembles a security-authority field")
                }
            }
        }
    }

    @Test("9. QDecisionPlan itself still carries no concrete model/provider/backend field after Phase 2B (regression lock on Phase 2A's own guarantee)")
    func decisionPlanStillCarriesNoConcreteProviderField() {
        let decisionPlan = QDeterministicDecisionEngine().decide(for: QTask(intent: "Research something"))
        let mirror = Mirror(reflecting: decisionPlan)
        let fieldNames = Set(mirror.children.compactMap { $0.label })
        // "modelStrategy" is a legitimate, already-existing Phase 2A conceptual-strategy field
        // (singleLocalModel/localReasoningModel/localPlannerModel — never a concrete backend), so
        // "model" itself is not checked here; "backend"/"provider"/"candidate" would be the
        // concrete-authority shape this test guards against.
        for forbidden in ["backend", "provider", "candidate"] {
            #expect(!fieldNames.contains { $0.localizedCaseInsensitiveContains(forbidden) }, "QDecisionPlan unexpectedly gained a concrete-provider-shaped field: \(fieldNames)")
        }
    }

    // MARK: - Forward compatibility (Phase 2C extension points, unused by 2B)

    @Test("10. verificationFailed/needsVerification are valid, constructible outcome cases (Phase 2C extension points) even though this phase's orchestrator never produces them")
    func phase2CExtensionPointsAreConstructible() {
        let a = QModelAttemptOutcome.verificationFailed(reason: "no independent evidence yet")
        let b = QModelAttemptOutcome.needsVerification
        #expect(!a.isAccepted)
        #expect(!b.isAccepted)
    }
}
