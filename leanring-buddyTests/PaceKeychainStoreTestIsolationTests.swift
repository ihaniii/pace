//
//  PaceKeychainStoreTestIsolationTests.swift
//  leanring-buddyTests
//
//  Proves unit tests can never read, overwrite, or delete the user's real
//  Pace API keys. Before this, PaceKeychainStoreTests' wipe-all and the
//  Direct API client tests operated directly on the production service
//  `com.pace.app.plannerAPIKeys` in the user's login keychain.
//
//  In a test host every PaceKeychainStore query resolves to the test-only
//  service `com.pace.app.unittest.plannerAPIKeys`. These tests use the real
//  Keychain (real SecItem semantics) in that namespace, and inspect the
//  production service by ATTRIBUTES ONLY — existence and modification date,
//  never `kSecReturnData` — so no real secret is ever read.
//
//  Synchronous and @MainActor, and limited to the `.openrouter`/`.custom`
//  accounts, so they cannot interleave with the async Direct API tests
//  (which use `.openai`/`.anthropic`) in the shared test namespace.
//

import Foundation
import Security
import Testing
@testable import Pace

@MainActor
@Suite("PaceKeychainStore test isolation", .serialized)
struct PaceKeychainStoreTestIsolationTests {

    /// Existence + modification date of one generic-password item, read via
    /// attributes only. Never requests the item's data.
    private struct KeychainItemAttributesSnapshot: Equatable {
        let exists: Bool
        let modificationDate: Date?
    }

    private static func attributesSnapshot(service: String, provider: PaceDirectAPIProvider) -> KeychainItemAttributesSnapshot {
        let attributesOnlyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: PaceKeychainStore.keychainAccountName(for: provider),
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var returnedAttributes: AnyObject?
        let status = SecItemCopyMatching(attributesOnlyQuery as CFDictionary, &returnedAttributes)
        guard status == errSecSuccess, let attributes = returnedAttributes as? [String: Any] else {
            return KeychainItemAttributesSnapshot(exists: false, modificationDate: nil)
        }
        return KeychainItemAttributesSnapshot(
            exists: true,
            modificationDate: attributes[kSecAttrModificationDate as String] as? Date
        )
    }

    private static func productionAttributesForEveryProvider() -> [PaceDirectAPIProvider: KeychainItemAttributesSnapshot] {
        var snapshot: [PaceDirectAPIProvider: KeychainItemAttributesSnapshot] = [:]
        for provider in PaceDirectAPIProvider.allCases {
            snapshot[provider] = attributesSnapshot(service: PaceKeychainStore.serviceIdentifier, provider: provider)
        }
        return snapshot
    }

    // MARK: - Resolution

    @Test("In a test host every query resolves to the test-only service, never production")
    func activeServiceIsTheTestNamespace() {
        #expect(PaceKeychainStore.serviceIdentifier == "com.pace.app.plannerAPIKeys")
        #expect(PaceKeychainStore.unitTestServiceIdentifier == "com.pace.app.unittest.plannerAPIKeys")
        #expect(PaceKeychainStore.unitTestServiceIdentifier != PaceKeychainStore.serviceIdentifier)
        #expect(PaceTestHostDataIsolation.isRunningUnderTestHost)
        #expect(PaceKeychainStore.activeServiceIdentifier == PaceKeychainStore.unitTestServiceIdentifier)
        #expect(PaceKeychainStore.activeServiceIdentifier != PaceKeychainStore.serviceIdentifier)
    }

    @Test("Without a test host the production service is resolved unchanged")
    func productionResolutionIsUnchanged() {
        #expect(PaceKeychainStore.resolveServiceIdentifier(isRunningUnderTestHost: false) == "com.pace.app.plannerAPIKeys")
        #expect(PaceKeychainStore.resolveServiceIdentifier(isRunningUnderTestHost: true) == "com.pace.app.unittest.plannerAPIKeys")
    }

    // MARK: - Real Keychain semantics in the test namespace

    @Test("Store, load, overwrite, and delete land in the test service only")
    func roundTripLandsInTestServiceOnly() {
        let productionBefore = Self.productionAttributesForEveryProvider()
        defer { _ = PaceKeychainStore.deleteAPIKey(for: .custom) }

        let firstValue = "sk-isolation-\(UUID().uuidString)"
        let secondValue = "sk-isolation-\(UUID().uuidString)"
        #expect(PaceKeychainStore.storeAPIKey(firstValue, for: .custom))
        #expect(PaceKeychainStore.loadAPIKey(for: .custom) == firstValue)
        #expect(PaceKeychainStore.storeAPIKey(secondValue, for: .custom))
        #expect(PaceKeychainStore.loadAPIKey(for: .custom) == secondValue)

        #expect(Self.attributesSnapshot(service: PaceKeychainStore.unitTestServiceIdentifier, provider: .custom).exists)

        #expect(PaceKeychainStore.deleteAPIKey(for: .custom))
        #expect(PaceKeychainStore.loadAPIKey(for: .custom) == nil)
        #expect(!Self.attributesSnapshot(service: PaceKeychainStore.unitTestServiceIdentifier, provider: .custom).exists)

        #expect(Self.productionAttributesForEveryProvider() == productionBefore)
    }

    @Test("Destructive store/delete cycles leave every production item exactly as it was")
    func destructiveCycleLeavesProductionUntouched() {
        let productionBefore = Self.productionAttributesForEveryProvider()
        defer {
            _ = PaceKeychainStore.deleteAPIKey(for: .openrouter)
            _ = PaceKeychainStore.deleteAPIKey(for: .custom)
        }

        // The same operations PaceKeychainStoreTests' wipe-all and the Direct
        // API fixture perform — against the accounts this suite owns.
        for provider in [PaceDirectAPIProvider.openrouter, .custom] {
            _ = PaceKeychainStore.deleteAPIKey(for: provider)
            #expect(PaceKeychainStore.storeAPIKey("sk-isolation-\(UUID().uuidString)", for: provider))
            #expect(PaceKeychainStore.storeAPIKey("sk-isolation-\(UUID().uuidString)", for: provider))
            #expect(PaceKeychainStore.deleteAPIKey(for: provider))
            #expect(PaceKeychainStore.deleteAPIKey(for: provider))
        }

        #expect(Self.productionAttributesForEveryProvider() == productionBefore)
    }
}
