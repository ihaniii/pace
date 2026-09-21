//
//  QEvidencePool.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2C Evidence Pool.
//  A bounded, in-memory, per-task pool of evidence items and the claims extracted from them. It is
//  the ONE place trust is computed: every trust/verification/contradiction field on an item or
//  claim is derived here by `recompute()` / `applyVerification(_:)`, and nowhere else can raise it.
//
//  Trust rules (all deterministic, none score-based):
//   - a claim's base trust comes from DISTINCT NON-MODEL sources asserting the same proposition:
//     0 → untrusted, 1 → observed, ≥2 → corroborated. A model repeating a claim (once or ten
//     times, one model or many) contributes nothing;
//   - `independentlyVerified` is reachable only through `applyVerification(_:)` with an
//     execution-evidence or deterministic-check basis. An `independentModel` verdict is advisory
//     and is downgraded to `unresolved` here regardless of what the caller passed;
//   - a verifier whose identity equals the claim's producer is refused (no self-verification);
//   - conflicting claims are BOTH preserved and marked; the pool never picks a winner except via
//     independent verification.
//
//  The pool is deliberately not `Codable` and never stores raw content (hash + length + bounded
//  metadata only), so it cannot be persisted by accident. Nothing here calls the network, a
//  model, or any executor.
//

import Foundation

// MARK: - Drafts (untrusted input, transient content)

/// An untrusted proposal to add an evidence item. `content` is TRANSIENT: it is hashed, scanned,
/// and mined for claims at ingestion, then dropped — it is never stored on the resulting item.
public struct QEvidenceDraft: Sendable {
    public let taskId: String
    public let sourceId: String
    public let kind: QEvidenceSourceKind
    public let provenance: QProvenanceKind
    public let origin: QEvidenceOrigin?
    public let content: String
    public let metadata: [String: String]
    public let initialVerification: QEvidenceVerificationState?

    public init(
        taskId: String,
        sourceId: String,
        kind: QEvidenceSourceKind,
        provenance: QProvenanceKind,
        origin: QEvidenceOrigin? = nil,
        content: String,
        metadata: [String: String] = [:],
        initialVerification: QEvidenceVerificationState? = nil
    ) {
        self.taskId = taskId
        self.sourceId = sourceId
        self.kind = kind
        self.provenance = provenance
        self.origin = origin
        self.content = content
        self.metadata = metadata
        self.initialVerification = initialVerification
    }
}

public enum QEvidenceAddResult: Sendable, Equatable {
    case added(QEvidenceID)
    case duplicate(QEvidenceID)
    case rejected(QEvidenceRejectionReason)
}

public enum QClaimAddResult: Sendable, Equatable {
    case added(QClaimID)
    case duplicate(QClaimID)
    case rejected(QEvidenceRejectionReason)
}

public struct QEvidenceIngestionResult: Sendable, Equatable {
    public let evidence: QEvidenceAddResult
    public let claimIds: [QClaimID]
    public let extraction: QClaimExtractionResult?
}

// MARK: - Pool

public struct QEvidencePool: Sendable, Equatable {
    public let taskId: String
    /// The effective verification requirement for this task. Set once at construction; there is no
    /// setter, so nothing downstream (critic, synthesis) can weaken it.
    public let requirement: QVerificationRequirement

    public private(set) var items: [QEvidenceItem] = []
    public private(set) var claims: [QEvidenceClaim] = []
    public private(set) var verificationRecords: [QVerificationRecord] = []
    public private(set) var contradictions: [QContradictionRecord] = []
    public private(set) var rejectionCounts: [QEvidenceRejectionReason: Int] = [:]

    public init(taskId: String, requirement: QVerificationRequirement) {
        self.taskId = taskId
        self.requirement = requirement
    }

    // MARK: Read access

    public func item(_ id: QEvidenceID) -> QEvidenceItem? {
        items.first { $0.evidenceId == id }
    }

    public func claim(_ id: QClaimID) -> QEvidenceClaim? {
        claims.first { $0.claimId == id }
    }

    public var totalRejections: Int { rejectionCounts.values.reduce(0, +) }
    public var isTainted: Bool { items.contains { !$0.source.provenance.isTrusted } }

    private mutating func reject(_ reason: QEvidenceRejectionReason) {
        rejectionCounts[reason, default: 0] += 1
    }

    // MARK: Evidence ingestion

    private static func isWellFormedSourceId(_ sourceId: String) -> Bool {
        !sourceId.isEmpty
            && sourceId.count <= QEvidenceLimits.maxSourceIdCharacters
            && !sourceId.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The provenance a source kind is REQUIRED to carry. A model or retrieved source can never be
    /// presented under trusted provenance, and a trusted source can never be presented as
    /// untrusted-retrieved — a mismatch is rejected rather than coerced, so a caller bug is loud.
    private static func isProvenanceConsistent(kind: QEvidenceSourceKind, provenance: QProvenanceKind) -> Bool {
        switch kind {
        case .modelGenerated, .retrievedExternal:
            return !provenance.isTrusted
        case .userProvided:
            if case .trustedUser = provenance { return true }
            return false
        case .executionObserved:
            if case .trustedSystem = provenance { return true }
            return false
        case .deterministicCheck:
            if case .trustedLocal = provenance { return true }
            if case .trustedSystem = provenance { return true }
            return false
        }
    }

    private static func boundedMetadata(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in metadata.keys.sorted() where result.count < QEvidenceLimits.maxMetadataEntries {
            guard key.count <= QEvidenceLimits.maxMetadataKeyCharacters,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }),
                  let value = metadata[key] else { continue }
            result[key] = QEvidenceText.boundedSafe(value, maxCharacters: QEvidenceLimits.maxMetadataValueCharacters)
        }
        return result
    }

    /// Adds an evidence item (no claims). Content is hashed and scanned, never stored.
    @discardableResult
    public mutating func addEvidence(_ draft: QEvidenceDraft) -> QEvidenceAddResult {
        guard draft.taskId == taskId else { reject(.taskMismatch); return .rejected(.taskMismatch) }
        guard Self.isWellFormedSourceId(draft.sourceId) else { reject(.malformedSource); return .rejected(.malformedSource) }
        guard Self.isProvenanceConsistent(kind: draft.kind, provenance: draft.provenance) else {
            reject(.provenanceKindMismatch); return .rejected(.provenanceKindMismatch)
        }
        // A retrieved document with no body is a malformed source, not "evidence of absence".
        if draft.kind == .retrievedExternal, draft.content.isEmpty {
            reject(.malformedSource); return .rejected(.malformedSource)
        }

        let scanned = String(draft.content.prefix(QEvidenceLimits.maxContentCharactersScanned))
        let contentHash = QEvidenceText.sha256Hex(scanned)
        let id = QEvidenceID(rawValue: "ev-" + QEvidenceText.shortHash([taskId, draft.kind.rawValue, draft.sourceId, contentHash]))
        if items.contains(where: { $0.evidenceId == id }) { return .duplicate(id) }
        guard items.count < QEvidenceLimits.maxEvidenceItems else { reject(.poolFull); return .rejected(.poolFull) }

        var flags: Set<QEvidenceFlag> = []
        if draft.content.count > QEvidenceLimits.maxContentCharactersScanned { flags.insert(.truncated) }
        if scanned.split(whereSeparator: { $0.isNewline }).contains(where: { QEvidenceInstructionScanner.looksLikeInstruction(String($0)) }) {
            flags.insert(.instructionLikeContent)
        }
        if QSecretRedactor.redact(scanned) != scanned { flags.insert(.credentialShapedContent) }

        let defaultVerification: QEvidenceVerificationState = draft.kind.isSelfEvidencing ? .notRequired : .pending
        items.append(
            QEvidenceItem(
                evidenceId: id,
                taskId: taskId,
                source: QEvidenceSource(
                    sourceId: draft.sourceId,
                    kind: draft.kind,
                    provenance: draft.provenance.strippedOfLocators,
                    origin: draft.origin
                ),
                contentHash: contentHash,
                contentLength: draft.content.count,
                trust: Self.baseItemTrust(kind: draft.kind),
                verification: draft.initialVerification ?? defaultVerification,
                flags: flags,
                metadata: Self.boundedMetadata(draft.metadata),
                createdAt: Date()
            )
        )
        recompute()
        return .added(id)
    }

    private static func baseItemTrust(kind: QEvidenceSourceKind) -> QEvidenceTrust {
        kind == .modelGenerated ? .untrusted : .observed
    }

    // MARK: Claim ingestion

    /// Adds one claim extracted from the evidence item `originEvidenceId`. Every cited ID must
    /// exist in THIS pool; a citation to a nonexistent item is dropped (counted) and can never make
    /// the claim look sourced. A credential-shaped proposition is refused outright.
    @discardableResult
    public mutating func addClaim(
        proposition: QClaimProposition,
        originEvidenceId: QEvidenceID,
        citedEvidenceIds: [QEvidenceID] = []
    ) -> QClaimAddResult {
        guard let origin = item(originEvidenceId) else { reject(.unknownEvidenceReference); return .rejected(.unknownEvidenceReference) }
        if QSecretRedactor.redact(proposition.renderedText) != proposition.renderedText {
            reject(.credentialShapedContent); return .rejected(.credentialShapedContent)
        }

        var sources = [originEvidenceId]
        for cited in citedEvidenceIds.prefix(QEvidenceLimits.maxCitedEvidencePerClaim) where cited != originEvidenceId {
            if item(cited) != nil {
                if !sources.contains(cited) { sources.append(cited) }
            } else {
                reject(.unknownEvidenceReference)
            }
        }

        let claimId = QClaimID(rawValue: "cl-" + QEvidenceText.shortHash([taskId, originEvidenceId.rawValue, proposition.subjectKey, proposition.normalizedValueHash]))
        if claims.contains(where: { $0.claimId == claimId }) { return .duplicate(claimId) }
        guard claims.count < QEvidenceLimits.maxClaims else { reject(.claimLimitReached); return .rejected(.claimLimitReached) }
        guard claims.filter({ $0.sourceEvidenceIds.first == originEvidenceId }).count < QEvidenceLimits.maxClaimsPerEvidenceItem else {
            reject(.claimLimitReached); return .rejected(.claimLimitReached)
        }

        let producer = origin.source.origin?.producerId ?? origin.source.sourceId
        claims.append(
            QEvidenceClaim(
                claimId: claimId,
                taskId: taskId,
                proposition: proposition,
                sourceEvidenceIds: sources,
                originKind: origin.source.kind,
                producerId: producer,
                supportKey: "\(origin.source.kind.rawValue):\(origin.source.sourceId)",
                trust: .untrusted,
                verification: origin.source.kind.isSelfEvidencing ? .notRequired : .pending,
                verifiedBasis: nil,
                verificationRequired: false,
                contradiction: .unresolved
            )
        )
        recompute()
        return .added(claimId)
    }

    /// Ingests a draft AND mines its (transient) content for claims via `extractor`.
    @discardableResult
    public mutating func ingest(_ draft: QEvidenceDraft, extractor: any QClaimExtractor = QDeterministicClaimExtractor()) -> QEvidenceIngestionResult {
        let addResult = addEvidence(draft)
        let evidenceId: QEvidenceID
        switch addResult {
        case .added(let id), .duplicate(let id): evidenceId = id
        case .rejected: return QEvidenceIngestionResult(evidence: addResult, claimIds: [], extraction: nil)
        }
        // A duplicate item was already mined when first added.
        if case .duplicate = addResult { return QEvidenceIngestionResult(evidence: addResult, claimIds: [], extraction: nil) }

        let extraction = extractor.extract(from: draft.content, maxClaims: QEvidenceLimits.maxClaimsPerEvidenceItem)
        var claimIds: [QClaimID] = []
        for extracted in extraction.propositions {
            switch addClaim(proposition: extracted.proposition, originEvidenceId: evidenceId, citedEvidenceIds: extracted.citedEvidenceIds) {
            case .added(let id), .duplicate(let id): claimIds.append(id)
            case .rejected: break
            }
        }
        for _ in 0..<extraction.droppedCredentialShapedLines { reject(.credentialShapedContent) }
        for _ in 0..<extraction.skippedMalformedLines { reject(.malformedClaim) }
        return QEvidenceIngestionResult(evidence: addResult, claimIds: claimIds, extraction: extraction)
    }

    // MARK: Verification application

    /// Applies verification records. The pool — not the caller — enforces what a record may do:
    ///  - a model-basis result can never produce `verified`/`contradicted` (downgraded to `unresolved`);
    ///  - a verifier whose id equals the claim's producer is refused (`selfVerificationRefused`);
    ///  - `verified` requires a truth-establishing basis and raises trust to `independentlyVerified`;
    ///  - unknown claim IDs are ignored.
    public mutating func applyVerification(_ records: [QVerificationRecord]) {
        for record in records {
            guard let index = claims.firstIndex(where: { $0.claimId == record.claimId }) else { continue }
            var effective = record

            if let basis = record.basis, !basis.canEstablishTruth,
               record.result == .verified || record.result == .contradicted {
                effective = QVerificationRecord(claimId: record.claimId, result: .unresolved, basis: basis, verifierId: record.verifierId, reason: .independentModelAdvisoryOnly)
            }
            if record.basis == .independentModel, record.verifierId == claims[index].producerId {
                effective = QVerificationRecord(claimId: record.claimId, result: .unresolved, basis: record.basis, verifierId: record.verifierId, reason: .selfVerificationRefused)
            }
            // `verified` without any basis is meaningless — never accepted.
            if effective.result == .verified, effective.basis == nil {
                effective = QVerificationRecord(claimId: record.claimId, result: .unresolved, basis: nil, verifierId: record.verifierId, reason: .noIndependentEvidence)
            }

            claims[index].verification = effective.result
            claims[index].verifiedBasis = effective.result == .verified ? effective.basis : nil
            verificationRecords.removeAll { $0.claimId == effective.claimId }
            verificationRecords.append(effective)
        }
        recompute()
    }

    // MARK: Recompute (the single trust derivation)

    /// Whether `claim` satisfies the pool's verification requirement. `.none` requires nothing of
    /// a claim beyond observation; the stronger requirements need a specific verification basis.
    public func isSatisfied(_ claim: QEvidenceClaim) -> Bool {
        if claim.verification == .contradicted { return false }
        if claim.contradiction == .conflicting && claim.trust != .independentlyVerified { return false }
        if claim.trust == .independentlyVerified {
            switch requirement {
            case .none: return true
            case .executionEvidence: return claim.verifiedBasis == .executionEvidence
            case .independentVerification: return claim.verifiedBasis?.canEstablishTruth == true
            }
        }
        return !claim.verificationRequired && claim.trust >= .observed
    }

    /// Whether claims from this origin need verification under the pool's requirement.
    private func requiresVerification(_ claim: QEvidenceClaim) -> Bool {
        if claim.originKind.isSelfEvidencing { return false }
        return requirement != .none || claim.contradiction == .conflicting
    }

    private mutating func recompute() {
        // 1. Base trust: distinct non-model support keys asserting the same proposition.
        for index in claims.indices {
            let claim = claims[index]
            let supportKeys = Set(
                claims
                    .filter {
                        $0.originKind != .modelGenerated
                            && $0.proposition.subjectKey == claim.proposition.subjectKey
                            && $0.proposition.normalizedValueHash == claim.proposition.normalizedValueHash
                    }
                    .map { $0.supportKey }
            )
            let derived: QEvidenceTrust
            switch supportKeys.count {
            case 0: derived = .untrusted
            case 1: derived = .observed
            default: derived = .corroborated
            }
            let verifiedFloor: QEvidenceTrust = (claim.verification == .verified && claim.verifiedBasis?.canEstablishTruth == true) ? .independentlyVerified : .untrusted
            claims[index].trust = max(derived, verifiedFloor)
        }

        // 2. Contradictions: same subject, more than one distinct normalized value.
        var bySubject: [String: [Int]] = [:]
        for index in claims.indices { bySubject[claims[index].proposition.subjectKey, default: []].append(index) }
        var records: [QContradictionRecord] = []
        var conflicting: Set<Int> = []
        var settledWinners: Set<Int> = []
        for subject in bySubject.keys.sorted() {
            guard let indices = bySubject[subject] else { continue }
            let values = Set(indices.map { claims[$0].proposition.normalizedValueHash })
            guard values.count > 1 else { continue }
            conflicting.formUnion(indices)

            // A value is ESTABLISHED only by evidence independent of models: a claim that was
            // independently verified, or an execution/deterministic observation itself. A conflict
            // is resolved only if exactly one value is established AND every claim holding another
            // value has been contradicted by verification. Never a model's say-so, recency, or
            // repetition.
            func isEstablished(_ index: Int) -> Bool {
                claims[index].trust == .independentlyVerified || claims[index].originKind.isIndependentOfModels
            }
            let establishedValues = Set(indices.filter(isEstablished).map { claims[$0].proposition.normalizedValueHash })
            let resolution: QContradictionResolution
            if establishedValues.count == 1, let winningValue = establishedValues.first,
               indices.filter({ claims[$0].proposition.normalizedValueHash != winningValue }).allSatisfy({ claims[$0].verification == .contradicted }) {
                let winners = indices.filter { claims[$0].proposition.normalizedValueHash == winningValue && isEstablished($0) }
                let basis: QVerificationBasis = winners.compactMap { index -> QVerificationBasis? in
                    if let verifiedBasis = claims[index].verifiedBasis { return verifiedBasis }
                    switch claims[index].originKind {
                    case .executionObserved: return .executionEvidence
                    case .deterministicCheck: return .deterministicCheck
                    default: return nil
                    }
                }.first ?? .executionEvidence
                settledWinners.formUnion(winners)
                resolution = .resolvedByVerification(winningClaimIds: winners.map { claims[$0].claimId }.sorted(), basis: basis)
            } else {
                resolution = .unresolved
            }
            records.append(
                QContradictionRecord(
                    contradictionId: "ctr-" + QEvidenceText.shortHash([taskId, subject]),
                    subjectKey: subject,
                    claimIds: indices.map { claims[$0].claimId }.sorted(),
                    distinctValueCount: values.count,
                    resolution: resolution
                )
            )
        }
        contradictions = records

        // Both sides of a conflict stay marked `conflicting` (nothing is silently dropped) — except
        // the winners of a conflict settled by independent evidence, which are consistent.
        for index in claims.indices {
            if settledWinners.contains(index) {
                claims[index].contradiction = .consistent
            } else if conflicting.contains(index) {
                claims[index].contradiction = .conflicting
            } else if claims[index].trust >= .corroborated {
                claims[index].contradiction = .consistent
            } else {
                claims[index].contradiction = .unresolved
            }
        }

        // 3. Verification requirement + pending/notRequired bookkeeping.
        for index in claims.indices {
            claims[index].verificationRequired = requiresVerification(claims[index])
            if claims[index].verification == .notRequired, claims[index].verificationRequired {
                claims[index].verification = .pending
            } else if claims[index].verification == .pending, !claims[index].verificationRequired {
                claims[index].verification = .notRequired
            }
        }

        // 4. Item roll-up from the claims extracted from each item (items with no claims keep the
        //    verification state they were ingested with, e.g. a Phase 2B attempt outcome).
        for itemIndex in items.indices {
            let id = items[itemIndex].evidenceId
            let own = claims.filter { $0.sourceEvidenceIds.first == id }
            guard !own.isEmpty else { continue }
            if own.contains(where: { $0.verification == .contradicted }) {
                items[itemIndex].verification = .contradicted
            } else if own.allSatisfy({ $0.verification == .verified }) {
                items[itemIndex].verification = .verified
            } else if own.contains(where: { $0.verification == .unavailable }) {
                items[itemIndex].verification = .unavailable
            } else if own.contains(where: { $0.verification == .unresolved }) {
                items[itemIndex].verification = .unresolved
            } else if own.allSatisfy({ $0.verification == .notRequired }) {
                items[itemIndex].verification = .notRequired
            } else {
                items[itemIndex].verification = .pending
            }
            items[itemIndex].trust = own.map { $0.trust }.max() ?? items[itemIndex].trust
        }
    }
}
