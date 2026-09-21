//
//  QEvidenceTestSupport.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2C shared test fixtures. Every fixture here builds the same
//  real types production uses; nothing fakes trust — trust is always computed by the real pool.
//

import Foundation
@testable import Pace

enum EvidenceFixtures {
    static let taskId = "task-2c"

    static func decisionPlan(
        taskType: QTaskType = .research,
        complexity: QTaskComplexity = .moderate,
        requirement: QVerificationRequirement = .independentVerification
    ) -> QDecisionPlan {
        QDecisionPlan(
            taskType: taskType,
            complexity: complexity,
            decompositionDecision: .notRequired,
            reasoningStepBudget: 4,
            modelStrategy: .singleLocalModel,
            verificationRequirement: requirement,
            provenanceRequirement: .required,
            resourceEnvelope: QDecisionResourceEnvelope(),
            uncertainty: .medium
        )
    }

    static func pool(requirement: QVerificationRequirement = .independentVerification) -> QEvidencePool {
        QEvidencePool(taskId: taskId, requirement: requirement)
    }

    static func modelDraft(
        sourceId: String,
        backend: QModelBackendType = .ollama,
        content: String,
        taskId: String = EvidenceFixtures.taskId
    ) -> QEvidenceDraft {
        QEvidenceDraft(
            taskId: taskId,
            sourceId: sourceId,
            kind: .modelGenerated,
            provenance: .untrustedTool(toolName: "model:\(backend.rawValue)"),
            origin: QEvidenceOrigin(
                attemptId: QModelAttemptID(rawValue: "\(taskId)-attempt-\(backend.rawValue)-\(sourceId)"),
                candidateId: QModelCandidateID(backend: backend),
                backend: backend
            ),
            content: content
        )
    }

    static func retrievedDraft(sourceId: String, content: String, url: String? = nil) -> QEvidenceDraft {
        QEvidenceDraft(
            taskId: taskId,
            sourceId: sourceId,
            kind: .retrievedExternal,
            provenance: .untrustedWeb(url: url),
            content: content
        )
    }

    static func executionDraft(sourceId: String = "exec-1", content: String, taskId: String = EvidenceFixtures.taskId) -> QEvidenceDraft {
        QEvidenceDraft(taskId: taskId, sourceId: sourceId, kind: .executionObserved, provenance: .trustedSystem, content: content)
    }

    static func userDraft(sourceId: String = "user-1", content: String) -> QEvidenceDraft {
        QEvidenceDraft(taskId: taskId, sourceId: sourceId, kind: .userProvided, provenance: .trustedUser(channel: "test"), content: content)
    }

    /// A claim's ID after ingesting `content` (one `subject: value` line) as a model draft.
    @discardableResult
    static func addModelClaim(
        _ pool: inout QEvidencePool,
        sourceId: String,
        backend: QModelBackendType = .ollama,
        subject: String,
        value: String
    ) -> QClaimID? {
        let result = pool.ingest(modelDraft(sourceId: sourceId, backend: backend, content: "\(subject): \(value)"))
        return result.claimIds.first
    }

    @discardableResult
    static func addExecutionClaim(_ pool: inout QEvidencePool, sourceId: String = "exec-1", subject: String, value: String) -> QClaimID? {
        let result = pool.ingest(executionDraft(sourceId: sourceId, content: "\(subject): \(value)"))
        return result.claimIds.first
    }

    @discardableResult
    static func addUserClaim(_ pool: inout QEvidencePool, subject: String, value: String) -> QClaimID? {
        pool.ingest(userDraft(content: "\(subject): \(value)")).claimIds.first
    }

    @discardableResult
    static func addRetrievedClaim(_ pool: inout QEvidencePool, sourceId: String, subject: String, value: String) -> QClaimID? {
        let result = pool.ingest(retrievedDraft(sourceId: sourceId, content: "\(subject): \(value)"))
        return result.claimIds.first
    }

    /// Runs the real verification service and applies its records — exactly what the pipeline does.
    static func verify(
        _ pool: inout QEvidencePool,
        backends: [any QClaimVerificationBackend] = [QExecutionEvidenceVerificationBackend()]
    ) async {
        let run = await QIndependentVerificationService(backends: backends).verify(pool: pool)
        pool.applyVerification(run.records)
    }
}

// MARK: - Configurable backends / stages

/// Records whether it started and whether it observed cancellation, so tests can prove no work is
/// abandoned after the pipeline returns.
final class EvidenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _sawCancellation = false
    private var _finished = false

    var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
    var sawCancellation: Bool { lock.lock(); defer { lock.unlock() }; return _sawCancellation }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }

    func markStarted() { lock.lock(); _started = true; lock.unlock() }
    func markCancelled() { lock.lock(); _sawCancellation = true; lock.unlock() }
    func markFinished() { lock.lock(); _finished = true; lock.unlock() }
}

struct SleepingVerificationBackend: QClaimVerificationBackend {
    let identity = QVerifierIdentity(basis: .executionEvidence, id: "sleeping-verifier")
    let probe: EvidenceProbe
    var seconds: Double = 30

    func verify(_ request: QClaimVerificationRequest) async throws -> QBackendVerdict {
        probe.markStarted()
        defer { probe.markFinished() }
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { probe.markCancelled(); throw error }
        return .supports
    }
}

struct ThrowingVerificationBackend: QClaimVerificationBackend {
    struct Failure: Error {}
    let identity = QVerifierIdentity(basis: .executionEvidence, id: "throwing-verifier")
    func verify(_ request: QClaimVerificationRequest) async throws -> QBackendVerdict { throw Failure() }
}

struct FixedVerdictBackend: QClaimVerificationBackend {
    let identity: QVerifierIdentity
    let verdict: QBackendVerdict
    func verify(_ request: QClaimVerificationRequest) async throws -> QBackendVerdict { verdict }
}

struct FixedJudge: QIndependentModelJudge {
    let judgeId: String
    let verdict: QBackendVerdict
    func judge(_ request: QClaimVerificationRequest) async throws -> QBackendVerdict { verdict }
}

struct StubCollector: QEvidenceCollector {
    let drafts: [QEvidenceDraft]
    func collect(taskId: String, limit: Int) async throws -> [QEvidenceDraft] { drafts }
}

struct ThrowingCollector: QEvidenceCollector {
    struct Failure: Error {}
    func collect(taskId: String, limit: Int) async throws -> [QEvidenceDraft] { throw Failure() }
}

struct SleepingCollector: QEvidenceCollector {
    let probe: EvidenceProbe
    func collect(taskId: String, limit: Int) async throws -> [QEvidenceDraft] {
        probe.markStarted()
        defer { probe.markFinished() }
        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { probe.markCancelled(); throw error }
        return []
    }
}

struct StubCritic: QEvidenceCritic {
    let findings: [QCriticFinding]
    func critique(pool: QEvidencePool) async throws -> [QCriticFinding] { findings }
}

struct ThrowingCritic: QEvidenceCritic {
    struct Failure: Error {}
    func critique(pool: QEvidencePool) async throws -> [QCriticFinding] { throw Failure() }
}

struct SleepingCritic: QEvidenceCritic {
    let probe: EvidenceProbe
    func critique(pool: QEvidencePool) async throws -> [QCriticFinding] {
        probe.markStarted()
        defer { probe.markFinished() }
        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { probe.markCancelled(); throw error }
        return []
    }
}

struct StubSynthesizer: QEvidenceSynthesizer {
    let draft: QSynthesisDraft
    func synthesize(_ input: QSynthesisInput) async throws -> QSynthesisDraft { draft }
}

struct ThrowingSynthesizer: QEvidenceSynthesizer {
    struct Failure: Error {}
    func synthesize(_ input: QSynthesisInput) async throws -> QSynthesisDraft { throw Failure() }
}

struct SleepingSynthesizer: QEvidenceSynthesizer {
    let probe: EvidenceProbe
    func synthesize(_ input: QSynthesisInput) async throws -> QSynthesisDraft {
        probe.markStarted()
        defer { probe.markFinished() }
        do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { probe.markCancelled(); throw error }
        return QSynthesisDraft(orderedClaimIds: [], proposedStatus: .sufficient)
    }
}
