import Foundation

@MainActor
protocol PacePadOutputDelegate: AnyObject {
    /// Delivers a turn's reply to the companion session it came from. Returns
    /// false, and sends nothing, when that session is no longer the live one.
    func deliverAssistantResponse(
        turnIdentifier: String,
        spokenText: String,
        usesOffDevicePlanner: Bool,
        originatingSessionIdentity: PaceCompanionSessionIdentity
    ) -> Bool

    func deliverProactiveMessage(_ utterance: PaceProactiveUtterance) -> Bool

    /// Whether this is the authenticated companion session right now.
    func isCompanionSessionActive(_ sessionIdentity: PaceCompanionSessionIdentity) -> Bool
}

@MainActor
extension CompanionManager {
    /// The trust boundary for iPad utterances (F-04b). `originatingSessionIdentity`
    /// is minted by `PaceCompanionServer` for the authenticated session the
    /// utterance arrived on; the turn carries it as its origin from here on.
    @discardableResult
    func submitPacePadTranscript(
        _ transcript: String,
        turnIdentifier: String,
        physicalSceneContext: String?,
        originatingSessionIdentity: PaceCompanionSessionIdentity
    ) -> Bool {
        guard voiceState == .idle else { return false }
        guard pacePadOutputDelegate?.isCompanionSessionActive(originatingSessionIdentity) == true else {
            return false
        }
        activePacePadTurnIdentifier = turnIdentifier
        activePacePadTurnSessionIdentity = originatingSessionIdentity
        activePacePadTurnUsesOffDevicePlanner = false
        pendingPacePadPhysicalSceneContext = physicalSceneContext

        // The Mac still owns the complete conversation pipeline, but its
        // speaker stays quiet for an iPad-originated turn because the iPad is
        // the user's selected audio surface for that interaction.
        isChatModeMutedForCurrentTurn = true
        submitChatTranscriptFromRemoteCompanion(
            transcript,
            originatingSessionIdentity: originatingSessionIdentity
        )
        return true
    }

    func consumePacePadPhysicalSceneContext() -> String? {
        defer { pendingPacePadPhysicalSceneContext = nil }
        return pendingPacePadPhysicalSceneContext
    }

    func abandonActivePacePadTurn() {
        activePacePadTurnIdentifier = nil
        activePacePadTurnSessionIdentity = nil
        activePacePadTurnUsesOffDevicePlanner = false
        pendingPacePadPhysicalSceneContext = nil
    }

    /// A local turn is always valid. A remote turn is valid only while the
    /// companion session it came from is still the authenticated session.
    func isTurnOriginStillValid(_ turnOrigin: PaceTurnOrigin) -> Bool {
        switch turnOrigin {
        case .local:
            return true
        case .remoteCompanion(let sessionIdentity):
            return pacePadOutputDelegate?.isCompanionSessionActive(sessionIdentity) == true
        }
    }

    /// Called by the companion server when an authenticated session ends for
    /// any reason (disconnect, timeout, replacement, unpair, opt-out, stop).
    /// A turn that session started does not outlive it: its remaining planner,
    /// action, and speech work is cancelled and its reply is never delivered.
    /// Turns of any other origin are left alone.
    func companionSessionDidEnd(_ endedSessionIdentity: PaceCompanionSessionIdentity) {
        if activePacePadTurnSessionIdentity == endedSessionIdentity {
            abandonActivePacePadTurn()
        }
        guard
            turnLeaseRegistry.currentTurnOrigin
                == .remoteCompanion(sessionIdentity: endedSessionIdentity)
        else {
            return
        }
        cancelCurrentTurnFromPanel()
    }

    /// The deterministic answer to a privileged voice command from a remote
    /// companion turn. Nothing is executed, the planner is never consulted
    /// (so it cannot route around the refusal), and the turn ends here.
    func refuseRemoteTurnCommand(
        _ refusedCommand: PaceRemoteTurnRefusedCommand,
        turnLease: PaceTurnLease
    ) {
        print("🛑 Remote companion turn refused: \(refusedCommand.rawValue) is Mac-only")
        if let activePacePadTurnIdentifier,
            let originatingSessionIdentity = turnLease.origin.originatingCompanionSessionIdentity,
            activePacePadTurnSessionIdentity == originatingSessionIdentity
        {
            _ = pacePadOutputDelegate?.deliverAssistantResponse(
                turnIdentifier: activePacePadTurnIdentifier,
                spokenText: PaceRemoteTurnCommandGate.refusalSpokenText,
                usesOffDevicePlanner: false,
                originatingSessionIdentity: originatingSessionIdentity
            )
        }
        abandonActivePacePadTurn()
        responseOverlayManager.finishStreaming()
        currentTurnHUDState = .unsupported(PaceRemoteTurnCommandGate.refusalSpokenText)
        voiceState = .idle
    }
}
