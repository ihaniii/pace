//
//  PaceCompanionServerTransport.swift
//  leanring-buddy
//
//  The seams between `PaceCompanionServer` and the things it must not reach
//  for implicitly: the network listener, an inbound connection, and the
//  Keychain. The server's admission and pairing decisions run against these
//  protocols, so they can be exercised in the unit-test host — where the
//  production listener and Keychain are deliberately unavailable (F-04a).
//

import Foundation
import Network

/// One inbound companion connection as the server sees it.
@MainActor
protocol PaceCompanionServerConnection: AnyObject {
    var onStateChange: ((PaceCompanionFramedConnection.State) -> Void)? { get set }
    var onFrameReceived: ((PaceCompanionWireFrame) -> Void)? { get set }
    func start()
    func send(_ frame: PaceCompanionWireFrame) throws
    func cancel()
}

extension PaceCompanionFramedConnection: PaceCompanionServerConnection {}

enum PaceCompanionServerListenerState: Equatable {
    case waiting
    case ready
    case failed(String)
    case cancelled
}

/// The companion listener (and its Bonjour advertisement) as the server sees it.
@MainActor
protocol PaceCompanionServerListener: AnyObject {
    var onNewConnection: ((PaceCompanionServerConnection) -> Void)? { get set }
    var onStateChange: ((PaceCompanionServerListenerState) -> Void)? { get set }
    func start()
    func cancel()
}

typealias PaceCompanionServerListenerFactory =
    @MainActor ([PaceCompanionTLSMaterial]) throws -> PaceCompanionServerListener

enum PaceCompanionServerListenerError: Error, Equatable, LocalizedError {
    case unavailableInUnitTestHost
    case noAuthenticationMaterial

    var errorDescription: String? {
        switch self {
        case .unavailableInUnitTestHost:
            return "The companion listener is not available in a unit-test host."
        case .noAuthenticationMaterial:
            return "The companion listener has no pairing or device key to accept."
        }
    }
}

/// The real Bonjour-advertised TLS-PSK listener. Binding and TLS parameters
/// are unchanged from before F-04a (`PaceCompanionTLSParameters`); only WHEN a
/// listener exists, and with which keys, changed.
@MainActor
final class PaceCompanionNetworkListener: PaceCompanionServerListener {
    var onNewConnection: ((PaceCompanionServerConnection) -> Void)?
    var onStateChange: ((PaceCompanionServerListenerState) -> Void)?

    private let listener: NWListener
    private let listenerQueue = DispatchQueue(
        label: "com.pace.companion-server.listener",
        qos: .userInitiated
    )

    /// The only production way to create a listener. Refuses in a unit-test
    /// host, and refuses to listen with no key at all — a listener that no
    /// peer could authenticate to is pure exposure.
    static func makeProductionListener(
        materials: [PaceCompanionTLSMaterial]
    ) throws -> PaceCompanionServerListener {
        guard !PaceTestHostDataIsolation.isRunningUnderTestHost else {
            throw PaceCompanionServerListenerError.unavailableInUnitTestHost
        }
        guard !materials.isEmpty else {
            throw PaceCompanionServerListenerError.noAuthenticationMaterial
        }
        return try PaceCompanionNetworkListener(materials: materials)
    }

    private init(materials: [PaceCompanionTLSMaterial]) throws {
        listener = try NWListener(using: PaceCompanionTLSParameters.make(materials: materials))
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Que on Mac",
            type: PaceCompanionProtocol.bonjourServiceType
        )
    }

    func start() {
        listener.newConnectionHandler = { [weak self] newConnection in
            Task { @MainActor [weak self] in
                guard let self else {
                    newConnection.cancel()
                    return
                }
                onNewConnection?(
                    PaceCompanionFramedConnection(
                        connection: newConnection,
                        queueLabel: "com.pace.companion-server.connection"
                    ))
            }
        }
        listener.stateUpdateHandler = { [weak self] listenerState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch listenerState {
                case .ready:
                    onStateChange?(.ready)
                case .failed(let error):
                    onStateChange?(.failed(error.localizedDescription))
                case .cancelled:
                    onStateChange?(.cancelled)
                case .setup, .waiting:
                    onStateChange?(.waiting)
                @unknown default:
                    onStateChange?(.failed("Unknown Bonjour listener state"))
                }
            }
        }
        listener.start(queue: listenerQueue)
    }

    func cancel() {
        listener.cancel()
    }
}

/// Where the Mac keeps the paired iPad's credential.
@MainActor
protocol PaceCompanionCredentialStoring: AnyObject {
    func loadCredential() -> PaceCompanionStoredCredential?
    func storeCredential(_ storedCredential: PaceCompanionStoredCredential) -> Bool
    func deleteCredential() -> Bool
}

/// The production store: the same Keychain item as before F-04a. Inert in a
/// unit-test host, so tests never read or overwrite the user's real pairing.
@MainActor
final class PaceCompanionKeychainCredentialStore: PaceCompanionCredentialStoring {
    private static let keychainServiceIdentifier = "com.pace.app.companion"
    private static let keychainAccountName = "paired-ipad"

    func loadCredential() -> PaceCompanionStoredCredential? {
        guard !PaceTestHostDataIsolation.isRunningUnderTestHost else { return nil }
        return PaceCompanionKeychain.load(
            serviceIdentifier: Self.keychainServiceIdentifier,
            accountName: Self.keychainAccountName
        )
    }

    func storeCredential(_ storedCredential: PaceCompanionStoredCredential) -> Bool {
        guard !PaceTestHostDataIsolation.isRunningUnderTestHost else { return false }
        return PaceCompanionKeychain.store(
            storedCredential,
            serviceIdentifier: Self.keychainServiceIdentifier,
            accountName: Self.keychainAccountName
        )
    }

    func deleteCredential() -> Bool {
        guard !PaceTestHostDataIsolation.isRunningUnderTestHost else { return true }
        return PaceCompanionKeychain.delete(
            serviceIdentifier: Self.keychainServiceIdentifier,
            accountName: Self.keychainAccountName
        )
    }
}
