//
//  PaceLocalPlannerBackendSettings.swift
//  leanring-buddy
//
//  Controlled local planner backend configuration and provider switching.
//  Provides typed presets for Ollama and LM Studio with clean reversible overrides.
//  Maintains fail-closed loopback security invariants: strictly localhost only.
//

import Foundation

public enum PaceLocalPlannerPreset: String, CaseIterable, Sendable {
    case ollama = "ollama"
    case lmStudio = "lmStudio"

    public var defaultBaseURL: String {
        switch self {
        case .ollama:
            return "http://127.0.0.1:11434/v1"
        case .lmStudio:
            return "http://127.0.0.1:1234/v1"
        }
    }

    public var defaultModelIdentifier: String {
        switch self {
        case .ollama:
            return "qwen2.5:3b"
        case .lmStudio:
            return "qwen/qwen3.5-4b"
        }
    }

    public var isLMStudioNativeChatSupported: Bool {
        switch self {
        case .ollama:
            return false
        case .lmStudio:
            return true
        }
    }
}

public enum PaceLocalPlannerBackendSettings {
    public static let baseURLOverrideKey = "PaceLocalPlannerBaseURL"
    public static let modelIdentifierOverrideKey = "PaceLocalPlannerModelIdentifier"
    public static let activePresetKey = "PaceLocalPlannerActivePreset"

    /// Resolved base URL for the local planner.
    /// Priority: Environment variable -> UserDefaults override -> Info.plist -> Compile-time default.
    public static func effectiveBaseURL() -> URL {
        if let envURLString = ProcessInfo.processInfo.environment["PACE_LOCAL_PLANNER_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !envURLString.isEmpty {
            return PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
                configuredURLString: envURLString,
                settingName: "PACE_LOCAL_PLANNER_BASE_URL"
            )
        }

        if let userDefaultsURLString = UserDefaults.standard.string(forKey: baseURLOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !userDefaultsURLString.isEmpty {
            return PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
                configuredURLString: userDefaultsURLString,
                settingName: baseURLOverrideKey
            )
        }

        let configuredBaseURL = AppBundleConfiguration.stringValue(forKey: "LocalPlannerBaseURL")
            ?? PaceLocalPlannerPreset.ollama.defaultBaseURL

        return PaceLocalEndpointGuard.resolvedLocalOpenAICompatibleBaseURL(
            configuredURLString: configuredBaseURL,
            settingName: "LocalPlannerBaseURL"
        )
    }

    /// Resolved model identifier for the local planner.
    /// Priority: Environment variable -> UserDefaults override -> Info.plist -> Compile-time default.
    public static func effectiveModelIdentifier() -> String {
        if let envModel = ProcessInfo.processInfo.environment["PACE_LOCAL_PLANNER_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !envModel.isEmpty {
            return envModel
        }

        if let userDefaultsModel = UserDefaults.standard.string(forKey: modelIdentifierOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !userDefaultsModel.isEmpty {
            return userDefaultsModel
        }

        return AppBundleConfiguration.stringValue(forKey: "LocalPlannerModelIdentifier")
            ?? PaceLocalPlannerPreset.ollama.defaultModelIdentifier
    }

    /// Whether the current endpoint is recognized as LM Studio (port 1234),
    /// which supports the proprietary /api/v1/chat endpoint with `reasoning: "off"`.
    /// Ollama and standard OpenAI-compatible local engines return false.
    public static func isLMStudioBackend(url: URL) -> Bool {
        return url.port == 1234
    }

    /// Switch active local planner configuration to Ollama.
    public static func switchToOllama() {
        UserDefaults.standard.set(PaceLocalPlannerPreset.ollama.rawValue, forKey: activePresetKey)
        UserDefaults.standard.set(PaceLocalPlannerPreset.ollama.defaultBaseURL, forKey: baseURLOverrideKey)
        UserDefaults.standard.set(PaceLocalPlannerPreset.ollama.defaultModelIdentifier, forKey: modelIdentifierOverrideKey)
    }

    /// Switch active local planner configuration to LM Studio.
    public static func switchToLMStudio() {
        UserDefaults.standard.set(PaceLocalPlannerPreset.lmStudio.rawValue, forKey: activePresetKey)
        UserDefaults.standard.set(PaceLocalPlannerPreset.lmStudio.defaultBaseURL, forKey: baseURLOverrideKey)
        UserDefaults.standard.set(PaceLocalPlannerPreset.lmStudio.defaultModelIdentifier, forKey: modelIdentifierOverrideKey)
    }

    /// Reset overrides to fall back to Info.plist configuration.
    public static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: activePresetKey)
        UserDefaults.standard.removeObject(forKey: baseURLOverrideKey)
        UserDefaults.standard.removeObject(forKey: modelIdentifierOverrideKey)
    }
}
