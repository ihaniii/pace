//
//  QVerifiedMemoryContracts.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 3 (Verified Response Path), first slice: memory provenance
//  and opt-in verified-memory write-back CONTRACTS. Data + pure validation only.
//
//  The problem this fixes ("memory laundering"): before this slice, `recordTaskCompletion` stored
//  model-generated summary text under the label `trusted:system`, and `queryContext` returned bare
//  strings with provenance dropped — so a proposition that entered memory with no verification at
//  all could come back later looking trusted. The rules below make that unrepresentable:
//   - a stored proposition carries STRUCTURED provenance (originating task, evidence IDs,
//     verification state, trust state, source kind, timestamp, eligibility, deterministic identity);
//   - only a proposition that Phase 2C's evidence pool independently verified (execution-evidence or
//     deterministic-check basis) can be written, and only when the caller explicitly opted in
//     (default OFF);
//   - a self-declared label (`trusted:system`, `trusted:local`, …) on an unstructured record is NOT
//     evidence: legacy records without structured provenance are conservatively UNVERIFIED;
//   - retrieval reports what a record IS; it never upgrades it. When retrieved memory is turned
//     into evidence (`QMemoryContextItem.asEvidenceDraft`) it enters the pool as untrusted
//     retrieved data, so it must be verified again — "it was in memory" is never verification.
//
//  Nothing here grants a permission, egress, resource, approval, or execution authority. "Verified"
//  means "the evidence pool established this proposition", never "authorized".
//
//  Persisted content is limited to the bounded proposition itself (`subject: value`, at most 200
//  characters, credential-, URL-, and instruction-screened) plus the provenance metadata above. No
//  prompt, model response, screen/OCR text, document body, credential, or URL is ever stored.
//

import Foundation
import CryptoKit

// MARK: - Configuration (default OFF)

/// The opt-in for verified-memory write-back. There is no existing user-facing configuration surface
/// for Q runtime features (they are constructor parameters), so this is the minimal internal
/// contract: it defaults to disabled and nothing enables it implicitly.
public struct QVerifiedMemoryWriteBackConfiguration: Sendable, Equatable {
    public let isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public static let disabled = QVerifiedMemoryWriteBackConfiguration(isEnabled: false)
}

// MARK: - Bounds

public enum QVerifiedMemoryLimits {
    public static let schemaVersion = 1
    /// Global cap on stored verified propositions; the oldest are pruned when exceeded.
    public static let maxPropositions = 2_000
    /// Per-subject cap (the newest are kept): a fact that changes over time cannot accumulate.
    public static let maxPerSubject = 5
    public static let maxEvidenceIdsPerProposition = 8
    public static let maxRetrievalLimit = 50
    public static let maxFutureSkewSeconds: TimeInterval = 300
}

// MARK: - Provenance

/// Structured, content-free provenance for one verified proposition.
public struct QVerifiedPropositionProvenance: Codable, Sendable, Equatable {
    public let propositionId: String
    public let originTaskId: String
    public let claimId: String
    public let evidenceIds: [String]
    /// Raw values of `QEvidenceVerificationState` / `QEvidenceTrust` / `QVerificationBasis` /
    /// `QEvidenceSourceKind` / `QVerificationRequirement` — the pool's own vocabulary, not a new one.
    public let verification: String
    public let trust: String
    public let verifiedBasis: String
    public let sourceKind: String
    public let requirement: String
    public let writeBackEligible: Bool
    public let writtenAt: Date
    public let schemaVersion: Int

    public init(
        propositionId: String, originTaskId: String, claimId: String, evidenceIds: [String],
        verification: String, trust: String, verifiedBasis: String, sourceKind: String, requirement: String,
        writeBackEligible: Bool, writtenAt: Date, schemaVersion: Int = QVerifiedMemoryLimits.schemaVersion
    ) {
        self.propositionId = propositionId
        self.originTaskId = originTaskId
        self.claimId = claimId
        self.evidenceIds = evidenceIds
        self.verification = verification
        self.trust = trust
        self.verifiedBasis = verifiedBasis
        self.sourceKind = sourceKind
        self.requirement = requirement
        self.writeBackEligible = writeBackEligible
        self.writtenAt = writtenAt
        self.schemaVersion = schemaVersion
    }
}

/// One verified fact plus its provenance. `subjectKey`/`value` ARE the bounded proposition — the
/// only free text this feature persists.
public struct QVerifiedProposition: Codable, Sendable, Equatable {
    public let provenance: QVerifiedPropositionProvenance
    public let subjectKey: String
    public let value: String

    public init(provenance: QVerifiedPropositionProvenance, subjectKey: String, value: String) {
        self.provenance = provenance
        self.subjectKey = subjectKey
        self.value = value
    }

    public var renderedText: String { "\(subjectKey): \(value)" }
}

// MARK: - Rejections & results

public enum QVerifiedWriteRejection: String, Sendable, Equatable, CaseIterable {
    case notEligible
    case notIndependentlyVerified
    case missingEvidence
    case invalidEvidenceReference
    case malformedProposition
    case malformedIdentity
    case credentialShapedContent
    case urlShapedContent
    case instructionShapedContent
    case futureTimestamp
    case schemaVersionUnsupported
}

public enum QVerifiedWriteResult: Sendable, Equatable {
    case written
    /// The same proposition (deterministic identity) is already stored: nothing changed.
    case duplicate
    case rejected(QVerifiedWriteRejection)
    /// Write-back was not opted into. Nothing was written.
    case disabled
    /// The store could not complete the write; nothing was changed.
    case storeUnavailable
}

public struct QVerifiedPropositionReadResult: Sendable, Equatable {
    public let propositions: [QVerifiedProposition]
    /// Rows that were present but failed validation (tampered, malformed, unknown version) — skipped.
    public let skippedRowCount: Int
}

// MARK: - Memory context (provenance-preserving retrieval)

/// What a retrieved memory item actually is. Note the absence of any "currently verified" case:
/// a retrieved item can at best be a PRIOR verified proposition, which must be re-verified before it
/// counts as evidence in a new task.
public enum QMemoryContextTrust: String, Codable, Sendable, Equatable, CaseIterable {
    /// No structured provenance establishes it (this includes every legacy record and any record
    /// that merely carries a `trusted:*` label).
    case unverified
    /// The user's own recorded statement (`trusted:user` on a non-completion record). Still not "verified".
    case userStatement
    /// A proposition an earlier task verified, with structured provenance. Historical, not current.
    case priorVerifiedProposition
}

public struct QMemoryContextItem: Sendable, Equatable {
    /// Transient text for immediate use; never persisted by this feature.
    public let text: String
    public let trust: QMemoryContextTrust
    /// The provenance label the record carried, reported for transparency — never used to grant trust.
    public let recordedProvenanceLabel: String
    public let verifiedProvenance: QVerifiedPropositionProvenance?

    public init(text: String, trust: QMemoryContextTrust, recordedProvenanceLabel: String, verifiedProvenance: QVerifiedPropositionProvenance? = nil) {
        self.text = text
        self.trust = trust
        self.recordedProvenanceLabel = recordedProvenanceLabel
        self.verifiedProvenance = verifiedProvenance
    }

    /// The ONLY way memory content becomes evidence: as untrusted retrieved data. Whatever the item's
    /// stored standing, the pool derives its trust afresh (retrieved ⇒ at most `observed`), so
    /// retrieving a fact from memory can never make it verified in a new task.
    public func asEvidenceDraft(taskId: String) -> QEvidenceDraft {
        QEvidenceDraft(
            taskId: taskId,
            sourceId: "memory-" + QEvidenceText.shortHash([text]),
            kind: .retrievedExternal,
            provenance: .untrustedTool(toolName: "memory"),
            content: text,
            metadata: ["memoryTrust": trust.rawValue]
        )
    }
}

// MARK: - Provider / store protocols (additive)

/// Additive extension of `QMemoryProvider`: existing conformers and callers are untouched.
public protocol QProvenanceAwareMemoryProvider: QMemoryProvider {
    func queryContextItems(for query: String, limit: Int) async throws -> [QMemoryContextItem]
}

public protocol QVerifiedPropositionStoring: Sendable {
    func writeVerifiedProposition(_ proposition: QVerifiedProposition, now: Date) -> QVerifiedWriteResult
    func verifiedPropositions(matching text: String, limit: Int) -> QVerifiedPropositionReadResult
    func verifiedPropositionCount() -> Int
}

// MARK: - Screening & validation (pure)

public enum QVerifiedPropositionScreen {

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?i)(\b[a-z][a-z0-9+.\-]*://|\bwww\.|\bmailto:)"#,
        options: []
    )

    /// Refuses content this feature must never persist: URLs, credential-shaped strings, and
    /// instruction-shaped text (which must never be laundered into durable memory as a "fact").
    public static func rejection(subject: String, value: String) -> QVerifiedWriteRejection? {
        for text in [subject, value] {
            let range = NSRange(location: 0, length: (text as NSString).length)
            if urlPattern.firstMatch(in: text, options: [], range: range) != nil { return .urlShapedContent }
            if QSecretRedactor.redact(text) != text { return .credentialShapedContent }
            if QEvidenceInstructionScanner.looksLikeInstruction(text) { return .instructionShapedContent }
        }
        // The pair rendered as one line must also pass (a secret can straddle the separator).
        let combined = "\(subject): \(value)"
        if QSecretRedactor.redact(combined) != combined { return .credentialShapedContent }
        return nil
    }
}

public enum QVerifiedPropositionValidator {

    private static let evidenceIdPattern = try! NSRegularExpression(pattern: #"^ev-[0-9a-f]{16}$"#)
    private static let claimIdPattern = try! NSRegularExpression(pattern: #"^cl-[0-9a-f]{16}$"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Deterministic identity: the same proposition (subject + normalized value) always has the same
    /// ID, regardless of task or time, so repeated evaluation cannot create duplicates.
    public static func deterministicId(subjectKey: String, value: String) -> String {
        let normalizedValueHash = QEvidenceText.sha256Hex(QEvidenceText.normalizeValue(value))
        return "vp-" + QEvidenceText.shortHash([QEvidenceText.normalizeKey(subjectKey), normalizedValueHash])
    }

    /// The first reason `proposition` must be refused, or `nil`. Applied on WRITE and again on READ,
    /// so a tampered or forged row is never trusted.
    public static func rejection(for proposition: QVerifiedProposition, now: Date) -> QVerifiedWriteRejection? {
        let provenance = proposition.provenance
        guard provenance.schemaVersion == QVerifiedMemoryLimits.schemaVersion else { return .schemaVersionUnsupported }
        guard provenance.writtenAt <= now.addingTimeInterval(QVerifiedMemoryLimits.maxFutureSkewSeconds) else { return .futureTimestamp }

        // Bounds and shape of the proposition itself.
        guard QClaimProposition(subject: proposition.subjectKey, value: proposition.value) != nil else { return .malformedProposition }
        guard proposition.subjectKey == QEvidenceText.normalizeKey(proposition.subjectKey) else { return .malformedProposition }
        if let screened = QVerifiedPropositionScreen.rejection(subject: proposition.subjectKey, value: proposition.value) { return screened }

        // Identity and provenance completeness.
        guard provenance.propositionId == deterministicId(subjectKey: proposition.subjectKey, value: proposition.value) else { return .malformedIdentity }
        guard !provenance.originTaskId.isEmpty, provenance.originTaskId.count <= QEvidenceLimits.maxSourceIdCharacters,
              !provenance.originTaskId.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .malformedIdentity
        }
        guard matches(claimIdPattern, provenance.claimId) else { return .malformedIdentity }
        guard !provenance.evidenceIds.isEmpty else { return .missingEvidence }
        guard provenance.evidenceIds.count <= QVerifiedMemoryLimits.maxEvidenceIdsPerProposition,
              Set(provenance.evidenceIds).count == provenance.evidenceIds.count,
              provenance.evidenceIds.allSatisfy({ matches(evidenceIdPattern, $0) }) else {
            return .invalidEvidenceReference
        }

        // Only an independently verified proposition may be stored as verified memory.
        guard provenance.writeBackEligible,
              provenance.verification == QEvidenceVerificationState.verified.rawValue,
              provenance.trust == QEvidenceTrust.independentlyVerified.trustLabel,
              let basis = QVerificationBasis(rawValue: provenance.verifiedBasis), basis.canEstablishTruth,
              QEvidenceSourceKind(rawValue: provenance.sourceKind) != nil,
              QVerificationRequirement(rawValue: provenance.requirement) != nil else {
            return .notIndependentlyVerified
        }
        return nil
    }
}

extension QEvidenceTrust {
    /// A stable string for persistence (`QEvidenceTrust` itself is an `Int`-backed enum that is
    /// deliberately not `Codable`).
    var trustLabel: String {
        switch self {
        case .untrusted: return "untrusted"
        case .observed: return "observed"
        case .corroborated: return "corroborated"
        case .independentlyVerified: return "independentlyVerified"
        }
    }
}
