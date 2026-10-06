import AppKit
import Combine
import Foundation

/// Bonjour-advertised, TLS-PSK Mac adapter for one paired PacePad.
///
/// Exposure and pairing lifecycle (F-04a):
///  - No listener exists unless the user turned the iPad companion on
///    (`isCompanionEnabled`, default off) AND the app attached this server
///    (`start`) AND there is at least one key a peer could authenticate with.
///  - The six-digit pairing key is offered only inside an explicit, bounded
///    pairing window (`PaceCompanionPairingWindow`).
///  - A pairing is stored only after the user allows it on the Mac.
///  - Every inbound connection starts unauthenticated and isolated. Only a
///    connection that has authenticated can become — or replace — the session.
@MainActor
final class PaceCompanionServer: ObservableObject, PacePadOutputDelegate {
    static let shared = PaceCompanionServer()

    enum ConnectionStatus: Equatable {
        case stopped
        case advertising
        case connected(deviceName: String)
        case unavailable(String)
    }

    @Published private(set) var connectionStatus: ConnectionStatus = .stopped
    /// The user's explicit opt-in. Default off; nothing else turns it on.
    @Published private(set) var isCompanionEnabled: Bool
    /// The pairing code, present only while a pairing window is open.
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingWindowExpiresAt: Date?
    @Published private(set) var pendingPairingConfirmation: PaceCompanionPendingPairingConfirmation?
    @Published private(set) var lastPairingWindowCloseReason: PaceCompanionPairingWindowCloseReason?
    @Published private(set) var pairedDeviceName: String?
    @Published private(set) var remotePrivacyState = PaceCompanionPrivacyState(
        isMicrophoneEnabled: false,
        isCameraEnabled: false,
        isSpeakerMuted: false,
        isAllCapturePaused: true
    )

    static let companionEnabledDefaultsKey = "PaceCompanionServerEnabled"
    static let serverIdentifierDefaultsKey = "PaceCompanionServerIdentifier"

    /// An inbound connection that has not authenticated. It can pair (inside a
    /// window) or present a session proof; it can do nothing else, and it can
    /// never affect the authenticated session.
    private struct UnauthenticatedConnection {
        let connection: PaceCompanionServerConnection
        let acceptedAt: Date
    }

    /// The one pairing request waiting on the Mac-side confirmation.
    private struct PairingCandidate {
        let connection: PaceCompanionServerConnection
        let sessionIdentifier: String
        let pairRequestMessageIdentifier: String
        let deviceIdentifier: String
        let deviceDisplayName: String
    }

    private weak var companionManager: CompanionManager?
    private var hasStarted = false
    private var listener: PaceCompanionServerListener?
    /// The keys the current listener accepts; lets a refresh that would not
    /// change them be a no-op instead of a re-advertisement.
    private var listenerMaterials: [PaceCompanionTLSMaterial] = []
    private var unauthenticatedConnections: [ObjectIdentifier: UnauthenticatedConnection] = [:]
    private var pairingWindow: PaceCompanionPairingWindow?
    private var pairingCandidate: PairingCandidate?
    private var activeConnection: PaceCompanionServerConnection?
    private var activeSessionIdentifier: String?
    /// Minted here each time a connection becomes the authenticated session
    /// (F-04b). Unlike `activeSessionIdentifier`, which the iPad chooses, this
    /// never leaves the Mac — it is what a remote turn's origin, its lifetime,
    /// and its reply are bound to.
    private(set) var activeSessionIdentity: PaceCompanionSessionIdentity?
    private var activeDeviceIdentifier: String?
    private var isActiveSessionAuthenticated = false
    private var storedCredential: PaceCompanionStoredCredential?
    private var lastHeartbeatReceivedAt = Date.distantPast
    private var outgoingHeartbeatSequenceNumber = 0
    private var heartbeatTask: Task<Void, Never>?
    private var deadlineSweepTask: Task<Void, Never>?
    private var voiceStateCancellable: AnyCancellable?
    private var offDeviceStateCancellable: AnyCancellable?
    private var pendingCameraFrameContinuations: [String: CheckedContinuation<Data?, Never>] = [:]
    private let serverIdentifier: String
    private let serverDisplayName: String
    private let userDefaults: UserDefaults
    private let credentialStore: PaceCompanionCredentialStoring
    private let listenerFactory: PaceCompanionServerListenerFactory
    private let now: () -> Date

    init(
        userDefaults: UserDefaults = .standard,
        credentialStore: PaceCompanionCredentialStoring? = nil,
        listenerFactory: PaceCompanionServerListenerFactory? = nil,
        serverDisplayName: String = Host.current().localizedName ?? "Que on Mac",
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.credentialStore = credentialStore ?? PaceCompanionKeychainCredentialStore()
        self.listenerFactory = listenerFactory ?? { materials in
            try PaceCompanionNetworkListener.makeProductionListener(materials: materials)
        }
        self.serverDisplayName = serverDisplayName
        self.now = now
        // Absent key reads false: the companion is off until the user turns it on.
        isCompanionEnabled = userDefaults.bool(forKey: Self.companionEnabledDefaultsKey)
        if let existingServerIdentifier = userDefaults.string(
            forKey: Self.serverIdentifierDefaultsKey
        ) {
            serverIdentifier = existingServerIdentifier
        } else {
            let newServerIdentifier = UUID().uuidString
            userDefaults.set(newServerIdentifier, forKey: Self.serverIdentifierDefaultsKey)
            serverIdentifier = newServerIdentifier
        }
        storedCredential = self.credentialStore.loadCredential()
        pairedDeviceName = storedCredential.map {
            PaceCompanionPairingPolicy.displayName(forClientProvidedDeviceName: $0.remoteName)
        }
    }

    // MARK: - Lifecycle

    /// Attaches the server to the conversation pipeline. This does NOT by
    /// itself open a listener: `refreshListener` only does so when the user
    /// has opted in and there is a key to accept.
    func start(companionManager: CompanionManager) {
        self.companionManager = companionManager
        companionManager.pacePadOutputDelegate = self
        voiceStateCancellable = companionManager.$voiceState
            .removeDuplicates(by: { leftState, rightState in
                switch (leftState, rightState) {
                case (.idle, .idle), (.listening, .listening),
                    (.processing, .processing), (.responding, .responding):
                    return true
                default:
                    return false
                }
            })
            .sink { [weak self] voiceState in
                self?.sendInteractionState(voiceState)
            }
        offDeviceStateCancellable = companionManager.$isOffDeviceTurnInFlight
            .removeDuplicates()
            .sink { [weak self, weak companionManager] _ in
                guard let companionManager else { return }
                self?.sendInteractionState(companionManager.voiceState)
            }
        hasStarted = true
        refreshListener()
    }

    func stop() {
        hasStarted = false
        closePairingWindow(reason: .serverStopped, refreshesListener: false)
        tearDownNetwork()
        voiceStateCancellable?.cancel()
        voiceStateCancellable = nil
        offDeviceStateCancellable?.cancel()
        offDeviceStateCancellable = nil
        connectionStatus = .stopped
        companionManager?.pacePadOutputDelegate = nil
        companionManager = nil
    }

    /// The explicit opt-in / opt-out. Turning the companion off closes the
    /// listener, any pairing window, and the active session.
    func setCompanionEnabled(_ isEnabled: Bool) {
        guard isEnabled != isCompanionEnabled else { return }
        isCompanionEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: Self.companionEnabledDefaultsKey)
        if isEnabled {
            refreshListener()
        } else {
            closePairingWindow(reason: .companionDisabled, refreshesListener: false)
            tearDownNetwork()
            connectionStatus = .stopped
        }
    }

    // MARK: - Pairing window

    /// Opens a fresh pairing window. Only a local action reaches this: inbound
    /// traffic never does. `triggeringEvent` is the input event that pressed
    /// the Settings button (`NSApp.currentEvent`), or nil for an Accessibility
    /// press; an event Que synthesized itself is refused, so a turn that
    /// drives Que's own UI cannot open pairing.
    @discardableResult
    func openPairingWindow(triggeringEvent: NSEvent?) -> Bool {
        guard hasStarted, isCompanionEnabled else { return false }
        guard PaceApprovalInputOrigin.verdict(forTriggeringEvent: triggeringEvent) == .allowed else {
            return false
        }
        // Re-opening is an explicit local action too: the old window (and any
        // request waiting on it) is closed before the new code is issued.
        closePairingWindow(reason: .cancelled, refreshesListener: false)
        let openedWindow = PaceCompanionPairingWindow(
            pairingCode: PaceCompanionSecurity.generatePairingCode(),
            openedAt: now()
        )
        pairingWindow = openedWindow
        pairingCode = openedWindow.pairingCode
        pairingWindowExpiresAt = openedWindow.expiresAt
        lastPairingWindowCloseReason = nil
        refreshListener()
        startDeadlineSweepIfNeeded()
        return true
    }

    func cancelPairingWindow() {
        closePairingWindow(reason: .cancelled)
    }

    /// The Mac-side "Allow" for the pending pairing request. Nothing is
    /// generated or stored before this point. `triggeringEvent` follows the
    /// same rule as `openPairingWindow`.
    @discardableResult
    func confirmPendingPairing(triggeringEvent: NSEvent?) -> Bool {
        guard PaceApprovalInputOrigin.verdict(forTriggeringEvent: triggeringEvent) == .allowed else {
            return false
        }
        enforceDeadlines()
        guard hasStarted, isCompanionEnabled, pairingWindow != nil,
            let confirmedCandidate = pairingCandidate,
            isTracked(confirmedCandidate.connection)
        else {
            return false
        }

        let credential = PaceCompanionSecurity.generateCredential()
        let newStoredCredential = PaceCompanionStoredCredential(
            remoteIdentifier: confirmedCandidate.deviceIdentifier,
            remoteName: confirmedCandidate.deviceDisplayName,
            localDeviceIdentifier: serverIdentifier,
            credential: credential
        )
        guard credentialStore.storeCredential(newStoredCredential) else {
            _ = send(
                payload: .error(
                    PaceCompanionErrorMessage(
                        code: "credential_storage_failed",
                        message: "Que could not save the pairing credential in Keychain.",
                        isRecoverable: true
                    )),
                to: confirmedCandidate.connection,
                sessionIdentifier: confirmedCandidate.sessionIdentifier,
                replyToMessageIdentifier: confirmedCandidate.pairRequestMessageIdentifier
            )
            removeUnauthenticatedConnection(
                confirmedCandidate.connection,
                countsAsFailedPairingAttempt: false
            )
            return false
        }

        storedCredential = newStoredCredential
        pairedDeviceName = newStoredCredential.remoteName
        pairingCandidate = nil
        pendingPairingConfirmation = nil
        promoteToAuthenticatedSession(
            confirmedCandidate.connection,
            sessionIdentifier: confirmedCandidate.sessionIdentifier,
            deviceIdentifier: confirmedCandidate.deviceIdentifier,
            deviceDisplayName: confirmedCandidate.deviceDisplayName
        )
        _ = send(
            payload: .pairResponse(
                PaceCompanionPairResponse(
                    serverIdentifier: serverIdentifier,
                    serverName: serverDisplayName,
                    deviceCredential: credential
                )),
            replyToMessageIdentifier: confirmedCandidate.pairRequestMessageIdentifier
        )
        // Closing the window drops the pairing key from the listener; the
        // accepted connection is independent of the listener and stays up.
        closePairingWindow(reason: .paired)
        return true
    }

    /// The Mac-side "Deny". Closes the whole window: the code has been used.
    func declinePendingPairing() {
        guard pairingCandidate != nil else { return }
        closePairingWindow(reason: .declined)
    }

    func unpairCurrentDevice() {
        _ = credentialStore.deleteCredential()
        storedCredential = nil
        pairedDeviceName = nil
        let unpairedConnection = activeConnection
        clearActiveSession()
        unpairedConnection?.cancel()
        refreshListener()
        connectionStatus = listener == nil ? .stopped : .advertising
    }

    /// Applies the time bounds: an expired pairing window closes, and a
    /// connection that stayed unauthenticated past its deadline is dropped.
    /// Driven by the deadline sweep, and re-checked before any pairing step.
    func enforceDeadlines() {
        let currentTime = now()
        if let openWindow = pairingWindow, openWindow.hasExpired(now: currentTime) {
            closePairingWindow(reason: .expired)
        }
        let overdueConnections = unauthenticatedConnections.values.filter { unauthenticatedConnection in
            pairingCandidate?.connection !== unauthenticatedConnection.connection
                && currentTime.timeIntervalSince(unauthenticatedConnection.acceptedAt)
                    >= PaceCompanionPairingPolicy.unauthenticatedConnectionDeadlineSeconds
        }
        for overdueConnection in overdueConnections {
            removeUnauthenticatedConnection(
                overdueConnection.connection,
                countsAsFailedPairingAttempt: true
            )
        }
    }

    private func closePairingWindow(
        reason: PaceCompanionPairingWindowCloseReason,
        refreshesListener: Bool = true
    ) {
        guard pairingWindow != nil else { return }
        pairingWindow = nil
        pairingCode = nil
        pairingWindowExpiresAt = nil
        lastPairingWindowCloseReason = reason
        if let abandonedCandidate = pairingCandidate {
            pairingCandidate = nil
            pendingPairingConfirmation = nil
            _ = send(
                payload: .error(
                    PaceCompanionErrorMessage(
                        code: reason == .declined ? "pairing_declined" : "pairing_window_closed",
                        message: reason == .declined
                            ? "Pairing was declined on the Mac."
                            : "Pairing is closed on the Mac. Open pairing in Que settings and try again.",
                        isRecoverable: true
                    )),
                to: abandonedCandidate.connection,
                sessionIdentifier: abandonedCandidate.sessionIdentifier,
                replyToMessageIdentifier: abandonedCandidate.pairRequestMessageIdentifier
            )
        }
        // Whatever is still unauthenticated was admitted while the pairing key
        // was on offer. It goes with the window; a paired iPad reconnects.
        cancelAllUnauthenticatedConnections()
        if refreshesListener {
            refreshListener()
        }
    }

    private func recordFailedPairingAttempt() {
        guard var openWindow = pairingWindow else { return }
        openWindow.recordFailedAttempt()
        pairingWindow = openWindow
        if openWindow.hasReachedFailedAttemptLimit {
            closePairingWindow(reason: .tooManyFailedAttempts)
        }
    }

    private func startDeadlineSweepIfNeeded() {
        guard deadlineSweepTask == nil else { return }
        deadlineSweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                enforceDeadlines()
                if pairingWindow == nil, unauthenticatedConnections.isEmpty {
                    deadlineSweepTask = nil
                    return
                }
            }
        }
    }

    // MARK: - PacePad output

    func deliverAssistantResponse(
        turnIdentifier: String,
        spokenText: String,
        usesOffDevicePlanner: Bool,
        originatingSessionIdentity: PaceCompanionSessionIdentity
    ) -> Bool {
        // A reply belongs to the session whose utterance produced it. If that
        // session is gone it is dropped — never rerouted to whichever session
        // happens to be authenticated now.
        guard isCompanionSessionActive(originatingSessionIdentity) else { return false }
        return send(
            payload: .assistantResponse(
                PaceCompanionAssistantResponse(
                    turnIdentifier: turnIdentifier,
                    spokenText: spokenText,
                    usesOffDevicePlanner: usesOffDevicePlanner
                )))
    }

    func isCompanionSessionActive(_ sessionIdentity: PaceCompanionSessionIdentity) -> Bool {
        isActiveSessionAuthenticated && activeSessionIdentity == sessionIdentity
    }

    func deliverProactiveMessage(_ utterance: PaceProactiveUtterance) -> Bool {
        guard isActiveSessionAuthenticated else { return false }
        // A connected but paused iPad owns this output route. Treat the message
        // as handled so the proactivity pipeline does not fall back to Mac TTS.
        guard remotePrivacyState.permitsProactiveOutput else { return true }
        return send(
            payload: .proactiveMessage(
                PaceCompanionProactiveMessage(
                    spokenText: utterance.spokenText,
                    source: utterance.source.rawValue,
                    expiresAt: utterance.relevanceWindowExpiresAt
                )))
    }

    // MARK: - Listener

    /// Brings the listener in line with the current state. A listener exists
    /// only when: the app attached the server, the user opted in, and there is
    /// at least one key to accept — the pairing key while a window is open,
    /// and the paired device's key while a device is paired.
    private func refreshListener() {
        guard hasStarted, isCompanionEnabled else {
            cancelListener()
            return
        }

        var tlsMaterials: [PaceCompanionTLSMaterial] = []
        if let openWindow = pairingWindow,
            let pairingMaterial = PaceCompanionSecurity.pairingTLSMaterial(
                pairingCode: openWindow.pairingCode
            )
        {
            tlsMaterials.append(pairingMaterial)
        }
        if let storedCredential,
            let credentialMaterial = PaceCompanionSecurity.credentialTLSMaterial(
                credential: storedCredential.credential,
                deviceIdentifier: storedCredential.remoteIdentifier
            )
        {
            tlsMaterials.append(credentialMaterial)
        }

        guard !tlsMaterials.isEmpty else {
            cancelListener()
            if !isActiveSessionAuthenticated {
                connectionStatus = .stopped
            }
            return
        }
        if listener != nil, tlsMaterials == listenerMaterials {
            return
        }

        cancelListener()
        do {
            let newListener = try listenerFactory(tlsMaterials)
            newListener.onNewConnection = { [weak self, weak newListener] newConnection in
                guard let self, let newListener, self.listener === newListener else {
                    newConnection.cancel()
                    return
                }
                accept(newConnection)
            }
            newListener.onStateChange = { [weak self, weak newListener] listenerState in
                guard let self, let newListener, self.listener === newListener else { return }
                handle(listenerState)
            }
            listener = newListener
            listenerMaterials = tlsMaterials
            newListener.start()
            if !isActiveSessionAuthenticated {
                connectionStatus = .advertising
            }
        } catch {
            if !isActiveSessionAuthenticated {
                connectionStatus = .unavailable(error.localizedDescription)
            }
        }
    }

    private func cancelListener() {
        let cancelledListener = listener
        listener = nil
        listenerMaterials = []
        cancelledListener?.cancel()
    }

    private func tearDownNetwork() {
        cancelListener()
        cancelAllUnauthenticatedConnections()
        let closedConnection = activeConnection
        clearActiveSession()
        closedConnection?.cancel()
        deadlineSweepTask?.cancel()
        deadlineSweepTask = nil
    }

    private func handle(_ listenerState: PaceCompanionServerListenerState) {
        switch listenerState {
        case .ready, .waiting:
            if !isActiveSessionAuthenticated {
                connectionStatus = .advertising
            }
        case .failed(let reason):
            // Fail closed: a failed listener is released, not left half-alive.
            cancelListener()
            if !isActiveSessionAuthenticated {
                connectionStatus = .unavailable(reason)
            }
        case .cancelled:
            break
        }
    }

    // MARK: - Connection admission

    /// A new inbound connection is unauthenticated and isolated. It does not
    /// touch the authenticated session — not now, and not if it fails later.
    private func accept(_ newConnection: PaceCompanionServerConnection) {
        guard hasStarted, isCompanionEnabled else {
            newConnection.cancel()
            return
        }
        guard
            unauthenticatedConnections.count
                < PaceCompanionPairingPolicy.maximumUnauthenticatedConnectionCount
        else {
            newConnection.cancel()
            recordFailedPairingAttempt()
            return
        }

        unauthenticatedConnections[ObjectIdentifier(newConnection)] = UnauthenticatedConnection(
            connection: newConnection,
            acceptedAt: now()
        )
        newConnection.onStateChange = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            handle(state, from: newConnection)
        }
        newConnection.onFrameReceived = { [weak self, weak newConnection] frame in
            guard let self, let newConnection else { return }
            handle(frame, from: newConnection)
        }
        newConnection.start()
        startDeadlineSweepIfNeeded()
    }

    private func isUnauthenticated(_ connection: PaceCompanionServerConnection) -> Bool {
        unauthenticatedConnections[ObjectIdentifier(connection)] != nil
    }

    private func isAuthenticatedSessionConnection(_ connection: PaceCompanionServerConnection) -> Bool {
        isActiveSessionAuthenticated && activeConnection === connection
    }

    private func isTracked(_ connection: PaceCompanionServerConnection) -> Bool {
        isUnauthenticated(connection) || isAuthenticatedSessionConnection(connection)
    }

    private func removeUnauthenticatedConnection(
        _ connection: PaceCompanionServerConnection,
        countsAsFailedPairingAttempt: Bool
    ) {
        guard unauthenticatedConnections.removeValue(forKey: ObjectIdentifier(connection)) != nil else {
            return
        }
        if pairingCandidate?.connection === connection {
            pairingCandidate = nil
            pendingPairingConfirmation = nil
        }
        connection.cancel()
        if countsAsFailedPairingAttempt {
            recordFailedPairingAttempt()
        }
    }

    private func cancelAllUnauthenticatedConnections() {
        let cancelledConnections = unauthenticatedConnections.values.map(\.connection)
        unauthenticatedConnections.removeAll()
        for cancelledConnection in cancelledConnections {
            cancelledConnection.cancel()
        }
    }

    private func handle(
        _ state: PaceCompanionFramedConnection.State,
        from connection: PaceCompanionServerConnection
    ) {
        if activeConnection === connection {
            switch state {
            case .ready, .preparing:
                break
            case .failed(let reason):
                clearActiveSession()
                connectionStatus = .unavailable(reason)
            case .cancelled:
                clearActiveSession()
                connectionStatus = listener == nil ? .stopped : .advertising
            }
            return
        }
        // An unauthenticated connection that ends without authenticating is a
        // failed attempt while a pairing window is open. A connection that is
        // neither (already replaced or already dropped) is ignored.
        switch state {
        case .ready, .preparing:
            break
        case .failed, .cancelled:
            removeUnauthenticatedConnection(connection, countsAsFailedPairingAttempt: true)
        }
    }

    private func handle(
        _ frame: PaceCompanionWireFrame,
        from connection: PaceCompanionServerConnection
    ) {
        if isAuthenticatedSessionConnection(connection) {
            switch frame.message.payload {
            case .pairRequest(let pairRequest):
                handlePairRequest(pairRequest, message: frame.message, from: connection)
            case .sessionHello(let sessionHello):
                handleSessionHello(sessionHello, message: frame.message, from: connection)
            default:
                guard frame.message.sessionIdentifier == activeSessionIdentifier else {
                    sendAuthenticationRequiredError(replyingTo: frame.message, on: connection)
                    return
                }
                handleAuthenticatedFrame(frame)
            }
            return
        }

        guard isUnauthenticated(connection) else { return }
        switch frame.message.payload {
        case .pairRequest(let pairRequest):
            handlePairRequest(pairRequest, message: frame.message, from: connection)
        case .sessionHello(let sessionHello):
            handleSessionHello(sessionHello, message: frame.message, from: connection)
        case .heartbeat(let heartbeat)
        where pairingCandidate?.connection === connection
            && pairingCandidate?.sessionIdentifier == frame.message.sessionIdentifier:
            // Keep the iPad's link alive while the user decides on the Mac.
            // A liveness reply only — the connection is still unauthenticated.
            _ = send(
                payload: .heartbeat(
                    PaceCompanionHeartbeat(
                        sequenceNumber: outgoingHeartbeatSequenceNumber,
                        acknowledgedSequenceNumber: heartbeat.sequenceNumber
                    )),
                to: connection,
                sessionIdentifier: frame.message.sessionIdentifier
            )
        default:
            sendAuthenticationRequiredError(replyingTo: frame.message, on: connection)
        }
    }

    private func sendAuthenticationRequiredError(
        replyingTo message: PaceCompanionMessage,
        on connection: PaceCompanionServerConnection
    ) {
        _ = send(
            payload: .error(
                PaceCompanionErrorMessage(
                    code: "authentication_required",
                    message: "Pair or authenticate this iPad before sending companion messages.",
                    isRecoverable: true
                )),
            to: connection,
            sessionIdentifier: message.sessionIdentifier,
            replyToMessageIdentifier: message.messageIdentifier
        )
    }

    /// A pairing request never stores or grants anything by itself. Inside an
    /// open window it becomes the one request waiting on the Mac-side
    /// confirmation; everything the client supplied is treated as a label.
    private func handlePairRequest(
        _ pairRequest: PaceCompanionPairRequest,
        message: PaceCompanionMessage,
        from connection: PaceCompanionServerConnection
    ) {
        enforceDeadlines()
        guard isTracked(connection) else { return }

        guard pairingWindow != nil else {
            rejectPairRequest(
                code: "pairing_window_closed",
                text: "Pairing is closed on the Mac. Open pairing in Que settings and try again.",
                message: message,
                from: connection,
                countsAsFailedPairingAttempt: false
            )
            return
        }
        guard !pairRequest.deviceIdentifier.isEmpty,
            !pairRequest.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            rejectPairRequest(
                code: "invalid_pair_request",
                text: "The iPad did not provide a valid device identity.",
                message: message,
                from: connection,
                countsAsFailedPairingAttempt: true
            )
            return
        }
        if let waitingCandidate = pairingCandidate {
            // One request at a time. A repeat from the same connection is
            // ignored; a competing connection is turned away.
            guard waitingCandidate.connection !== connection else { return }
            rejectPairRequest(
                code: "pairing_in_progress",
                text: "Another device is already waiting to pair with this Mac.",
                message: message,
                from: connection,
                countsAsFailedPairingAttempt: true
            )
            return
        }

        let deviceDisplayName = PaceCompanionPairingPolicy.displayName(
            forClientProvidedDeviceName: pairRequest.deviceName
        )
        pairingCandidate = PairingCandidate(
            connection: connection,
            sessionIdentifier: message.sessionIdentifier,
            pairRequestMessageIdentifier: message.messageIdentifier,
            deviceIdentifier: pairRequest.deviceIdentifier,
            deviceDisplayName: deviceDisplayName
        )
        pendingPairingConfirmation = PaceCompanionPendingPairingConfirmation(
            id: UUID(),
            deviceDisplayName: deviceDisplayName,
            deviceIdentifierDisplaySuffix: PaceCompanionPairingPolicy.displaySuffix(
                forClientProvidedDeviceIdentifier: pairRequest.deviceIdentifier
            ),
            replacedPairedDeviceName: pairedDeviceName
        )
    }

    private func rejectPairRequest(
        code: String,
        text: String,
        message: PaceCompanionMessage,
        from connection: PaceCompanionServerConnection,
        countsAsFailedPairingAttempt: Bool
    ) {
        _ = send(
            payload: .error(
                PaceCompanionErrorMessage(code: code, message: text, isRecoverable: true)
            ),
            to: connection,
            sessionIdentifier: message.sessionIdentifier,
            replyToMessageIdentifier: message.messageIdentifier
        )
        // The authenticated session keeps running after a refused request;
        // an unauthenticated connection is dropped.
        guard isUnauthenticated(connection) else { return }
        removeUnauthenticatedConnection(
            connection,
            countsAsFailedPairingAttempt: countsAsFailedPairingAttempt
        )
    }

    private func handleSessionHello(
        _ sessionHello: PaceCompanionSessionHello,
        message: PaceCompanionMessage,
        from connection: PaceCompanionServerConnection
    ) {
        guard let storedCredential,
            storedCredential.remoteIdentifier == sessionHello.deviceIdentifier,
            PaceCompanionSecurity.validateSessionAuthenticationProof(
                sessionHello.authenticationProof,
                credential: storedCredential.credential,
                serverIdentifier: serverIdentifier,
                deviceIdentifier: sessionHello.deviceIdentifier,
                sessionIdentifier: message.sessionIdentifier
            )
        else {
            _ = send(
                payload: .error(
                    PaceCompanionErrorMessage(
                        code: "authentication_failed",
                        message: "The stored companion pairing is no longer valid.",
                        isRecoverable: true
                    )),
                to: connection,
                sessionIdentifier: message.sessionIdentifier,
                replyToMessageIdentifier: message.messageIdentifier
            )
            if isUnauthenticated(connection) {
                removeUnauthenticatedConnection(connection, countsAsFailedPairingAttempt: true)
            }
            return
        }
        // Proven holder of the paired device's credential: this connection may
        // now become the session, replacing an older one from the same pairing.
        promoteToAuthenticatedSession(
            connection,
            sessionIdentifier: message.sessionIdentifier,
            deviceIdentifier: sessionHello.deviceIdentifier,
            deviceDisplayName: PaceCompanionPairingPolicy.displayName(
                forClientProvidedDeviceName: sessionHello.deviceName
            )
        )
        _ = send(
            payload: .heartbeat(
                PaceCompanionHeartbeat(
                    sequenceNumber: outgoingHeartbeatSequenceNumber,
                    acknowledgedSequenceNumber: nil
                )))
    }

    /// The only place a connection becomes the authenticated session. Callers
    /// reach it only after authentication (a valid session proof, or a pairing
    /// the user allowed on the Mac). The previous session, if any, is closed
    /// only here — after its replacement has authenticated.
    private func promoteToAuthenticatedSession(
        _ connection: PaceCompanionServerConnection,
        sessionIdentifier: String,
        deviceIdentifier: String,
        deviceDisplayName: String
    ) {
        unauthenticatedConnections.removeValue(forKey: ObjectIdentifier(connection))
        if activeConnection !== connection {
            let replacedConnection = activeConnection
            clearActiveSession()
            replacedConnection?.cancel()
        } else if let supersededSessionIdentity = activeSessionIdentity {
            // The same connection authenticated again: that is a new session
            // too, so the previous one's in-flight turn ends with it.
            activeSessionIdentity = nil
            companionManager?.companionSessionDidEnd(supersededSessionIdentity)
        }
        activeConnection = connection
        activeSessionIdentifier = sessionIdentifier
        activeSessionIdentity = .mintForNewlyAuthenticatedSession()
        activeDeviceIdentifier = deviceIdentifier
        isActiveSessionAuthenticated = true
        lastHeartbeatReceivedAt = now()
        connectionStatus = .connected(deviceName: deviceDisplayName)
        startHeartbeatLoop()
        sendInteractionState(companionManager?.voiceState ?? .idle)
    }

    private func handleAuthenticatedFrame(_ frame: PaceCompanionWireFrame) {
        switch frame.message.payload {
        case .heartbeat(let heartbeat):
            lastHeartbeatReceivedAt = now()
            _ = send(
                payload: .heartbeat(
                    PaceCompanionHeartbeat(
                        sequenceNumber: outgoingHeartbeatSequenceNumber,
                        acknowledgedSequenceNumber: heartbeat.sequenceNumber
                    )))
        case .userUtterance(let utterance):
            // The session identity is captured now, from the authenticated
            // session this frame arrived on — before any asynchronous work.
            guard let originatingSessionIdentity = activeSessionIdentity else { return }
            process(
                utterance: utterance,
                audioData: frame.binaryPayload,
                originatingSessionIdentity: originatingSessionIdentity
            )
        case .presenceChanged(let presenceChange):
            guard remotePrivacyState.permitsCameraMedia else { return }
            companionManager?.companionRuntime.acceptRemotePresenceChange(
                isUserPresent: presenceChange.isUserPresent,
                confidence: presenceChange.confidence,
                observedAt: presenceChange.observedAt
            )
        case .cameraFrameResponse(let cameraFrameResponse):
            guard remotePrivacyState.permitsCameraMedia else { return }
            resolveCameraFrame(
                requestIdentifier: cameraFrameResponse.requestIdentifier,
                imageData: frame.binaryPayload
            )
        case .privacyStateChanged(let privacyState):
            remotePrivacyState = privacyState
            if !privacyState.permitsCameraMedia {
                cancelPendingCameraFrameRequests()
            }
        case .unpairRequest(let unpairRequest):
            guard unpairRequest.deviceIdentifier == activeDeviceIdentifier else {
                sendError(
                    code: "unpair_identity_mismatch",
                    message: "That iPad cannot remove this companion pairing.",
                    replyToMessageIdentifier: frame.message.messageIdentifier
                )
                return
            }
            unpairCurrentDevice()
        case .pairRequest, .pairResponse, .sessionHello, .interactionState,
            .assistantResponse, .proactiveMessage, .cameraFrameRequest, .error:
            sendError(
                code: "unexpected_message",
                message: "That message type is not accepted by Que on Mac.",
                replyToMessageIdentifier: frame.message.messageIdentifier
            )
        }
    }

    private func process(
        utterance: PaceCompanionUserUtterance,
        audioData: Data,
        originatingSessionIdentity: PaceCompanionSessionIdentity
    ) {
        guard remotePrivacyState.permitsMicrophoneMedia else {
            sendError(
                code: "microphone_paused",
                message: "The iPad microphone is paused.",
                replyToMessageIdentifier: nil
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Every suspension below can outlast the session. Once the session
            // that sent this utterance is no longer the live one, the utterance
            // is dropped: nothing more is sent, and no turn is started.
            guard isCompanionSessionActive(originatingSessionIdentity) else { return }
            _ = send(
                payload: .interactionState(
                    PaceCompanionInteractionStateChange(
                        state: .transcribing,
                        turnIdentifier: utterance.turnIdentifier,
                        usesOffDevicePlanner: false
                    )))
            let temporaryAudioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("pacepad-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            do {
                try audioData.write(to: temporaryAudioURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: temporaryAudioURL) }
                let transcript = try await PaceAudioFileTranscriber.transcribeAudioFile(
                    at: temporaryAudioURL
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isCompanionSessionActive(originatingSessionIdentity) else { return }
                guard !transcript.isEmpty else {
                    sendError(
                        code: "empty_transcript",
                        message: "I couldn't hear enough speech to answer.",
                        replyToMessageIdentifier: nil
                    )
                    sendInteractionState(.idle)
                    return
                }

                var physicalSceneContext: String?
                if PaceCompanionPhysicalSceneRequestParser.requestsCameraContext(transcript),
                    remotePrivacyState.isCameraEnabled,
                    !remotePrivacyState.isAllCapturePaused,
                    let imageData = await requestCameraFrame(
                        originatingTurnIdentifier: utterance.turnIdentifier,
                        reason: "You asked Que about the physical scene."
                    )
                {
                    physicalSceneContext = await analyzePhysicalScene(
                        imageData: imageData,
                        userIntent: transcript
                    )
                }

                guard isCompanionSessionActive(originatingSessionIdentity) else { return }
                guard
                    companionManager?.submitPacePadTranscript(
                        transcript,
                        turnIdentifier: utterance.turnIdentifier,
                        physicalSceneContext: physicalSceneContext,
                        originatingSessionIdentity: originatingSessionIdentity
                    ) == true
                else {
                    sendError(
                        code: "pace_busy",
                        message: "Que is finishing another turn. Try again in a moment.",
                        replyToMessageIdentifier: nil
                    )
                    sendInteractionState(.idle)
                    return
                }
            } catch {
                try? FileManager.default.removeItem(at: temporaryAudioURL)
                guard isCompanionSessionActive(originatingSessionIdentity) else { return }
                sendError(
                    code: "transcription_failed",
                    message: "The iPad recording could not be transcribed locally.",
                    replyToMessageIdentifier: nil
                )
                sendInteractionState(.idle)
            }
        }
    }

    private func requestCameraFrame(
        originatingTurnIdentifier: String,
        reason: String
    ) async -> Data? {
        let requestIdentifier = UUID().uuidString
        let expiresAt = Date().addingTimeInterval(8)
        return await withCheckedContinuation { continuation in
            pendingCameraFrameContinuations[requestIdentifier] = continuation
            let didSend = send(
                payload: .cameraFrameRequest(
                    PaceCompanionCameraFrameRequest(
                        requestIdentifier: requestIdentifier,
                        originatingTurnIdentifier: originatingTurnIdentifier,
                        reason: reason,
                        expiresAt: expiresAt
                    )))
            guard didSend else {
                pendingCameraFrameContinuations.removeValue(forKey: requestIdentifier)?.resume(
                    returning: nil
                )
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.pendingCameraFrameContinuations
                    .removeValue(forKey: requestIdentifier)?
                    .resume(returning: nil)
            }
        }
    }

    private func resolveCameraFrame(requestIdentifier: String, imageData: Data) {
        pendingCameraFrameContinuations
            .removeValue(forKey: requestIdentifier)?
            .resume(returning: imageData)
    }

    private func cancelPendingCameraFrameRequests() {
        for pendingContinuation in pendingCameraFrameContinuations.values {
            pendingContinuation.resume(returning: nil)
        }
        pendingCameraFrameContinuations.removeAll()
    }

    private func analyzePhysicalScene(imageData: Data, userIntent: String) async -> String? {
        do {
            let analysisClient =
                try PaceCompanionScreenAnalysisClientFactory
                .makePrivacyPinnedLocalClient()
            let analysis = try await analysisClient.analyzeScreenshot(
                screenshotImageData: imageData,
                userIntent: "Describe only the physical scene details needed to answer: \(userIntent)"
            )
            let description = analysis.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty ? nil : description
        } catch {
            return nil
        }
    }

    private func sendInteractionState(_ voiceState: CompanionVoiceState) {
        if case .idle = voiceState,
            companionManager?.activePacePadTurnIdentifier != nil
        {
            sendError(
                code: "turn_ended_without_response",
                message: "Que could not finish that response. Please try again.",
                replyToMessageIdentifier: nil
            )
            companionManager?.abandonActivePacePadTurn()
        }
        let interactionState: PaceCompanionInteractionState =
            switch voiceState {
            case .idle: .idle
            case .listening: .listening
            case .processing: .processing
            case .responding: .speaking
            }
        _ = send(
            payload: .interactionState(
                PaceCompanionInteractionStateChange(
                    state: interactionState,
                    turnIdentifier: companionManager?.activePacePadTurnIdentifier,
                    usesOffDevicePlanner: companionManager?.activePacePadTurnIdentifier != nil
                        && companionManager?.isOffDeviceTurnInFlight == true
                )))
    }

    /// Sends on the authenticated session only. Nothing about the Mac's state
    /// is ever written to a connection that has not authenticated.
    @discardableResult
    private func send(
        payload: PaceCompanionMessagePayload,
        binaryPayload: Data = Data(),
        replyToMessageIdentifier: String? = nil
    ) -> Bool {
        guard isActiveSessionAuthenticated,
            let activeConnection,
            let activeSessionIdentifier
        else {
            return false
        }
        return send(
            payload: payload,
            binaryPayload: binaryPayload,
            to: activeConnection,
            sessionIdentifier: activeSessionIdentifier,
            replyToMessageIdentifier: replyToMessageIdentifier
        )
    }

    /// Sends to one specific connection. Used for the protocol replies an
    /// unauthenticated connection is owed (errors, the pairing liveness ack).
    @discardableResult
    private func send(
        payload: PaceCompanionMessagePayload,
        binaryPayload: Data = Data(),
        to connection: PaceCompanionServerConnection,
        sessionIdentifier: String,
        replyToMessageIdentifier: String? = nil
    ) -> Bool {
        let message = PaceCompanionMessage(
            payload: payload,
            sessionIdentifier: sessionIdentifier,
            replyToMessageIdentifier: replyToMessageIdentifier
        )
        do {
            try connection.send(
                PaceCompanionWireFrame(
                    message: message,
                    binaryPayload: binaryPayload
                ))
            return true
        } catch {
            return false
        }
    }

    private func sendError(
        code: String,
        message: String,
        replyToMessageIdentifier: String?
    ) {
        _ = send(
            payload: .error(
                PaceCompanionErrorMessage(
                    code: code,
                    message: message,
                    isRecoverable: true
                )),
            replyToMessageIdentifier: replyToMessageIdentifier
        )
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(PaceCompanionProtocol.heartbeatIntervalSeconds))
                guard let self, !Task.isCancelled else { return }
                if PaceCompanionConnectionPolicy.heartbeatHasTimedOut(
                    lastHeartbeatReceivedAt: lastHeartbeatReceivedAt,
                    now: now()
                ) {
                    let timedOutConnection = activeConnection
                    clearActiveSession()
                    timedOutConnection?.cancel()
                    connectionStatus = listener == nil ? .stopped : .advertising
                    return
                }
                outgoingHeartbeatSequenceNumber += 1
                _ = send(
                    payload: .heartbeat(
                        PaceCompanionHeartbeat(
                            sequenceNumber: outgoingHeartbeatSequenceNumber,
                            acknowledgedSequenceNumber: nil
                        )))
            }
        }
    }

    private func clearActiveSession() {
        let endedSessionIdentity = activeSessionIdentity
        activeSessionIdentity = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        activeConnection = nil
        activeSessionIdentifier = nil
        activeDeviceIdentifier = nil
        isActiveSessionAuthenticated = false
        remotePrivacyState = PaceCompanionPrivacyState(
            isMicrophoneEnabled: false,
            isCameraEnabled: false,
            isSpeakerMuted: false,
            isAllCapturePaused: true
        )
        cancelPendingCameraFrameRequests()
        // Last, once this server no longer considers the session live: a turn
        // the ended session started is cancelled and its reply is dropped.
        if let endedSessionIdentity {
            companionManager?.companionSessionDidEnd(endedSessionIdentity)
        }
    }
}
