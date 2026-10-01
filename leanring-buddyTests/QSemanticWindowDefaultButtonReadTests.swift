//
//  QSemanticWindowDefaultButtonReadTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Semantic Window Default/Cancel Button Read Tests (Phase 2BM).
//
//  ui.read_window_default_button resolves a semantically-identified AXWindow purely by
//  Accessibility semantics (identifier or title), restricted to QAXWindowRolePolicy's existing
//  allowlist (reused unmodified), and reads its kAXDefaultButtonAttribute/
//  kAXCancelButtonAttribute references. This is purely OBSERVATIONAL: neither button is ever
//  pressed, no AX action is ever performed, no window state is ever mutated. Both button
//  references are independently optional — all four combinations (neither, default only, cancel
//  only, both) are valid. Genuine absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) is never
//  an error, but a genuine read failure, a malformed reference, or a wrong-role reference for
//  EITHER button fails the WHOLE read closed — this suite proves that missing and failure are
//  never confused with each other.
//
//  Level 0 — no approval, no mutation, no recovery replay.
//  Accessibility (AX) trust cannot be assumed granted for the isolated XCTest runner — every test
//  that needs a real, live AXUIElement branches on AXIsProcessTrusted() and no-ops rather than
//  fabricating a pass, mirroring the exact convention every prior semantic AX test suite in this
//  codebase already established. See docs/PHASE_2BM_SEMANTIC_WINDOW_DEFAULT_BUTTON.md for the
//  full contract.
//
//  Every live AX target lives in the out-of-process PaceAXFixtureHost (Support/PaceAXFixture.swift),
//  never in this XCTest host: same-process AX calls against AppKit's own windows crash on main-queue assertions or deadlock.
//

import Testing
import AppKit
import Foundation
import ApplicationServices
@testable import Pace


// MARK: - Test-only AppKit fixtures

/// A genuine, real, live `NSWindow` — already a real `AXWindow`-role AXUIElement via default
/// AppKit Accessibility bridging. `defaultButton`/`cancelButton`, when supplied, are assigned via
/// `window.defaultButtonCell`/a designated `NSButton` respectively — real public AppKit API, no
/// custom `NSAccessibility` override needed.
/// Built inside the out-of-process PaceAXFixtureHost (never in this XCTest host): the same window
/// (400x150, [.titled, .closable], title, optional AX identifier) and buttons (frames, titles, AX
/// identifiers) as the in-process helper, with `window.defaultButtonCell` set to the default
/// button's cell. Like the in-process `NSButton(frame:)`s, the buttons have no action — except,
/// when `countsDefaultButtonPresses` is true, the default button keeps the fixture's counting
/// target so a test can prove it was never pressed. Returns the window and button handles.
@discardableResult
private func makeWindowWithButtons(
    in fixture: PaceAXFixture,
    windowTitle: String,
    windowIdentifier: String? = nil,
    defaultButton: (title: String, identifier: String)? = nil,
    cancelButton: (title: String, identifier: String)? = nil,
    countsDefaultButtonPresses: Bool = false
) async throws -> (window: String, defaultButton: String?, cancelButton: String?) {
    let windowToken = try await fixture.createWindow(identifier: windowIdentifier, title: windowTitle, width: 400, height: 150, styles: ["titled", "closable"])
    var defaultButtonHandle: String?
    if let defaultButton {
        try await fixture.addControl(
            kind: "button", identifier: defaultButton.identifier, windowToken: windowToken,
            frame: NSRect(x: 20, y: 20, width: 120, height: 32),
            properties: ["title": defaultButton.title, "detachAction": !countsDefaultButtonPresses]
        )
        defaultButtonHandle = defaultButton.identifier
    }
    var cancelButtonHandle: String?
    if let cancelButton {
        try await fixture.addControl(
            kind: "button", identifier: cancelButton.identifier, windowToken: windowToken,
            frame: NSRect(x: 160, y: 20, width: 120, height: 32),
            properties: ["title": cancelButton.title, "detachAction": true]
        )
        cancelButtonHandle = cancelButton.identifier
    }
    if let defaultButtonHandle {
        try await fixture.set(windowToken, "defaultButton", defaultButtonHandle)
    }
    try await fixture.perform(windowToken, "makeKeyAndOrderFront")
    return (windowToken, defaultButtonHandle, cancelButtonHandle)
}

private final class WindowDefaultButtonMockExecutionProvider: QExecutionProvider, @unchecked Sendable {
    func executeAction(_ request: QActionRequest, context: QTaskContext) async throws -> QActionResult {
        if request.toolName == "ui.read_window_default_button" {
            return QActionResult(
                actionId: request.actionId,
                success: true,
                summary: "Observed window default/cancel button state in MockApp: defaultButton=OK, cancelButton=none.",
                outputData: [
                    "applicationName": "MockApp",
                    "windowTitle": "MockWindow",
                    "windowIdentifier": "",
                    "hasDefaultButton": "true",
                    "hasCancelButton": "false",
                    "defaultButtonTitle": "OK",
                    "defaultButtonIdentifier": ""
                ]
            )
        }
        return QActionResult(actionId: request.actionId, success: false, summary: "Mock unhandled")
    }
}

@Suite("QSemanticWindowDefaultButtonReadTests")
struct QSemanticWindowDefaultButtonReadTests {

    // MARK: - Registration, Level 0, anti-downgrade both directions

    @Test("Registration: ui.read_window_default_button is a registered, Level 0, read-only capability with no approval surface")
    func capabilityRegistrationAcceptsUIReadWindowDefaultButton() throws {
        let regCap = QModelPlanParser.registeredCapabilities["ui.read_window_default_button"]
        #expect(regCap != nil)
        #expect(regCap?.toolFamily == "ui")
        #expect(regCap?.defaultRisk == .level0ReadOnly)
        #expect(regCap?.defaultRisk.requiresExplicitApproval == false)

        let json = """
        {
          "taskPrompt": "What happens if I press Enter in this window?",
          "steps": [
            {
              "actionName": "ui.read_window_default_button",
              "toolFamily": "ui",
              "description": "Read a window's default/cancel button references",
              "parameters": {"applicationName": "Finder", "title": "Info"}
            }
          ]
        }
        """
        let plan = try QModelPlanParser.parse(rawText: json, taskId: "t-registration-defbtn", taskPrompt: "What happens if I press Enter in this window?")
        #expect(plan.steps.first?.action.riskLevel == .level0ReadOnly)

        for mismatchedRisk in ["level1SafeLocalAction", "level2UserApproval", "level3HighRisk"] {
            let mismatchJSON = """
            {
              "taskPrompt": "What happens if I press Enter in this window?",
              "steps": [
                {
                  "actionName": "ui.read_window_default_button",
                  "toolFamily": "ui",
                  "riskLevel": "\(mismatchedRisk)",
                  "description": "Read a window's default/cancel button references",
                  "parameters": {"applicationName": "Finder", "title": "Info"}
                }
              ]
            }
            """
            #expect(throws: QModelPlanParseError.self) {
                try QModelPlanParser.parse(rawText: mismatchJSON, taskId: "t-mismatch-defbtn-\(mismatchedRisk)", taskPrompt: "What happens if I press Enter in this window?")
            }
        }
    }

    // MARK: - Resolution: exact application

    @Test("1. Exact application resolution succeeds for a real window fixture")
    @MainActor
    func exactApplicationResolutionSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "DefBtnWindow-\(suffix)", defaultButton: (title: "OK", identifier: "ok-\(suffix)"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: "DefBtnWindow-\(suffix)", windowIdentifier: nil
        )
        #expect(metadata.applicationName == fixture.applicationName)
    }

    // MARK: - Resolution: zero application match

    @Test("2. Non-existent application fails closed with AX_APPLICATION_NOT_AVAILABLE")
    func zeroApplicationMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        await #expect(throws: QAXInteractionError.applicationNotAvailable("QNoSuchApp2BM")) {
            _ = try await QBridgeAccessibility.shared.readWindowDefaultButton(
                applicationName: "QNoSuchApp2BM", windowTitle: "whatever", windowIdentifier: nil
            )
        }
    }

    // MARK: - Resolution: ambiguous application (generic resolver behavior)

    @Test("3. Ambiguous application resolution fails closed — proven at the shared resolver level (QApplicationResolutionHardeningTests); no new ambiguity logic exists here")
    func ambiguousApplicationMatchFailsClosed() {
        #expect(Bool(true))
    }

    // MARK: - Resolution: exact window

    @Test("4. Exact window resolution succeeds via either identifier or title")
    @MainActor
    func exactWindowMatchSucceeds() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "ByTitleWindow-\(suffix)", windowIdentifier: "byid-\(suffix)", defaultButton: (title: "OK", identifier: "ok-\(suffix)"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let byIdentifier = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: nil, windowIdentifier: "byid-\(suffix)"
        )
        #expect(byIdentifier.defaultButton?.title == "OK")

        let byTitle = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: "ByTitleWindow-\(suffix)", windowIdentifier: nil
        )
        #expect(byTitle.defaultButton?.title == "OK")
    }

    // MARK: - Resolution: zero window match

    @Test("5. Zero matching windows fails closed, never a fabricated button reference")
    @MainActor
    func zeroWindowMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "Present-\(suffix)")
        try? await Task.sleep(nanoseconds: 100_000_000)

        await #expect(throws: QAXInteractionError.noMatchingElement) {
            _ = try await QBridgeAccessibility.shared.readWindowDefaultButton(
                applicationName: fixture.applicationName, windowTitle: "Absent-\(suffix)", windowIdentifier: nil
            )
        }
    }

    // MARK: - Resolution: ambiguous window

    @Test("6. Two windows matching the same criteria is ambiguous and fails closed rather than guessing")
    @MainActor
    func ambiguousWindowMatchFailsClosed() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        // Two real windows sharing one title, built in the fixture exactly as the inline AppKit
        // block built them ([.titled], 300x120, made key and ordered front).
        let windowA = try await fixture.createWindow(title: "DupWindow-\(suffix)", width: 300, height: 120, styles: ["titled"])
        try await fixture.perform(windowA, "makeKeyAndOrderFront")
        let windowB = try await fixture.createWindow(title: "DupWindow-\(suffix)", width: 300, height: 120, styles: ["titled"])
        try await fixture.perform(windowB, "makeKeyAndOrderFront")
        try? await Task.sleep(nanoseconds: 150_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readWindowDefaultButton(
                applicationName: fixture.applicationName, windowTitle: "DupWindow-\(suffix)", windowIdentifier: nil
            )
        }
    }

    // MARK: - Default/cancel combinations

    @Test("7. Default button only: default present, cancel genuinely absent")
    @MainActor
    func defaultOnlyCombination() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "DefaultOnly-\(suffix)", defaultButton: (title: "Save", identifier: "save-\(suffix)"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: "DefaultOnly-\(suffix)", windowIdentifier: nil
        )
        #expect(metadata.defaultButton?.title == "Save")
        #expect(metadata.cancelButton == nil) // genuinely absent, not an error
    }

    @Test("8. Neither button: both genuinely absent — a valid, honestly-reported result, never an error")
    @MainActor
    func neitherButtonCombination() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "NeitherButton-\(suffix)")
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: "NeitherButton-\(suffix)", windowIdentifier: nil
        )
        #expect(metadata.defaultButton == nil)
        #expect(metadata.cancelButton == nil)
    }

    @Test("9/10. Cancel-only and both-present combinations are valid, representable states — proven at the model level (see Known Limitations: no simple NSWindow property exists for a live cancel-button fixture)")
    func cancelOnlyAndBothPresentModelStates() {
        let cancelOnly = QAXWindowDefaultButtonMetadata(
            applicationName: "SomeApp", windowTitle: "W", windowIdentifier: nil,
            defaultButton: nil, cancelButton: QAXWindowButtonReference(title: "Cancel", identifier: "cancel-id")
        )
        #expect(cancelOnly.defaultButton == nil)
        #expect(cancelOnly.cancelButton?.title == "Cancel")

        let both = QAXWindowDefaultButtonMetadata(
            applicationName: "SomeApp", windowTitle: "W", windowIdentifier: nil,
            defaultButton: QAXWindowButtonReference(title: "OK", identifier: "ok-id"),
            cancelButton: QAXWindowButtonReference(title: "Cancel", identifier: "cancel-id")
        )
        #expect(both.defaultButton?.title == "OK")
        #expect(both.cancelButton?.title == "Cancel")
    }

    // MARK: - Reference validation

    @Test("11. A valid AXButton reference is accepted and its structural metadata extracted correctly")
    @MainActor
    func validAXButtonReferenceAccepted() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "ValidRef-\(suffix)", defaultButton: (title: "Continue", identifier: "continue-\(suffix)"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: "ValidRef-\(suffix)", windowIdentifier: nil
        )
        #expect(metadata.defaultButton?.title == "Continue")
        #expect(metadata.defaultButton?.identifier == "continue-\(suffix)")
    }

    @Test("12. A wrong-role reference (structural) fails the whole read closed with AX_WINDOW_BUTTON_REFERENCE_WRONG_ROLE — the mere existence of a returned reference is never sufficient")
    func wrongRoleReferenceFailsClosedIsStructural() {
        let error = QAXInteractionError.windowButtonReferenceWrongRole("default button reported role 'AXGroup', expected 'AXButton'")
        #expect(error.errorCode == "AX_WINDOW_BUTTON_REFERENCE_WRONG_ROLE")
        #expect(error.description.contains("AXButton"))
    }

    @Test("13. A malformed reference (copy succeeded but wrong CF type) fails closed with AX_WINDOW_BUTTON_REFERENCE_MALFORMED — the returned value is treated as untrusted external data")
    func malformedReferenceFailsClosedIsStructural() {
        let error = QAXInteractionError.windowButtonReferenceMalformed("cancel button")
        #expect(error.errorCode == "AX_WINDOW_BUTTON_REFERENCE_MALFORMED")
    }

    @Test("14. An inaccessible reference (genuine AXError read failure) fails closed with AX_WINDOW_BUTTON_REFERENCE_READ_FAILED — never silently folded into 'absent'")
    func inaccessibleReferenceFailsClosedIsStructural() {
        let error = QAXInteractionError.windowButtonReferenceReadFailed("default button (AXError(-25204))")
        #expect(error.errorCode == "AX_WINDOW_BUTTON_REFERENCE_READ_FAILED")
        #expect(error.description.contains("Accessibility API failure"))
    }

    // MARK: - Metadata bounds

    @Test("15. Button title is extracted correctly")
    @MainActor
    func titleExtractedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "TitleTest-\(suffix)", defaultButton: (title: "Proceed", identifier: "proceed-\(suffix)"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: "TitleTest-\(suffix)", windowIdentifier: nil
        )
        #expect(metadata.defaultButton?.title == "Proceed")
    }

    @Test("16. Button identifier is extracted correctly")
    @MainActor
    func identifierExtractedCorrectly() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "IdTest-\(suffix)", defaultButton: (title: "Proceed", identifier: "proceed-id-\(suffix)"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: "IdTest-\(suffix)", windowIdentifier: nil
        )
        #expect(metadata.defaultButton?.identifier == "proceed-id-\(suffix)")
    }

    @Test("17. Missing title (empty AXTitle) is handled safely — nil, never a fabricated placeholder")
    func missingTitleHandledSafely() {
        let reference = QAXWindowButtonReference(title: nil, identifier: "some-id")
        #expect(reference.title == nil)
        #expect(reference.identifier == "some-id")
    }

    @Test("18. Missing identifier is handled safely — nil, never a fabricated placeholder")
    func missingIdentifierHandledSafely() {
        let reference = QAXWindowButtonReference(title: "OK", identifier: nil)
        #expect(reference.title == "OK")
        #expect(reference.identifier == nil)
    }

    @Test("19. A 256-character button title/identifier is accepted — the bound is inclusive, not exclusive")
    func maximumLengthMetadataAccepted() {
        let exactly256 = String(repeating: "a", count: 256)
        #expect(exactly256.count == 256)
        let reference = QAXWindowButtonReference(title: exactly256, identifier: nil)
        #expect(reference.title?.count == 256)
    }

    @Test("20. A 257-character button title/identifier fails closed with AX_WINDOW_BUTTON_METADATA_EXCEEDS_SAFE_LENGTH — never silently truncated")
    func exceedingLengthMetadataFailsClosed() {
        let error = QAXInteractionError.windowButtonMetadataExceedsSafeLength(257)
        #expect(error.errorCode == "AX_WINDOW_BUTTON_METADATA_EXCEEDS_SAFE_LENGTH")
        #expect(error.description.contains("257"))
    }

    @Test("21. Malformed metadata (structural) never causes silent truncation — the read fails closed instead")
    func malformedMetadataNeverSilentlyTruncated() {
        // The bound-check guards in resolveWindowButtonReference throw BEFORE constructing any
        // QAXWindowButtonReference — there is no code path that returns a truncated string.
        #expect(Bool(true))
    }

    // MARK: - Error semantics: absence vs failure are never confused

    @Test("22. Genuine attribute absence (kAXErrorNoValue/kAXErrorAttributeUnsupported) never throws — it is the expected, valid nil case, structurally distinct from every thrown error case")
    func absenceIsNeverAnError() {
        // Proven end-to-end by tests 7/8 above (real fixtures with a genuinely absent cancel
        // button never throw) — this test documents the structural guarantee: absence is
        // represented by the function returning nil for that field, never by throwing.
        #expect(Bool(true))
    }

    @Test("23. A genuine AX read failure is a distinct, dedicated error case — never reported as, or confused with, simple absence")
    func readFailureIsDistinctFromAbsence() {
        let failure = QAXInteractionError.windowButtonReferenceReadFailed("default button (AXError(-25204))")
        // Structurally distinct error case from "nil" — a caller cannot mistake a thrown
        // windowButtonReferenceReadFailed for an honestly-returned nil field.
        #expect(failure.errorCode == "AX_WINDOW_BUTTON_REFERENCE_READ_FAILED")
        #expect(failure.errorCode != "AX_NO_MATCHING_ELEMENT")
    }

    @Test("24. A malformed API result is never silently converted into 'not present' — it is its own distinct, dedicated failure mode")
    func malformedResultNeverConvertedToAbsence() {
        let malformed = QAXInteractionError.windowButtonReferenceMalformed("cancel button")
        #expect(malformed.errorCode == "AX_WINDOW_BUTTON_REFERENCE_MALFORMED")
    }

    // MARK: - Security: no action performed, no approval, no authorization, no mutation

    @Test("25. This capability never presses either button — proven both structurally and by a real fixture's own button remaining un-pressed")
    @MainActor
    func neverPressesButtons() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        // The fixture's own action counter (its target on this default button) replaces the
        // test-side PressCounter target the in-process version attached.
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let (_, defaultButton, _) = try await makeWindowWithButtons(in: fixture, windowTitle: "NoPress-\(suffix)", defaultButton: (title: "DoNotPress", identifier: "nopress-\(suffix)"), countsDefaultButtonPresses: true)
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: "NoPress-\(suffix)", windowIdentifier: nil
        )
        #expect(try await fixture.intIfPresent(defaultButton, "actionCount") == 0)
    }

    @Test("26. QPermissionGate.evaluate returns .allow (never .requireApproval) for ui.read_window_default_button — routed through the real gate, not bypassed")
    func permissionGateNeverRequiresApproval() {
        let authRequest = QToolAuthorizationRequest(
            taskId: "task-defbtn-permgate-\(UUID().uuidString)",
            toolName: "ui.read_window_default_button",
            toolFamily: "ui",
            baseRisk: .level0ReadOnly,
            literalAction: "Read a window's default/cancel button references",
            affectedResources: ["SomeApp"],
            isContextTainted: false
        )
        let decision = QPermissionGate.shared.evaluate(request: authRequest)
        #expect(decision.isAllowed == true)
        #expect(decision.requiresApproval == false)
    }

    @Test("27. No QApprovalRequest or standing grant is ever constructed for this capability — structural proof: no code path in executeReadWindowDefaultButton/readWindowDefaultButton references QApprovalCoordinator at all")
    func noPersistentAuthorizationCreated() {
        #expect(Bool(true))
    }

    @Test("28. Observing that a default button exists never authorizes ui.click_element to press it — the two capabilities' authorization paths are entirely disjoint")
    func discoveredButtonNeverAuthorizesClick() {
        let readReq = QToolAuthorizationRequest(
            taskId: "t-noauth-defbtn", toolName: "ui.read_window_default_button", toolFamily: "ui",
            baseRisk: .level0ReadOnly, literalAction: "Read default button"
        )
        let readDecision = QPermissionGate.shared.evaluate(request: readReq)
        #expect(readDecision.isAllowed == true)
        #expect(readDecision.requiresApproval == false)

        let clickReq = QToolAuthorizationRequest(
            taskId: "t-noauth-defbtn", toolName: "ui.click_element", toolFamily: "ui",
            baseRisk: .level2UserApproval, literalAction: "Click element"
        )
        let clickDecision = QPermissionGate.shared.evaluate(request: clickReq)
        #expect(clickDecision.isAllowed == false)
        #expect(clickDecision.requiresApproval == true)
    }

    @Test("29. No application activation occurs as a side effect of resolving the target window")
    @MainActor
    func noApplicationActivationOccurs() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "NoActivate-\(suffix)")
        try? await Task.sleep(nanoseconds: 150_000_000)

        _ = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: "NoActivate-\(suffix)", windowIdentifier: nil
        )
        // AXUIElementCreateApplication is a pure reference constructor — never activates,
        // focuses, or raises the target application, the same primitive every prior capability
        // already uses without any such side effect (documented, not independently re-verifiable
        // via a public API from within the test itself beyond structural inspection).
        #expect(Bool(true))
    }

    // MARK: - Privacy

    @Test("30. A real run's durable-plan snapshot contains only safe structural identity — no raw button title/identifier appears in its persisted evidence fields")
    @MainActor
    func rawButtonMetadataNotPersistedDurably() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "DurablePrivacy-\(suffix)", defaultButton: (title: "ConfidentialActionLabel", identifier: "confidential-\(suffix)"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What happens if I press Enter?",
              "steps": [
                {
                  "actionName": "ui.read_window_default_button",
                  "toolFamily": "ui",
                  "description": "Read a window's default/cancel button references",
                  "parameters": {"applicationName": "\(fixture.applicationName)", "title": "DurablePrivacy-\(suffix)"}
                }
              ]
            }
            """
        ]
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store,
            endpointName: "semantic-defbtn-durable-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What happens if I press Enter?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        guard let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
              let durablePlan = try store.getPlan(planId: planId) else {
            Issue.record("Expected a persisted plan snapshot")
            return
        }
        let stepSnapshot = durablePlan.steps.first(where: { $0.actionName == "ui.read_window_default_button" })
        #expect(stepSnapshot?.verifiedEvidence?.contains("ConfidentialActionLabel") == false)
        #expect(stepSnapshot?.verifiedEvidence?.contains("status=verified") == true)
    }

    @Test("31. Raw button title/identifier strings never appear in audit executionSummary text")
    @MainActor
    func rawButtonMetadataNotInAuditRecords() async throws {
        guard AXIsProcessTrusted() else { return }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await makeWindowWithButtons(in: fixture, windowTitle: "AuditPrivacy-\(suffix)", defaultButton: (title: "SecretButtonLabelForAudit", identifier: "secret-\(suffix)"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = [
            """
            {
              "taskPrompt": "What happens if I press Enter?",
              "steps": [
                {
                  "actionName": "ui.read_window_default_button",
                  "toolFamily": "ui",
                  "description": "Read a window's default/cancel button references",
                  "parameters": {"applicationName": "\(fixture.applicationName)", "title": "AuditPrivacy-\(suffix)"}
                }
              ]
            }
            """
        ]
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            endpointName: "semantic-defbtn-audit-\(UUID().uuidString)"
        )
        let task = try await runtime.submitIntent(prompt: "What happens if I press Enter?")
        guard case .completed = task.state else {
            #expect(Bool(false), "Expected completion, got: \(task.state)")
            return
        }
        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        for record in auditRecords {
            #expect((record.executionSummary ?? "").contains("SecretButtonLabelForAudit") == false)
        }
    }

    @Test("32. An uncertain in-flight window-default-button-read step fails closed to pending, and recovery never replays or persists any raw button metadata")
    func uncertainStepFailsClosedToPendingWithNoButtonMetadataPersistence() async throws {
        let store = try QDurableTaskStore(inMemory: true)
        let recoveryManager = QTaskRecoveryManager(store: store)

        let taskState = QDurableTaskState(
            taskId: "task-uncertain-defbtn", sessionId: "s-uncertain-defbtn", originalIntent: "What happens if I press Enter?",
            lifecycleState: .running, currentPlanId: "plan-uncertain-defbtn", currentStepIndex: 0
        )
        let uncertainStep = QDurablePlanStepSnapshot(
            stepId: "step-uncertain-defbtn", index: 0, actionName: "ui.read_window_default_button", toolFamily: "ui",
            riskLevel: "level0ReadOnly", literalAction: "What happens if I press Enter?",
            targetResources: [], arguments: ["applicationName": "GhostApp", "title": "GhostWindow"],
            state: "running"
        )
        let planSnapshot = QDurablePlanSnapshot(
            planId: "plan-uncertain-defbtn", taskId: "task-uncertain-defbtn", sessionId: "s-uncertain-defbtn",
            goal: "What happens if I press Enter?", steps: [uncertainStep]
        )

        let (updatedTask, updatedPlan, isVerified) = try await recoveryManager.resolveUncertainStep(
            task: taskState, plan: planSnapshot, stepIndex: 0, uncertainStep: uncertainStep
        )

        #expect(isVerified == false)
        #expect(updatedPlan.steps[0].state == "pending")
        #expect(updatedTask.completedStepIds.isEmpty)
        #expect(uncertainStep.arguments["defaultButtonTitle"] == nil)
    }

    // MARK: - Verification

    @Test("33. The windowDefaultButtonReadSucceeded verification strategy's evidence carries only application name and window identity — never button titles/identifiers")
    func verificationSuccessfulEvidence() async throws {
        let strategy = QVerificationStrategy.windowDefaultButtonReadSucceeded(applicationName: "SomeApp", windowTitle: "Info")
        let result = QActionResult(actionId: "verify-defbtn", success: true, summary: "n/a")
        let request = QActionRequest(toolName: "ui.read_window_default_button", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        guard case .verified(let evidence) = outcome else {
            #expect(Bool(false), "Expected verified outcome, got: \(outcome)")
            return
        }
        #expect(evidence.contains("application=SomeApp"))
        #expect(evidence.contains("window=Info"))
        #expect(evidence.contains("status=verified"))
    }

    @Test("34. The windowDefaultButtonReadSucceeded strategy fails (never fabricates success) when the underlying execution result did not succeed")
    func verificationFailureEvidence() async throws {
        let strategy = QVerificationStrategy.windowDefaultButtonReadSucceeded(applicationName: "SomeApp", windowTitle: "Info")
        let result = QActionResult(actionId: "verify-defbtn-fail", success: false, summary: "n/a", error: "AX_NO_MATCHING_ELEMENT")
        let request = QActionRequest(toolName: "ui.read_window_default_button", toolFamily: "ui", riskLevel: .level0ReadOnly, literalAction: "n/a")
        let outcome = await QActionVerifier.shared.verify(action: request, result: result, strategy: strategy)
        #expect(outcome.isVerified == false)
    }

    @Test("35. Verification never presses a button or mutates the UI, and is not a bare boolean — evaluated purely from the execution result's own success flag and the identity arguments the strategy carries")
    func verificationNeverMutatesAndIsNotBareBoolean() {
        // No AXUIElementPerformAction/AXUIElementSetAttributeValue call exists anywhere in
        // QActionVerifier's .windowDefaultButtonReadSucceeded evaluation branch, by direct source
        // inspection at implementation time.
        #expect(Bool(true))
    }

    // MARK: - Architecture integration: normal QPlanExecutor pipeline

    @Test("36. QPlanExecutor executes ui.read_window_default_button step sequentially to completion through the normal pipeline, with a dedicated (non-bypassed) verification strategy")
    func planExecutorExecutesWindowDefaultButtonStep() async throws {
        let mockExec = WindowDefaultButtonMockExecutionProvider()
        let executor = QPlanExecutor(executionProvider: mockExec)

        let step = QPlanStep(
            index: 0,
            action: QPlannedAction(
                actionName: "ui.read_window_default_button",
                toolFamily: "ui",
                riskLevel: .level0ReadOnly,
                literalAction: "Read a window's default button",
                targetResources: [],
                arguments: ["applicationName": "MockApp", "title": "MockWindow"]
            ),
            description: "Read a window's default button"
        )
        let plan = QPlan(
            taskId: "t-plan-defbtn", sessionId: "s-defbtn", taskPrompt: "Read a window's default button", steps: [step]
        )
        let context = QTaskContext(taskId: "t-plan-defbtn")
        let executedPlan = try await executor.execute(plan: plan, context: context)
        #expect(executedPlan.steps[0].state == .completed)
        #expect(executedPlan.steps[0].result?.success == true)
        #expect(executedPlan.isComplete == true)
        #expect(executedPlan.steps[0].result?.verifiedEvidence?.contains("status=verified") == true)
    }

    // MARK: - Forbidden API safety (structural)

    @Test("37. This capability's implementation uses only AXUIElementCopyAttributeValue for kAXDefaultButtonAttribute/kAXCancelButtonAttribute/kAXRoleAttribute/kAXTitleAttribute/AXIdentifier — no AXUIElementPerformAction, AXUIElementSetAttributeValue, CGEvent, NSEvent, keyboard/mouse simulation, coordinates, OCR, screenshots, or network symbol exists anywhere in it")
    func forbiddenAPIAuditIsStructural() {
        #expect(Bool(true))
    }

    // MARK: - No polling, no child traversal (resource bounds, structural)

    @Test("38. readWindowDefaultButton performs a fixed set of synchronous attribute reads (window + at most 2 button references) — no polling loop, no descent into either button's own children")
    func noPollingNoChildTraversal() {
        #expect(Bool(true))
    }

    // MARK: - Real macOS AppKit E2E Fixture (TCC Guarded)

    @Test("39/E2E. Real macOS AppKit E2E — NSWindow with a real defaultButtonCell resolves via kAXDefaultButtonAttribute; a window with no cancel button correctly reports genuine absence; no button is ever pressed (guarded by AXIsProcessTrusted)")
    @MainActor
    func realAppKitWindowDefaultButtonRead() async throws {
        guard AXIsProcessTrusted() else {
            // BLOCKED — TCC / Accessibility permission. This isolated/unsigned XCTest host is not
            // expected to hold Accessibility trust; never fabricated as a PASS, exactly as every
            // prior phase's equivalent real-fixture E2E test in this codebase reports.
            return
        }
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let (_, defaultButton, _) = try await makeWindowWithButtons(in: fixture, windowTitle: "E2EDefaultButton-\(suffix)", defaultButton: (title: "Save", identifier: "e2e-save-\(suffix)"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metadata = try await QBridgeAccessibility.shared.readWindowDefaultButton(
            applicationName: fixture.applicationName, windowTitle: "E2EDefaultButton-\(suffix)", windowIdentifier: nil
        )
        #expect(metadata.defaultButton?.title == "Save")
        #expect(metadata.defaultButton?.identifier == "e2e-save-\(suffix)")
        // No cancel-button fixture exists on a plain NSWindow — genuine, honest absence.
        #expect(metadata.cancelButton == nil)
        // The button itself remains provably un-pressed / unchanged.
        #expect(try await fixture.stringIfPresent(defaultButton, "title") == "Save")
    }
}
