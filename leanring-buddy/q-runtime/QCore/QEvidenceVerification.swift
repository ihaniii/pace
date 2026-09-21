//
//  QEvidenceVerification.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2C Independent Verification.
//  A bounded verifier layer that is independent of the model that produced a claim. It verifies
//  using (1) execution evidence already in the pool, (2) registered deterministic checks, and
//  (3) — advisory only — an independent local model. It never grants permission/egress/resource
//  authority and never replaces `QActionVerifier`, which remains the authoritative, execution-time
//  verifier; this layer only evaluates CLAIMS against evidence that verifier (or a deterministic
//  check) already established.
//
//  Rules enforced here AND re-enforced by `QEvidencePool.applyVerification(_:)`:
//   - a model cannot verify its own claim by repeating it (self-verification refused);
//   - an independent-model verdict is advisory: recorded as `unresolved`, never `verified`;
//   - disagreeing verifiers are never resolved by picking one — the claim stays `unresolved`;
//   - every backend call has a timeout, is cancellable, and a failing backend is isolated
//     (→ `unavailable`), never fatal. Calls are sequential (no fan-out on a 16 GB laptop) and
//     bounded by `QEvidenceLimits.maxVerificationCalls`.
//

import Foundation

// MARK: - Bounded Async Helper

enum QEvidenceAsyncOutcome<T: Sendable>: Sendable {
    case value(T)
    case timedOut
    case cancelled
    case failed
}

private enum QEvidenceRaced<T: Sendable>: Sendable {
    case value(T)
    case timedOut
    case cancelled
    case failed
}

/// Races `operation` against a timeout inside a structured task group: on timeout or outer
/// cancellation the operation is cancelled and awaited (no detached/abandoned work). An operation
/// that ignores cancellation delays this call's return until it finishes — cooperative
/// cancellation is a documented requirement of every Phase 2C backend.
enum QEvidenceAsync {
    static func run<T: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async -> QEvidenceAsyncOutcome<T> {
        if Task.isCancelled { return .cancelled }
        let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
        let first: QEvidenceRaced<T> = await withTaskGroup(of: QEvidenceRaced<T>.self) { group in
            group.addTask {
                do { return .value(try await operation()) }
                catch is CancellationError { return .cancelled }
                catch { return .failed }
            }
            group.addTask {
                do { try await Task.sleep(nanoseconds: nanoseconds); return .timedOut }
                catch { return .cancelled }
            }
            let winner = await group.next() ?? .cancelled
            group.cancelAll()
            return winner
        }
        switch first {
        case .value(let value): return .value(value)
        case .timedOut: return .timedOut
        case .failed: return .failed
        case .cancelled: return Task.isCancelled ? .cancelled : .failed
        }
    }
}

// MARK: - Backend Contract

public struct QVerifierIdentity: Sendable, Equatable {
    public let basis: QVerificationBasis
    public let id: String
    public init(basis: QVerificationBasis, id: String) {
        self.basis = basis
        self.id = id
    }
}

/// A backend's raw opinion. Never a score; the service maps opinions to typed results.
public enum QBackendVerdict: Sendable, Equatable {
    case supports
    case refutes
    case cannotDetermine
}

/// Read-only snapshot handed to a backend. Value types only — a backend cannot mutate the pool.
public struct QClaimVerificationRequest: Sendable {
    public let claim: QEvidenceClaim
    public let evidence: [QEvidenceItem]
    public let peerClaims: [QEvidenceClaim]
}

public protocol QClaimVerificationBackend: Sendable {
    var identity: QVerifierIdentity { get }
    /// Must honour cancellation cooperatively. Throwing is treated as "backend unavailable".
    func verify(_ request: QClaimVerificationRequest) async throws -> QBackendVerdict
}

// MARK: - Built-in Backends

/// Verifies a claim against `executionObserved` claims already in the pool (facts Q's own
/// execution/verification machinery observed). Same subject + same value → supports; same subject
/// + different value → refutes; no execution evidence about the subject → cannotDetermine.
public struct QExecutionEvidenceVerificationBackend: QClaimVerificationBackend {
    public let identity = QVerifierIdentity(basis: .executionEvidence, id: "execution-evidence")
    public init() {}

    public func verify(_ request: QClaimVerificationRequest) async throws -> QBackendVerdict {
        try Task.checkCancellation()
        let observed = request.peerClaims.filter {
            $0.originKind == .executionObserved && $0.proposition.subjectKey == request.claim.proposition.subjectKey
        }
        guard !observed.isEmpty else { return .cannotDetermine }
        if observed.contains(where: { $0.proposition.normalizedValueHash == request.claim.proposition.normalizedValueHash }) {
            return .supports
        }
        return .refutes
    }
}

/// Verifies claims with registered, deterministic, local rules keyed by subject (e.g. arithmetic).
/// A rule returns `.cannotDetermine` for anything it does not recognise.
public struct QDeterministicCheckVerificationBackend: QClaimVerificationBackend {
    public let identity: QVerifierIdentity
    private let rules: [String: @Sendable (String) -> QBackendVerdict]

    public init(id: String, rules: [String: @Sendable (String) -> QBackendVerdict]) {
        self.identity = QVerifierIdentity(basis: .deterministicCheck, id: id)
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { (QEvidenceText.normalizeKey($0.key), $0.value) })
    }

    public func verify(_ request: QClaimVerificationRequest) async throws -> QBackendVerdict {
        try Task.checkCancellation()
        return rules[request.claim.proposition.subjectKey]?(request.claim.proposition.value) ?? .cannotDetermine
    }
}

/// The judgment an independent local model gives about a claim. ADVISORY ONLY (see
/// `QVerificationBasis.independentModel`).
public protocol QIndependentModelJudge: Sendable {
    var judgeId: String { get }
    func judge(_ request: QClaimVerificationRequest) async throws -> QBackendVerdict
}

/// Adapts an independent local model judge to the backend contract. Its verdicts are recorded as
/// advisory `unresolved` results — see `QEvidencePool.applyVerification(_:)`.
public struct QIndependentModelVerificationBackend: QClaimVerificationBackend {
    public let identity: QVerifierIdentity
    private let judge: any QIndependentModelJudge

    public init(judge: any QIndependentModelJudge) {
        self.identity = QVerifierIdentity(basis: .independentModel, id: judge.judgeId)
        self.judge = judge
    }

    public func verify(_ request: QClaimVerificationRequest) async throws -> QBackendVerdict {
        try await judge.judge(request)
    }
}

// MARK: - Service

public struct QVerificationRunResult: Sendable, Equatable {
    public let records: [QVerificationRecord]
    public let wasCancelled: Bool
    public let callsMade: Int
    public let budgetExhausted: Bool
}

public struct QIndependentVerificationService: Sendable {
    public let backends: [any QClaimVerificationBackend]
    public let perCallTimeout: TimeInterval

    public init(backends: [any QClaimVerificationBackend], perCallTimeout: TimeInterval = 5) {
        self.backends = Array(backends.prefix(QEvidenceLimits.maxVerificationBackendsPerClaim))
        self.perCallTimeout = perCallTimeout
    }

    /// Verifies every claim that requires verification or is in a conflict. Pure with respect to
    /// the pool: returns records; the caller applies them via `QEvidencePool.applyVerification`.
    public func verify(pool: QEvidencePool) async -> QVerificationRunResult {
        let targets = pool.claims
            .filter { $0.verificationRequired || $0.contradiction == .conflicting }
            .sorted { $0.claimId < $1.claimId }

        var records: [QVerificationRecord] = []
        var calls = 0
        var budgetExhausted = false

        for claim in targets {
            if Task.isCancelled { return QVerificationRunResult(records: records, wasCancelled: true, callsMade: calls, budgetExhausted: budgetExhausted) }

            guard !backends.isEmpty else {
                records.append(QVerificationRecord(claimId: claim.claimId, result: .unavailable, basis: nil, verifierId: nil, reason: .noVerifierConfigured))
                continue
            }
            if calls + backends.count > QEvidenceLimits.maxVerificationCalls {
                budgetExhausted = true
                records.append(QVerificationRecord(claimId: claim.claimId, result: .unavailable, basis: nil, verifierId: nil, reason: .verificationBudgetExhausted))
                continue
            }

            let request = QClaimVerificationRequest(
                claim: claim,
                evidence: claim.sourceEvidenceIds.compactMap { pool.item($0) },
                peerClaims: pool.claims.filter { $0.claimId != claim.claimId && $0.proposition.subjectKey == claim.proposition.subjectKey }
            )

            var supporters: [QVerifierIdentity] = []
            var refuters: [QVerifierIdentity] = []
            var undetermined = 0
            var failures = 0
            var timeouts = 0
            var selfRefusals = 0

            for backend in backends {
                if Task.isCancelled { return QVerificationRunResult(records: records, wasCancelled: true, callsMade: calls, budgetExhausted: budgetExhausted) }
                let identity = backend.identity
                // A model may not verify a claim it produced — not even under a different judge
                // wrapper — so refuse before spending a call.
                if identity.basis == .independentModel, identity.id == claim.producerId {
                    selfRefusals += 1
                    continue
                }
                calls += 1
                let outcome = await QEvidenceAsync.run(timeout: perCallTimeout) { try await backend.verify(request) }
                switch outcome {
                case .value(let verdict):
                    switch verdict {
                    case .supports: supporters.append(identity)
                    case .refutes: refuters.append(identity)
                    case .cannotDetermine: undetermined += 1
                    }
                case .timedOut: timeouts += 1
                case .failed: failures += 1
                case .cancelled:
                    return QVerificationRunResult(records: records, wasCancelled: true, callsMade: calls, budgetExhausted: budgetExhausted)
                }
            }

            records.append(Self.combine(
                claimId: claim.claimId,
                supporters: supporters,
                refuters: refuters,
                undetermined: undetermined,
                failures: failures,
                timeouts: timeouts,
                selfRefusals: selfRefusals
            ))
        }

        return QVerificationRunResult(records: records, wasCancelled: false, callsMade: calls, budgetExhausted: budgetExhausted)
    }

    /// Combines backend opinions for one claim. Never picks a winner among disagreeing verifiers.
    static func combine(
        claimId: QClaimID,
        supporters: [QVerifierIdentity],
        refuters: [QVerifierIdentity],
        undetermined: Int,
        failures: Int,
        timeouts: Int,
        selfRefusals: Int
    ) -> QVerificationRecord {
        let strongSupport = supporters.first { $0.basis == .executionEvidence } ?? supporters.first { $0.basis == .deterministicCheck }
        let strongRefute = refuters.first { $0.basis == .executionEvidence } ?? refuters.first { $0.basis == .deterministicCheck }

        if let support = strongSupport, strongRefute != nil {
            return QVerificationRecord(claimId: claimId, result: .unresolved, basis: support.basis, verifierId: support.id, reason: .conflictingVerifiers)
        }
        if let refute = strongRefute {
            return QVerificationRecord(claimId: claimId, result: .contradicted, basis: refute.basis, verifierId: refute.id, reason: .contradictedByIndependentEvidence)
        }
        if let support = strongSupport {
            return QVerificationRecord(claimId: claimId, result: .verified, basis: support.basis, verifierId: support.id, reason: .agreedWithIndependentEvidence)
        }
        if let advisory = supporters.first ?? refuters.first {
            return QVerificationRecord(claimId: claimId, result: .unresolved, basis: advisory.basis, verifierId: advisory.id, reason: .independentModelAdvisoryOnly)
        }
        if failures + timeouts > 0, undetermined == 0 {
            return QVerificationRecord(claimId: claimId, result: .unavailable, basis: nil, verifierId: nil, reason: timeouts > 0 && failures == 0 ? .backendTimedOut : .backendFailed)
        }
        if selfRefusals > 0, undetermined == 0 {
            return QVerificationRecord(claimId: claimId, result: .unresolved, basis: nil, verifierId: nil, reason: .selfVerificationRefused)
        }
        return QVerificationRecord(claimId: claimId, result: .unresolved, basis: nil, verifierId: nil, reason: .noIndependentEvidence)
    }
}
