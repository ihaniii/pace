//
//  PaceTTSVoiceResolver.swift
//  leanring-buddy
//
//  Shared voice-picking logic for LocalTTSClient and the panel's voice
//  quality preflight row. Delegates to PaceSpeechVoiceResolver.
//

import AVFoundation
import Foundation

public enum PaceTTSVoiceResolver {
    /// Resolves the best installed voice, delegating to `PaceSpeechVoiceResolver` to prefer
    /// high-quality female Apple voices with deterministic fallback.
    public static func bestAvailableVoice(
        locale: String? = nil,
        preferredVoiceIdentifier: String? = nil
    ) -> AVSpeechSynthesisVoice? {
        PaceSpeechVoiceResolver.bestAvailableVoice(
            locale: locale,
            preferredVoiceIdentifier: preferredVoiceIdentifier
        )
    }

    /// Backward-compatible overload for existing callers without explicit locale.
    public static func bestAvailableVoice(
        preferredVoiceIdentifier: String? = nil
    ) -> AVSpeechSynthesisVoice? {
        bestAvailableVoice(locale: nil, preferredVoiceIdentifier: preferredVoiceIdentifier)
    }
}

public struct PaceTTSVoiceSummary: Equatable {
    public let voiceName: String
    public let qualityName: String
    public let needsUpgrade: Bool

    public var displayText: String {
        "\(voiceName) · \(qualityName)"
    }

    public var recommendationText: String {
        needsUpgrade
            ? "Install an Enhanced or Premium Apple voice for better playback."
            : "High-quality local Apple voice active."
    }

    public static func current() -> PaceTTSVoiceSummary {
        let preferredVoiceIdentifier = AppBundleConfiguration.stringValue(forKey: "LocalTTSVoiceIdentifier")
        guard let voice = PaceSpeechVoiceResolver.bestAvailableVoice(
            preferredVoiceIdentifier: preferredVoiceIdentifier
        ) else {
            return PaceTTSVoiceSummary(
                voiceName: "System voice",
                qualityName: "unknown",
                needsUpgrade: true
            )
        }

        switch voice.quality {
        case .premium:
            return PaceTTSVoiceSummary(voiceName: voice.name, qualityName: "Premium", needsUpgrade: false)
        case .enhanced:
            return PaceTTSVoiceSummary(voiceName: voice.name, qualityName: "Enhanced", needsUpgrade: false)
        default:
            return PaceTTSVoiceSummary(voiceName: voice.name, qualityName: "Compact", needsUpgrade: true)
        }
    }
}
