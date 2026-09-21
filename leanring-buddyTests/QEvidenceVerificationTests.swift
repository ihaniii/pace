//
//  QEvidenceVerificationTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2C Independent Verification tests: result types, independence,
//  advisory model verdicts, disagreement handling, isolation, timeout, cancellation, bounds.
//

import Testing
import Foundation
@testable import Pace

@Suite("QEvidenceVerificationTests")
struct QEvidenceVerificationTests {

    // MARK: - Result types

    @Test("verified: a model claim matching execution evidence becomes independentlyVerified via the execution basis")
    func verifiedByExecutionEvidence() async {
        var pool = EvidenceFixtures.pool()
        let modelClaim = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "file count", value: "3")!
        EvidenceFixtures.addExecutionClaim(&pool, subject: "file count", value: "3")

        await EvidenceFixtures.verify(&pool)

        let claim = pool.claim(modelClaim)!
        #expect(claim.verification == .verified)
        #expect(claim.verifiedBasis == .executionEvidence)
        #expect(claim.trust == .independentlyVerified)
        #expect(claim.status == .verified)
        #expect(pool.isSatisfied(claim))
    }

    @Test("contradicted: a model claim that disagrees with execution evidence is contradicted, not silently kept")
    func contradictedByExecutionEvidence() async {
        var pool = EvidenceFixtures.pool()
        let modelClaim = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "file count", value: "7")!
        EvidenceFixtures.addExecutionClaim(&pool, subject: "file count", value: "3")

        await EvidenceFixtures.verify(&pool)

        let claim = pool.claim(modelClaim)!
        #expect(claim.verification == .contradicted)
        #expect(claim.status == .contradicted)
        #expect(!pool.isSatisfied(claim))
    }

    @Test("unresolved: with no independent evidence about the subject, the claim stays unresolved and unverified")
    func unresolvedWithoutIndependentEvidence() async {
        var pool = EvidenceFixtures.pool()
        let modelClaim = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "obscure fact", value: "42")!

        await EvidenceFixtures.verify(&pool)

        let claim = pool.claim(modelClaim)!
        #expect(claim.verification == .unresolved)
        #expect(claim.trust == .untrusted)
        #expect(pool.verificationRecords.first?.reason == .noIndependentEvidence)
    }

    @Test("unavailable: with no verifier configured, claims are unavailable — never verified by default")
    func unavailableWithoutVerifier() async {
        var pool = EvidenceFixtures.pool()
        let modelClaim = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "fact", value: "x")!

        await EvidenceFixtures.verify(&pool, backends: [])

        #expect(pool.claim(modelClaim)?.verification == .unavailable)
        #expect(pool.claim(modelClaim)?.trust == .untrusted)
        #expect(pool.verificationRecords.first?.reason == .noVerifierConfigured)
    }

    @Test("notRequired: with requirement .none, model claims need no verification and none is attempted")
    func notRequiredWhenRequirementIsNone() async {
        var pool = EvidenceFixtures.pool(requirement: .none)
        let modelClaim = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "fact", value: "x")!
        let userClaim = pool.ingest(EvidenceFixtures.userDraft(content: "name: sam")).claimIds.first!

        let run = await QIndependentVerificationService(backends: [QExecutionEvidenceVerificationBackend()]).verify(pool: pool)

        #expect(run.records.isEmpty)
        #expect(run.callsMade == 0)
        #expect(pool.claim(modelClaim)?.verification == .notRequired)
        #expect(pool.claim(userClaim)?.verification == .notRequired)
        #expect(!pool.claim(modelClaim)!.verificationRequired)
    }

    @Test("A deterministic check can independently verify or contradict")
    func deterministicCheckVerifies() async {
        var pool = EvidenceFixtures.pool()
        let right = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "two plus two", value: "4")!
        let wrong = EvidenceFixtures.addModelClaim(&pool, sourceId: "m2", backend: .llamaCpp, subject: "three times three", value: "10")!
        let arithmetic = QDeterministicCheckVerificationBackend(
            id: "arithmetic",
            rules: [
                "two plus two": { $0 == "4" ? .supports : .refutes },
                "three times three": { $0 == "9" ? .supports : .refutes }
            ]
        )

        await EvidenceFixtures.verify(&pool, backends: [arithmetic])

        #expect(pool.claim(right)?.verifiedBasis == .deterministicCheck)
        #expect(pool.claim(right)?.trust == .independentlyVerified)
        #expect(pool.claim(wrong)?.verification == .contradicted)
    }

    // MARK: - Independence

    @Test("A model cannot verify its own claim: a judge with the producer's identity is refused")
    func selfVerificationIsRefused() async {
        var pool = EvidenceFixtures.pool()
        let claimId = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", backend: .ollama, subject: "fact", value: "x")!
        let selfJudge = QIndependentModelVerificationBackend(judge: FixedJudge(judgeId: QModelBackendType.ollama.rawValue, verdict: .supports))

        await EvidenceFixtures.verify(&pool, backends: [selfJudge])

        let claim = pool.claim(claimId)!
        #expect(claim.verification == .unresolved)
        #expect(claim.trust == .untrusted)
        #expect(pool.verificationRecords.first?.reason == .selfVerificationRefused)
    }

    @Test("An independent model's verdict is advisory only: it never produces verified or contradicted and never raises trust")
    func independentModelIsAdvisoryOnly() async {
        var pool = EvidenceFixtures.pool()
        let supported = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", backend: .ollama, subject: "fact one", value: "x")!
        let refuted = EvidenceFixtures.addModelClaim(&pool, sourceId: "m2", backend: .ollama, subject: "fact two", value: "y")!
        let supportingJudge = FixedJudge(judgeId: QModelBackendType.llamaCpp.rawValue, verdict: .supports)

        await EvidenceFixtures.verify(&pool, backends: [QIndependentModelVerificationBackend(judge: supportingJudge)])

        #expect(pool.claim(supported)?.verification == .unresolved)
        #expect(pool.claim(supported)?.trust == .untrusted)
        #expect(pool.claim(refuted)?.verification == .unresolved)
        #expect(pool.verificationRecords.allSatisfy { $0.reason == .independentModelAdvisoryOnly })

        var refutingPool = EvidenceFixtures.pool()
        let target = EvidenceFixtures.addModelClaim(&refutingPool, sourceId: "m1", backend: .ollama, subject: "fact", value: "x")!
        let refutingJudge = FixedJudge(judgeId: QModelBackendType.llamaCpp.rawValue, verdict: .refutes)
        await EvidenceFixtures.verify(&refutingPool, backends: [QIndependentModelVerificationBackend(judge: refutingJudge)])
        #expect(refutingPool.claim(target)?.verification == .unresolved)   // never `.contradicted` on a model's say-so
    }

    @Test("The pool itself refuses forged records: model-basis verified, nil-basis verified, and self-verification")
    func poolRefusesForgedVerificationRecords() {
        var pool = EvidenceFixtures.pool()
        let claimId = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", backend: .ollama, subject: "fact", value: "x")!

        pool.applyVerification([QVerificationRecord(claimId: claimId, result: .verified, basis: .independentModel, verifierId: "some-judge", reason: .agreedWithIndependentEvidence)])
        #expect(pool.claim(claimId)?.verification == .unresolved)
        #expect(pool.claim(claimId)?.trust == .untrusted)

        pool.applyVerification([QVerificationRecord(claimId: claimId, result: .verified, basis: nil, verifierId: nil, reason: .agreedWithIndependentEvidence)])
        #expect(pool.claim(claimId)?.verification == .unresolved)
        #expect(pool.claim(claimId)?.trust == .untrusted)

        pool.applyVerification([QVerificationRecord(claimId: claimId, result: .verified, basis: .independentModel, verifierId: QModelBackendType.ollama.rawValue, reason: .agreedWithIndependentEvidence)])
        #expect(pool.verificationRecords.first?.reason == .selfVerificationRefused)
        #expect(pool.claim(claimId)?.trust == .untrusted)

        pool.applyVerification([QVerificationRecord(claimId: QClaimID(rawValue: "cl-unknown"), result: .verified, basis: .executionEvidence, verifierId: "x", reason: .agreedWithIndependentEvidence)])
        #expect(pool.claims.count == 1)
    }

    // MARK: - Disagreement

    @Test("Disagreeing verifiers are never resolved by picking one: the claim stays unresolved")
    func disagreeingVerifiersStayUnresolved() async {
        var pool = EvidenceFixtures.pool()
        let claimId = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "fact", value: "x")!
        let supporter = FixedVerdictBackend(identity: QVerifierIdentity(basis: .executionEvidence, id: "exec-a"), verdict: .supports)
        let refuter = FixedVerdictBackend(identity: QVerifierIdentity(basis: .deterministicCheck, id: "check-b"), verdict: .refutes)

        await EvidenceFixtures.verify(&pool, backends: [supporter, refuter])

        #expect(pool.claim(claimId)?.verification == .unresolved)
        #expect(pool.claim(claimId)?.trust == .untrusted)
        #expect(pool.verificationRecords.first?.reason == .conflictingVerifiers)
    }

    @Test("Model A says X, Model B says Y, no evidence: both preserved, contradiction recorded, no automatic winner")
    func modelDisagreementWithoutEvidenceHasNoWinner() async {
        var pool = EvidenceFixtures.pool()
        let claimX = EvidenceFixtures.addModelClaim(&pool, sourceId: "a", backend: .ollama, subject: "answer", value: "X")!
        let claimY = EvidenceFixtures.addModelClaim(&pool, sourceId: "b", backend: .llamaCpp, subject: "answer", value: "Y")!

        await EvidenceFixtures.verify(&pool)

        #expect(pool.claims.count == 2)
        #expect(pool.contradictions.count == 1)
        #expect(!pool.contradictions[0].isResolved)
        #expect(pool.claim(claimX)?.trust == .untrusted)
        #expect(pool.claim(claimY)?.trust == .untrusted)
        #expect(pool.claim(claimX)?.verification == .unresolved)
        #expect(pool.claim(claimY)?.verification == .unresolved)
    }

    @Test("Model A correct, Model B incorrect: independent execution evidence settles it — A verified, B contradicted, both preserved")
    func independentEvidenceSettlesDisagreement() async {
        var pool = EvidenceFixtures.pool()
        let claimA = EvidenceFixtures.addModelClaim(&pool, sourceId: "a", backend: .ollama, subject: "line count", value: "120")!
        let claimB = EvidenceFixtures.addModelClaim(&pool, sourceId: "b", backend: .llamaCpp, subject: "line count", value: "99")!
        let observed = EvidenceFixtures.addExecutionClaim(&pool, subject: "line count", value: "120")!

        await EvidenceFixtures.verify(&pool)

        #expect(pool.claim(claimA)?.status == .verified)
        #expect(pool.claim(claimB)?.status == .contradicted)
        #expect(pool.claims.count == 3)   // nothing dropped
        #expect(pool.contradictions.count == 1)
        guard case .resolvedByVerification(let winners, let basis) = pool.contradictions[0].resolution else {
            Issue.record("Expected the contradiction to be resolved by independent evidence")
            return
        }
        #expect(basis == .executionEvidence)
        #expect(winners.contains(claimA) && winners.contains(observed))
        #expect(!winners.contains(claimB))
    }

    @Test("Model self-confidence is irrelevant: certainty language earns no trust and does not settle a conflict")
    func selfConfidenceDoesNotWin() async {
        var pool = EvidenceFixtures.pool()
        let confident = EvidenceFixtures.addModelClaim(&pool, sourceId: "a", subject: "answer", value: "definitely X, 100% guaranteed")!
        let hesitant = EvidenceFixtures.addModelClaim(&pool, sourceId: "b", backend: .llamaCpp, subject: "answer", value: "maybe Y")!

        await EvidenceFixtures.verify(&pool)

        #expect(pool.claim(confident)?.trust == .untrusted)
        #expect(pool.claim(hesitant)?.trust == .untrusted)
        #expect(!pool.contradictions[0].isResolved)
    }

    // MARK: - Failure isolation, timeout, cancellation, bounds

    @Test("A throwing backend is isolated: the claim is unavailable and other claims still verify")
    func throwingBackendIsIsolated() async {
        var pool = EvidenceFixtures.pool()
        let claimId = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "fact", value: "x")!

        await EvidenceFixtures.verify(&pool, backends: [ThrowingVerificationBackend()])
        #expect(pool.claim(claimId)?.verification == .unavailable)
        #expect(pool.verificationRecords.first?.reason == .backendFailed)

        // A failing backend alongside a healthy one: the healthy verdict stands.
        var mixedPool = EvidenceFixtures.pool()
        let mixedClaim = EvidenceFixtures.addModelClaim(&mixedPool, sourceId: "m1", subject: "fact", value: "x")!
        EvidenceFixtures.addExecutionClaim(&mixedPool, subject: "fact", value: "x")
        await EvidenceFixtures.verify(&mixedPool, backends: [ThrowingVerificationBackend(), QExecutionEvidenceVerificationBackend()])
        #expect(mixedPool.claim(mixedClaim)?.verification == .verified)
    }

    @Test("A slow backend times out per call: unavailable with a timeout reason, and the backend is cancelled, not abandoned")
    func slowBackendTimesOut() async {
        var pool = EvidenceFixtures.pool()
        let claimId = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "fact", value: "x")!
        let probe = EvidenceProbe()
        let service = QIndependentVerificationService(backends: [SleepingVerificationBackend(probe: probe)], perCallTimeout: 0.1)

        let started = Date()
        let run = await service.verify(pool: pool)
        pool.applyVerification(run.records)

        #expect(Date().timeIntervalSince(started) < 5)
        #expect(pool.claim(claimId)?.verification == .unavailable)
        #expect(pool.verificationRecords.first?.reason == .backendTimedOut)
        #expect(probe.started)
        #expect(probe.sawCancellation)
        #expect(probe.finished)   // no abandoned work: it has already unwound when verify returns
    }

    @Test("Cancelling verification stops it promptly, reports cancelled, and leaves no backend running")
    func cancelledVerificationStopsPromptly() async {
        var pool = EvidenceFixtures.pool()
        for index in 0..<5 { EvidenceFixtures.addModelClaim(&pool, sourceId: "m\(index)", subject: "fact \(index)", value: "x") }
        let probe = EvidenceProbe()
        let service = QIndependentVerificationService(backends: [SleepingVerificationBackend(probe: probe)], perCallTimeout: 60)
        let snapshot = pool

        let task = Task { await service.verify(pool: snapshot) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let started = Date()
        let run = await task.value

        #expect(Date().timeIntervalSince(started) < 5)
        #expect(run.wasCancelled)
        #expect(run.records.count < 5)
        #expect(probe.sawCancellation)
        #expect(probe.finished)
    }

    @Test("Verification is bounded: total backend calls never exceed the call budget")
    func verificationCallBudgetIsBounded() async {
        var pool = EvidenceFixtures.pool()
        for index in 0..<QEvidenceLimits.maxClaims {
            EvidenceFixtures.addModelClaim(&pool, sourceId: "m\(index)", subject: "fact \(index)", value: "x")
        }
        let backends: [any QClaimVerificationBackend] = [
            FixedVerdictBackend(identity: QVerifierIdentity(basis: .executionEvidence, id: "a"), verdict: .cannotDetermine),
            FixedVerdictBackend(identity: QVerifierIdentity(basis: .deterministicCheck, id: "b"), verdict: .cannotDetermine),
            FixedVerdictBackend(identity: QVerifierIdentity(basis: .independentModel, id: "c"), verdict: .cannotDetermine),
            FixedVerdictBackend(identity: QVerifierIdentity(basis: .independentModel, id: "d"), verdict: .cannotDetermine)
        ]
        let service = QIndependentVerificationService(backends: backends)
        #expect(service.backends.count == QEvidenceLimits.maxVerificationBackendsPerClaim)

        let run = await service.verify(pool: pool)

        #expect(run.callsMade <= QEvidenceLimits.maxVerificationCalls)
        #expect(run.budgetExhausted)
        #expect(run.records.contains { $0.reason == .verificationBudgetExhausted })
        #expect(run.records.count == QEvidenceLimits.maxClaims)   // every claim still gets a typed outcome
    }

    @Test("Verification is idempotent and single-shot: applying the same run twice changes nothing")
    func verificationIsIdempotent() async {
        var pool = EvidenceFixtures.pool()
        EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "fact", value: "x")
        EvidenceFixtures.addExecutionClaim(&pool, subject: "fact", value: "x")
        let run = await QIndependentVerificationService(backends: [QExecutionEvidenceVerificationBackend()]).verify(pool: pool)
        pool.applyVerification(run.records)
        let afterFirst = pool
        pool.applyVerification(run.records)
        #expect(pool == afterFirst)
    }
}
