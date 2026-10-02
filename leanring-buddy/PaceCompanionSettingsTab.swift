//
//  PaceCompanionSettingsTab.swift
//  leanring-buddy
//
//  Explicit opt-in, source transparency, retention, readiness, and clear
//  controls for Always-On Companion Mode.
//

import SwiftUI

struct PaceCompanionSettingsTab: View {
    @ObservedObject var controlCenter: PaceCompanionControlCenter
    @ObservedObject private var companionServer = PaceCompanionServer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            iPadCompanionSection
            statusCard

            paceSettingsToggleRow(
                title: "Always-On Companion Mode",
                subtitle: "Default off. Observe locally and remember structured changes only from sources you enable.",
                isOn: Binding(
                    get: { controlCenter.preferences.isCompanionModeEnabled },
                    set: { controlCenter.setModeEnabled($0) }
                )
            )

            if controlCenter.preferences.isCompanionModeEnabled {
                HStack {
                    paceSettingsButton("Pause now", systemName: "pause.fill") {
                        controlCenter.pause()
                    }
                    Spacer()
                }
            }

            sourceSection
            outputSection
            storageSection
        }
    }

    private var iPadCompanionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("iPad companion")
            paceSettingsToggleRow(
                title: "Allow an iPad companion",
                subtitle: "Default off. While on, Que accepts a local-network connection from the iPad you paired.",
                isOn: Binding(
                    get: { companionServer.isCompanionEnabled },
                    set: { companionServer.setCompanionEnabled($0) }
                )
            )
            .pointerCursor()

            if companionServer.isCompanionEnabled {
                Text(companionServerStatusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                if let pendingPairingConfirmation = companionServer.pendingPairingConfirmation {
                    pairingConfirmationCard(pendingPairingConfirmation)
                } else if let pairingCode = companionServer.pairingCode {
                    openPairingWindowCard(pairingCode: pairingCode)
                } else {
                    HStack(spacing: 8) {
                        paceSettingsButton(
                            companionServer.pairedDeviceName == nil ? "Pair an iPad" : "Pair a different iPad",
                            systemName: "link.badge.plus"
                        ) {
                            // The pressing event is passed through so an input event Que
                            // synthesized itself cannot open pairing.
                            companionServer.openPairingWindow(triggeringEvent: NSApp.currentEvent)
                        }
                        if companionServer.pairedDeviceName != nil {
                            paceSettingsButton("Unpair iPad", systemName: "link.badge.minus") {
                                companionServer.unpairCurrentDevice()
                            }
                        }
                        Spacer()
                    }
                    if let pairingWindowClosedText {
                        Text(pairingWindowClosedText)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }
            Text(
                "Discovery, speech, presence events, and requested camera stills stay "
                    + "on your local network. The Mac remains the only place that plans and remembers."
            )
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The pairing code, shown only while the pairing window is open.
    private func openPairingWindowCard(pairingCode: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing code")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(pairingCode)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.localSignal)
                    .textSelection(.enabled)
                if let pairingWindowExpiresAt = companionServer.pairingWindowExpiresAt {
                    HStack(spacing: 4) {
                        Text("Pairing closes in")
                        Text(pairingWindowExpiresAt, style: .timer)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                }
            }
            Spacer()
            paceSettingsButton("Cancel pairing", systemName: "xmark") {
                companionServer.cancelPairingWindow()
            }
        }
    }

    /// Nothing is stored for the requesting device until "Allow" is pressed.
    /// The name and identifier are whatever the device sent, so they are
    /// presented as its claim.
    private func pairingConfirmationCard(
        _ pendingPairingConfirmation: PaceCompanionPendingPairingConfirmation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A device entered the pairing code and wants to pair")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(
                "It calls itself “\(pendingPairingConfirmation.deviceDisplayName)” "
                    + "(ID ending \(pendingPairingConfirmation.deviceIdentifierDisplaySuffix))."
            )
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if let replacedPairedDeviceName = pendingPairingConfirmation.replacedPairedDeviceName {
                Text("Allowing it replaces your current pairing with \(replacedPairedDeviceName).")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                paceSettingsButton("Deny", systemName: "xmark") {
                    companionServer.declinePendingPairing()
                }
                paceSettingsButton("Allow", systemName: "checkmark") {
                    // The pressing event is passed through so an input event Que
                    // synthesized itself cannot approve a pairing.
                    companionServer.confirmPendingPairing(triggeringEvent: NSApp.currentEvent)
                }
                Spacer()
            }
        }
    }

    private var pairingWindowClosedText: String? {
        switch companionServer.lastPairingWindowCloseReason {
        case .expired:
            return "Pairing closed: the code expired."
        case .tooManyFailedAttempts:
            return "Pairing closed after too many failed attempts."
        case .declined:
            return "Pairing denied."
        case .paired, .cancelled, .companionDisabled, .serverStopped, .none:
            return nil
        }
    }

    private var companionServerStatusText: String {
        switch companionServer.connectionStatus {
        case .stopped:
            return companionServer.pairedDeviceName == nil
                ? "No iPad paired"
                : "iPad companion server stopped"
        case .advertising:
            if companionServer.pairingCode != nil {
                return "Ready to pair an iPad"
            }
            if let pairedDeviceName = companionServer.pairedDeviceName {
                return "Waiting for \(pairedDeviceName)"
            }
            return "Ready to pair an iPad"
        case .connected(let deviceName):
            return "Connected to \(deviceName)"
        case .unavailable(let reason):
            return "Local connection unavailable: \(reason)"
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(controlCenter.runtimeStatusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Text(controlCenter.isLocalModelReady ? "Local model ready" : "Local model unavailable")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(controlCenter.isLocalModelReady ? .green : DS.Colors.textTertiary)
            }
            Text(activeSourceSummary)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
            if let lastObservationAt = controlCenter.lastObservationAt {
                Text("Last structured observation: \(lastObservationAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Sources")
            sourceToggle(.camera, title: "Camera", subtitle: "Low-rate motion/object gating in named zones. Separate camera permission required.")
            sourceToggle(.ambientVoice, title: "Ambient voice", subtitle: "Local VAD/wake gate; no transcription before wake and no raw-audio persistence.")
            sourceToggle(.screen, title: "Screen Watch events", subtitle: "Uses the existing explicit Watch Mode loop; no duplicate screen polling.")
            sourceToggle(.macOSContext, title: "Mac context", subtitle: "Frontmost app, window metadata, displays, and time — no screen pixels.")
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Interventions")
            paceSettingsToggleRow(
                title: "Silent cards",
                subtitle: "Locked until observe-only accuracy and resource acceptance is documented and met.",
                isOn: Binding(
                    get: { controlCenter.preferences.areSilentCardsEnabled },
                    set: { controlCenter.setSilentCardsEnabled($0) }
                )
            )
            .disabled(PaceCompanionControlCenter.silentCardsAcceptancePassed == false)
            .opacity(PaceCompanionControlCenter.silentCardsAcceptancePassed ? 1 : 0.55)
            paceSettingsToggleRow(
                title: "Spoken interventions",
                subtitle: "Locked until repetition/interruption acceptance passes; then every utterance still passes restraint.",
                isOn: Binding(
                    get: { controlCenter.preferences.areSpokenInterventionsEnabled },
                    set: { controlCenter.setSpokenInterventionsEnabled($0) }
                )
            )
            .disabled(PaceCompanionControlCenter.spokenInterventionsAcceptancePassed == false)
            .opacity(PaceCompanionControlCenter.spokenInterventionsAcceptancePassed ? 1 : 0.55)
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Structured memory")
            Stepper(
                "Retention: \(controlCenter.preferences.structuredObservationRetentionDays) days",
                value: Binding(
                    get: { controlCenter.preferences.structuredObservationRetentionDays },
                    set: { controlCenter.setRetentionDays($0) }
                ),
                in: 1...90
            )
            .font(.system(size: 13))
            .foregroundColor(DS.Colors.textPrimary)
            .pointerCursor()

            Text("Storage used: \(ByteCountFormatter.string(fromByteCount: Int64(controlCenter.structuredStorageByteCount), countStyle: .file))")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)

            HStack {
                ForEach(clearableSources, id: \.rawValue) { source in
                    paceSettingsButton("Clear \(displayName(for: source))", systemName: "trash") {
                        controlCenter.clear(source: source)
                    }
                }
                Spacer()
                paceSettingsButton("Clear all", systemName: "trash.fill") {
                    controlCenter.clearAll()
                }
            }
        }
    }

    private func sourceToggle(
        _ source: PacePerceptionSourceKind,
        title: String,
        subtitle: String
    ) -> some View {
        paceSettingsToggleRow(
            title: title,
            subtitle: subtitle,
            isOn: Binding(
                get: { controlCenter.preferences.enabledSources.contains(source) },
                set: { controlCenter.setSource(source, enabled: $0) }
            )
        )
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.bottom, 6)
    }

    private var clearableSources: [PacePerceptionSourceKind] {
        [.camera, .ambientVoice, .screen, .macOSContext]
    }

    private var activeSourceSummary: String {
        guard controlCenter.activeSources.isEmpty == false else { return "No sources actively sampling" }
        return "Active: " + controlCenter.activeSources.map(displayName).sorted().joined(separator: ", ")
    }

    private func displayName(for source: PacePerceptionSourceKind) -> String {
        switch source {
        case .camera: return "camera"
        case .ambientVoice: return "voice"
        case .screen: return "screen"
        case .macOSContext: return "Mac context"
        case .userCorrection: return "corrections"
        }
    }

    private var statusColor: Color {
        switch controlCenter.runtimeState {
        case .observing: return .green
        case .interpreting: return .cyan
        case .paused: return .yellow
        case .degraded: return .orange
        case .privacyBlocked: return .red
        case .off, .starting: return DS.Colors.textTertiary
        }
    }
}
