//
//  QVerifiedResponseContracts.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 3 (Verified Response Path), first slice: the verified-response
//  contract. DATA ONLY — no assembly logic (see `QVerifiedResponseAssembler.swift`), no persistence,
//  no model call, no network.
//
//  A `QVerifiedResponse` is derived from Phase 2C evidence records, never from model prose:
//   - it holds ORDERED STATEMENT REFERENCES (a claim ID plus the evidence IDs behind it), each with
//     the pool's own trust / verification / contradiction standing — it is a projection of the
//     existing `QEvidencePool` state, not a second trust system (`QSynthesisPolicy` remains the one
//     derivation, and the assembler recomputes from the pool rather than trusting any caller);
//   - it carries NO statement text. Text exists only in the pool (transient, in memory) and is
//     joined back in at render time (`QVerifiedResponseRenderer`), so this Codable, Equatable,
//     persistable structure contains only enums, counts, deterministic IDs, and a timestamp. It
//     cannot hold a prompt, model response, OCR/screen text, document body, credential, or URL;
//   - it carries no authority: no permission, egress, resource, approval, or execution field exists.
//     "Verified" here means "the evidence pool established this", never "authorized".
//

import Foundation

// MARK: - Configuration (default: nothing enabled)

/// Opt-in configuration for the Phase 3 response path. `QCoreRuntime` takes it as an OPTIONAL
/// parameter that defaults to `nil` (nothing assembled, nothing written — behaviour identical to
/// Phase 2E). Memory write-back inside it defaults to disabled.
public struct QVerifiedResponseConfiguration: Sendable, Equatable {
    public let writeBack: QVerifiedMemoryWriteBackConfiguration
    /// Second slice: whether to ask the model for a claims-only answer (default OFF; see
    /// `QStructuredAnswer.swift`). Source-compatible: existing initializer calls are unchanged.
    public let structuredAnswer: QStructuredAnswerConfiguration

    public init(
        writeBack: QVerifiedMemoryWriteBackConfiguration = .disabled,
        structuredAnswer: QStructuredAnswerConfiguration = .disabled
    ) {
        self.writeBack = writeBack
        self.structuredAnswer = structuredAnswer
    }
}

// MARK: - Projected vocabulary (1:1 with the pool's own; Codable copies, not new policy)

/// The standing of one statement. Mirrors `QStatementDisposition` (which `QSynthesisPolicy` derives
/// from the pool) as a Codable enum.
public enum QResponseStanding: String, Codable, Sendable, Equatable, CaseIterable {
    case verified
    case corroborated
    case observed
    case unverified
    case unresolved
    case contradicted

    init(_ disposition: QStatementDisposition) {
        switch disposition {
        case .verified: self = .verified
        case .corroborated: self = .corroborated
        case .observed: self = .observed
        case .unverified: self = .unverified
        case .unresolved: self = .unresolved
        case .contradicted: self = .contradicted
        }
    }
}

public enum QResponseTrust: String, Codable, Sendable, Equatable, CaseIterable {
    case untrusted
    case observed
    case corroborated
    case independentlyVerified

    init(_ trust: QEvidenceTrust) {
        switch trust {
        case .untrusted: self = .untrusted
        case .observed: self = .observed
        case .corroborated: self = .corroborated
        case .independentlyVerified: self = .independentlyVerified
        }
    }
}

public enum QResponseVerification: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case verified
    case contradicted
    case unresolved
    case unavailable
    case notRequired

    init(_ state: QEvidenceVerificationState) {
        switch state {
        case .pending: self = .pending
        case .verified: self = .verified
        case .contradicted: self = .contradicted
        case .unresolved: self = .unresolved
        case .unavailable: self = .unavailable
        case .notRequired: self = .notRequired
        }
    }
}

public enum QResponseContradictionState: String, Codable, Sendable, Equatable, CaseIterable {
    case consistent
    case conflicting
    case unresolved

    init(_ state: QContradictionState) {
        switch state {
        case .consistent: self = .consistent
        case .conflicting: self = .conflicting
        case .unresolved: self = .unresolved
        }
    }
}

public enum QVerifiedResponseStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case sufficient
    case partial
    case contradictory
    case insufficient

    init(_ status: QSynthesisStatus) {
        switch status {
        case .sufficient: self = .sufficient
        case .partial: self = .partial
        case .contradictory: self = .contradictory
        case .insufficient, .unavailable: self = .insufficient
        }
    }
}

// MARK: - Response

/// One statement REFERENCE: which claim, which evidence, and the pool's standing for it. No text.
public struct QVerifiedResponseStatement: Codable, Sendable, Equatable {
    public let claimId: String
    /// Always non-empty and every ID resolved in the pool at assembly time (else the statement is
    /// dropped and counted — see `QVerifiedResponse.Provenance.rejectedStatementCount`).
    public let evidenceIds: [String]
    public let standing: QResponseStanding
    public let trust: QResponseTrust
    public let verification: QResponseVerification
    public let contradiction: QResponseContradictionState
    public let contradictionId: String?
    /// Raw value of `QEvidenceSourceKind` — the trust-boundary category the claim came from.
    public let sourceKind: String
    /// True only when the pool independently verified the claim AND its content passed the URL /
    /// credential / instruction screen. The writer re-derives this and never trusts the flag.
    public let memoryWriteBackEligible: Bool
}

public struct QVerifiedResponseContradiction: Codable, Sendable, Equatable {
    public let contradictionId: String
    public let claimIds: [String]
    /// True only when the existing verification system actually settled it (see `QEvidencePool`).
    public let isResolved: Bool
}

public struct QVerifiedResponseProvenance: Codable, Sendable, Equatable {
    public let taskId: String
    public let assembledAt: Date
    /// Sorted, unique raw values of `QEvidenceSourceKind` among the statements.
    public let sourceKinds: [String]
    public let isTainted: Bool
    /// Statements dropped because their claim/evidence references were empty or did not resolve.
    public let rejectedStatementCount: Int
}

public struct QVerifiedResponse: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Bumped whenever `QVerifiedResponseRenderer`'s deterministic output format changes.
    public let renderingVersion: Int
    public let status: QVerifiedResponseStatus
    public let statements: [QVerifiedResponseStatement]
    public let contradictions: [QVerifiedResponseContradiction]
    /// Fixed vocabulary only: `QSynthesisCaveat` raw values plus `invalidEvidenceReferencesDropped`.
    public let caveats: [String]
    public let completeness: QEvidenceCompleteness
    public let uncertainty: QDecisionUncertainty
    /// The pool's verification requirement (fixed at pool construction; for critical/high-risk work
    /// it is `independentVerification`). Recorded, never overridable here.
    public let requirement: QVerificationRequirement
    public let provenance: QVerifiedResponseProvenance

    public var memoryWriteBackEligibleCount: Int {
        statements.filter { $0.memoryWriteBackEligible }.count
    }

    public var verifiedStatementCount: Int { statements.filter { $0.standing == .verified }.count }
    public var unresolvedStatementCount: Int { statements.filter { $0.standing == .unresolved || $0.standing == .unverified }.count }
    public var contradictedStatementCount: Int { statements.filter { $0.standing == .contradicted }.count }

    /// The one extra caveat this layer adds to `QSynthesisCaveat`'s vocabulary.
    public static let invalidReferencesCaveat = "invalidEvidenceReferencesDropped"

    /// Counts and enum raw values only — safe for a lifecycle event payload.
    public var auditPayload: [String: String] {
        [
            "status": status.rawValue,
            "uncertainty": uncertainty.rawValue,
            "completeness": completeness.rawValue,
            "requirement": requirement.rawValue,
            "statementCount": "\(statements.count)",
            "verifiedCount": "\(verifiedStatementCount)",
            "unresolvedCount": "\(unresolvedStatementCount)",
            "contradictedCount": "\(contradictedStatementCount)",
            "contradictionCount": "\(contradictions.count)",
            "rejectedStatementCount": "\(provenance.rejectedStatementCount)",
            "writeBackEligibleCount": "\(memoryWriteBackEligibleCount)",
            "tainted": "\(provenance.isTainted)"
        ]
    }
}

/// A response joined with its transient rendered lines. NOT Codable on purpose: the lines contain
/// claim text, which must never be persisted by this feature.
public struct QRenderedResponse: Sendable, Equatable {
    public let response: QVerifiedResponse
    public let lines: [String]
    public var text: String { lines.joined(separator: "\n") }
}
