//
//  PaceLocalPlannerReachabilityTests.swift
//  leanring-buddyTests
//
//  The panel's reachability indicator reports the *local planner's* server, not LM Studio.
//  Regression: it read only Info.plist `LocalPlannerBaseURL` (falling back to port 1234)
//  and was labelled "LM Studio", so with the planner on Ollama and LM Studio closed the
//  log said "LM Studio reachability: up" and the panel showed LM Studio as reachable.
//

import Foundation
import Testing
@testable import Pace

struct PaceLocalPlannerReachabilityTests {

    private let ollamaPlannerURL = URL(string: "http://127.0.0.1:11434/v1")!
    private let lmStudioPlannerURL = URL(string: "http://127.0.0.1:1234/v1")!

    @Test func probeTargetsTheConfiguredPlannerModelList() {
        #expect(
            PaceLocalPlannerBackendSettings.reachabilityProbeURL(plannerBaseURL: ollamaPlannerURL).absoluteString
                == "http://127.0.0.1:11434/v1/models"
        )
        #expect(
            PaceLocalPlannerBackendSettings.reachabilityProbeURL(plannerBaseURL: lmStudioPlannerURL).absoluteString
                == "http://127.0.0.1:1234/v1/models"
        )
    }

    @Test func ollamaPlannerIsNeverLabelledLMStudio() {
        #expect(PaceLocalPlannerBackendSettings.backendDisplayName(url: ollamaPlannerURL) == "Ollama")
    }

    @Test func lmStudioPlannerIsLabelledLMStudio() {
        #expect(PaceLocalPlannerBackendSettings.backendDisplayName(url: lmStudioPlannerURL) == "LM Studio")
    }

    @Test func otherLoopbackServerGetsNeutralLabel() {
        let otherLoopbackURL = URL(string: "http://127.0.0.1:8080/v1")!
        #expect(PaceLocalPlannerBackendSettings.backendDisplayName(url: otherLoopbackURL) == "local server")
    }

    @Test func presetBaseURLsProbeTheirOwnServer() {
        let ollamaPresetURL = URL(string: PaceLocalPlannerPreset.ollama.defaultBaseURL)!
        let lmStudioPresetURL = URL(string: PaceLocalPlannerPreset.lmStudio.defaultBaseURL)!
        #expect(PaceLocalPlannerBackendSettings.reachabilityProbeURL(plannerBaseURL: ollamaPresetURL).port == 11434)
        #expect(PaceLocalPlannerBackendSettings.backendDisplayName(url: ollamaPresetURL) == "Ollama")
        #expect(PaceLocalPlannerBackendSettings.reachabilityProbeURL(plannerBaseURL: lmStudioPresetURL).port == 1234)
        #expect(PaceLocalPlannerBackendSettings.backendDisplayName(url: lmStudioPresetURL) == "LM Studio")
    }

    /// The Planner settings tab ("Default: Ollama with …", tier title "Local — Ollama")
    /// and the Bundled Models brain picker ("Local — Ollama") label the default local
    /// planner from `PaceLocalPlannerPreset.ollama.defaultModelIdentifier`; pin that the
    /// preset is really Ollama's port and the qwen2.5:3b model so the labels cannot drift.
    @Test func defaultLocalPlannerLabelMatchesTheOllamaPreset() {
        let ollamaPresetURL = URL(string: PaceLocalPlannerPreset.ollama.defaultBaseURL)!
        #expect(PaceLocalPlannerBackendSettings.backendDisplayName(url: ollamaPresetURL) == "Ollama")
        #expect(PaceLocalPlannerPreset.ollama.defaultModelIdentifier == "qwen2.5:3b")
    }

    /// The indicator must follow the planner's own resolution (env → UserDefaults →
    /// Info.plist → default), not a separate Info.plist-only read.
    @Test func probeFollowsTheEffectivePlannerBaseURL() {
        let effectivePlannerBaseURL = PaceLocalPlannerBackendSettings.effectiveBaseURL()
        let probeURL = PaceLocalPlannerBackendSettings.reachabilityProbeURL(plannerBaseURL: effectivePlannerBaseURL)
        #expect(probeURL.host == effectivePlannerBaseURL.host)
        #expect(probeURL.port == effectivePlannerBaseURL.port)
        #expect(probeURL.path == effectivePlannerBaseURL.appendingPathComponent("models").path)
    }

    @MainActor
    @Test func reachabilityStateStartsFalseUntilTheFirstProbe() {
        let companionManager = CompanionManager()
        #expect(companionManager.isLocalPlannerReachable == false)
    }
}
