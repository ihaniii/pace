//
//  QEvidenceContracts.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2C Evidence Contracts.
//  Typed vocabulary for the Evidence Pool → Claim → Verification → Critic → Synthesis pipeline.
//  DATA ONLY — no pipeline logic, no execution, no network. See `QEvidencePool.swift` for the pool
//  that enforces these contracts and `QEvidencePipeline.swift` for the bounded orchestration.
//
//  These contracts describe EVIDENTIAL STATE, never authority:
//   - nothing here references `QCapability`, `QPermissionGate`, `QResourceGuard`, `QEgressBroker`
//     or `QActionVerifier`; there is no field on any type in the Phase 2C files that could carry a
//     permission, egress, resource, approval, risk, or execution grant — by construction, not by
//     convention;
//   - trust is a four-step ladder (`QEvidenceTrust`) that can only be climbed by concrete, typed
//     events (a non-model source asserting the same proposition, or an independent execution/
//     deterministic verification) — never because a model said so, several models repeated it, a
//     source "looks authoritative", or text contains citations;
//   - the pool NEVER stores raw content: an evidence item carries a SHA-256 content hash, a length,
//     and bounded metadata. A claim carries one bounded, credential-screened proposition. No type
//     here is `Codable` except two ID wrappers and the audit-safe `QEvidenceOutcomeMetadata` (with
//     its completeness enum), so raw evidence cannot accidentally be serialised to disk by these
//     types — a test pins that exact set.
//

import Foundation
import CryptoKit

// MARK: - Explicit Bounds

/// Every Phase 2C loop, collection, and retry is bounded by one of these constants. There is no
/// unbounded evidence, claim, critic-pass, verification-loop, or synthesis-retry path.
public enum QEvidenceLimits {
    public static let maxEvidenceItems = 64
    public static let maxClaims = 64
    public static let maxClaimsPerEvidenceItem = 8
    public static let maxCitedEvidencePerClaim = 8
    public static let maxSubjectKeyCharacters = 80
    public static let maxClaimValueCharacters = 200
    public static let maxSourceIdCharacters = 128
    /// Content beyond this many characters is neither hashed-in-full-scanned for claims nor
    /// stored; the item is flagged `.truncated`.
    public static let maxContentCharactersScanned = 20_000
    public static let maxMetadataEntries = 8
    public static let maxMetadataKeyCharacters = 32
    public static let maxMetadataValueCharacters = 64
    public static let maxVerificationBackendsPerClaim = 3
    public static let maxVerificationCalls = 64
    public static let maxCriticPasses = 1
    public static let maxCriticFindings = 32
    public static let maxCriticDetailCharacters = 160
    public static let maxSynthesisAttempts = 1
    public static let maxStatements = 64
}

// MARK: - Identity

/// Deterministic evidence identifier — derived from task/source/content, never a random `UUID()`.
public struct QEvidenceID: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Deterministic claim identifier — derived from task/origin/proposition, never a random `UUID()`.
public struct QClaimID: Codable, Sendable, Equatable, Hashable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: QClaimID, rhs: QClaimID) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Source Kind (the trust-boundary categories)

/// Where a piece of evidence came from. These categories are deliberately NOT collapsed into one
/// generic "trusted" state: a user statement, a model claim, a retrieved document and an execution
/// observation are different kinds of thing and each keeps its own identity through the pipeline.
public enum QEvidenceSourceKind: String, Sendable, Equatable, CaseIterable {
    /// Information the user themself provided (trusted provenance; still not "verified").
    case userProvided
    /// Output produced by a model. Always untrusted; never evidence of its own truth.
    case modelGenerated
    /// Content retrieved from a document, page, file, screen, OCR, tool, or any external source.
    /// Always untrusted DATA — never instructions.
    case retrievedExternal
    /// A fact observed by Q's own execution/verification machinery (`QActionVerifier`, the goal
    /// evaluator). Trusted-system provenance.
    case executionObserved
    /// The output of a deterministic local check (e.g. arithmetic). Trusted-local provenance.
    case deterministicCheck

    /// Kinds that Q itself produced deterministically — the only kinds able to independently
    /// verify a model or retrieved claim.
    public var isIndependentOfModels: Bool {
        self == .executionObserved || self == .deterministicCheck
    }

    /// Kinds whose claims never need verification just to be reported (they ARE the observation).
    public var isSelfEvidencing: Bool {
        self == .userProvided || self == .executionObserved || self == .deterministicCheck
    }
}

// MARK: - Trust Ladder

/// The trust progression for evidence and claims. Each step can only be reached by a concrete,
/// typed event — see `QEvidencePool.recompute()` and `QEvidencePool.applyVerification(_:)`.
public enum QEvidenceTrust: Int, Sendable, Equatable, Comparable, CaseIterable {
    /// Only a model (or nothing non-model) asserts this. Repeating it does not change that.
    case untrusted = 0
    /// One non-model source asserts it. Says "we saw it stated", never "it is true".
    case observed = 1
    /// Two or more DISTINCT non-model sources assert the same proposition and none conflict.
    case corroborated = 2
    /// An independent execution-evidence or deterministic-check verifier confirmed it.
    case independentlyVerified = 3

    public static func < (lhs: QEvidenceTrust, rhs: QEvidenceTrust) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Verification

/// Per-item / per-claim verification state. `pending` = not yet attempted; the other five are the
/// spec's verification result types.
public enum QEvidenceVerificationState: String, Sendable, Equatable, CaseIterable {
    case pending
    case verified
    case contradicted
    case unresolved
    case unavailable
    case notRequired
}

/// What kind of verifier produced a verdict.
public enum QVerificationBasis: String, Sendable, Equatable, CaseIterable {
    case executionEvidence
    case deterministicCheck
    /// An independent local model. ADVISORY ONLY: a model verdict is recorded but can never raise
    /// trust or produce `verified`/`contradicted` (models are untrusted — even a second one).
    case independentModel

    public var canEstablishTruth: Bool {
        self != .independentModel
    }
}

/// Why a verification result came out the way it did — an objective enum, never free text.
public enum QVerificationReason: String, Sendable, Equatable, CaseIterable {
    case agreedWithIndependentEvidence
    case contradictedByIndependentEvidence
    case noIndependentEvidence
    case conflictingVerifiers
    case independentModelAdvisoryOnly
    case selfVerificationRefused
    case noVerifierConfigured
    case backendFailed
    case backendTimedOut
    case verificationBudgetExhausted
    case notRequired
    case cancelled
}

/// One verification outcome for one claim. Carries only bounded identity/enum metadata.
public struct QVerificationRecord: Sendable, Equatable {
    public let claimId: QClaimID
    public let result: QEvidenceVerificationState
    public let basis: QVerificationBasis?
    public let verifierId: String?
    public let reason: QVerificationReason

    public init(
        claimId: QClaimID,
        result: QEvidenceVerificationState,
        basis: QVerificationBasis?,
        verifierId: String?,
        reason: QVerificationReason
    ) {
        self.claimId = claimId
        self.result = result
        self.basis = basis
        self.verifierId = verifierId
        self.reason = reason
    }
}

// MARK: - Contradiction

public enum QContradictionState: String, Sendable, Equatable, CaseIterable {
    /// No conflicting claim exists AND the claim is corroborated or independently verified.
    case consistent
    /// Another claim about the same subject asserts a different value. Both are preserved.
    case conflicting
    /// Nothing conflicts, but nothing corroborates either — not enough to call it consistent.
    case unresolved
}

/// How a conflict was (or was not) settled. A winner may only be named on the strength of
/// independent evidence — never a model's self-confidence, recency, or repetition.
public enum QContradictionResolution: Sendable, Equatable {
    case unresolved
    case resolvedByVerification(winningClaimIds: [QClaimID], basis: QVerificationBasis)
}

/// A recorded conflict: every claim involved is preserved; nothing is silently dropped.
public struct QContradictionRecord: Sendable, Equatable {
    public let contradictionId: String
    public let subjectKey: String
    public let claimIds: [QClaimID]
    public let distinctValueCount: Int
    public let resolution: QContradictionResolution

    public var isResolved: Bool {
        if case .resolvedByVerification = resolution { return true }
        return false
    }
}

// MARK: - Provenance (locator-stripped)

extension QProvenanceKind {
    /// The same provenance category with any URL/path locator removed. Evidence keeps WHERE-KIND
    /// (web/file/screen/...) but never the raw locator — a locator can itself be sensitive, and
    /// `sourceId` (an opaque, caller-chosen identifier) is the stable handle instead.
    public var strippedOfLocators: QProvenanceKind {
        switch self {
        case .untrustedWeb: return .untrustedWeb(url: nil)
        case .untrustedFile: return .untrustedFile(path: nil)
        default: return self
        }
    }
}

// MARK: - Origin (Phase 2B bridge)

/// Which Phase 2B model candidate/attempt produced a model-generated item. Kept SEPARATE from the
/// evidence → claim → verification chain (candidate → attempt → result is one lineage; evidence
/// is another) — this struct is the only bridge, and it carries identity only.
public struct QEvidenceOrigin: Sendable, Equatable {
    public let attemptId: QModelAttemptID?
    public let candidateId: QModelCandidateID?
    public let backend: QModelBackendType?

    public init(attemptId: QModelAttemptID? = nil, candidateId: QModelCandidateID? = nil, backend: QModelBackendType? = nil) {
        self.attemptId = attemptId
        self.candidateId = candidateId
        self.backend = backend
    }

    /// The identity a verifier must differ from to count as independent of this producer.
    public var producerId: String {
        backend?.rawValue ?? candidateId?.rawValue ?? "model-unknown"
    }
}

// MARK: - Flags

public enum QEvidenceFlag: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Content contained text shaped like an instruction to an AI/agent. Flagged and skipped;
    /// the text never reaches any authority, strategy, or claim.
    case instructionLikeContent
    /// A credential-shaped string was detected; the claim(s) carrying it were dropped.
    case credentialShapedContent
    case truncated
}

// MARK: - Source

public struct QEvidenceSource: Sendable, Equatable {
    public let sourceId: String
    public let kind: QEvidenceSourceKind
    public let provenance: QProvenanceKind
    public let origin: QEvidenceOrigin?
}

// MARK: - Evidence Item

/// One piece of evidence. NO raw content: only a hash, a length, flags, and bounded metadata.
public struct QEvidenceItem: Sendable, Equatable {
    public let evidenceId: QEvidenceID
    public let taskId: String
    public let source: QEvidenceSource
    public let contentHash: String
    public let contentLength: Int
    public internal(set) var trust: QEvidenceTrust
    public internal(set) var verification: QEvidenceVerificationState
    public let flags: Set<QEvidenceFlag>
    public let metadata: [String: String]
    public let createdAt: Date
}

// MARK: - Claim Status

/// A single derived summary of a claim's standing. Never stored independently of trust /
/// verification / contradiction, so it cannot drift from them.
public enum QClaimStatus: String, Sendable, Equatable, CaseIterable {
    case unverified
    case supported
    case verified
    case contradicted
    case unresolved
}

// MARK: - Proposition

/// A concise factual proposition: `subject` → `value`. Structured (not free prose) so conflicts
/// can be detected deterministically without any model and without inventing a similarity score.
public struct QClaimProposition: Sendable, Equatable {
    public let subjectKey: String
    public let value: String
    public let normalizedValueHash: String
    /// Whether the original text used certainty language ("definitely", "guaranteed", …). Only a
    /// critic input — never evidence.
    public let assertsCertainty: Bool

    public init?(subject: String, value: String) {
        let key = QEvidenceText.normalizeKey(subject)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= QEvidenceLimits.maxSubjectKeyCharacters,
              !trimmedValue.isEmpty, trimmedValue.count <= QEvidenceLimits.maxClaimValueCharacters else {
            return nil
        }
        self.subjectKey = key
        self.value = trimmedValue
        self.normalizedValueHash = QEvidenceText.sha256Hex(QEvidenceText.normalizeValue(trimmedValue))
        self.assertsCertainty = QEvidenceInstructionScanner.assertsCertainty(subject + " " + value)
    }

    public var renderedText: String { "\(subjectKey): \(value)" }
}

// MARK: - Claim

public struct QEvidenceClaim: Sendable, Equatable {
    public let claimId: QClaimID
    public let taskId: String
    public let proposition: QClaimProposition
    /// The extracting item first, then any cited items that genuinely exist in the pool. Citation
    /// gives TRACEABILITY only — a cited item lends the claim no trust unless a claim extracted
    /// from that item asserts the same proposition.
    public let sourceEvidenceIds: [QEvidenceID]
    public let originKind: QEvidenceSourceKind
    /// Identity of whoever produced the claim (model backend id, or the source id otherwise).
    public let producerId: String
    /// `sourceKind:sourceId` of the extracting item — the unit of corroboration independence.
    public let supportKey: String
    public internal(set) var trust: QEvidenceTrust
    public internal(set) var verification: QEvidenceVerificationState
    public internal(set) var verifiedBasis: QVerificationBasis?
    public internal(set) var verificationRequired: Bool
    public internal(set) var contradiction: QContradictionState

    public var status: QClaimStatus {
        if verification == .contradicted { return .contradicted }
        if trust == .independentlyVerified { return .verified }
        if contradiction == .conflicting { return .unresolved }
        if trust >= .observed { return .supported }
        if verification == .unresolved || verification == .unavailable { return .unresolved }
        return .unverified
    }
}

// MARK: - Rejections

/// Why an input was refused entry to the pool. Counted, never stored with content.
public enum QEvidenceRejectionReason: String, Sendable, Equatable, CaseIterable {
    case poolFull
    case claimLimitReached
    case malformedSource
    case taskMismatch
    case provenanceKindMismatch
    case credentialShapedContent
    case malformedClaim
    case unknownEvidenceReference
}

// MARK: - Text Helpers

enum QEvidenceText {
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func shortHash(_ parts: [String]) -> String {
        String(sha256Hex(parts.joined(separator: "\u{1F}")).prefix(16))
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func normalizeKey(_ text: String) -> String {
        collapseWhitespace(text).lowercased()
    }

    static func normalizeValue(_ text: String) -> String {
        var normalized = collapseWhitespace(text).lowercased()
        while let last = normalized.last, last == "." || last == ";" { normalized.removeLast() }
        return normalized
    }

    /// Bounds and credential-redacts a short free-text field (critic detail, metadata values).
    static func boundedSafe(_ text: String, maxCharacters: Int) -> String {
        let redacted = QSecretRedactor.redact(text)
        let flattened = redacted.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(flattened.prefix(maxCharacters))
    }
}
