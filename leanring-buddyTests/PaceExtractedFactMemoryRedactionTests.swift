//
//  PaceExtractedFactMemoryRedactionTests.swift
//  leanring-buddyTests
//
//  Proves an extracted episodic fact with credential-shaped content in any
//  persisted field (F-03) never becomes DURABLE memory — the episodic fact
//  store, the retrieval index (retrieval-index.json), the unified memory
//  index (memory-index.json), or the planner's LOCAL CONTEXT block — no
//  matter which API it arrives through, while normal facts and the store's
//  dedup / tombstone / LRU behavior are unchanged.
//
//  Runs on a bare CompanionManager in the test host, whose stores are all
//  isolated temp files (PaceTestHostDataIsolation). Only synthetic sentinels
//  are used; persisted-content checks report presence/absence only.
//

import Foundation
import Testing
@testable import Pace

@MainActor
@Suite("Extracted episodic facts with credential-shaped content never become durable memory", .serialized)
struct PaceExtractedFactMemoryRedactionTests {

    // MARK: - Synthetic sentinels

    /// The core every credential-shaped sentinel below embeds. Sinks are
    /// searched for this core, so a partially-redacted leftover is caught too.
    private static let secretSentinelCore = "F03SENTINEL9C41X"
    /// Prefix-shaped: matches the `sk-` API key pattern of `QSecretRedactor`.
    private static let apiKeyShapedSentinel = "sk-\(secretSentinelCore)abcdefghij0123"
    /// Assignment-shaped: a plain secret `QSecretRedactor` recognizes only
    /// because of the `password=` assignment around it.
    private static let passwordAssignmentSentinel = "password=\(secretSentinelCore)"
    /// Bearer-shaped authorization value.
    private static let bearerShapedSentinel = "Bearer \(secretSentinelCore)abcdefgh"
    /// A plain secret with NO credential shape — the recorded known limit.
    private static let plainSecretSentinel = "F03PLAINSENTINEL7B22"

    // MARK: - Helpers

    /// A marker that is unique per test and can never look credential-shaped
    /// (letters and digits only, no hyphens).
    private static func uniqueMarker() -> String {
        "marker" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func makeFact(
        subject: String,
        predicate: String,
        value: String,
        confidence: Double = 0.9,
        topicHashtags: [String] = ["#preference"],
        extractedAt: Date = Date(),
        identifier: String? = nil
    ) -> PaceEpisodicFact {
        PaceEpisodicFact(
            identifier: identifier ?? "episodic-f03-\(uniqueMarker())",
            extractedAt: extractedAt,
            subject: subject,
            predicate: predicate,
            value: value,
            confidence: confidence,
            expiresAt: nil,
            topicHashtags: topicHashtags,
            sourceTurnId: "turn-f03-\(uniqueMarker())"
        )
    }

    private static func jsonText<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Everything the manager currently holds in the durable sinks a fact can
    /// reach, in memory AND as the bytes on disk a relaunch would load.
    private static func durableSinkTexts(_ companionManager: CompanionManager) throws -> [String] {
        var texts: [String] = []
        texts.append(try jsonText(companionManager.episodicFactStore.allFacts))
        texts.append(try jsonText(companionManager.episodicFactStore.allTombstones))
        texts.append(try jsonText(companionManager.localRetriever.documents(forSource: .episodicMemory)))
        texts.append(try jsonText(companionManager.memoryIndex.allEntries()))
        texts.append(try jsonText(companionManager.memoryStore.load()))
        let retrievalIndexFileURL = try #require(PaceLocalRetriever.defaultPersistenceURL())
        let memoryIndexFileURL = try #require(companionManager.memoryStore.persistedFileURL)
        for persistedFileURL in [retrievalIndexFileURL, memoryIndexFileURL] {
            if let persistedData = try? Data(contentsOf: persistedFileURL) {
                texts.append(String(decoding: persistedData, as: UTF8.self))
            }
        }
        return texts
    }

    private static func anyContains(_ texts: [String], _ needle: String) -> Bool {
        texts.contains { $0.contains(needle) }
    }

    // MARK: - The central policy

    @Test("The policy flags a credential in each persisted field and across fields, and passes clean facts")
    func policyFlagsEveryPersistedField() {
        let cleanFact = Self.makeFact(subject: "user", predicate: "prefers", value: "dark mode")
        #expect(!PaceDurableConversationContent.episodicFactContainsCredentialShapedContent(cleanFact))

        let credentialBearingFacts: [PaceEpisodicFact] = [
            Self.makeFact(subject: "user", predicate: "uses key", value: Self.apiKeyShapedSentinel),
            Self.makeFact(subject: Self.apiKeyShapedSentinel, predicate: "is", value: "the key"),
            Self.makeFact(subject: "user", predicate: Self.passwordAssignmentSentinel, value: "for wifi"),
            Self.makeFact(subject: "user", predicate: "said", value: Self.passwordAssignmentSentinel),
            Self.makeFact(subject: "user", predicate: "sends header", value: Self.bearerShapedSentinel),
            Self.makeFact(subject: "user", predicate: "prefers", value: "dark mode", topicHashtags: ["#work", "token=\(Self.secretSentinelCore)"]),
            Self.makeFact(subject: "user", predicate: "prefers", value: "dark mode", identifier: "episodic-\(Self.apiKeyShapedSentinel)"),
            // The shape only exists once the sinks join the fields.
            Self.makeFact(subject: "user", predicate: "password:", value: Self.secretSentinelCore),
            Self.makeFact(subject: "user api_key", predicate: "=", value: Self.secretSentinelCore),
        ]
        for credentialBearingFact in credentialBearingFacts {
            #expect(PaceDurableConversationContent.episodicFactContainsCredentialShapedContent(credentialBearingFact))
        }
    }

    // MARK: - Through CompanionManager.recordExtractedEpisodicFacts

    @Test("A credential in fact.value, fact.subject, or fact.predicate keeps the fact out of every durable sink")
    func credentialInAnyTripletFieldIsDropped() throws {
        let credentialBearingFacts: [PaceEpisodicFact] = [
            Self.makeFact(subject: "user", predicate: "uses key", value: Self.apiKeyShapedSentinel),
            Self.makeFact(subject: Self.apiKeyShapedSentinel, predicate: "is", value: "the deploy key"),
            Self.makeFact(subject: "user", predicate: Self.passwordAssignmentSentinel, value: "for wifi"),
        ]
        for credentialBearingFact in credentialBearingFacts {
            let companionManager = CompanionManager()
            companionManager.recordExtractedEpisodicFacts([credentialBearingFact], turnId: "turn-f03")

            #expect(!companionManager.episodicFactStore.allFacts.contains { $0.identifier == credentialBearingFact.identifier })
            #expect(!companionManager.localRetriever.documents(forSource: .episodicMemory).contains { $0.id == credentialBearingFact.identifier })
            #expect(companionManager.memoryIndex.entry(id: credentialBearingFact.identifier) == nil)
            #expect(!Self.anyContains(try Self.durableSinkTexts(companionManager), Self.secretSentinelCore))
        }
    }

    @Test("A plain secret QSecretRedactor recognizes by its assignment or bearer shape is dropped")
    func recognizedPlainSecretIsDropped() throws {
        let companionManager = CompanionManager()
        let assignmentFact = Self.makeFact(subject: "user", predicate: "said", value: "my \(Self.passwordAssignmentSentinel)")
        let bearerFact = Self.makeFact(subject: "user", predicate: "sends header", value: Self.bearerShapedSentinel)
        let crossFieldFact = Self.makeFact(subject: "user", predicate: "password:", value: Self.secretSentinelCore)

        companionManager.recordExtractedEpisodicFacts([assignmentFact, bearerFact, crossFieldFact], turnId: "turn-f03")

        #expect(!Self.anyContains(try Self.durableSinkTexts(companionManager), Self.secretSentinelCore))
        for droppedFact in [assignmentFact, bearerFact, crossFieldFact] {
            #expect(companionManager.memoryIndex.entry(id: droppedFact.identifier) == nil)
        }
    }

    @Test("An LLM-extractor-built fact carrying a credential is dropped")
    func extractorProducedCredentialFactIsDropped() throws {
        let companionManager = CompanionManager()
        // The same converter both LLM extractors use to turn model output into a fact.
        let extractorProducedFact = try #require(PaceExtractedFactBuilder.buildFact(
            subject: "user",
            predicate: "uses api key",
            value: Self.apiKeyShapedSentinel,
            confidence: 0.95,
            expiresAtISOString: nil,
            topicHashtags: ["#work"],
            sourceTurnId: "turn-f03-llm",
            extractedAt: Date()
        ))

        companionManager.recordExtractedEpisodicFacts([extractorProducedFact], turnId: "turn-f03-llm")

        #expect(!companionManager.episodicFactStore.allFacts.contains { $0.identifier == extractorProducedFact.identifier })
        #expect(companionManager.memoryIndex.entry(id: extractorProducedFact.identifier) == nil)
        #expect(!Self.anyContains(try Self.durableSinkTexts(companionManager), Self.secretSentinelCore))
    }

    @Test("In a mixed batch the safe fact survives unchanged in every sink and the credential-bearing fact is dropped")
    func mixedBatchKeepsSafeFactAndDropsCredentialFact() throws {
        let companionManager = CompanionManager()
        let marker = Self.uniqueMarker()
        let safeFact = Self.makeFact(subject: "user", predicate: "prefers \(marker)", value: "oolong tea")
        let credentialBearingFact = Self.makeFact(subject: "user", predicate: "stores \(marker)", value: Self.apiKeyShapedSentinel)

        companionManager.recordExtractedEpisodicFacts([credentialBearingFact, safeFact], turnId: "turn-f03")

        // Safe fact: stored byte-for-byte and written to both indexes in the existing shape.
        #expect(companionManager.episodicFactStore.allFacts.contains(safeFact))
        #expect(companionManager.localRetriever.documents(forSource: .episodicMemory)
            .contains(PaceEpisodicPatternFactExtractor.retrievalDocument(for: safeFact)))
        let safeUnifiedEntry = try #require(companionManager.memoryIndex.entry(id: safeFact.identifier))
        #expect(safeUnifiedEntry.text == "user prefers \(marker) oolong tea")
        #expect(safeUnifiedEntry.structured == ["subject": "user", "predicate": "prefers \(marker)", "value": "oolong tea"])
        #expect(safeUnifiedEntry.confidence == safeFact.confidence)
        #expect(safeUnifiedEntry.topicTags == safeFact.topicHashtags)
        #expect(safeUnifiedEntry.isActive)

        // Credential-bearing fact: nowhere.
        #expect(!companionManager.episodicFactStore.allFacts.contains { $0.identifier == credentialBearingFact.identifier })
        #expect(!companionManager.localRetriever.documents(forSource: .episodicMemory).contains { $0.id == credentialBearingFact.identifier })
        #expect(companionManager.memoryIndex.entry(id: credentialBearingFact.identifier) == nil)
        #expect(!Self.anyContains(try Self.durableSinkTexts(companionManager), Self.secretSentinelCore))
    }

    @Test("A dropped fact never reaches the planner's LOCAL CONTEXT block; the safe fact from the same batch does")
    func droppedFactNeverReachesLocalContext() throws {
        let companionManager = CompanionManager()
        let marker = Self.uniqueMarker()
        let safeFact = Self.makeFact(subject: "user", predicate: "prefers", value: "oolong \(marker)")
        let credentialBearingFact = Self.makeFact(subject: "user", predicate: "stores \(marker)", value: Self.apiKeyShapedSentinel)

        companionManager.recordExtractedEpisodicFacts([safeFact, credentialBearingFact], turnId: "turn-f03")

        let queryTexts = [
            "what does the user prefer \(marker)",
            "user stores \(marker) \(Self.apiKeyShapedSentinel)",
            Self.secretSentinelCore,
        ]
        var contextBlocks: [String] = []
        for queryText in queryTexts {
            if let contextBlock = companionManager.localRetriever.localContextBlock(for: PaceRetrievalQuery(text: queryText, maximumResultCount: 8)) {
                contextBlocks.append(contextBlock)
            }
        }
        #expect(!Self.anyContains(contextBlocks, Self.secretSentinelCore))
        // Positive control: retrieval is live, so the absence above is meaningful.
        #expect(Self.anyContains(contextBlocks, "oolong \(marker)"))
    }

    // MARK: - Direct ingestion, bypassing CompanionManager and conversation-turn redaction

    @Test("PaceEpisodicFactStore rejects a credential-bearing fact handed to it directly")
    func factStoreRejectsDirectIngestion() {
        let store = PaceEpisodicFactStore()
        let safeFact = Self.makeFact(subject: "user", predicate: "prefers", value: "dark mode")
        let credentialBearingFact = Self.makeFact(subject: "user", predicate: "uses key", value: Self.apiKeyShapedSentinel)

        #expect(store.apply(credentialBearingFact) == .rejectedBecauseOfCredentialShapedContent)
        let batchOutcomes = store.applyBatch([credentialBearingFact, safeFact]).map { $0.1 }
        #expect(batchOutcomes == [.rejectedBecauseOfCredentialShapedContent, .inserted])

        #expect(store.allFacts == [safeFact])
        #expect(store.factsForInjection(includeSensitiveTopics: true) == [safeFact])
        #expect(store.allTombstones.isEmpty)
    }

    @Test("PaceLocalRetriever.recordEpisodicFacts drops a credential-bearing fact handed to it directly")
    func retrieverRejectsDirectIngestion() {
        let retrievalStore = PaceInMemoryRetrievalStore()
        let retriever = PaceLocalRetriever(store: retrievalStore, appliesPersistedSourcePreferences: false)
        let marker = Self.uniqueMarker()
        let safeFact = Self.makeFact(subject: "user", predicate: "prefers", value: "oolong \(marker)")
        let credentialBearingFact = Self.makeFact(subject: "user", predicate: "stores \(marker)", value: Self.apiKeyShapedSentinel)

        retriever.recordEpisodicFacts([credentialBearingFact])
        #expect(retriever.documents(forSource: .episodicMemory).isEmpty)

        retriever.recordEpisodicFacts([credentialBearingFact, safeFact])
        #expect(retriever.documents(forSource: .episodicMemory) == [PaceEpisodicPatternFactExtractor.retrievalDocument(for: safeFact)])
        let contextBlock = retriever.localContextBlock(for: PaceRetrievalQuery(text: "user stores \(marker) \(Self.secretSentinelCore)", maximumResultCount: 8))
        #expect(!(contextBlock ?? "").contains(Self.secretSentinelCore))
    }

    @Test("CompanionManager.upsertUnifiedMemoryFacts drops a credential-bearing fact handed to it directly")
    func unifiedMemoryRejectsDirectIngestion() throws {
        let companionManager = CompanionManager()
        let safeFact = Self.makeFact(subject: "user", predicate: "prefers \(Self.uniqueMarker())", value: "oolong tea")
        let credentialBearingFact = Self.makeFact(subject: "user", predicate: "uses key", value: Self.apiKeyShapedSentinel)

        companionManager.upsertUnifiedMemoryFacts([credentialBearingFact, safeFact], replacedPreviousFactIds: [])

        #expect(companionManager.memoryIndex.entry(id: credentialBearingFact.identifier) == nil)
        #expect(companionManager.memoryIndex.entry(id: safeFact.identifier) != nil)
        #expect(!Self.anyContains(try Self.durableSinkTexts(companionManager), Self.secretSentinelCore))
    }

    // MARK: - Restart / reload

    @Test("Reloading the persisted indexes after a drop does not resurrect the fact")
    func reloadDoesNotResurrectDroppedFact() throws {
        let marker = Self.uniqueMarker()
        let safeFact = Self.makeFact(subject: "user", predicate: "prefers \(marker)", value: "oolong tea")
        let credentialBearingFact = Self.makeFact(subject: "user", predicate: "stores \(marker)", value: Self.apiKeyShapedSentinel)
        let firstCompanionManager = CompanionManager()
        firstCompanionManager.recordExtractedEpisodicFacts([credentialBearingFact, safeFact], turnId: "turn-f03")
        firstCompanionManager.localRetriever.recordEpisodicFacts([credentialBearingFact])
        firstCompanionManager.upsertUnifiedMemoryFacts([credentialBearingFact], replacedPreviousFactIds: [])

        // A relaunch: fresh objects that load only what is on disk.
        let retrievalIndexFileURL = try #require(PaceLocalRetriever.defaultPersistenceURL())
        let reloadedRetrievalStore = PaceInMemoryRetrievalStore(persistenceURL: retrievalIndexFileURL)
        let reloadedEpisodicDocuments = reloadedRetrievalStore.documents(withSource: .episodicMemory)
        #expect(!reloadedEpisodicDocuments.contains { $0.id == credentialBearingFact.identifier })
        #expect(!Self.anyContains([try Self.jsonText(reloadedEpisodicDocuments)], Self.secretSentinelCore))
        // Positive control: the reload really read the file the first manager wrote.
        #expect(reloadedEpisodicDocuments.contains { $0.id == safeFact.identifier })

        let relaunchedCompanionManager = CompanionManager()
        relaunchedCompanionManager.restoreUnifiedMemory()
        #expect(relaunchedCompanionManager.memoryIndex.entry(id: credentialBearingFact.identifier) == nil)
        #expect(relaunchedCompanionManager.memoryIndex.entry(id: safeFact.identifier) != nil)
        #expect(!relaunchedCompanionManager.localRetriever.documents(forSource: .episodicMemory).contains { $0.id == credentialBearingFact.identifier })
        #expect(relaunchedCompanionManager.episodicFactStore.allFacts.isEmpty)
        #expect(!Self.anyContains(try Self.durableSinkTexts(relaunchedCompanionManager), Self.secretSentinelCore))
    }

    // MARK: - Existing behavior is intact

    @Test("Normal facts keep their existing confidence threshold, insert, replace, and append behavior")
    func normalFactsRetainExistingBehavior() throws {
        let companionManager = CompanionManager()
        let marker = Self.uniqueMarker()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let originalFact = Self.makeFact(subject: "user", predicate: "lives in \(marker)", value: "Lisbon", confidence: 0.85, extractedAt: baseTime)
        let lowConfidenceFact = Self.makeFact(subject: "user", predicate: "maybe likes \(marker)", value: "jazz", confidence: 0.69, extractedAt: baseTime)
        companionManager.recordExtractedEpisodicFacts([originalFact, lowConfidenceFact], turnId: "turn-f03")

        #expect(companionManager.episodicFactStore.allFacts == [originalFact])
        #expect(companionManager.memoryIndex.entry(id: lowConfidenceFact.identifier) == nil)

        // Newer + close confidence → replaced; the previous row leaves both indexes.
        let refreshedFact = Self.makeFact(subject: "user", predicate: "lives in \(marker)", value: "Porto", confidence: 0.88, extractedAt: baseTime.addingTimeInterval(60))
        companionManager.recordExtractedEpisodicFacts([refreshedFact], turnId: "turn-f03")
        #expect(companionManager.episodicFactStore.allFacts == [refreshedFact])
        let episodicDocumentIds = companionManager.localRetriever.documents(forSource: .episodicMemory).map(\.id)
        #expect(episodicDocumentIds.contains(refreshedFact.identifier))
        #expect(!episodicDocumentIds.contains(originalFact.identifier))
        #expect(companionManager.memoryIndex.entry(id: originalFact.identifier)?.isActive == false)
        #expect(companionManager.memoryIndex.entry(id: refreshedFact.identifier)?.isActive == true)

        // Large confidence gap → appended alongside.
        let distantConfidenceFact = Self.makeFact(subject: "user", predicate: "lives in \(marker)", value: "Faro", confidence: 0.72, extractedAt: baseTime.addingTimeInterval(120))
        companionManager.recordExtractedEpisodicFacts([distantConfidenceFact], turnId: "turn-f03")
        #expect(companionManager.episodicFactStore.allFacts == [refreshedFact, distantConfidenceFact])
    }

    @Test("A rejected fact does not replace a same-key fact, create a tombstone, or disturb tombstone gating")
    func rejectedFactLeavesDedupAndTombstonesIntact() {
        let clockTime = Date(timeIntervalSince1970: 1_700_000_000)
        let store = PaceEpisodicFactStore(now: { clockTime })
        let existingFact = Self.makeFact(subject: "user", predicate: "uses", value: "the staging cluster", confidence: 0.85, extractedAt: clockTime)
        #expect(store.apply(existingFact) == .inserted)

        // Same (subject, predicate), newer, close confidence: would be `.replaced` if it were clean.
        let credentialBearingRefresh = Self.makeFact(subject: "user", predicate: "uses", value: Self.apiKeyShapedSentinel, confidence: 0.86, extractedAt: clockTime.addingTimeInterval(60))
        #expect(store.apply(credentialBearingRefresh) == .rejectedBecauseOfCredentialShapedContent)
        #expect(store.allFacts == [existingFact])
        #expect(store.allTombstones.isEmpty)

        // The clean equivalent still replaces, and tombstones still block re-insertion.
        let cleanRefresh = Self.makeFact(subject: "user", predicate: "uses", value: "the production cluster", confidence: 0.86, extractedAt: clockTime.addingTimeInterval(120))
        #expect(store.apply(cleanRefresh) == .replaced(previousFactId: existingFact.identifier))
        #expect(store.deleteFact(withIdentifier: cleanRefresh.identifier) != nil)
        let reExtractedFact = Self.makeFact(subject: "user", predicate: "uses", value: "the production cluster", confidence: 0.86, extractedAt: clockTime.addingTimeInterval(180))
        #expect(store.apply(reExtractedFact) == .skippedBecauseOfTombstone)
        #expect(store.allFacts.isEmpty)
        #expect(store.allTombstones.count == 1)
    }

    @Test("A rejected fact does not evict anything from a store at the LRU cap, and the cap still evicts the oldest")
    func rejectedFactLeavesLRUCapIntact() {
        let store = PaceEpisodicFactStore()
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let maximumStoredFactCount = PaceEpisodicMemoryLimits.maximumStoredFactCount
        var storedFacts: [PaceEpisodicFact] = []
        for factIndex in 0..<maximumStoredFactCount {
            let fact = Self.makeFact(
                subject: "topic \(factIndex)",
                predicate: "is",
                value: "value \(factIndex)",
                extractedAt: baseTime.addingTimeInterval(TimeInterval(factIndex)),
                identifier: "episodic-f03-lru-\(factIndex)"
            )
            storedFacts.append(fact)
            store.apply(fact)
        }
        #expect(store.allFacts == storedFacts)

        let credentialBearingFact = Self.makeFact(
            subject: "newest topic",
            predicate: "is",
            value: Self.apiKeyShapedSentinel,
            extractedAt: baseTime.addingTimeInterval(TimeInterval(maximumStoredFactCount + 1))
        )
        #expect(store.apply(credentialBearingFact) == .rejectedBecauseOfCredentialShapedContent)
        #expect(store.allFacts == storedFacts)

        let cleanNewestFact = Self.makeFact(
            subject: "newest topic",
            predicate: "is",
            value: "clean",
            extractedAt: baseTime.addingTimeInterval(TimeInterval(maximumStoredFactCount + 2))
        )
        #expect(store.apply(cleanNewestFact) == .inserted)
        #expect(store.allFacts == Array(storedFacts.dropFirst()) + [cleanNewestFact])
    }

    // MARK: - Known limit (recorded explicitly)

    @Test("Known limit: a plain secret with no credential shape in a fact is NOT detected")
    func plainSecretWithoutCredentialShapeIsAKnownLimit() {
        let store = PaceEpisodicFactStore()
        let plainSecretFact = Self.makeFact(subject: "wifi", predicate: "passphrase is", value: Self.plainSecretSentinel)

        // Documented gap, the same one PaceDurableConversationRedactionTests records for turns:
        // credential-SHAPE detection cannot recognize this. Provenance-based gating is the follow-up.
        #expect(!PaceDurableConversationContent.episodicFactContainsCredentialShapedContent(plainSecretFact))
        #expect(store.apply(plainSecretFact) == .inserted)
    }
}
