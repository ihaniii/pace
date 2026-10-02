//
//  PaceCompanionServerHardeningTests.swift
//  leanring-buddyTests
//
//  F-04a: the iPad companion server's listener exposure and pairing lifecycle.
//
//  These tests drive the REAL `PaceCompanionServer` — its opt-in gate, pairing
//  window, Mac-side confirmation, and connection admission all run for real.
//  Only the three things a unit-test host must not touch are substituted, at
//  the seams in `PaceCompanionServerTransport.swift`: the network listener,
//  the inbound connection, and the Keychain. (The production listener refuses
//  to exist in a test host; that refusal is itself asserted below.)
//
//  Only synthetic credentials and identifiers are used.
//

import AppKit
import Foundation
import Network
import Testing
@testable import Pace

// MARK: - Transport substitutes

@MainActor
private final class RecordingCompanionConnection: PaceCompanionServerConnection {
    var onStateChange: ((PaceCompanionFramedConnection.State) -> Void)?
    var onFrameReceived: ((PaceCompanionWireFrame) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var sentFrames: [PaceCompanionWireFrame] = []

    func start() { startCount += 1 }
    func send(_ frame: PaceCompanionWireFrame) throws { sentFrames.append(frame) }
    func cancel() { cancelCount += 1 }

    func simulate(_ state: PaceCompanionFramedConnection.State) { onStateChange?(state) }

    func receive(_ payload: PaceCompanionMessagePayload, sessionIdentifier: String) {
        onFrameReceived?(
            PaceCompanionWireFrame(
                message: PaceCompanionMessage(payload: payload, sessionIdentifier: sessionIdentifier)
            ))
    }

    var sentErrorCodes: [String] {
        sentFrames.compactMap { frame in
            if case .error(let errorMessage) = frame.message.payload { return errorMessage.code }
            return nil
        }
    }

    var sentPairResponses: [PaceCompanionPairResponse] {
        sentFrames.compactMap { frame in
            if case .pairResponse(let pairResponse) = frame.message.payload { return pairResponse }
            return nil
        }
    }

    var sentHeartbeats: [PaceCompanionHeartbeat] {
        sentFrames.compactMap { frame in
            if case .heartbeat(let heartbeat) = frame.message.payload { return heartbeat }
            return nil
        }
    }
}

@MainActor
private final class RecordingCompanionListener: PaceCompanionServerListener {
    var onNewConnection: ((PaceCompanionServerConnection) -> Void)?
    var onStateChange: ((PaceCompanionServerListenerState) -> Void)?
    let materials: [PaceCompanionTLSMaterial]
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    init(materials: [PaceCompanionTLSMaterial]) { self.materials = materials }

    func start() { startCount += 1 }
    func cancel() { cancelCount += 1 }

    /// Listening (and advertising over Bonjour) right now.
    var isListening: Bool { startCount > 0 && cancelCount == 0 }

    func simulateInboundConnection(_ connection: PaceCompanionServerConnection) {
        onNewConnection?(connection)
    }
}

@MainActor
private final class InMemoryCompanionCredentialStore: PaceCompanionCredentialStoring {
    var storedCredential: PaceCompanionStoredCredential?
    var storeSucceeds = true
    private(set) var storeCallCount = 0
    private(set) var deleteCallCount = 0

    func loadCredential() -> PaceCompanionStoredCredential? { storedCredential }

    func storeCredential(_ storedCredential: PaceCompanionStoredCredential) -> Bool {
        storeCallCount += 1
        guard storeSucceeds else { return false }
        self.storedCredential = storedCredential
        return true
    }

    func deleteCredential() -> Bool {
        deleteCallCount += 1
        storedCredential = nil
        return true
    }
}

// MARK: - Harness

@MainActor
private final class CompanionServerHarness {
    static let serverIdentifier = "f04a-test-server"
    static let pairedDeviceIdentifier = "f04a-test-paired-device"
    static let pairedDeviceName = "Synthetic Paired iPad"
    /// 32 synthetic bytes, base64 — never a real credential.
    static let syntheticCredential = Data(repeating: 0x5A, count: 32).base64EncodedString()

    private let userDefaultsSuiteName = "f04a-companion-server-tests-\(UUID().uuidString)"
    let userDefaults: UserDefaults
    let credentialStore = InMemoryCompanionCredentialStore()
    let companionManager = CompanionManager()
    private(set) var createdListeners: [RecordingCompanionListener] = []
    var currentTime = Date(timeIntervalSince1970: 1_800_000_000)

    init(isCompanionEnabled: Bool, hasPairedDevice: Bool) {
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
        userDefaults.set(Self.serverIdentifier, forKey: PaceCompanionServer.serverIdentifierDefaultsKey)
        if isCompanionEnabled {
            userDefaults.set(true, forKey: PaceCompanionServer.companionEnabledDefaultsKey)
        }
        if hasPairedDevice {
            credentialStore.storedCredential = PaceCompanionStoredCredential(
                remoteIdentifier: Self.pairedDeviceIdentifier,
                remoteName: Self.pairedDeviceName,
                localDeviceIdentifier: Self.serverIdentifier,
                credential: Self.syntheticCredential
            )
        }
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    /// A server over the same persisted state — a fresh one models a relaunch.
    func makeServer() -> PaceCompanionServer {
        PaceCompanionServer(
            userDefaults: userDefaults,
            credentialStore: credentialStore,
            listenerFactory: { [unowned self] materials in
                let listener = RecordingCompanionListener(materials: materials)
                createdListeners.append(listener)
                return listener
            },
            serverDisplayName: "Synthetic Mac",
            now: { [unowned self] in currentTime }
        )
    }

    func makeStartedServer() -> PaceCompanionServer {
        let server = makeServer()
        server.start(companionManager: companionManager)
        return server
    }

    var listeningListeners: [RecordingCompanionListener] {
        createdListeners.filter(\.isListening)
    }

    func advanceTime(bySeconds seconds: TimeInterval) {
        currentTime = currentTime.addingTimeInterval(seconds)
    }

    /// A new inbound connection delivered by the listener that is listening now.
    func connectInbound() throws -> RecordingCompanionConnection {
        let listener = try #require(listeningListeners.last)
        let connection = RecordingCompanionConnection()
        listener.simulateInboundConnection(connection)
        connection.simulate(.ready)
        return connection
    }

    func validSessionHello(sessionIdentifier: String) throws -> PaceCompanionMessagePayload {
        let proof = try #require(
            PaceCompanionSecurity.sessionAuthenticationProof(
                credential: Self.syntheticCredential,
                serverIdentifier: Self.serverIdentifier,
                deviceIdentifier: Self.pairedDeviceIdentifier,
                sessionIdentifier: sessionIdentifier
            ))
        return .sessionHello(
            PaceCompanionSessionHello(
                deviceIdentifier: Self.pairedDeviceIdentifier,
                deviceName: Self.pairedDeviceName,
                authenticationProof: proof
            ))
    }

    /// The paired device connecting and proving its credential.
    func connectAuthenticatedSession(sessionIdentifier: String) throws -> RecordingCompanionConnection {
        let connection = try connectInbound()
        connection.receive(try validSessionHello(sessionIdentifier: sessionIdentifier), sessionIdentifier: sessionIdentifier)
        return connection
    }

    static func pairRequest(
        deviceIdentifier: String = "f04a-test-new-device",
        deviceName: String = "Synthetic New iPad"
    ) -> PaceCompanionMessagePayload {
        .pairRequest(PaceCompanionPairRequest(deviceIdentifier: deviceIdentifier, deviceName: deviceName))
    }

    static var pairedDeviceCredentialMaterial: PaceCompanionTLSMaterial? {
        PaceCompanionSecurity.credentialTLSMaterial(
            credential: syntheticCredential,
            deviceIdentifier: pairedDeviceIdentifier
        )
    }
}

@MainActor
private func isConnected(_ server: PaceCompanionServer) -> Bool {
    if case .connected = server.connectionStatus { return true }
    return false
}

// MARK: - Tests

@MainActor
@Suite("F-04a: companion listener exposure and pairing lifecycle", .serialized)
struct PaceCompanionServerHardeningTests {

    // MARK: Startup / exposure

    @Test("App launch with the companion disabled starts no listener, even with a paired device stored")
    func launchWithCompanionDisabledStartsNoListener() {
        let harness = CompanionServerHarness(isCompanionEnabled: false, hasPairedDevice: true)
        let server = harness.makeStartedServer()

        #expect(harness.createdListeners.isEmpty)
        #expect(server.isCompanionEnabled == false)
        #expect(server.connectionStatus == .stopped)
        #expect(server.pairingCode == nil)
    }

    @Test("With the companion enabled and a device paired, launch starts one listener carrying only that device's key")
    func enabledAndPairedLaunchStartsOneDeviceKeyListener() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()

        #expect(harness.createdListeners.count == 1)
        let listener = try #require(harness.listeningListeners.first)
        #expect(listener.materials == [try #require(CompanionServerHarness.pairedDeviceCredentialMaterial)])
        #expect(server.connectionStatus == .advertising)
        #expect(server.pairingCode == nil)
    }

    @Test("Enabled but unpaired with pairing closed: no key to accept, so no listener at all")
    func enabledUnpairedWithPairingClosedStartsNoListener() {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: false)
        let server = harness.makeStartedServer()

        #expect(harness.createdListeners.isEmpty)
        #expect(server.connectionStatus == .stopped)
    }

    @Test("The opt-in alone does not start a listener: the app must attach the server first")
    func enabledPreferenceWithoutStartCreatesNoListener() {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeServer()

        #expect(harness.createdListeners.isEmpty)
        // Not started, so explicit local actions cannot open exposure either.
        #expect(server.openPairingWindow(triggeringEvent: nil) == false)
        #expect(harness.createdListeners.isEmpty)
    }

    @Test("The production listener refuses to exist in the unit-test host")
    func productionListenerIsUnavailableInUnitTestHost() {
        #expect(PaceTestHostDataIsolation.isRunningUnderTestHost)
        let material = PaceCompanionTLSMaterial(preSharedKey: Data(repeating: 1, count: 32), identity: Data("f04a".utf8))
        #expect(throws: PaceCompanionServerListenerError.unavailableInUnitTestHost) {
            _ = try PaceCompanionNetworkListener.makeProductionListener(materials: [material])
        }
    }

    @Test("A server on the production listener path, enabled and paired, still has no listener in the unit-test host")
    func serverWithProductionListenerPathStaysClosedInUnitTestHost() {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = PaceCompanionServer(
            userDefaults: harness.userDefaults,
            credentialStore: harness.credentialStore,
            serverDisplayName: "Synthetic Mac"
        )
        server.start(companionManager: harness.companionManager)

        #expect(
            server.connectionStatus
                == .unavailable(PaceCompanionServerListenerError.unavailableInUnitTestHost.localizedDescription))
        server.stop()
        #expect(server.connectionStatus == .stopped)
    }

    @Test("The production Keychain store is inert in the unit-test host")
    func productionCredentialStoreIsInertInUnitTestHost() {
        let productionStore = PaceCompanionKeychainCredentialStore()
        #expect(productionStore.loadCredential() == nil)
        #expect(
            productionStore.storeCredential(
                PaceCompanionStoredCredential(
                    remoteIdentifier: "f04a-never-stored",
                    remoteName: "f04a-never-stored",
                    localDeviceIdentifier: "f04a-never-stored",
                    credential: CompanionServerHarness.syntheticCredential
                )) == false)
        #expect(productionStore.loadCredential() == nil)
    }

    @Test("Disabling the companion stops the listener, closes the session and any pairing window, and persists the opt-out")
    func disablingCompanionClosesEverything() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let sessionConnection = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")
        #expect(isConnected(server))
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let unauthenticatedConnection = try harness.connectInbound()

        server.setCompanionEnabled(false)

        #expect(harness.listeningListeners.isEmpty)
        #expect(sessionConnection.cancelCount == 1)
        #expect(unauthenticatedConnection.cancelCount == 1)
        #expect(server.connectionStatus == .stopped)
        #expect(server.pairingCode == nil)
        #expect(server.lastPairingWindowCloseReason == .companionDisabled)
        #expect(harness.userDefaults.bool(forKey: PaceCompanionServer.companionEnabledDefaultsKey) == false)
        // The pairing itself is not forgotten by an opt-out.
        #expect(harness.credentialStore.storedCredential != nil)
        // A closed session cannot be driven any more.
        let frameCountAfterDisable = sessionConnection.sentFrames.count
        sessionConnection.receive(.heartbeat(PaceCompanionHeartbeat(sequenceNumber: 1, acknowledgedSequenceNumber: nil)), sessionIdentifier: "session-1")
        #expect(sessionConnection.sentFrames.count == frameCountAfterDisable)
    }

    @Test("Enabling is the explicit lifecycle that starts the listener, and it persists")
    func enablingStartsTheListener() {
        let harness = CompanionServerHarness(isCompanionEnabled: false, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        #expect(harness.createdListeners.isEmpty)

        server.setCompanionEnabled(true)

        #expect(harness.listeningListeners.count == 1)
        #expect(harness.userDefaults.bool(forKey: PaceCompanionServer.companionEnabledDefaultsKey))
    }

    // MARK: Pairing window

    @Test("A pairing request while the pairing window is closed is refused and stores nothing")
    func pairingIsRefusedWhileWindowIsClosed() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let sessionConnection = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")

        // From an unauthenticated connection: refused and dropped.
        let unauthenticatedConnection = try harness.connectInbound()
        unauthenticatedConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-attempt")
        #expect(unauthenticatedConnection.sentErrorCodes == ["pairing_window_closed"])
        #expect(unauthenticatedConnection.cancelCount == 1)
        #expect(unauthenticatedConnection.sentPairResponses.isEmpty)

        // From the authenticated session itself: refused, session kept.
        sessionConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "session-1")
        #expect(sessionConnection.sentErrorCodes == ["pairing_window_closed"])
        #expect(sessionConnection.cancelCount == 0)

        #expect(server.pendingPairingConfirmation == nil)
        #expect(server.confirmPendingPairing(triggeringEvent: nil) == false)
        #expect(harness.credentialStore.storeCallCount == 0)
        #expect(harness.credentialStore.storedCredential?.credential == CompanionServerHarness.syntheticCredential)
        #expect(isConnected(server))
    }

    @Test("Only an explicit local action opens the pairing window; inbound traffic never does")
    func pairingWindowOpensOnlyThroughLocalAction() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let listenerCountBeforeTraffic = harness.createdListeners.count

        for attemptNumber in 0..<8 {
            let connection = try harness.connectInbound()
            connection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-attempt-\(attemptNumber)")
            connection.receive(.heartbeat(PaceCompanionHeartbeat(sequenceNumber: 1, acknowledgedSequenceNumber: nil)), sessionIdentifier: "x")
        }
        #expect(server.pairingCode == nil)
        #expect(server.pairingWindowExpiresAt == nil)
        // The listener was never rebuilt, so it never gained the pairing key.
        #expect(harness.createdListeners.count == listenerCountBeforeTraffic)

        #expect(server.openPairingWindow(triggeringEvent: nil))
        let openCode = try #require(server.pairingCode)
        #expect(PaceCompanionSecurity.normalizedPairingCode(openCode) == openCode)
        #expect(server.pairingWindowExpiresAt == harness.currentTime.addingTimeInterval(PaceCompanionPairingPolicy.pairingWindowDurationSeconds))
        let listener = try #require(harness.listeningListeners.last)
        #expect(listener.materials.contains(try #require(PaceCompanionSecurity.pairingTLSMaterial(pairingCode: openCode))))
        #expect(harness.listeningListeners.count == 1)
    }

    @Test("An input event Que synthesized itself can neither open pairing nor confirm a pairing")
    func selfSynthesizedInputCannotOpenOrConfirmPairing() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: false)
        let server = harness.makeStartedServer()
        let synthesizedMouseUp = try #require(
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: 1, y: 1), mouseButton: .left))
        let selfSynthesizedEvent = try #require(NSEvent(cgEvent: synthesizedMouseUp))
        #expect(PaceApprovalInputOrigin.verdict(forTriggeringEvent: selfSynthesizedEvent) == .rejectedSelfSynthesizedEvent)

        #expect(server.openPairingWindow(triggeringEvent: selfSynthesizedEvent) == false)
        #expect(server.pairingCode == nil)
        #expect(harness.createdListeners.isEmpty)

        #expect(server.openPairingWindow(triggeringEvent: nil))
        let pairingConnection = try harness.connectInbound()
        pairingConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-1")
        #expect(server.pendingPairingConfirmation != nil)

        #expect(server.confirmPendingPairing(triggeringEvent: selfSynthesizedEvent) == false)
        #expect(harness.credentialStore.storeCallCount == 0)
        #expect(pairingConnection.sentPairResponses.isEmpty)
        #expect(server.pendingPairingConfirmation != nil)
    }

    @Test("The pairing window expires, and the pairing key leaves the listener with it")
    func pairingWindowExpires() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let openCode = try #require(server.pairingCode)
        let pairingMaterial = try #require(PaceCompanionSecurity.pairingTLSMaterial(pairingCode: openCode))

        harness.advanceTime(bySeconds: PaceCompanionPairingPolicy.pairingWindowDurationSeconds - 1)
        server.enforceDeadlines()
        #expect(server.pairingCode == openCode)

        harness.advanceTime(bySeconds: 1)
        server.enforceDeadlines()

        #expect(server.pairingCode == nil)
        #expect(server.pairingWindowExpiresAt == nil)
        #expect(server.lastPairingWindowCloseReason == .expired)
        let listener = try #require(harness.listeningListeners.last)
        #expect(harness.listeningListeners.count == 1)
        #expect(!listener.materials.contains(pairingMaterial))
        #expect(listener.materials == [try #require(CompanionServerHarness.pairedDeviceCredentialMaterial)])
    }

    @Test("After expiry the pairing credential is unusable even before any sweep runs")
    func pairingRequestAfterExpiryIsRefusedWithoutASweep() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: false)
        let server = harness.makeStartedServer()
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let lateConnection = try harness.connectInbound()

        harness.advanceTime(bySeconds: PaceCompanionPairingPolicy.pairingWindowDurationSeconds)
        // No enforceDeadlines() call here: the request path must check for itself.
        lateConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-late")

        #expect(server.pendingPairingConfirmation == nil)
        #expect(server.pairingCode == nil)
        #expect(server.lastPairingWindowCloseReason == .expired)
        #expect(lateConnection.cancelCount == 1)
        #expect(lateConnection.sentPairResponses.isEmpty)
        #expect(server.confirmPendingPairing(triggeringEvent: nil) == false)
        #expect(harness.credentialStore.storeCallCount == 0)
        // Unpaired and pairing closed: nothing left to listen for.
        #expect(harness.listeningListeners.isEmpty)
    }

    @Test("A request waiting on confirmation is dropped when the window expires; confirming afterwards does nothing")
    func confirmationAfterExpiryDoesNothing() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: false)
        let server = harness.makeStartedServer()
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let pairingConnection = try harness.connectInbound()
        pairingConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-1")
        #expect(server.pendingPairingConfirmation != nil)

        harness.advanceTime(bySeconds: PaceCompanionPairingPolicy.pairingWindowDurationSeconds)
        #expect(server.confirmPendingPairing(triggeringEvent: nil) == false)

        #expect(server.pendingPairingConfirmation == nil)
        #expect(harness.credentialStore.storeCallCount == 0)
        #expect(pairingConnection.sentPairResponses.isEmpty)
        #expect(pairingConnection.sentErrorCodes == ["pairing_window_closed"])
        #expect(pairingConnection.cancelCount == 1)
        #expect(!isConnected(server))
    }

    @Test("The pairing window closes after a successful pairing, leaving only the new device's key")
    func pairingWindowClosesAfterSuccessfulPairing() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: false)
        let server = harness.makeStartedServer()
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let pairingConnection = try harness.connectInbound()
        pairingConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-1")
        #expect(server.confirmPendingPairing(triggeringEvent: nil))

        #expect(server.pairingCode == nil)
        #expect(server.lastPairingWindowCloseReason == .paired)
        let newStoredCredential = try #require(harness.credentialStore.storedCredential)
        let listener = try #require(harness.listeningListeners.last)
        #expect(harness.listeningListeners.count == 1)
        #expect(
            listener.materials == [
                try #require(
                    PaceCompanionSecurity.credentialTLSMaterial(
                        credential: newStoredCredential.credential,
                        deviceIdentifier: newStoredCredential.remoteIdentifier
                    ))
            ])
        // The paired connection outlives the listener refresh.
        #expect(pairingConnection.cancelCount == 0)
        #expect(isConnected(server))
    }

    @Test("The pairing window closes at the failed-attempt limit, and not before it")
    func pairingWindowClosesAtFailedAttemptLimit() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let attemptLimit = PaceCompanionPairingPolicy.maximumFailedPairingAttemptsPerWindow

        // Each kind of unauthenticated failure counts.
        let failedHandshake = try harness.connectInbound()
        failedHandshake.simulate(.failed("synthetic TLS failure"))
        let closedBeforeAuthenticating = try harness.connectInbound()
        closedBeforeAuthenticating.simulate(.cancelled)
        let badSessionProof = try harness.connectInbound()
        badSessionProof.receive(
            .sessionHello(PaceCompanionSessionHello(deviceIdentifier: CompanionServerHarness.pairedDeviceIdentifier, deviceName: "x", authenticationProof: "bm90LWEtcHJvb2Y=")),
            sessionIdentifier: "bad-proof")
        let idlePastDeadline = try harness.connectInbound()
        harness.advanceTime(bySeconds: PaceCompanionPairingPolicy.unauthenticatedConnectionDeadlineSeconds)
        server.enforceDeadlines()
        #expect(idlePastDeadline.cancelCount == 1)

        #expect(attemptLimit == 5)
        #expect(server.pairingCode != nil)
        #expect(server.lastPairingWindowCloseReason == nil)

        let bystander = try harness.connectInbound()
        let finalFailure = try harness.connectInbound()
        finalFailure.simulate(.failed("synthetic TLS failure"))

        #expect(server.pairingCode == nil)
        #expect(server.lastPairingWindowCloseReason == .tooManyFailedAttempts)
        // Everything admitted while the pairing key was on offer goes with it.
        #expect(bystander.cancelCount == 1)
        let listener = try #require(harness.listeningListeners.last)
        #expect(listener.materials == [try #require(CompanionServerHarness.pairedDeviceCredentialMaterial)])
        #expect(harness.credentialStore.storeCallCount == 0)

        // Closed means closed: a later request is refused.
        let afterLimit = try harness.connectInbound()
        afterLimit.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "after-limit")
        #expect(afterLimit.sentErrorCodes == ["pairing_window_closed"])
        #expect(server.pendingPairingConfirmation == nil)
    }

    @Test("Connections beyond the unauthenticated capacity are refused immediately")
    func unauthenticatedConnectionCapacityIsBounded() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        // Held for the whole test: the listener only reaches a live server.
        let server = harness.makeStartedServer()
        let capacity = PaceCompanionPairingPolicy.maximumUnauthenticatedConnectionCount
        let admittedConnections = try (0..<capacity).map { _ in try harness.connectInbound() }
        let overflowConnection = try harness.connectInbound()

        #expect(capacity == 4)
        #expect(admittedConnections.allSatisfy { $0.startCount == 1 && $0.cancelCount == 0 })
        #expect(overflowConnection.startCount == 0)
        #expect(overflowConnection.cancelCount == 1)
        #expect(server.connectionStatus == .advertising)
    }

    @Test("Cancelling closes the pairing window; denying a request closes it too")
    func cancellationAndDenialCloseThePairingWindow() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: false)
        let server = harness.makeStartedServer()

        #expect(server.openPairingWindow(triggeringEvent: nil))
        server.cancelPairingWindow()
        #expect(server.pairingCode == nil)
        #expect(server.lastPairingWindowCloseReason == .cancelled)
        #expect(harness.listeningListeners.isEmpty)

        #expect(server.openPairingWindow(triggeringEvent: nil))
        let pairingConnection = try harness.connectInbound()
        pairingConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-1")
        server.declinePendingPairing()

        #expect(server.pairingCode == nil)
        #expect(server.pendingPairingConfirmation == nil)
        #expect(server.lastPairingWindowCloseReason == .declined)
        #expect(pairingConnection.sentErrorCodes == ["pairing_declined"])
        #expect(pairingConnection.cancelCount == 1)
        #expect(pairingConnection.sentPairResponses.isEmpty)
        #expect(harness.credentialStore.storeCallCount == 0)
        #expect(harness.listeningListeners.isEmpty)
    }

    @Test("A relaunch never reopens a pairing window, and each window gets a fresh code")
    func relaunchDoesNotReopenPairingWindow() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let firstServer = harness.makeStartedServer()
        #expect(firstServer.openPairingWindow(triggeringEvent: nil))
        #expect(firstServer.pairingCode != nil)
        firstServer.stop()
        #expect(firstServer.pairingCode == nil)
        #expect(firstServer.lastPairingWindowCloseReason == .serverStopped)

        let relaunchedServer = harness.makeStartedServer()

        #expect(relaunchedServer.pairingCode == nil)
        #expect(relaunchedServer.pairingWindowExpiresAt == nil)
        #expect(relaunchedServer.pendingPairingConfirmation == nil)
        let listener = try #require(harness.listeningListeners.last)
        #expect(harness.listeningListeners.count == 1)
        #expect(listener.materials == [try #require(CompanionServerHarness.pairedDeviceCredentialMaterial)])
    }

    // MARK: Pairing authorization

    @Test("A first pairing stores and grants nothing until it is confirmed on the Mac")
    func firstPairingRequiresLocalConfirmation() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: false)
        let server = harness.makeStartedServer()
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let pairingConnection = try harness.connectInbound()
        pairingConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-1")

        // Awaiting confirmation: no credential, no session, no reply that grants anything.
        let confirmation = try #require(server.pendingPairingConfirmation)
        #expect(confirmation.deviceDisplayName == "Synthetic New iPad")
        #expect(confirmation.replacedPairedDeviceName == nil)
        #expect(harness.credentialStore.storeCallCount == 0)
        #expect(harness.credentialStore.storedCredential == nil)
        #expect(pairingConnection.sentFrames.isEmpty)
        #expect(!isConnected(server))
        #expect(server.pairedDeviceName == nil)
        // Still unauthenticated: a companion message is refused.
        pairingConnection.receive(.privacyStateChanged(PaceCompanionPrivacyState(isMicrophoneEnabled: true, isCameraEnabled: true, isSpeakerMuted: false, isAllCapturePaused: false)), sessionIdentifier: "pairing-1")
        #expect(pairingConnection.sentErrorCodes == ["authentication_required"])
        #expect(server.remotePrivacyState.isAllCapturePaused)

        #expect(server.confirmPendingPairing(triggeringEvent: nil))

        let storedCredential = try #require(harness.credentialStore.storedCredential)
        #expect(harness.credentialStore.storeCallCount == 1)
        #expect(storedCredential.remoteIdentifier == "f04a-test-new-device")
        #expect(storedCredential.localDeviceIdentifier == CompanionServerHarness.serverIdentifier)
        let pairResponse = try #require(pairingConnection.sentPairResponses.first)
        #expect(pairingConnection.sentPairResponses.count == 1)
        #expect(pairResponse.deviceCredential == storedCredential.credential)
        #expect(Data(base64Encoded: pairResponse.deviceCredential)?.count == PaceCompanionProtocol.credentialByteCount)
        #expect(pairResponse.serverIdentifier == CompanionServerHarness.serverIdentifier)
        #expect(server.connectionStatus == .connected(deviceName: "Synthetic New iPad"))
        #expect(server.pendingPairingConfirmation == nil)
        // A second confirmation has nothing to act on.
        #expect(server.confirmPendingPairing(triggeringEvent: nil) == false)
        #expect(harness.credentialStore.storeCallCount == 1)
    }

    @Test("Replacing a paired device requires confirmation; the existing pairing and session survive until it is given")
    func replacingAPairedDeviceRequiresLocalConfirmation() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let existingSession = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let replacementConnection = try harness.connectInbound()
        replacementConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-1")

        let confirmation = try #require(server.pendingPairingConfirmation)
        #expect(confirmation.replacedPairedDeviceName == CompanionServerHarness.pairedDeviceName)
        // Nothing replaced yet.
        #expect(harness.credentialStore.storedCredential?.credential == CompanionServerHarness.syntheticCredential)
        #expect(harness.credentialStore.storeCallCount == 0)
        #expect(existingSession.cancelCount == 0)
        #expect(server.connectionStatus == .connected(deviceName: CompanionServerHarness.pairedDeviceName))
        existingSession.receive(.heartbeat(PaceCompanionHeartbeat(sequenceNumber: 41, acknowledgedSequenceNumber: nil)), sessionIdentifier: "session-1")
        #expect(existingSession.sentHeartbeats.last?.acknowledgedSequenceNumber == 41)

        #expect(server.confirmPendingPairing(triggeringEvent: nil))

        #expect(harness.credentialStore.storedCredential?.remoteIdentifier == "f04a-test-new-device")
        #expect(harness.credentialStore.storedCredential?.credential != CompanionServerHarness.syntheticCredential)
        #expect(existingSession.cancelCount == 1)
        #expect(replacementConnection.cancelCount == 0)
        #expect(server.connectionStatus == .connected(deviceName: "Synthetic New iPad"))
        #expect(server.pairedDeviceName == "Synthetic New iPad")
    }

    @Test("A pairing that is denied, expires, or hits the attempt limit leaves the persisted pairing untouched")
    func failedPairingDoesNotModifyPersistedPairing() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let originalCredential = try #require(harness.credentialStore.storedCredential)

        // Denied.
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let deniedConnection = try harness.connectInbound()
        deniedConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-denied")
        server.declinePendingPairing()

        // Expired while waiting.
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let expiredConnection = try harness.connectInbound()
        expiredConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-expired")
        harness.advanceTime(bySeconds: PaceCompanionPairingPolicy.pairingWindowDurationSeconds)
        server.enforceDeadlines()

        // Attempt limit.
        #expect(server.openPairingWindow(triggeringEvent: nil))
        for _ in 0..<PaceCompanionPairingPolicy.maximumFailedPairingAttemptsPerWindow {
            try harness.connectInbound().simulate(.failed("synthetic TLS failure"))
        }
        #expect(server.lastPairingWindowCloseReason == .tooManyFailedAttempts)

        // Keychain write failure at confirmation.
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let storageFailureConnection = try harness.connectInbound()
        storageFailureConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-storage-failure")
        harness.credentialStore.storeSucceeds = false
        #expect(server.confirmPendingPairing(triggeringEvent: nil) == false)
        #expect(storageFailureConnection.sentErrorCodes == ["credential_storage_failed"])
        #expect(storageFailureConnection.sentPairResponses.isEmpty)
        #expect(storageFailureConnection.cancelCount == 1)

        #expect(harness.credentialStore.storedCredential == originalCredential)
        #expect(harness.credentialStore.deleteCallCount == 0)
        #expect(server.pairedDeviceName == CompanionServerHarness.pairedDeviceName)
        #expect(!isConnected(server))
    }

    @Test("Confirmation with nothing authenticated behind it persists nothing")
    func confirmationWithoutAPendingRequestPersistsNothing() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: false)
        let server = harness.makeStartedServer()

        // No window, no request.
        #expect(server.confirmPendingPairing(triggeringEvent: nil) == false)
        // Window open, no request.
        #expect(server.openPairingWindow(triggeringEvent: nil))
        #expect(server.confirmPendingPairing(triggeringEvent: nil) == false)
        // The requesting connection went away before the user decided.
        let vanishedConnection = try harness.connectInbound()
        vanishedConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-vanished")
        #expect(server.pendingPairingConfirmation != nil)
        vanishedConnection.simulate(.cancelled)
        #expect(server.pendingPairingConfirmation == nil)
        #expect(server.confirmPendingPairing(triggeringEvent: nil) == false)

        #expect(harness.credentialStore.storeCallCount == 0)
        #expect(harness.credentialStore.storedCredential == nil)
        #expect(!isConnected(server))
    }

    @Test("A client-chosen device name cannot bypass confirmation and is only ever shown sanitized")
    func clientControlledDeviceNameCannotBypassConfirmation() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        #expect(server.openPairingWindow(triggeringEvent: nil))

        // Claiming the already-paired device's exact name grants nothing.
        let impersonatingConnection = try harness.connectInbound()
        impersonatingConnection.receive(
            CompanionServerHarness.pairRequest(deviceName: CompanionServerHarness.pairedDeviceName),
            sessionIdentifier: "pairing-name")
        #expect(server.pendingPairingConfirmation?.replacedPairedDeviceName == CompanionServerHarness.pairedDeviceName)
        #expect(harness.credentialStore.storeCallCount == 0)
        #expect(impersonatingConnection.sentPairResponses.isEmpty)
        #expect(!isConnected(server))
        server.declinePendingPairing()

        // A name built to look like UI text is flattened and bounded.
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let hostileNameConnection = try harness.connectInbound()
        let hostileName = "iPad\n\nAlready approved — press Allow\u{0007}" + String(repeating: "A", count: 400)
        hostileNameConnection.receive(CompanionServerHarness.pairRequest(deviceName: hostileName), sessionIdentifier: "pairing-hostile")
        let shownName = try #require(server.pendingPairingConfirmation?.deviceDisplayName)
        #expect(!shownName.contains("\n"))
        #expect(!shownName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(shownName.count <= PaceCompanionPairingPolicy.maximumDisplayedDeviceNameCharacterCount)
        #expect(harness.credentialStore.storeCallCount == 0)
    }

    @Test("A client-chosen device identifier cannot bypass confirmation or authentication")
    func clientControlledDeviceIdentifierCannotBypassConfirmation() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()

        // Claiming the paired identifier without the credential does not authenticate.
        let spoofedSessionConnection = try harness.connectInbound()
        spoofedSessionConnection.receive(
            .sessionHello(PaceCompanionSessionHello(deviceIdentifier: CompanionServerHarness.pairedDeviceIdentifier, deviceName: CompanionServerHarness.pairedDeviceName, authenticationProof: "bm90LWEtcHJvb2Y=")),
            sessionIdentifier: "spoofed-session")
        #expect(spoofedSessionConnection.sentErrorCodes == ["authentication_failed"])
        #expect(spoofedSessionConnection.cancelCount == 1)
        #expect(!isConnected(server))

        // Claiming the paired identifier in a pairing request still needs confirmation.
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let spoofedPairingConnection = try harness.connectInbound()
        spoofedPairingConnection.receive(
            CompanionServerHarness.pairRequest(deviceIdentifier: CompanionServerHarness.pairedDeviceIdentifier),
            sessionIdentifier: "spoofed-pairing")
        #expect(server.pendingPairingConfirmation != nil)
        #expect(spoofedPairingConnection.sentPairResponses.isEmpty)
        #expect(harness.credentialStore.storeCallCount == 0)
        #expect(harness.credentialStore.storedCredential?.credential == CompanionServerHarness.syntheticCredential)
        #expect(!isConnected(server))
    }

    // MARK: Session security

    @Test("An authenticated session survives unauthenticated inbound connections")
    func authenticatedSessionSurvivesUnauthenticatedConnections() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let sessionConnection = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")

        let randomConnection = try harness.connectInbound()

        #expect(sessionConnection.cancelCount == 0)
        #expect(server.connectionStatus == .connected(deviceName: CompanionServerHarness.pairedDeviceName))
        // The newcomer is isolated: started, but told nothing about the Mac's state.
        #expect(randomConnection.startCount == 1)
        #expect(randomConnection.sentFrames.isEmpty)
        // And it cannot speak for the session, even quoting the session's identifier.
        randomConnection.receive(.privacyStateChanged(PaceCompanionPrivacyState(isMicrophoneEnabled: true, isCameraEnabled: true, isSpeakerMuted: false, isAllCapturePaused: false)), sessionIdentifier: "session-1")
        randomConnection.receive(.unpairRequest(PaceCompanionUnpairRequest(deviceIdentifier: CompanionServerHarness.pairedDeviceIdentifier)), sessionIdentifier: "session-1")
        #expect(randomConnection.sentErrorCodes == ["authentication_required", "authentication_required"])
        #expect(server.remotePrivacyState.isAllCapturePaused)
        #expect(harness.credentialStore.deleteCallCount == 0)
        #expect(sessionConnection.cancelCount == 0)
        #expect(isConnected(server))
    }

    @Test("A malformed unauthenticated request cannot terminate the authenticated session")
    func malformedUnauthenticatedRequestLeavesSessionIntact() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let sessionConnection = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")

        let malformedConnection = try harness.connectInbound()
        // What the framed connection reports for bytes that do not decode,
        // followed by the cancellation it then performs.
        malformedConnection.simulate(.failed("Invalid companion frame: invalidHeader"))
        malformedConnection.simulate(.cancelled)

        #expect(malformedConnection.cancelCount == 1)
        #expect(sessionConnection.cancelCount == 0)
        #expect(server.connectionStatus == .connected(deviceName: CompanionServerHarness.pairedDeviceName))
    }

    @Test("A failed authentication cannot terminate the authenticated session")
    func failedAuthenticationLeavesSessionIntact() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let sessionConnection = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")

        let failingConnection = try harness.connectInbound()
        // A proof that is valid for a DIFFERENT session identifier.
        failingConnection.receive(try harness.validSessionHello(sessionIdentifier: "some-other-session"), sessionIdentifier: "replayed-session")

        #expect(failingConnection.sentErrorCodes == ["authentication_failed"])
        #expect(failingConnection.cancelCount == 1)
        #expect(sessionConnection.cancelCount == 0)
        #expect(server.connectionStatus == .connected(deviceName: CompanionServerHarness.pairedDeviceName))
    }

    @Test("Only a connection that authenticated replaces the session, and the old session is closed only then")
    func sessionIsReplacedOnlyAfterAuthentication() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let firstSession = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")

        let reconnectingConnection = try harness.connectInbound()
        // Connected but not yet authenticated: the first session is untouched.
        #expect(firstSession.cancelCount == 0)

        reconnectingConnection.receive(try harness.validSessionHello(sessionIdentifier: "session-2"), sessionIdentifier: "session-2")

        #expect(firstSession.cancelCount == 1)
        #expect(reconnectingConnection.cancelCount == 0)
        #expect(isConnected(server))
        // The new connection is the session now.
        reconnectingConnection.receive(.heartbeat(PaceCompanionHeartbeat(sequenceNumber: 9, acknowledgedSequenceNumber: nil)), sessionIdentifier: "session-2")
        #expect(reconnectingConnection.sentHeartbeats.last?.acknowledgedSequenceNumber == 9)
        // The replaced connection's late close, and anything it still sends, change nothing.
        firstSession.simulate(.cancelled)
        let replacedFrameCount = firstSession.sentFrames.count
        firstSession.receive(.heartbeat(PaceCompanionHeartbeat(sequenceNumber: 10, acknowledgedSequenceNumber: nil)), sessionIdentifier: "session-1")
        #expect(firstSession.sentFrames.count == replacedFrameCount)
        #expect(isConnected(server))
        #expect(reconnectingConnection.cancelCount == 0)
    }

    @Test("Two simultaneous unauthenticated clients cannot race into replacing the authenticated session")
    func simultaneousUnauthenticatedClientsCannotReplaceSession() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let sessionConnection = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")
        #expect(server.openPairingWindow(triggeringEvent: nil))

        let firstRacer = try harness.connectInbound()
        let secondRacer = try harness.connectInbound()
        firstRacer.receive(CompanionServerHarness.pairRequest(deviceIdentifier: "f04a-racer-1", deviceName: "Racer One"), sessionIdentifier: "race-1")
        secondRacer.receive(CompanionServerHarness.pairRequest(deviceIdentifier: "f04a-racer-2", deviceName: "Racer Two"), sessionIdentifier: "race-2")

        // Exactly one request is waiting; the other was turned away.
        #expect(server.pendingPairingConfirmation?.deviceDisplayName == "Racer One")
        #expect(secondRacer.sentErrorCodes == ["pairing_in_progress"])
        #expect(secondRacer.cancelCount == 1)
        // Neither has a credential, a session, or any effect on the existing one.
        #expect(firstRacer.sentPairResponses.isEmpty)
        #expect(secondRacer.sentPairResponses.isEmpty)
        #expect(harness.credentialStore.storeCallCount == 0)
        #expect(sessionConnection.cancelCount == 0)
        #expect(server.connectionStatus == .connected(deviceName: CompanionServerHarness.pairedDeviceName))

        // Both racers trying to authenticate as the paired device fail too.
        let thirdRacer = try harness.connectInbound()
        let fourthRacer = try harness.connectInbound()
        for racer in [thirdRacer, fourthRacer] {
            racer.receive(
                .sessionHello(PaceCompanionSessionHello(deviceIdentifier: CompanionServerHarness.pairedDeviceIdentifier, deviceName: "x", authenticationProof: "bm90LWEtcHJvb2Y=")),
                sessionIdentifier: "race-hello")
        }
        #expect(sessionConnection.cancelCount == 0)
        #expect(server.connectionStatus == .connected(deviceName: CompanionServerHarness.pairedDeviceName))
    }

    @Test("The authenticated session stays usable after rejected inbound connections")
    func authenticatedSessionRemainsUsableAfterRejections() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let sessionConnection = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")

        try harness.connectInbound().simulate(.failed("synthetic TLS failure"))
        try harness.connectInbound().receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "rejected-pairing")
        try harness.connectInbound().receive(
            .sessionHello(PaceCompanionSessionHello(deviceIdentifier: "f04a-unknown", deviceName: "x", authenticationProof: "bm90LWEtcHJvb2Y=")),
            sessionIdentifier: "rejected-hello")
        let idleConnection = try harness.connectInbound()
        harness.advanceTime(bySeconds: PaceCompanionPairingPolicy.unauthenticatedConnectionDeadlineSeconds)
        server.enforceDeadlines()
        #expect(idleConnection.cancelCount == 1)

        sessionConnection.receive(.heartbeat(PaceCompanionHeartbeat(sequenceNumber: 77, acknowledgedSequenceNumber: nil)), sessionIdentifier: "session-1")
        #expect(sessionConnection.sentHeartbeats.last?.acknowledgedSequenceNumber == 77)
        let livePrivacyState = PaceCompanionPrivacyState(isMicrophoneEnabled: true, isCameraEnabled: false, isSpeakerMuted: false, isAllCapturePaused: false)
        sessionConnection.receive(.privacyStateChanged(livePrivacyState), sessionIdentifier: "session-1")
        #expect(server.remotePrivacyState == livePrivacyState)
        #expect(sessionConnection.cancelCount == 0)
        #expect(sessionConnection.sentErrorCodes.isEmpty)
        #expect(server.connectionStatus == .connected(deviceName: CompanionServerHarness.pairedDeviceName))
    }

    @Test("While the user decides, the waiting device gets liveness replies and nothing else")
    func waitingPairingRequestGetsOnlyLivenessReplies() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: false)
        let server = harness.makeStartedServer()
        #expect(server.openPairingWindow(triggeringEvent: nil))
        let pairingConnection = try harness.connectInbound()
        pairingConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-1")

        pairingConnection.receive(.heartbeat(PaceCompanionHeartbeat(sequenceNumber: 3, acknowledgedSequenceNumber: nil)), sessionIdentifier: "pairing-1")
        // Waiting on the user is not idling: the unauthenticated deadline does not drop it.
        harness.advanceTime(bySeconds: PaceCompanionPairingPolicy.unauthenticatedConnectionDeadlineSeconds + 1)
        server.enforceDeadlines()

        #expect(pairingConnection.sentFrames.count == 1)
        #expect(pairingConnection.sentHeartbeats.first?.acknowledgedSequenceNumber == 3)
        #expect(pairingConnection.cancelCount == 0)
        #expect(server.pendingPairingConfirmation != nil)
        #expect(!isConnected(server))
    }

    // MARK: Lifecycle

    @Test("Stopping the server releases the listener and every connection; stopping again is safe")
    func stopReleasesListenerAndRepeatedStopIsSafe() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let sessionConnection = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")
        let unauthenticatedConnection = try harness.connectInbound()
        let listener = try #require(harness.listeningListeners.first)

        server.stop()
        server.stop()
        server.stop()

        #expect(listener.cancelCount == 1)
        #expect(harness.listeningListeners.isEmpty)
        #expect(sessionConnection.cancelCount == 1)
        #expect(unauthenticatedConnection.cancelCount == 1)
        #expect(server.connectionStatus == .stopped)
        // Stopping is not an opt-out.
        #expect(server.isCompanionEnabled)
    }

    @Test("A restart leaves no stale listener state: late events from the old listener are ignored")
    func restartLeavesNoStaleListenerState() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let staleListener = try #require(harness.listeningListeners.first)

        server.stop()
        server.start(companionManager: harness.companionManager)

        #expect(harness.createdListeners.count == 2)
        #expect(harness.listeningListeners.count == 1)
        #expect(server.connectionStatus == .advertising)

        // The old listener delivering a connection or a failure after it was released.
        let lateConnection = RecordingCompanionConnection()
        staleListener.simulateInboundConnection(lateConnection)
        staleListener.onStateChange?(.failed("late failure from a released listener"))
        #expect(lateConnection.startCount == 0)
        #expect(lateConnection.cancelCount == 1)
        #expect(server.connectionStatus == .advertising)
        #expect(harness.listeningListeners.count == 1)

        // A real failure of the current listener fails closed.
        let currentListener = try #require(harness.listeningListeners.first)
        currentListener.onStateChange?(.failed("synthetic bind failure"))
        #expect(harness.listeningListeners.isEmpty)
        #expect(server.connectionStatus == .unavailable("synthetic bind failure"))
    }

    @Test("Repeated start calls and repeated enable calls never create a second listener")
    func repeatedStartNeverCreatesDuplicateListeners() {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()

        server.start(companionManager: harness.companionManager)
        server.start(companionManager: harness.companionManager)
        server.setCompanionEnabled(true)

        #expect(harness.createdListeners.count == 1)
        #expect(harness.listeningListeners.count == 1)
    }

    @Test("A fresh install or crash-restart never enables the companion by itself")
    func restartNeverEnablesCompanionByItself() {
        // Nothing persisted except a paired device: still off.
        let harness = CompanionServerHarness(isCompanionEnabled: false, hasPairedDevice: true)
        for _ in 0..<3 {
            let relaunchedServer = harness.makeStartedServer()
            #expect(relaunchedServer.isCompanionEnabled == false)
        }
        #expect(harness.createdListeners.isEmpty)
        #expect(harness.userDefaults.object(forKey: PaceCompanionServer.companionEnabledDefaultsKey) == nil)

        // An opt-out survives a relaunch too.
        let server = harness.makeStartedServer()
        server.setCompanionEnabled(true)
        server.setCompanionEnabled(false)
        let serverAfterOptOut = harness.makeStartedServer()
        #expect(serverAfterOptOut.isCompanionEnabled == false)
        #expect(harness.listeningListeners.isEmpty)
    }

    @Test("Unpairing from the authenticated session removes the pairing and leaves nothing listening")
    func unpairLeavesNothingListening() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: true, hasPairedDevice: true)
        let server = harness.makeStartedServer()
        let sessionConnection = try harness.connectAuthenticatedSession(sessionIdentifier: "session-1")

        sessionConnection.receive(.unpairRequest(PaceCompanionUnpairRequest(deviceIdentifier: CompanionServerHarness.pairedDeviceIdentifier)), sessionIdentifier: "session-1")

        #expect(harness.credentialStore.storedCredential == nil)
        #expect(server.pairedDeviceName == nil)
        #expect(sessionConnection.cancelCount == 1)
        #expect(harness.listeningListeners.isEmpty)
        #expect(server.connectionStatus == .stopped)
        // Unpairing does not open pairing.
        #expect(server.pairingCode == nil)
    }

    // MARK: Network

    @Test("Listener transport parameters are unchanged: TLS 1.3 PSK over TCP, no interface pinning, peer-to-peer included")
    func listenerTransportParametersAreUnchanged() {
        let material = PaceCompanionTLSMaterial(preSharedKey: Data(repeating: 1, count: 32), identity: Data("f04a".utf8))
        let parameters = PaceCompanionTLSParameters.make(materials: [material])

        #expect(parameters.includePeerToPeer)
        #expect(parameters.requiredLocalEndpoint == nil)
        #expect(parameters.requiredInterfaceType == .other)
        #expect(parameters.prohibitedInterfaceTypes?.isEmpty ?? true)
        #expect(parameters.defaultProtocolStack.transportProtocol is NWProtocolTCP.Options)
        #expect(parameters.defaultProtocolStack.applicationProtocols.first is NWProtocolTLS.Options)
        #expect(PaceCompanionProtocol.bonjourServiceType == "_pace-companion._tcp")
    }

    @Test("A listener — and so the Bonjour advertisement — exists only while the companion is intentionally active")
    func advertisementExistsOnlyWhileIntentionallyActive() throws {
        let harness = CompanionServerHarness(isCompanionEnabled: false, hasPairedDevice: false)
        let server = harness.makeStartedServer()
        #expect(harness.listeningListeners.isEmpty)  // disabled

        server.setCompanionEnabled(true)
        #expect(harness.listeningListeners.isEmpty)  // enabled, unpaired, pairing closed

        #expect(server.openPairingWindow(triggeringEvent: nil))
        #expect(harness.listeningListeners.count == 1)  // pairing window open

        server.cancelPairingWindow()
        #expect(harness.listeningListeners.isEmpty)  // pairing closed again

        #expect(server.openPairingWindow(triggeringEvent: nil))
        let pairingConnection = try harness.connectInbound()
        pairingConnection.receive(CompanionServerHarness.pairRequest(), sessionIdentifier: "pairing-1")
        #expect(server.confirmPendingPairing(triggeringEvent: nil))
        #expect(harness.listeningListeners.count == 1)  // paired

        server.setCompanionEnabled(false)
        #expect(harness.listeningListeners.isEmpty)  // opted out

        server.setCompanionEnabled(true)
        #expect(harness.listeningListeners.count == 1)  // opted back in, still paired

        server.unpairCurrentDevice()
        #expect(harness.listeningListeners.isEmpty)  // unpaired

        // Every listener ever created was started once and cancelled at most once.
        #expect(harness.createdListeners.allSatisfy { $0.startCount == 1 && $0.cancelCount <= 1 })
    }

    // MARK: Pure policy

    @Test("The pairing window value enforces its own time and attempt bounds")
    func pairingWindowValueBounds() {
        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var window = PaceCompanionPairingWindow(pairingCode: "000000", openedAt: openedAt)

        #expect(window.expiresAt == openedAt.addingTimeInterval(120))
        #expect(!window.hasExpired(now: openedAt))
        #expect(!window.hasExpired(now: openedAt.addingTimeInterval(119.999)))
        #expect(window.hasExpired(now: openedAt.addingTimeInterval(120)))

        for _ in 0..<4 { window.recordFailedAttempt() }
        #expect(!window.hasReachedFailedAttemptLimit)
        window.recordFailedAttempt()
        #expect(window.hasReachedFailedAttemptLimit)
        #expect(window.failedAttemptCount == 5)
    }

    @Test("Client-provided device labels are flattened, bounded, and never empty")
    func clientProvidedLabelsAreSanitized() {
        #expect(PaceCompanionPairingPolicy.displayName(forClientProvidedDeviceName: "  Hani's iPad  ") == "Hani's iPad")
        #expect(PaceCompanionPairingPolicy.displayName(forClientProvidedDeviceName: "line one\nline two\ttabbed") == "line one line two tabbed")
        #expect(PaceCompanionPairingPolicy.displayName(forClientProvidedDeviceName: "\n\u{0000}\u{001B}") == "Unnamed device")
        #expect(PaceCompanionPairingPolicy.displayName(forClientProvidedDeviceName: String(repeating: "x", count: 500)).count == 48)
        #expect(PaceCompanionPairingPolicy.displaySuffix(forClientProvidedDeviceIdentifier: "ABCD-1234-EF\n56") == "34EF56")
    }
}
