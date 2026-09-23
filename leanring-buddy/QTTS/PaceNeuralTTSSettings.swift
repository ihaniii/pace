//
//  PaceNeuralTTSSettings.swift
//  leanring-buddy
//
//  Opt-in developer/feature flag for Local Neural TTS (Sherpa-ONNX).
//  Default is strictly disabled (false), maintaining the existing
//  Apple AVSpeechSynthesizer production default.
//

import Foundation

public enum PaceNeuralTTSSettings {
    /// UserDefaults key governing opt-in activation of Neural TTS.
    public static let useLocalNeuralTTSKey = "PaceUseLocalNeuralTTS"

    /// Whether Neural TTS is active. Defaults to false.
    public static var isNeuralTTSEnabled: Bool {
        UserDefaults.standard.bool(forKey: useLocalNeuralTTSKey)
    }

    /// Sets the opt-in flag.
    public static func setNeuralTTSEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: useLocalNeuralTTSKey)
    }

    /// Resets the setting to default disabled state (for testing).
    public static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: useLocalNeuralTTSKey)
    }
}
