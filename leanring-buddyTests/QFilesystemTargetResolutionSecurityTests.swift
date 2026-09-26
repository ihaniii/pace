//
//  QFilesystemTargetResolutionSecurityTests.swift
//  leanring-buddyTests
//
//  Regression for a QResourceGuard bypass: when a model's fs.read / fs.write_sandbox step
//  omitted `parameters.path`, `QModelPlanParser.validateSteps` substituted the benign sandbox
//  default AND overwrote `targetResources`, so a requested `~/.ssh/id_rsa` never reached
//  QResourceGuard and the task reported success. The parser must hand the REQUESTED resource
//  to the guard; the sandbox default applies only when no target was requested at all.
//

import Testing
import Foundation
@testable import Pace

/// Scripted structured provider that runs the model JSON through the REAL `QModelPlanParser`.
private final class ScriptedFilesystemPlanProvider: QStructuredModelProvider, @unchecked Sendable {
    private let scriptedPlanJSON: String

    init(scriptedPlanJSON: String) {
        self.scriptedPlanJSON = scriptedPlanJSON
    }

    func generatePlan(for task: QTask) async throws -> [QActionRequest] { [] }

    func generateStructuredPlan(for task: QTask, memoryContext: String?, failureContext: String?) async throws -> QPlan {
        let parsed = try QModelPlanParser.parseResult(
            rawText: scriptedPlanJSON,
            taskId: task.taskId,
            taskPrompt: task.intent,
            sessionId: task.sessionId
        )
        guard case .plan(let plan) = parsed else {
            throw QModelPlanParseError.unexpectedDirectAnswer
        }
        return plan
    }

    func generateGroundedSummary(for task: QTask, verifiedEvidence: [String], isSuccess: Bool) async throws -> String {
        isSuccess ? "Done." : "Failed."
    }
}

private func filesystemStepJSON(actionName: String, targetResources: [String], parameters: [String: String] = [:]) -> String {
    let riskLevel = actionName == "fs.read" ? "level0ReadOnly" : "level1SafeLocalAction"
    let stepObject: [String: Any] = [
        "actionName": actionName,
        "toolFamily": "fs",
        "riskLevel": riskLevel,
        "description": "\(actionName) step",
        "targetResources": targetResources,
        "parameters": parameters
    ]
    let planObject: [String: Any] = ["responseMode": "action", "taskPrompt": "filesystem request", "steps": [stepObject]]
    let data = try! JSONSerialization.data(withJSONObject: planObject)
    return String(data: data, encoding: .utf8)!
}

private func parsedSingleStep(actionName: String, targetResources: [String], parameters: [String: String] = [:]) throws -> QPlannedAction {
    let parsed = try QModelPlanParser.parseResult(
        rawText: filesystemStepJSON(actionName: actionName, targetResources: targetResources, parameters: parameters),
        taskId: "fs-target-\(UUID().uuidString)",
        taskPrompt: "filesystem request"
    )
    guard case .plan(let plan) = parsed, let step = plan.steps.first else {
        throw QModelPlanParseError.emptySteps
    }
    return step.action
}

/// Protected credential locations covered by QResourceGuard's absolute denylist / sensitive
/// filename rules — every one must be denied, never swapped for the sandbox default.
private let protectedCredentialPaths: [String] = [
    "~/.ssh/id_rsa",
    "~/.ssh/id_ed25519",
    "\(NSHomeDirectory())/.ssh/id_rsa",
    "~/.aws/credentials",
    "~/.gnupg/private-keys-v1.d/secret.key",
    "~/.config/gh/hosts.yml",
    "~/Library/Keychains/login.keychain-db",
    "/etc/passwd",
    "../../../../.ssh/id_rsa"
]

@Suite("QFilesystemTargetResolutionSecurityTests")
struct QFilesystemTargetResolutionSecurityTests {

    // MARK: - Parser

    @Test("fs.read without path adopts the requested target instead of the sandbox default", arguments: ["~/.ssh/id_rsa", "/etc/passwd"])
    func readAdoptsRequestedTarget(requestedTarget: String) throws {
        let action = try parsedSingleStep(actionName: "fs.read", targetResources: [requestedTarget])
        #expect(action.arguments["path"] == requestedTarget)
        #expect(action.targetResources == [requestedTarget])
        #expect(!(action.arguments["path"] ?? "").hasSuffix("test-sandbox-data.txt"))
    }

    @Test("fs.write_sandbox without path adopts the requested target")
    func writeAdoptsRequestedTarget() throws {
        let action = try parsedSingleStep(actionName: "fs.write_sandbox", targetResources: ["~/.ssh/authorized_keys"])
        #expect(action.arguments["path"] == "~/.ssh/authorized_keys")
        #expect(action.targetResources == ["~/.ssh/authorized_keys"])
    }

    @Test("The sandbox default applies only when no target was requested", arguments: [[String](), ["   "]])
    func sandboxDefaultOnlyWithoutTarget(targetResources: [String]) throws {
        let action = try parsedSingleStep(actionName: "fs.read", targetResources: targetResources)
        let expectedDefault = (QResourceGuard.filesystemCapabilitySandboxRoot as NSString).appendingPathComponent("test-sandbox-data.txt")
        #expect(action.arguments["path"] == expectedDefault)
        #expect(action.targetResources == [expectedDefault])
    }

    @Test("A relative requested target is still jailed inside the sandbox")
    func relativeTargetIsJailed() throws {
        let action = try parsedSingleStep(actionName: "fs.read", targetResources: ["notes.txt"])
        let expectedPath = (QResourceGuard.filesystemCapabilitySandboxRoot as NSString).appendingPathComponent("notes.txt")
        #expect(action.arguments["path"] == expectedPath)
        #expect(action.targetResources == [expectedPath])
    }

    @Test("An explicit path keeps its existing precedence over targetResources")
    func explicitPathPrecedence() throws {
        let action = try parsedSingleStep(actionName: "fs.read", targetResources: ["~/.ssh/id_rsa"], parameters: ["path": "~/.aws/credentials"])
        #expect(action.arguments["path"] == "~/.aws/credentials")
        #expect(action.targetResources == ["~/.aws/credentials"])
    }

    // MARK: - Guard (after parsing)

    @Test("Every protected credential path reaches QResourceGuard and is denied", arguments: protectedCredentialPaths)
    func protectedTargetsAreDeniedByGuard(protectedPath: String) throws {
        let action = try parsedSingleStep(actionName: "fs.read", targetResources: [protectedPath])
        #expect(!action.targetResources.isEmpty)
        for resource in action.targetResources {
            guard case .denied = QResourceGuard.validateSandboxedFilesystemAccess(path: resource) else {
                Issue.record("QResourceGuard allowed \(resource) (requested \(protectedPath))")
                continue
            }
        }
    }

    // MARK: - End to end (QCoreRuntime → QPlanExecutor → QResourceGuard)

    @Test("Runtime denies protected fs.read targets and never dispatches them", arguments: protectedCredentialPaths)
    func runtimeDeniesProtectedRead(protectedPath: String) async throws {
        let executionProvider = MockExecutionProvider()
        let runtime = QCoreRuntime(
            modelProvider: ScriptedFilesystemPlanProvider(scriptedPlanJSON: filesystemStepJSON(actionName: "fs.read", targetResources: [protectedPath])),
            executionProvider: executionProvider,
            endpointName: "fs-target-read-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Read the file \(protectedPath)")

        guard case .failed(let reason) = task.state else {
            Issue.record("Expected QResourceGuard denial for \(protectedPath), got \(task.state)")
            return
        }
        #expect(reason.contains("Security Guard Denied"))
        #expect(executionProvider.executedActions.isEmpty, "must never dispatch a protected path")
    }

    @Test("Runtime denies a protected fs.write_sandbox target without path")
    func runtimeDeniesProtectedWrite() async throws {
        let executionProvider = MockExecutionProvider()
        let runtime = QCoreRuntime(
            modelProvider: ScriptedFilesystemPlanProvider(scriptedPlanJSON: filesystemStepJSON(actionName: "fs.write_sandbox", targetResources: ["~/.ssh/authorized_keys"])),
            executionProvider: executionProvider,
            endpointName: "fs-target-write-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "Write to the file ~/.ssh/authorized_keys")

        guard case .failed(let reason) = task.state else {
            Issue.record("Expected QResourceGuard denial, got \(task.state)")
            return
        }
        #expect(reason.contains("Security Guard Denied"))
        #expect(executionProvider.executedActions.isEmpty)
    }

    @Test("A step with no requested target still uses the sandbox default and is allowed to dispatch")
    func runtimeSandboxDefaultStillWorks() async throws {
        let executionProvider = MockExecutionProvider()
        let runtime = QCoreRuntime(
            modelProvider: ScriptedFilesystemPlanProvider(scriptedPlanJSON: filesystemStepJSON(actionName: "fs.read", targetResources: [])),
            executionProvider: executionProvider,
            endpointName: "fs-target-default-\(UUID().uuidString)"
        )
        _ = try await runtime.submitIntent(prompt: "Read the file")

        let dispatchedPaths = executionProvider.executedActions.compactMap { $0.parameters["path"] }
        #expect(!dispatchedPaths.isEmpty, "the benign sandbox default must still be dispatched")
        #expect(dispatchedPaths.allSatisfy { path in
            path.hasPrefix(QResourceGuard.filesystemCapabilitySandboxRoot)
        })
    }
}
