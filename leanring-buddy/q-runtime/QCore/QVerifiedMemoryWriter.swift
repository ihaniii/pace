//
//  QVerifiedMemoryWriter.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 3 (Verified Response Path), first slice: OPT-IN verified-memory
//  write-back.
//
//      QVerifiedResponse (+ the evidence pool it was assembled from)
//        → eligible propositions → QVerifiedPropositionStoring (the existing QSQLiteMemoryStore)
//
//  DEFAULT OFF: unless `QVerifiedMemoryWriteBackConfiguration(isEnabled: true)` is passed explicitly
//  the writer touches nothing (it does not even call the store). Enabling it is persistence only —
//  it can never execute, approve, authorize, or widen anything; "verified" ≠ "authorized".
//
//  The writer does NOT trust the response it is handed. `QVerifiedResponse` is Codable, so it could
//  be forged or edited; the writer therefore re-derives eligibility for every statement from the
//  evidence pool with the same predicate the assembler uses, requires the response and pool to
//  describe the same task, and lets the store's validator refuse anything that is not an
//  independently verified, evidence-backed, URL/credential/instruction-free proposition with
//  complete provenance. Observed, corroborated, unverified, unresolved, and contradicted claims can
//  never be written.
//

import Foundation

public struct QVerifiedWriteBackReport: Sendable, Equatable {
    public let isEnabled: Bool
    public var statementsConsidered = 0
    public var eligible = 0
    public var written = 0
    public var duplicates = 0
    public var storeUnavailable = 0
    public var rejections: [QVerifiedWriteRejection: Int] = [:]

    public var rejectedCount: Int { rejections.values.reduce(0, +) }

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Counts and booleans only — safe for a lifecycle event payload.
    public var auditPayload: [String: String] {
        [
            "writeBackEnabled": "\(isEnabled)",
            "writeBackConsidered": "\(statementsConsidered)",
            "writeBackEligible": "\(eligible)",
            "writeBackWritten": "\(written)",
            "writeBackDuplicates": "\(duplicates)",
            "writeBackRejected": "\(rejectedCount)",
            "writeBackStoreUnavailable": "\(storeUnavailable)"
        ]
    }
}

public struct QVerifiedMemoryWriter: Sendable {
    public let configuration: QVerifiedMemoryWriteBackConfiguration
    private let store: any QVerifiedPropositionStoring

    public init(store: any QVerifiedPropositionStoring, configuration: QVerifiedMemoryWriteBackConfiguration = .disabled) {
        self.store = store
        self.configuration = configuration
    }

    /// Idempotent: re-evaluating the same verified proposition reports `.duplicate` and changes nothing.
    @discardableResult
    public func write(response: QVerifiedResponse, pool: QEvidencePool, now: Date) -> QVerifiedWriteBackReport {
        var report = QVerifiedWriteBackReport(isEnabled: configuration.isEnabled)
        guard configuration.isEnabled else { return report }   // default path: nothing is touched

        guard response.provenance.taskId == pool.taskId else {
            // A response for a different task than the pool is not a basis for any write.
            report.statementsConsidered = response.statements.count
            report.rejections[.notEligible, default: 0] += response.statements.count
            return report
        }

        for statement in response.statements.prefix(QEvidenceLimits.maxStatements) {
            report.statementsConsidered += 1
            guard statement.memoryWriteBackEligible else { continue }
            report.eligible += 1

            // Re-derive from the pool; the Codable flag on the response is never trusted.
            guard let claim = pool.claim(QClaimID(rawValue: statement.claimId)) else {
                report.rejections[.invalidEvidenceReference, default: 0] += 1
                continue
            }
            guard QVerifiedResponseAssembler.isWriteBackEligible(claim, in: pool), let basis = claim.verifiedBasis else {
                report.rejections[.notIndependentlyVerified, default: 0] += 1
                continue
            }

            let proposition = QVerifiedProposition(
                provenance: QVerifiedPropositionProvenance(
                    propositionId: QVerifiedPropositionValidator.deterministicId(subjectKey: claim.proposition.subjectKey, value: claim.proposition.value),
                    originTaskId: pool.taskId,
                    claimId: claim.claimId.rawValue,
                    evidenceIds: QVerifiedResponseAssembler.supportingEvidenceIds(for: claim, in: pool).map { $0.rawValue },
                    verification: QEvidenceVerificationState.verified.rawValue,
                    trust: claim.trust.trustLabel,
                    verifiedBasis: basis.rawValue,
                    sourceKind: claim.originKind.rawValue,
                    requirement: pool.requirement.rawValue,
                    writeBackEligible: true,
                    writtenAt: now
                ),
                subjectKey: claim.proposition.subjectKey,
                value: claim.proposition.value
            )

            switch store.writeVerifiedProposition(proposition, now: now) {
            case .written: report.written += 1
            case .duplicate: report.duplicates += 1
            case .rejected(let reason): report.rejections[reason, default: 0] += 1
            case .disabled: break
            case .storeUnavailable: report.storeUnavailable += 1
            }
        }
        return report
    }
}
