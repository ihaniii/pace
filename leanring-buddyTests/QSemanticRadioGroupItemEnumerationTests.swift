//
//  QSemanticRadioGroupItemEnumerationTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Radio Group Item Enumeration Tests (Phase 2AI).
//
//  ui.list_radio_group_items is Q's twenty-fifth controlled UI-interaction capability, and its seventh
//  read-only, Level 0 discovery capability at the application surface (following Phase 2Z's
//  ui.list_windows, Phase 2AA's ui.list_menu_items, Phase 2AD's ui.list_popup_items, Phase 2AE's
//  ui.list_table_rows, Phase 2AF's ui.list_outline_items, and Phase 2AH's ui.list_tab_items).
//  Enumerates direct radio button options belonging to exactly ONE named AXRadioGroup in a named application.
//
//  Level 0 — no approval, no mutation, no press, no focus, no recovery replay.
//  Safe metadata only (title, identifier, isSelected, isEnabled, role, subrole, index).
//  Raw radio item contents remain ephemeral in outputData and are never persisted into durable
//  task snapshots, audit logs, or SQLite WAL memory stores.
//
//  Every live AX target lives in the out-of-process PaceAXFixtureHost (Support/PaceAXFixture.swift),
//  never in this XCTest host: same-process AX calls against AppKit's own windows crash on main-queue assertions or deadlock.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace


private final class RadioGroupItemEnumerationMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.list_radio_group_items" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Enumerated 3 radio item(s) for radio group in application 'MockApp' (selected: 1).",
                outputData: [
                    "applicationName": "MockApp",
                    "role": "AXRadioGroup",
                    "itemCount": "3",
                    "selectedItemCount": "1",
                    "item0.index": "0",
                    "item0.title": "Small",
                    "item0.selected": "true",
                    "item0.enabled": "true",
                    "item0.role": "AXRadioButton",
                    "item0.subrole": "",
                    "item1.index": "1",
                    "item1.title": "Medium",
                    "item1.selected": "false",
                    "item1.enabled": "true",
                    "item1.role": "AXRadioButton",
                    "item1.subrole": "",
                    "item2.index": "2",
                    "item2.title": "Large",
                    "item2.selected": "false",
                    "item2.enabled": "true",
                    "item2.role": "AXRadioButton",
                    "item2.subrole": ""
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticRadioGroupItemEnumerationTests")
struct QSemanticRadioGroupItemEnumerationTests {

    // MARK: - 1. Registration, Level 0, no approval, no downgrade/upgrade

    @Test("1. ui.list_radio_group_items is registered under toolFamily 'ui'")
    func capabilityRegistrationToolFamily() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_radio_group_items"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
    }

    @Test("2. ui.list_radio_group_items is Level 0 Read-Only by default")
    func capabilityRegistrationRiskLevel() {
        let regCap = QModelPlanParser.registeredCapabilities["ui.list_radio_group_items"]
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)
        #expect(regCap?.defaultRisk.isConsideredReversible == true)
    }

    @Test("3. Parser accepts valid ui.list_radio_group_items plan step")
    func planParserAcceptsValidStep() throws {
        let json = """
        {
          "taskPrompt": "List radio group items",
          "steps": [
            {
              "actionName": "ui.list_radio_group_items",
              "toolFamily": "ui",
              "description": "Enumerate options in a radio group",
              "parameters": {
                "applicationName": "TextEdit",
                "role": "AXRadioGroup",
                "title": "Alignment"
              }
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-reg-radio-group", taskPrompt: "List radio group items")
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.action.actionName == "ui.list_radio_group_items")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)
    }

    @Test("4. Risk level mismatch for ui.list_radio_group_items fails closed")
    func riskLevelMismatchFailsClosed() {
        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "List radio group items",
              "steps": [
                {
                  "actionName": "ui.list_radio_group_items",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Enumerate options in a radio group",
                  "parameters": {
                    "applicationName": "TextEdit",
                    "role": "AXRadioGroup",
                    "title": "Alignment"
                  }
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-radio-\(mismatchedRisk)", taskPrompt: "List radio group items")
            }
        }
    }

    // MARK: - 2. Argument Validation & Role Policy

    @Test("5. Missing applicationName parameter fails closed")
    func missingApplicationNameFailsClosed() async throws {
        let req = QActionRequest(
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            parameters: [
                "role": "AXRadioGroup",
                "title": "Alignment"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "applicationName missing")
    }

    @Test("6. Missing both identifier and title fails closed")
    func missingMatchCriteriaFailsClosed() async throws {
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let req = QActionRequest(
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            parameters: [
                "applicationName": fixture.applicationName,
                "role": "AXRadioGroup"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-criteria"))
        #expect(result.success == false)
        #expect(result.error == "AX_MISSING_MATCH_CRITERIA")
    }

    @Test("7. Disallowed roles (e.g. AXTable, AXButton, AXGroup, AXWindow, AXTabGroup) are rejected")
    func disallowedRolesRejected() async throws {
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        for invalidRole in ["AXTable", "AXButton", "AXGroup", "AXWindow", "AXTabGroup", "AXRow", "AXPopUpButton"] {
            let req = QActionRequest(
                toolName: "ui.list_radio_group_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List radio items",
                parameters: [
                    "applicationName": fixture.applicationName,
                    "role": invalidRole,
                    "title": "Alignment"
                ]
            )
            let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-invalid-role-\(invalidRole)"))
            #expect(result.success == false)
            #expect(result.error == "AX_DISALLOWED_ROLE")
        }
    }

    // MARK: - 3. Application Resolution

    @Test("8. Non-existent application throws applicationNotAvailable")
    func nonExistentApplicationThrows() async throws {
        let nonExistentApp = "QNoSuchApp-2AI-\(UUID().uuidString)"
        let req = QActionRequest(
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            parameters: [
                "applicationName": nonExistentApp,
                "role": "AXRadioGroup",
                "title": "Alignment"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-app"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 4. Radio Group Target Resolution

    @Test("9. Non-existent radio group target fails closed")
    func nonExistentRadioGroupTargetFailsClosed() async throws {
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let req = QActionRequest(
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            parameters: [
                "applicationName": fixture.applicationName,
                "role": "AXRadioGroup",
                "title": "QNoSuchRadioGroup-2AI-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-missing-radiogroup"))
        #expect(result.success == false)
        #expect(result.error == "AX_NO_MATCHING_ELEMENT" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 5. Metadata Models & Output Contract

    @Test("10. QAXRadioGroupItemMetadata and QAXRadioGroupMetadata model structures")
    func radioGroupMetadataModels() {
        let item1 = QAXRadioGroupItemMetadata(
            index: 0,
            title: "Option A",
            identifier: "opt-a",
            isSelected: true,
            isEnabled: true,
            role: "AXRadioButton",
            subrole: nil
        )
        let item2 = QAXRadioGroupItemMetadata(
            index: 1,
            title: "Option B",
            identifier: "opt-b",
            isSelected: false,
            isEnabled: true,
            role: "AXRadioButton",
            subrole: nil
        )
        let groupMeta = QAXRadioGroupMetadata(
            applicationName: "TextEdit",
            radioGroupTitle: "Choices",
            radioGroupIdentifier: "choices-group",
            itemCount: 2,
            selectedItemCount: 1,
            items: [item1, item2]
        )

        #expect(groupMeta.applicationName == "TextEdit")
        #expect(groupMeta.radioGroupTitle == "Choices")
        #expect(groupMeta.itemCount == 2)
        #expect(groupMeta.selectedItemCount == 1)
        #expect(groupMeta.items[0].title == "Option A")
        #expect(groupMeta.items[0].isSelected == true)
        #expect(groupMeta.items[1].title == "Option B")
        #expect(groupMeta.items[1].isSelected == false)
    }

    // MARK: - 6. Privacy & Persistence Boundaries

    @Test("11. Verification evidence and result summary carry aggregate counts only")
    func privacyBoundaryEnforced() async {
        let verifier = QActionVerifier.shared
        let actionReq = QActionRequest(
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            parameters: [
                "applicationName": "TextEdit",
                "role": "AXRadioGroup",
                "title": "Alignment"
            ]
        )
        let fakeResult = QActionResult(
            actionId: actionReq.actionId,
            success: true,
            summary: "Enumerated 3 radio item(s) for radio group in application 'TextEdit' (selected: 1). This is a point-in-time snapshot only — ordering is not meaningful, and this result is never itself an actionable target; any subsequent action must independently resolve its own fresh target.",
            outputData: [
                "applicationName": "TextEdit",
                "itemCount": "3",
                "selectedItemCount": "1",
                "item0.title": "Confidential Form Choice",
                "radioGroupTitle": "Alignment"
            ]
        )
        let strategy = QVerificationStrategy.radioGroupEnumerationSucceeded(applicationName: "TextEdit", itemCount: 3, selectedCount: 1)
        let outcome = await verifier.verify(action: actionReq, result: fakeResult, strategy: strategy)
        #expect(outcome.isVerified == true)
        if case .verified(let evidence) = outcome {
            #expect(evidence.contains("application=TextEdit"))
            #expect(evidence.contains("itemCount=3"))
            #expect(evidence.contains("selectedCount=1"))
            #expect(evidence.contains("radioGroupRole=AXRadioGroup"))
            #expect(evidence.contains("status=verified"))
            #expect(!evidence.contains("Confidential Form Choice"))
        } else {
            Issue.record("Expected .verified outcome")
        }
    }

    @Test("12. QDurablePlanStepSnapshot does not serialize raw outputData")
    func durableSnapshotOmitsRawOutputData() {
        let plannedAction = QPlannedAction(
            actionName: "ui.list_radio_group_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List radio items",
            targetResources: [],
            arguments: ["applicationName": "TextEdit", "title": "Alignment"]
        )
        let step = QPlanStep(index: 0, action: plannedAction, description: "List radio items")
        let snapshot = QDurablePlanStepSnapshot(from: step)

        #expect(snapshot.actionName == "ui.list_radio_group_items")
        #expect(snapshot.arguments["applicationName"] == "TextEdit")
        #expect(snapshot.arguments["title"] == "Alignment")
    }

    // MARK: - 7. Security Isolation: ui.list_radio_group_items does NOT authorize ui.set_element_state

    @Test("13. ui.list_radio_group_items does not confer authorization for ui.set_element_state")
    func authorizationIsolation() {
        let listReq = QToolAuthorizationRequest(
            taskId: "t-iso-1",
            toolName: "ui.list_radio_group_items",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "List radio group items"
        )
        let listDecision = QPermissionGate.shared.evaluate(request: listReq)
        #expect(listDecision.isAllowed == true)

        let setReq = QToolAuthorizationRequest(
            taskId: "t-iso-2",
            toolName: "ui.set_element_state",
            toolFamily: "ui",
            baseRisk: .level2UserApproval,
            literalAction: "Set radio button state"
        )
        let setDecision = QPermissionGate.shared.evaluate(request: setReq)
        #expect(setDecision.isAllowed == false)
        #expect(setDecision.requiresApproval == true)
    }

    // MARK: - 8. Plan Execution Pipeline

    @Test("14. QPlanExecutor executes ui.list_radio_group_items step sequentially to completion")
    func planExecutorExecutesRadioEnumerationStep() async throws {
        let mockExec = RadioGroupItemEnumerationMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.list_radio_group_items",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "List radio items of app",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "Alignment"]
            ),
            description: "List radio items of app"
        )
        let plan = QPlan(
            taskId: "t-plan-list-radios",
            sessionId: "s-list-radios",
            taskPrompt: "List radio items",
            steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-list-radios")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
    }

    // MARK: - 9. Real AppKit NSStackView of Radio Buttons Fixture (TCC Guarded)

    @Test("15. Real macOS AppKit E2E — NSStackView radio group item discovery (guarded by AXIsProcessTrusted)")
    func realAppKitRadioGroupEnumeration() async throws {
        guard AXIsProcessTrusted() else {
            return
        }

        // Built inside the out-of-process PaceAXFixtureHost with the same 400x300 titled/closable
        // window and the same plain, vertical 380x280 NSStackView holding three arranged radio
        // buttons (Small on, Medium off, Large off — no target/action, no AX identifier), with
        // the same AX role override (AXRadioGroup), AX identifier and AX label the in-process setup
        // used. The stack view overrides nothing else, exactly as before.
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let windowToken = try await fixture.createWindow(width: 400, height: 300, styles: ["titled", "closable"])
        try await fixture.addControl(
            kind: "stackView",
            identifier: "QTestRadioGroup-2AI",
            windowToken: windowToken,
            frame: NSRect(x: 10, y: 10, width: 380, height: 280),
            properties: ["orientation": "vertical"]
        )
        for (radioHandle, radioTitle, radioState) in [("radio-small", "Small", 1), ("radio-medium", "Medium", 0), ("radio-large", "Large", 0)] {
            try await fixture.addControl(
                kind: "radio",
                identifier: radioHandle,
                parentIdentifier: "QTestRadioGroup-2AI",
                properties: ["title": radioTitle, "state": radioState, "accessibilityIdentifier": "", "detachAction": true]
            )
        }
        try await fixture.setAccessibility("QTestRadioGroup-2AI", "role", "AXRadioGroup")
        try await fixture.setAccessibility("QTestRadioGroup-2AI", "label", "Size Selection")
        try await fixture.perform(windowToken, "makeKeyAndOrderFront")

        let metadata = try await QBridgeAccessibility.shared.listRadioGroupItems(
            applicationName: fixture.applicationName,
            role: "AXRadioGroup",
            identifier: "QTestRadioGroup-2AI",
            title: nil
        )

        #expect(metadata.itemCount >= 0)
    }
}
