//
//  QExplicitApplicationOpenRecoveryTests.swift
//  leanring-buddyTests
//
//  Dogfood defect: "Open Safari" failed with QModelPlanParseError.unauthorizedRiskLevel
//  ("error 2"). qwen2.5:3b emitted valid JSON but declared `system.running_apps` at level1
//  and `ui.open_app` at level2; the parser correctly rejected the mismatch, and the
//  deterministic fallback only knew Calculator/Notes, so the turn failed.
//
//  Fix under test:
//   - an explicit "open <Application>" request recovers deterministically, with the
//     application name taken ONLY from the user's request and ui.open_app's registered risk;
//   - the parser still rejects every model-declared risk mismatch;
//   - a ui.open_app step with no application name fails closed in the parser and recovers
//     only from the user's request;
//   - conversational requests never become actions.
//
//  The model-facing schema keeps `riskLevel`: removing it let qwen2.5:3b's own plans pass
//  validation where they previously fell back to deterministic templates (QAgentE2ETests
//  test3 then read a non-existent model-chosen sandbox path). The parser, not the prompt,
//  is what keeps model-declared risk from ever being trusted.
//
//  Every router here writes its audit records to a temporary file, never the real q-audit.log.
//

import Foundation
import Testing
@testable import Pace

/// Scripted local backend: returns `scriptedResponses[callIndex]` (repeating the last one once
/// exhausted) and records every request.
private final class ScriptedPlannerBackend: QLocalModelBackend, @unchecked Sendable {
    let capabilities = QModelCapabilities(backend: .ollama, modelIdentifier: "qwen2.5:3b")
    private let scriptedResponses: [String]
    private(set) var receivedRequests: [QModelInferenceRequest] = []

    init(scriptedResponses: [String]) {
        self.scriptedResponses = scriptedResponses
    }

    func isAvailable() async -> Bool { true }

    func complete(request: QModelInferenceRequest) async throws -> QModelInferenceResponse {
        let responseIndex = min(receivedRequests.count, scriptedResponses.count - 1)
        receivedRequests.append(request)
        return QModelInferenceResponse(text: scriptedResponses[responseIndex], providerUsed: .ollama)
    }

    func streamInference(
        request: QModelInferenceRequest,
        onEvent: @Sendable @escaping (QCoreStreamEvent) -> Void
    ) async throws -> QModelInferenceResponse {
        let response = try await complete(request: request)
        onEvent(.textDelta(response.text))
        onEvent(.completed)
        return response
    }
}

private func makeTemporaryAuditLogURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("q-explicit-open-audit-\(UUID().uuidString).log")
}

/// A router that talks only to `backend` and audits only into `temporaryAuditLogURL`.
private func makeIsolatedRouter(backend: any QLocalModelBackend, temporaryAuditLogURL: URL) -> QModelRouter {
    let router = QModelRouter(localOnly: true)
    router.clearBackends()
    router.registerBackend(backend)
    router.setPriorityOrder([backend.capabilities.backend])
    router.auditLogger = QAuditLogger(customLogURL: temporaryAuditLogURL)
    return router
}

/// The plan shape qwen2.5:3b produced for "Open Safari" in dogfood: valid JSON, wrong risks.
private func observedWrongRiskPlan(modelNamedApplication: String) -> String {
    """
    {
      "responseMode": "action",
      "taskPrompt": "Open \(modelNamedApplication)",
      "summary": "Opening \(modelNamedApplication)",
      "steps": [
        {
          "actionName": "system.running_apps",
          "toolFamily": "system",
          "riskLevel": "level1SafeLocalAction",
          "description": "Identify running applications",
          "targetResources": [],
          "parameters": {}
        },
        {
          "actionName": "ui.open_app",
          "toolFamily": "ui",
          "riskLevel": "level2UserApproval",
          "description": "Open \(modelNamedApplication)",
          "targetResources": ["\(modelNamedApplication)"],
          "parameters": {"appName": "\(modelNamedApplication)"}
        }
      ]
    }
    """
}

/// A ui.open_app step that names no application anywhere (seen in replay for "Open Mail").
private func namelessOpenApplicationPlan(modelDescription: String) -> String {
    """
    {
      "responseMode": "action",
      "summary": "\(modelDescription)",
      "steps": [
        {
          "actionName": "ui.open_app",
          "toolFamily": "app",
          "description": "\(modelDescription)",
          "targetResources": [],
          "parameters": {}
        }
      ]
    }
    """
}

private let registeredOpenApplicationRisk = QModelPlanParser.registeredCapabilities["ui.open_app"]!.defaultRisk

/// Asserts `result` is exactly one registered-risk ui.open_app step for `expectedApplicationName`.
private func expectSingleOpenApplicationStep(
    _ result: QParsedPlanResult,
    expectedApplicationName: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .plan(let plan) = result else {
        Issue.record("Expected a plan, got \(result)", sourceLocation: sourceLocation)
        return
    }
    #expect(plan.steps.count == 1, sourceLocation: sourceLocation)
    guard let onlyStep = plan.steps.first else { return }
    #expect(onlyStep.action.actionName == "ui.open_app", sourceLocation: sourceLocation)
    #expect(onlyStep.action.toolFamily == "app", sourceLocation: sourceLocation)
    #expect(onlyStep.action.riskLevel == registeredOpenApplicationRisk, sourceLocation: sourceLocation)
    #expect(onlyStep.action.arguments["appName"] == expectedApplicationName, sourceLocation: sourceLocation)
    #expect(onlyStep.action.targetResources == [expectedApplicationName], sourceLocation: sourceLocation)
}

struct QExplicitApplicationOpenRecoveryTests {

    // MARK: - Recovery from the observed wrong-risk plan

    @Test(
        "Explicit open request recovers from a wrong-risk model plan",
        arguments: ["Safari", "Mail", "Notes", "Calculator", "Pixelmator Pro"]
    )
    func explicitOpenRecoversFromWrongRiskPlan(applicationName: String) async throws {
        let temporaryAuditLogURL = makeTemporaryAuditLogURL()
        defer { try? FileManager.default.removeItem(at: temporaryAuditLogURL) }
        let backend = ScriptedPlannerBackend(scriptedResponses: [observedWrongRiskPlan(modelNamedApplication: applicationName)])
        let router = makeIsolatedRouter(backend: backend, temporaryAuditLogURL: temporaryAuditLogURL)

        let result = try await router.generateTurnPlan(for: QTask(intent: "Open \(applicationName)"))

        expectSingleOpenApplicationStep(result, expectedApplicationName: applicationName)
    }

    @Test func recoveredApplicationNameComesFromTheUserNotTheModel() async throws {
        let temporaryAuditLogURL = makeTemporaryAuditLogURL()
        defer { try? FileManager.default.removeItem(at: temporaryAuditLogURL) }
        let backend = ScriptedPlannerBackend(scriptedResponses: [observedWrongRiskPlan(modelNamedApplication: "Terminal")])
        let router = makeIsolatedRouter(backend: backend, temporaryAuditLogURL: temporaryAuditLogURL)

        let result = try await router.generateTurnPlan(for: QTask(intent: "Open Safari"))

        expectSingleOpenApplicationStep(result, expectedApplicationName: "Safari")
        if case .plan(let plan) = result {
            #expect(!plan.steps.contains { $0.action.arguments.values.contains("Terminal") || $0.action.targetResources.contains("Terminal") })
        }
    }

    @Test(
        "Ambiguous or malformed open request fails closed",
        arguments: ["Open Safari and go to GitHub", "Open a new tab", "open ~/.ssh/id_rsa", "Open https://example.com"]
    )
    func ambiguousOpenRequestFailsClosed(userRequest: String) async throws {
        let temporaryAuditLogURL = makeTemporaryAuditLogURL()
        defer { try? FileManager.default.removeItem(at: temporaryAuditLogURL) }
        let backend = ScriptedPlannerBackend(scriptedResponses: [observedWrongRiskPlan(modelNamedApplication: "Safari")])
        let router = makeIsolatedRouter(backend: backend, temporaryAuditLogURL: temporaryAuditLogURL)

        do {
            let result = try await router.generateTurnPlan(for: QTask(intent: userRequest))
            if case .plan(let plan) = result {
                #expect(
                    !plan.steps.contains { $0.action.actionName == "ui.open_app" },
                    "\(userRequest) produced an open-application step: \(plan.steps)"
                )
            }
        } catch let parseError as QModelPlanParseError {
            #expect(parseError == .unauthorizedRiskLevel(toolName: "system.running_apps", risk: "level1SafeLocalAction"))
        }
    }

    // MARK: - Explicit application name extraction (user request only)

    @Test(
        "Plain explicit open requests yield the application name",
        arguments: [
            ("Open Safari", "Safari"),
            ("open safari", "safari"),
            ("Open Mail.", "Mail"),
            ("Please open Notes", "Notes"),
            ("Open Calculator app", "Calculator"),
            ("Open Safari.app", "Safari"),
            ("Open Visual Studio Code", "Visual Studio Code"),
            ("open Pixelmator Pro!", "Pixelmator Pro")
        ]
    )
    func explicitOpenNameExtraction(userRequest: String, expectedApplicationName: String) {
        #expect(QModelRouter.explicitApplicationOpenName(fromUserRequest: userRequest) == expectedApplicationName)
    }

    @Test(
        "Anything that is not a plain explicit open request yields no name",
        arguments: [
            "", "open", "Open app", "Open the app", "Open a new tab", "Open Safari and go to GitHub",
            "Open Safari, then Mail", "open ~/.ssh/id_rsa", "open /Applications/Safari.app",
            "Open https://example.com", "Open the file report.txt", "What is Safari?", "Close Safari",
            "افتح Safari", "Open Safari; rm -rf ~", "Open \"Safari\"", "Open my clipboard",
            "Open one two three four five", "Open 1Password7"
        ]
    )
    func nonExplicitOpenRequestYieldsNoName(userRequest: String) {
        let extractedName = QModelRouter.explicitApplicationOpenName(fromUserRequest: userRequest)
        if userRequest == "Open 1Password7" {
            // Starts with a digit: not accepted as a plain application name (fails closed).
            #expect(extractedName == nil)
        } else {
            #expect(extractedName == nil, "\(userRequest) → \(extractedName ?? "nil")")
        }
    }

    // MARK: - Parser security: model risk mismatches are still rejected

    @Test func parserStillRejectsTheObservedWrongRiskPlan() {
        #expect(throws: QModelPlanParseError.unauthorizedRiskLevel(toolName: "system.running_apps", risk: "level1SafeLocalAction")) {
            try QModelPlanParser.parseResult(
                rawText: observedWrongRiskPlan(modelNamedApplication: "Safari"),
                taskId: "task-risk",
                taskPrompt: "Open Safari"
            )
        }
    }

    @Test(
        "Parser rejects every declared ui.open_app risk other than the registered one",
        arguments: ["level0ReadOnly", "level2UserApproval", "level3HighRisk", "level4Blocked", "safe", "none"]
    )
    func parserRejectsOpenApplicationRiskMismatch(declaredRisk: String) {
        let modelPlan = """
        {"responseMode":"action","steps":[{"actionName":"ui.open_app","toolFamily":"app","riskLevel":"\(declaredRisk)","description":"Open Safari","targetResources":["Safari"],"parameters":{"appName":"Safari"}}]}
        """
        #expect(throws: QModelPlanParseError.unauthorizedRiskLevel(toolName: "ui.open_app", risk: declaredRisk)) {
            try QModelPlanParser.parseResult(rawText: modelPlan, taskId: "task-risk", taskPrompt: "Open Safari")
        }
    }

    @Test func parserAcceptsOpenApplicationWithoutDeclaredRiskAndAssignsTheRegisteredOne() throws {
        let modelPlan = """
        {"responseMode":"action","steps":[{"actionName":"ui.open_app","toolFamily":"app","description":"Open Safari","targetResources":["Safari"],"parameters":{"appName":"Safari"}}]}
        """
        let result = try QModelPlanParser.parseResult(rawText: modelPlan, taskId: "task-risk", taskPrompt: "Open Safari")
        expectSingleOpenApplicationStep(result, expectedApplicationName: "Safari")
    }

    // MARK: - ui.open_app with no application name

    @Test func parserFailsClosedOnNamelessOpenApplication() {
        #expect(throws: QModelPlanParseError.missingRequiredField("step[0].parameters.appName")) {
            try QModelPlanParser.parseResult(
                rawText: namelessOpenApplicationPlan(modelDescription: "Open Mail"),
                taskId: "task-nameless",
                taskPrompt: "Open Mail"
            )
        }
    }

    @Test func namelessOpenApplicationRecoversOnlyFromTheUserRequest() async throws {
        let temporaryAuditLogURL = makeTemporaryAuditLogURL()
        defer { try? FileManager.default.removeItem(at: temporaryAuditLogURL) }
        // The model's prose mentions Terminal; the user asked for Safari. Only the user counts.
        let backend = ScriptedPlannerBackend(scriptedResponses: [namelessOpenApplicationPlan(modelDescription: "Open Terminal")])
        let router = makeIsolatedRouter(backend: backend, temporaryAuditLogURL: temporaryAuditLogURL)

        let result = try await router.generateTurnPlan(for: QTask(intent: "Open Safari"))

        expectSingleOpenApplicationStep(result, expectedApplicationName: "Safari")
    }

    @Test func namelessOpenApplicationWithoutExplicitUserRequestFailsClosed() async {
        let temporaryAuditLogURL = makeTemporaryAuditLogURL()
        defer { try? FileManager.default.removeItem(at: temporaryAuditLogURL) }
        let backend = ScriptedPlannerBackend(scriptedResponses: [namelessOpenApplicationPlan(modelDescription: "Open Terminal")])
        let router = makeIsolatedRouter(backend: backend, temporaryAuditLogURL: temporaryAuditLogURL)

        await #expect(throws: QModelPlanParseError.missingRequiredField("step[0].parameters.appName")) {
            _ = try await router.generateTurnPlan(for: QTask(intent: "Launch whatever I used yesterday"))
        }
    }

    // MARK: - Conversational requests never become actions

    @Test func conversationalRequestNeverBecomesAnAction() async throws {
        let conversationalRequest = "What is Safari?"
        #expect(!QDeterministicDecisionEngine.containsExecutionIndicators(intent: conversationalRequest))

        let temporaryAuditLogURL = makeTemporaryAuditLogURL()
        defer { try? FileManager.default.removeItem(at: temporaryAuditLogURL) }
        let backend = ScriptedPlannerBackend(scriptedResponses: [
            observedWrongRiskPlan(modelNamedApplication: "Safari"),
            #"{"responseMode":"directAnswer","directAnswer":"Safari is Apple's web browser."}"#
        ])
        let router = makeIsolatedRouter(backend: backend, temporaryAuditLogURL: temporaryAuditLogURL)

        let result = try await router.generateTurnPlan(for: QTask(intent: conversationalRequest))

        guard case .directAnswer(let directAnswer) = result else {
            Issue.record("Conversational request produced \(result)")
            return
        }
        #expect(directAnswer.text == "Safari is Apple's web browser.")
    }

    // MARK: - Audit isolation

    @Test func routerAuditRecordsGoToTheInjectedLogOnly() async throws {
        let temporaryAuditLogURL = makeTemporaryAuditLogURL()
        defer { try? FileManager.default.removeItem(at: temporaryAuditLogURL) }
        let backend = ScriptedPlannerBackend(scriptedResponses: [observedWrongRiskPlan(modelNamedApplication: "Safari")])
        let router = makeIsolatedRouter(backend: backend, temporaryAuditLogURL: temporaryAuditLogURL)

        _ = try await router.generateTurnPlan(for: QTask(intent: "Open Safari"))

        let temporaryAuditLogContents = try String(contentsOf: temporaryAuditLogURL, encoding: .utf8)
        #expect(temporaryAuditLogContents.contains("\"tool\":\"model.\(QModelBackendType.ollama.rawValue)\""))
        #expect(!temporaryAuditLogContents.contains("Open Safari"), "prompt text must stay out of the audit log")
    }

    // MARK: - Real Ollama (qwen2.5:3b on 127.0.0.1:11434)

    @Test("Real Ollama: explicit open requests plan a registered-risk ui.open_app", arguments: ["Safari", "Mail"])
    func realOllamaExplicitOpenPlansOpenApplication(applicationName: String) async throws {
        let ollamaBackend = QLocalhostHTTPBackend(
            capabilities: QModelCapabilities(backend: .ollama, modelIdentifier: "qwen2.5:3b", isLocalOnDevice: true),
            baseURL: URL(string: "http://127.0.0.1:11434")!
        )
        guard await ollamaBackend.isAvailable() else {
            print("ℹ️ Skipping real Ollama explicit-open validation: Ollama not reachable on 127.0.0.1:11434")
            return
        }
        let temporaryAuditLogURL = makeTemporaryAuditLogURL()
        defer { try? FileManager.default.removeItem(at: temporaryAuditLogURL) }
        let router = makeIsolatedRouter(backend: ollamaBackend, temporaryAuditLogURL: temporaryAuditLogURL)

        let result = try await router.generateTurnPlan(for: QTask(intent: "Open \(applicationName)"))
        print("🧪 REAL explicit open [Open \(applicationName)] result=\(result)")

        guard case .plan(let plan) = result else {
            Issue.record("Open \(applicationName) did not produce a plan: \(result)")
            return
        }
        let openApplicationSteps = plan.steps.filter { $0.action.actionName == "ui.open_app" }
        #expect(openApplicationSteps.count == 1)
        #expect(openApplicationSteps.first?.action.arguments["appName"]?.lowercased() == applicationName.lowercased())
        for step in plan.steps {
            #expect(step.action.riskLevel == QModelPlanParser.registeredCapabilities[step.action.actionName]?.defaultRisk)
        }
    }
}
