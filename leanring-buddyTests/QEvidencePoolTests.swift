//
//  QEvidencePoolTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2C Evidence Pool, trust ladder, claim extraction, and
//  contradiction tests. Trust is always computed by the real pool; no test sets it directly.
//

import Testing
import Foundation
@testable import Pace

@Suite("QEvidencePoolTests")
struct QEvidencePoolTests {

    // MARK: - Creation, provenance, privacy

    @Test("Model-generated evidence is created untrusted with pending verification")
    func modelEvidenceIsUntrusted() {
        var pool = EvidenceFixtures.pool()
        let result = pool.ingest(EvidenceFixtures.modelDraft(sourceId: "m1", content: "capital of france: paris"))

        guard case .added(let evidenceId) = result.evidence, let item = pool.item(evidenceId) else {
            Issue.record("Expected the model item to be added")
            return
        }
        #expect(item.source.kind == .modelGenerated)
        #expect(item.trust == .untrusted)
        #expect(item.verification == .pending)
        #expect(!item.source.provenance.isTrusted)
        #expect(item.source.origin?.backend == .ollama)
        #expect(pool.claims.count == 1)
        #expect(pool.claims[0].trust == .untrusted)
        #expect(pool.claims[0].status == .unverified)
    }

    @Test("Provenance is preserved by category and stripped of URL/path locators")
    func provenanceIsPreservedWithoutLocators() {
        var pool = EvidenceFixtures.pool()
        pool.ingest(EvidenceFixtures.retrievedDraft(sourceId: "doc-1", content: "boiling point: 100c", url: "https://internal.example.com/private/report?token=abc123"))
        pool.ingest(
            QEvidenceDraft(
                taskId: EvidenceFixtures.taskId, sourceId: "file-1", kind: .retrievedExternal,
                provenance: .untrustedFile(path: "/Users/someone/Documents/secret-plan.txt"), content: "owner: someone"
            )
        )

        for item in pool.items {
            #expect(!item.source.provenance.isTrusted)
            #expect(!item.source.provenance.rawTag.contains("example.com"))
            #expect(!item.source.provenance.rawTag.contains("secret-plan"))
        }
        #expect(pool.items[0].source.provenance.rawTag == "untrusted:web")
        #expect(pool.items[1].source.provenance.rawTag == "untrusted:file")
        #expect(pool.items[0].source.sourceId == "doc-1")
    }

    @Test("The pool never stores raw content: only hash, length, and bounded metadata survive")
    func poolNeverStoresRawContent() {
        var pool = EvidenceFixtures.pool()
        let distinctiveBody = "zebra-marker-7431 quarterly revenue: 12 million\nadditional private paragraph zebra-marker-9902"
        pool.ingest(EvidenceFixtures.retrievedDraft(sourceId: "doc-1", content: distinctiveBody))

        let dump = String(describing: pool)
        #expect(!dump.contains("zebra-marker-9902"))
        #expect(!dump.contains("additional private paragraph"))
        #expect(pool.items[0].contentHash.count == 64)
        #expect(pool.items[0].contentLength == distinctiveBody.count)
    }

    @Test("Evidence and claim IDs are deterministic across pools")
    func identifiersAreDeterministic() {
        var first = EvidenceFixtures.pool()
        var second = EvidenceFixtures.pool()
        let firstId = EvidenceFixtures.addModelClaim(&first, sourceId: "m1", subject: "sky colour", value: "blue")
        let secondId = EvidenceFixtures.addModelClaim(&second, sourceId: "m1", subject: "sky colour", value: "blue")
        #expect(firstId == secondId)
        #expect(first.items.map { $0.evidenceId } == second.items.map { $0.evidenceId })
    }

    @Test("Verification state defaults: self-evidencing kinds are notRequired, model/retrieved are pending")
    func verificationStateDefaults() {
        var pool = EvidenceFixtures.pool()
        pool.ingest(EvidenceFixtures.executionDraft(content: "a: 1"))
        pool.ingest(EvidenceFixtures.userDraft(content: "b: 2"))
        pool.ingest(EvidenceFixtures.modelDraft(sourceId: "m1", content: "c: 3"))
        pool.ingest(EvidenceFixtures.retrievedDraft(sourceId: "r1", content: "d: 4"))

        let byKind = Dictionary(uniqueKeysWithValues: pool.items.map { ($0.source.kind, $0.verification) })
        #expect(byKind[.executionObserved] == .notRequired)
        #expect(byKind[.userProvided] == .notRequired)
        #expect(byKind[.modelGenerated] == .pending)
        #expect(byKind[.retrievedExternal] == .pending)
    }

    // MARK: - Deduplication and bounds

    @Test("Duplicate evidence (same task/kind/source/content) is not added twice")
    func duplicatesAreDeduplicated() {
        var pool = EvidenceFixtures.pool()
        let draft = EvidenceFixtures.retrievedDraft(sourceId: "doc-1", content: "melting point: 0c")
        let first = pool.addEvidence(draft)
        let second = pool.addEvidence(draft)

        guard case .added(let firstId) = first, case .duplicate(let secondId) = second else {
            Issue.record("Expected added then duplicate, got \(first) / \(second)")
            return
        }
        #expect(firstId == secondId)
        #expect(pool.items.count == 1)
    }

    @Test("The pool is bounded: items beyond the limit are rejected and counted")
    func poolIsBounded() {
        var pool = EvidenceFixtures.pool()
        for index in 0..<(QEvidenceLimits.maxEvidenceItems + 6) {
            pool.addEvidence(EvidenceFixtures.retrievedDraft(sourceId: "doc-\(index)", content: "k\(index): v\(index)"))
        }
        #expect(pool.items.count == QEvidenceLimits.maxEvidenceItems)
        #expect(pool.rejectionCounts[.poolFull] == 6)
    }

    @Test("Claims are bounded per pool and per evidence item")
    func claimsAreBounded() {
        var pool = EvidenceFixtures.pool()
        let manyLines = (0..<20).map { "subject\($0): value\($0)" }.joined(separator: "\n")
        let result = pool.ingest(EvidenceFixtures.retrievedDraft(sourceId: "doc-1", content: manyLines))
        #expect(result.claimIds.count == QEvidenceLimits.maxClaimsPerEvidenceItem)

        for source in 0..<20 {
            let lines = (0..<QEvidenceLimits.maxClaimsPerEvidenceItem).map { "s\(source)-\($0): v" }.joined(separator: "\n")
            pool.ingest(EvidenceFixtures.retrievedDraft(sourceId: "bulk-\(source)", content: lines))
        }
        #expect(pool.claims.count == QEvidenceLimits.maxClaims)
        #expect((pool.rejectionCounts[.claimLimitReached] ?? 0) > 0)
    }

    @Test("Oversized content is truncated-flagged and scanned only up to the bound")
    func oversizedContentIsFlagged() {
        var pool = EvidenceFixtures.pool()
        let huge = "topic: value\n" + String(repeating: "x", count: QEvidenceLimits.maxContentCharactersScanned + 500)
        pool.ingest(EvidenceFixtures.retrievedDraft(sourceId: "doc-1", content: huge))
        #expect(pool.items[0].flags.contains(.truncated))
        #expect(pool.items[0].contentLength == huge.count)
    }

    @Test("Metadata is bounded: entry count, key charset/length, and value length; secrets are redacted")
    func metadataIsBounded() {
        var pool = EvidenceFixtures.pool()
        var metadata: [String: String] = [:]
        for index in 0..<20 { metadata["key\(index)"] = "v\(index)" }
        metadata["bad key!"] = "dropped"
        metadata[String(repeating: "k", count: 40)] = "dropped"
        pool.addEvidence(
            QEvidenceDraft(
                taskId: EvidenceFixtures.taskId, sourceId: "doc-1", kind: .retrievedExternal,
                provenance: .untrustedWeb(url: nil), content: "a: b", metadata: metadata
            )
        )
        #expect(pool.items[0].metadata.count == QEvidenceLimits.maxMetadataEntries)
        #expect(pool.items[0].metadata["bad key!"] == nil)

        var secretPool = EvidenceFixtures.pool()
        secretPool.addEvidence(
            QEvidenceDraft(
                taskId: EvidenceFixtures.taskId, sourceId: "doc-2", kind: .retrievedExternal, provenance: .untrustedWeb(url: nil),
                content: "a: b", metadata: ["note": "token=abcdefghijklmnop " + String(repeating: "z", count: 200)]
            )
        )
        let stored = secretPool.items[0].metadata["note"] ?? ""
        #expect(!stored.contains("abcdefghijklmnop"))
        #expect(stored.count <= QEvidenceLimits.maxMetadataValueCharacters)
    }

    // MARK: - Rejections

    @Test("Malformed sources are rejected: empty, oversized, control characters, empty retrieved body")
    func malformedSourcesAreRejected() {
        var pool = EvidenceFixtures.pool()
        #expect(pool.addEvidence(EvidenceFixtures.retrievedDraft(sourceId: "", content: "a: b")) == .rejected(.malformedSource))
        #expect(pool.addEvidence(EvidenceFixtures.retrievedDraft(sourceId: String(repeating: "s", count: 200), content: "a: b")) == .rejected(.malformedSource))
        #expect(pool.addEvidence(EvidenceFixtures.retrievedDraft(sourceId: "bad\u{0007}id", content: "a: b")) == .rejected(.malformedSource))
        #expect(pool.addEvidence(EvidenceFixtures.retrievedDraft(sourceId: "empty-body", content: "")) == .rejected(.malformedSource))
        #expect(pool.items.isEmpty)
        #expect(pool.rejectionCounts[.malformedSource] == 4)
    }

    @Test("A task-mismatched draft is rejected")
    func taskMismatchIsRejected() {
        var pool = EvidenceFixtures.pool()
        let foreign = QEvidenceDraft(taskId: "other-task", sourceId: "x", kind: .retrievedExternal, provenance: .untrustedWeb(url: nil), content: "a: b")
        #expect(pool.addEvidence(foreign) == .rejected(.taskMismatch))
    }

    @Test("Source kind and provenance must agree: a model or retrieved item can never carry trusted provenance, and vice versa")
    func provenanceKindMismatchIsRejected() {
        var pool = EvidenceFixtures.pool()
        let trustedModel = QEvidenceDraft(taskId: EvidenceFixtures.taskId, sourceId: "m", kind: .modelGenerated, provenance: .trustedSystem, content: "a: b")
        let trustedRetrieved = QEvidenceDraft(taskId: EvidenceFixtures.taskId, sourceId: "r", kind: .retrievedExternal, provenance: .trustedUser(channel: "x"), content: "a: b")
        let untrustedExecution = QEvidenceDraft(taskId: EvidenceFixtures.taskId, sourceId: "e", kind: .executionObserved, provenance: .untrustedWeb(url: nil), content: "a: b")
        let untrustedUser = QEvidenceDraft(taskId: EvidenceFixtures.taskId, sourceId: "u", kind: .userProvided, provenance: .untrustedScreen, content: "a: b")

        #expect(pool.addEvidence(trustedModel) == .rejected(.provenanceKindMismatch))
        #expect(pool.addEvidence(trustedRetrieved) == .rejected(.provenanceKindMismatch))
        #expect(pool.addEvidence(untrustedExecution) == .rejected(.provenanceKindMismatch))
        #expect(pool.addEvidence(untrustedUser) == .rejected(.provenanceKindMismatch))
        #expect(pool.items.isEmpty)
    }

    @Test("Credential-shaped content is never carried: the claim is dropped and the item flagged")
    func credentialShapedContentIsDropped() {
        var pool = EvidenceFixtures.pool()
        let result = pool.ingest(
            EvidenceFixtures.retrievedDraft(sourceId: "doc-1", content: "api_key: sk-abcdefghijklmnopqrstuvwxyz123456\nweather: sunny")
        )
        guard case .added(let evidenceId) = result.evidence, let item = pool.item(evidenceId) else {
            Issue.record("Expected the item to be added")
            return
        }
        #expect(item.flags.contains(.credentialShapedContent))
        #expect(pool.claims.count == 1)
        #expect(pool.claims[0].proposition.subjectKey == "weather")
        #expect(!String(describing: pool).contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
        #expect((pool.rejectionCounts[.credentialShapedContent] ?? 0) >= 1)
    }

    @Test("A claim added directly with a credential-shaped proposition is refused")
    func directCredentialClaimIsRefused() {
        var pool = EvidenceFixtures.pool()
        guard case .added(let evidenceId) = pool.addEvidence(EvidenceFixtures.retrievedDraft(sourceId: "d", content: "x: y")),
              let proposition = QClaimProposition(subject: "config", value: "password=hunter2hunter2") else {
            Issue.record("setup failed")
            return
        }
        #expect(pool.addClaim(proposition: proposition, originEvidenceId: evidenceId) == .rejected(.credentialShapedContent))
    }

    // MARK: - Trust ladder

    @Test("Trust ladder: model-only → untrusted, one non-model source → observed, two distinct → corroborated")
    func trustLadder() {
        var pool = EvidenceFixtures.pool()
        let modelClaim = EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "water boils at", value: "100c")
        #expect(pool.claim(modelClaim!)?.trust == .untrusted)

        EvidenceFixtures.addRetrievedClaim(&pool, sourceId: "doc-a", subject: "water boils at", value: "100c")
        #expect(pool.claim(modelClaim!)?.trust == .observed)

        EvidenceFixtures.addRetrievedClaim(&pool, sourceId: "doc-b", subject: "water boils at", value: "100c")
        #expect(pool.claim(modelClaim!)?.trust == .corroborated)
        #expect(pool.claim(modelClaim!)?.contradiction == .consistent)
    }

    @Test("Several models repeating a claim — the same model or different ones — never raise its trust")
    func modelRepetitionNeverRaisesTrust() {
        var pool = EvidenceFixtures.pool()
        for (index, backend) in [QModelBackendType.ollama, .llamaCpp, .mlx, .appleFoundation].enumerated() {
            EvidenceFixtures.addModelClaim(&pool, sourceId: "m\(index)", backend: backend, subject: "moon is made of", value: "cheese")
        }
        for _ in 0..<5 {
            EvidenceFixtures.addModelClaim(&pool, sourceId: "again", subject: "moon is made of", value: "cheese")
        }
        #expect(pool.claims.allSatisfy { $0.trust == .untrusted })
        #expect(pool.claims.allSatisfy { $0.status == .unverified })
    }

    @Test("The same non-model source repeating itself is one support, not corroboration")
    func sameSourceIsNotCorroboration() {
        var pool = EvidenceFixtures.pool()
        pool.ingest(EvidenceFixtures.retrievedDraft(sourceId: "doc-a", content: "fact: same"))
        pool.ingest(EvidenceFixtures.retrievedDraft(sourceId: "doc-a", content: "fact: same\nother: padding"))
        let claim = pool.claims.first { $0.proposition.subjectKey == "fact" }
        #expect(claim?.trust == .observed)
    }

    @Test("A retrieved claim is observed at most — a source that looks authoritative is not verified")
    func retrievedIsNeverVerified() {
        var pool = EvidenceFixtures.pool()
        EvidenceFixtures.addRetrievedClaim(&pool, sourceId: "official-government-site", subject: "population", value: "10 million")
        #expect(pool.claims[0].trust == .observed)
        #expect(pool.claims[0].status == .supported)
        #expect(pool.claims[0].verificationRequired)
        #expect(!pool.isSatisfied(pool.claims[0]))
    }

    @Test("Citations lend traceability, not trust: citing a real item that does not assert the claim adds no trust")
    func citationsAddNoTrust() {
        var pool = EvidenceFixtures.pool()
        guard case .added(let docId) = pool.addEvidence(EvidenceFixtures.retrievedDraft(sourceId: "doc-1", content: "unrelated: thing")) else {
            Issue.record("setup failed")
            return
        }
        let result = pool.ingest(EvidenceFixtures.modelDraft(sourceId: "m1", content: "sky colour: green [\(docId.rawValue)]"))
        guard let claimId = result.claimIds.first, let claim = pool.claim(claimId) else {
            Issue.record("Expected a claim")
            return
        }
        #expect(claim.sourceEvidenceIds.contains(docId))
        #expect(claim.trust == .untrusted)
        #expect(claim.proposition.value == "green")
    }

    @Test("A citation to evidence that does not exist is dropped and counted — the claim never looks sourced")
    func fakeCitationIsDropped() {
        var pool = EvidenceFixtures.pool()
        let result = pool.ingest(EvidenceFixtures.modelDraft(sourceId: "m1", content: "vaccine efficacy: 99% [ev-deadbeefdeadbeef]"))
        guard let claimId = result.claimIds.first, let claim = pool.claim(claimId) else {
            Issue.record("Expected a claim")
            return
        }
        #expect(claim.sourceEvidenceIds.count == 1)
        #expect(claim.sourceEvidenceIds[0] == pool.items[0].evidenceId)
        #expect(claim.trust == .untrusted)
        #expect(pool.rejectionCounts[.unknownEvidenceReference] == 1)
    }

    @Test("Free-text citations inside a claim ('according to NIST') create no provenance and no trust")
    func freeTextCitationsCreateNothing() {
        var pool = EvidenceFixtures.pool()
        pool.ingest(EvidenceFixtures.modelDraft(sourceId: "m1", content: "speed of light: 300000 km/s (source: NIST, https://nist.gov/c)"))
        #expect(pool.items.count == 1)
        #expect(pool.claims[0].trust == .untrusted)
        #expect(pool.claims[0].sourceEvidenceIds.count == 1)
    }

    // MARK: - Claim extraction

    @Test("Extraction: colon/equals/bulleted lines become bounded propositions; prose yields none")
    func extractionShapes() {
        let extractor = QDeterministicClaimExtractor()
        let result = extractor.extract(
            from: "capital of france: Paris\n- height of everest = 8849 m\n* author: Someone\nThis is a plain sentence without structure.",
            maxClaims: 8
        )
        #expect(result.propositions.count == 3)
        #expect(result.propositions[0].proposition.subjectKey == "capital of france")
        #expect(result.propositions[1].proposition.value == "8849 m")
        #expect(result.skippedMalformedLines == 1)
    }

    @Test("Extraction rejects oversized values and empty sides; certainty language is recorded, not trusted")
    func extractionBounds() {
        let extractor = QDeterministicClaimExtractor()
        let long = String(repeating: "v", count: QEvidenceLimits.maxClaimValueCharacters + 1)
        let result = extractor.extract(from: "big: \(long)\nempty:\nkey: value\nverdict: definitely 100% true", maxClaims: 8)
        #expect(result.propositions.count == 2)
        #expect(result.propositions[1].proposition.assertsCertainty)
        #expect(!result.propositions[0].proposition.assertsCertainty)
    }

    @Test("Claims link back to their extracting evidence item and carry deterministic identity")
    func claimsLinkToSourceEvidence() {
        var pool = EvidenceFixtures.pool()
        let result = pool.ingest(EvidenceFixtures.retrievedDraft(sourceId: "doc-1", content: "a: 1\nb: 2"))
        guard case .added(let evidenceId) = result.evidence else {
            Issue.record("setup failed")
            return
        }
        #expect(result.claimIds.count == 2)
        for claimId in result.claimIds {
            #expect(pool.claim(claimId)?.sourceEvidenceIds.first == evidenceId)
            #expect(pool.claim(claimId)?.originKind == .retrievedExternal)
        }
    }

    @Test("A claim referencing an unknown origin evidence item is rejected")
    func claimWithUnknownOriginIsRejected() {
        var pool = EvidenceFixtures.pool()
        let proposition = QClaimProposition(subject: "a", value: "b")!
        #expect(pool.addClaim(proposition: proposition, originEvidenceId: QEvidenceID(rawValue: "ev-0000000000000000")) == .rejected(.unknownEvidenceReference))
    }

    // MARK: - Contradictions

    @Test("Two models disagree: both claims are preserved, both marked conflicting, no winner is chosen")
    func modelDisagreementIsPreserved() {
        var pool = EvidenceFixtures.pool()
        let claimX = EvidenceFixtures.addModelClaim(&pool, sourceId: "a", backend: .ollama, subject: "boiling point of water", value: "100c")!
        let claimY = EvidenceFixtures.addModelClaim(&pool, sourceId: "b", backend: .llamaCpp, subject: "boiling point of water", value: "90c")!

        #expect(pool.claims.count == 2)
        #expect(pool.claim(claimX)?.contradiction == .conflicting)
        #expect(pool.claim(claimY)?.contradiction == .conflicting)
        #expect(pool.contradictions.count == 1)
        #expect(pool.contradictions[0].claimIds.sorted() == [claimX, claimY].sorted())
        #expect(pool.contradictions[0].resolution == .unresolved)
        #expect(pool.claims.allSatisfy { $0.status == .unresolved })
        #expect(pool.claims.allSatisfy { $0.trust == .untrusted })
    }

    @Test("Cosmetic differences (case, spacing, trailing period) are not contradictions")
    func cosmeticDifferencesAreNotContradictions() {
        var pool = EvidenceFixtures.pool()
        EvidenceFixtures.addModelClaim(&pool, sourceId: "a", subject: "Capital  of France", value: "Paris")
        EvidenceFixtures.addModelClaim(&pool, sourceId: "b", backend: .llamaCpp, subject: "capital of france", value: "  paris. ")
        #expect(pool.contradictions.isEmpty)
        #expect(pool.claims.allSatisfy { $0.contradiction != .conflicting })
    }

    @Test("Conflicting retrieved sources stay conflicting and unresolved; corroboration by repetition does not settle them")
    func conflictingRetrievedSourcesStayConflicting() {
        var pool = EvidenceFixtures.pool()
        EvidenceFixtures.addRetrievedClaim(&pool, sourceId: "doc-a", subject: "release year", value: "2019")
        EvidenceFixtures.addRetrievedClaim(&pool, sourceId: "doc-b", subject: "release year", value: "2021")
        EvidenceFixtures.addModelClaim(&pool, sourceId: "m1", subject: "release year", value: "2021")
        EvidenceFixtures.addModelClaim(&pool, sourceId: "m2", backend: .llamaCpp, subject: "release year", value: "2021")

        #expect(pool.contradictions.count == 1)
        #expect(pool.contradictions[0].distinctValueCount == 2)
        #expect(pool.contradictions[0].claimIds.count == 4)
        #expect(!pool.contradictions[0].isResolved)
    }

    @Test("Lone uncorroborated claim is `unresolved`, not `consistent`; a corroborated one is `consistent`")
    func contradictionStateForNonConflictingClaims() {
        var pool = EvidenceFixtures.pool()
        let lone = EvidenceFixtures.addRetrievedClaim(&pool, sourceId: "doc-a", subject: "fact one", value: "x")!
        #expect(pool.claim(lone)?.contradiction == .unresolved)

        EvidenceFixtures.addRetrievedClaim(&pool, sourceId: "doc-a", subject: "fact two", value: "y")
        EvidenceFixtures.addRetrievedClaim(&pool, sourceId: "doc-b", subject: "fact two", value: "y")
        let corroborated = pool.claims.first { $0.proposition.subjectKey == "fact two" }!
        #expect(corroborated.contradiction == .consistent)
    }
}
