//
//  PaceLMStudioModelLoaderGatingTests.swift
//  leanring-buddyTests
//
//  The LM Studio warmup/keepalive may only target models whose configured endpoint
//  is LM Studio (port 1234), and the keepalive may only start once LM Studio answered.
//  Regression: with the planner on Ollama, the loader still pinged the planner model at
//  127.0.0.1:1234/api/v1/chat every 60 seconds.
//

import Foundation
import Testing
@testable import Pace

struct PaceLMStudioModelLoaderGatingTests {

    private let ollamaPlannerURL = URL(string: "http://127.0.0.1:11434/v1")!
    private let lmStudioURL = URL(string: "http://127.0.0.1:1234/v1")!

    private func warmupTargets(
        plannerBaseURL: URL,
        plannerModelIdentifier: String = "qwen2.5:3b",
        isPlannerServedInProcess: Bool = false,
        isScreenAnalysisEnabled: Bool,
        vlmBaseURL: URL,
        vlmModelIdentifier: String = "qwen/qwen3.5-4b",
        isVLMServedInProcess: Bool = false
    ) -> PaceLMStudioModelLoader.WarmupTargets {
        PaceLMStudioModelLoader.warmupTargets(
            plannerBaseURL: plannerBaseURL,
            plannerModelIdentifier: plannerModelIdentifier,
            isPlannerServedInProcess: isPlannerServedInProcess,
            isScreenAnalysisEnabled: isScreenAnalysisEnabled,
            vlmBaseURL: vlmBaseURL,
            vlmModelIdentifier: vlmModelIdentifier,
            isVLMServedInProcess: isVLMServedInProcess
        )
    }

    @Test func ollamaPlannerWithScreenAnalysisOffTargetsNothing() {
        let targets = warmupTargets(plannerBaseURL: ollamaPlannerURL, isScreenAnalysisEnabled: false, vlmBaseURL: lmStudioURL)
        #expect(targets.isEmpty)
        #expect(!PaceLMStudioModelLoader.shouldStartKeepalive(targets: targets, isLMStudioReachable: true))
    }

    @Test func ollamaPlannerIsNeverSentToLMStudio() {
        let targets = warmupTargets(plannerBaseURL: ollamaPlannerURL, isScreenAnalysisEnabled: true, vlmBaseURL: lmStudioURL)
        #expect(targets.plannerModelIdentifier == nil)
        #expect(targets.vlmModelIdentifier == "qwen/qwen3.5-4b")
    }

    @Test func screenAnalysisOnOllamaIsNotTargeted() {
        let targets = warmupTargets(plannerBaseURL: ollamaPlannerURL, isScreenAnalysisEnabled: true, vlmBaseURL: ollamaPlannerURL)
        #expect(targets.isEmpty)
    }

    @Test func bothRolesOnLMStudioAreTargeted() {
        let targets = warmupTargets(
            plannerBaseURL: lmStudioURL,
            plannerModelIdentifier: "qwen3-4b-instruct",
            isScreenAnalysisEnabled: true,
            vlmBaseURL: lmStudioURL
        )
        #expect(targets == .init(plannerModelIdentifier: "qwen3-4b-instruct", vlmModelIdentifier: "qwen/qwen3.5-4b"))
    }

    @Test func oneModelServingBothRolesIsWarmedOnce() {
        let targets = warmupTargets(
            plannerBaseURL: lmStudioURL,
            plannerModelIdentifier: "qwen/qwen3.5-4b",
            isScreenAnalysisEnabled: true,
            vlmBaseURL: lmStudioURL,
            vlmModelIdentifier: "qwen/qwen3.5-4b"
        )
        #expect(targets == .init(plannerModelIdentifier: "qwen/qwen3.5-4b", vlmModelIdentifier: nil))
    }

    @Test func lmStudioPlannerWithScreenAnalysisOffTargetsPlannerOnly() {
        let targets = warmupTargets(plannerBaseURL: lmStudioURL, isScreenAnalysisEnabled: false, vlmBaseURL: lmStudioURL)
        #expect(targets == .init(plannerModelIdentifier: "qwen2.5:3b", vlmModelIdentifier: nil))
    }

    @Test func inProcessModelsAreNeverTargeted() {
        let targets = warmupTargets(
            plannerBaseURL: lmStudioURL,
            isPlannerServedInProcess: true,
            isScreenAnalysisEnabled: true,
            vlmBaseURL: lmStudioURL,
            isVLMServedInProcess: true
        )
        #expect(targets.isEmpty)
    }

    @Test func keepaliveRequiresReachableLMStudio() {
        let targets = PaceLMStudioModelLoader.WarmupTargets(plannerModelIdentifier: nil, vlmModelIdentifier: "qwen/qwen3.5-4b")
        #expect(!PaceLMStudioModelLoader.shouldStartKeepalive(targets: targets, isLMStudioReachable: false))
        #expect(PaceLMStudioModelLoader.shouldStartKeepalive(targets: targets, isLMStudioReachable: true))
    }
}
