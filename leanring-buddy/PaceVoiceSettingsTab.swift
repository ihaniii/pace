//
//  PaceVoiceSettingsTab.swift
//  leanring-buddy
//
//  Settings → Voice tab content. Status rows for the active
//  transcription provider, transcription model readiness, and active
//  TTS voice quality. Surfaces the "open Spoken Content" deep-link
//  when the user is on a compact fallback voice.
//

import AppKit
import SwiftUI

struct PaceVoiceSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            paceSettingsInfoRow(title: "Transcription", value: companionManager.buddyDictationManager.transcriptionProviderDisplayName)
            paceSettingsInfoRow(title: "Transcription model", value: companionManager.isTranscriptionModelReady ? "Ready" : "Loading")
            Toggle("Local Neural Speech (Kokoro / Piper)", isOn: Binding(
                get: { PaceNeuralTTSSettings.isNeuralTTSEnabled },
                set: { newValue in
                    PaceNeuralTTSSettings.setNeuralTTSEnabled(newValue)
                    companionManager.reloadTTSClient()
                }
            ))
            .font(.system(size: 13, weight: .medium))
            paceSettingsInfoRow(title: "Active voice", value: PaceNeuralTTSSettings.isNeuralTTSEnabled ? "Kokoro (af_heart) / Piper (Alma)" : companionManager.activeTTSVoiceSummary.displayText)
            if !PaceNeuralTTSSettings.isNeuralTTSEnabled && companionManager.activeTTSVoiceSummary.needsUpgrade {
                Text(companionManager.activeTTSVoiceSummary.recommendationText)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            paceSettingsButton("Open Spoken Content", systemName: "speaker.wave.2") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
