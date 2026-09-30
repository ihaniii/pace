//
//  QSecureTextFieldProtectionTests.swift
//  leanring-buddyTests
//
//  Secure-field (password) protection against the REAL macOS representation. Every test targets
//  a genuine AppKit NSSecureTextField hosted in the out-of-process PaceAXFixtureHost, which
//  reports role AXTextField with subrole AXSecureTextField — never a fake element reporting
//  AXSecureTextField as its role (that legacy literal-role coverage lives in the per-capability
//  suites). Callers request the generic role "AXTextField", exactly what a model plan would use.
//
//  All secrets are synthetic and live only inside the fixture process and these tests.
//

import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Pace

/// The window and controls a secure-field test works with, by fixture handle. Each handle is also
/// the control's AXIdentifier unless a test overrides it.
private struct SecureFieldScene {
    let window: String
    let secureField: String
    let plainField: String
    let searchField: String
    let secret: String
    let plainValue: String
    let searchValue: String
}

private func makeSecureFieldScene(in fixture: PaceAXFixture, suffix: String) async throws -> SecureFieldScene {
    let scene = SecureFieldScene(
        window: "",
        secureField: "secure-\(suffix)",
        plainField: "plain-\(suffix)",
        searchField: "search-\(suffix)",
        secret: "QSyntheticPassword-\(suffix.prefix(8))",
        plainValue: "plain visible text",
        searchValue: "search visible text"
    )
    let windowToken = try await fixture.createWindow(title: "QSecureTextFieldProtectionFixture", width: 420, height: 200, styles: ["titled"])
    try await fixture.addControl(kind: "secureTextField", identifier: scene.secureField, windowToken: windowToken,
                                 frame: NSRect(x: 20, y: 150, width: 260, height: 24),
                                 properties: ["stringValue": scene.secret, "detachAction": true])
    try await fixture.addControl(kind: "textField", identifier: scene.plainField, windowToken: windowToken,
                                 frame: NSRect(x: 20, y: 110, width: 260, height: 24),
                                 properties: ["stringValue": scene.plainValue, "detachAction": true])
    try await fixture.addControl(kind: "searchField", identifier: scene.searchField, windowToken: windowToken,
                                 frame: NSRect(x: 20, y: 70, width: 260, height: 24),
                                 properties: ["stringValue": scene.searchValue, "detachAction": true])
    try await fixture.perform(windowToken, "makeKeyAndOrderFront")
    try? await Task.sleep(nanoseconds: 200_000_000)
    return SecureFieldScene(window: windowToken, secureField: scene.secureField, plainField: scene.plainField,
                            searchField: scene.searchField, secret: scene.secret, plainValue: scene.plainValue,
                            searchValue: scene.searchValue)
}

/// Makes `identifier` the fixture's first responder and the fixture the active application, so
/// it is the system-wide focused element — the precondition `ui.set_text_value` requires.
private func focusFixtureControl(_ identifier: String, in fixture: PaceAXFixture) async throws {
    try await fixture.perform(identifier, "attemptMakeFirstResponder")
    try await fixture.activateApplication()
    try? await Task.sleep(nanoseconds: 200_000_000)
}

/// Resolves a fixture control's real cross-process AXUIElement by its AXIdentifier.
private func accessibilityElement(in fixture: PaceAXFixture, identifier: String) -> AXUIElement? {
    func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 12 else { return nil }
        if accessibilityString(kAXIdentifierAttribute, of: element) == identifier { return element }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }
        for child in children {
            if let found = search(child, depth: depth + 1) { return found }
        }
        return nil
    }
    return search(AXUIElementCreateApplication(fixture.processIdentifier), depth: 0)
}

private func accessibilityString(_ attribute: String, of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

/// A single-step `ui.set_text_value` plan the mock model hands the runtime.
private func setTextValuePlanJSON(applicationName: String, identifier: String, value: String) -> String {
    """
    {
      "taskPrompt": "Fill in the field",
      "steps": [
        {
          "actionName": "ui.set_text_value",
          "toolFamily": "ui",
          "description": "Set a semantically-identified text field's value",
          "parameters": {"applicationName": "\(applicationName)", "role": "AXTextField", "identifier": "\(identifier)", "value": "\(value)"}
        }
      ]
    }
    """
}

@Suite("QSecureTextFieldProtectionTests", .serialized)
@MainActor
struct QSecureTextFieldProtectionTests {

    private let secureDenialLabel = "AXSecureTextField"

    // MARK: - Real representation

    @Test("A genuine NSSecureTextField reports role AXTextField + subrole AXSecureTextField and is classified secure; plain and search fields are not")
    func realPasswordFieldRepresentationIsClassifiedSecure() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)

        let secureElement = try #require(accessibilityElement(in: fixture, identifier: scene.secureField))
        let plainElement = try #require(accessibilityElement(in: fixture, identifier: scene.plainField))
        let searchElement = try #require(accessibilityElement(in: fixture, identifier: scene.searchField))

        #expect(accessibilityString(kAXRoleAttribute, of: secureElement) == "AXTextField")
        #expect(accessibilityString(kAXSubroleAttribute, of: secureElement) == "AXSecureTextField")
        #expect(QAXSecureTextElementPolicy.classify(element: secureElement) == .secure)
        // The role/subrole-only classification (used by the protected-content state read) still
        // recognises the real password field.
        #expect(QAXSecureTextElementPolicy.classifySecureTextRepresentation(element: secureElement) == .secure)
        #expect(QAXSecureTextElementPolicy.classifySecureTextRepresentation(element: plainElement) == .notSecure)

        #expect(accessibilityString(kAXRoleAttribute, of: plainElement) == "AXTextField")
        #expect(accessibilityString(kAXSubroleAttribute, of: plainElement) == nil)
        #expect(QAXSecureTextElementPolicy.classify(element: plainElement) == .notSecure)

        #expect(accessibilityString(kAXRoleAttribute, of: searchElement) == "AXTextField")
        #expect(accessibilityString(kAXSubroleAttribute, of: searchElement) == "AXSearchField")
        #expect(QAXSecureTextElementPolicy.classify(element: searchElement) == .notSecure)
    }

    // MARK: - A. Write

    @Test("A. set_text_value requested as AXTextField is refused for a real password field, which stays unchanged")
    func setTextValueRefusesRealPasswordField() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)
        // Focused, so the only thing that can stop the write is the secure-field classification.
        try await focusFixtureControl(scene.secureField, in: fixture)
        let injectedValue = "InjectedBySecureFieldTest-\(suffix.prefix(8))"

        do {
            _ = try await QBridgeAccessibility.shared.setTextValue(
                applicationName: fixture.applicationName, role: "AXTextField",
                identifier: scene.secureField, title: nil, newValue: injectedValue
            )
            Issue.record("setTextValue wrote to a real password field")
        } catch let error as QAXInteractionError {
            #expect(error == .disallowedTargetRole(secureDenialLabel))
            let description = String(describing: error)
            #expect(!description.contains(scene.secret))
            #expect(!description.contains(injectedValue))
            // No password length (or any other number) in the refusal.
            let descriptionContainsDigits = description.contains { $0.isNumber }
            #expect(!descriptionContainsDigits)
        }
        #expect(try await fixture.string(scene.secureField, "stringValue") == scene.secret)
    }

    @Test("A. The production dispatcher refuses ui.set_text_value on a real password field with no value, length, or write")
    func dispatcherRefusesSetTextValueOnRealPasswordField() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)
        try await focusFixtureControl(scene.secureField, in: fixture)
        let injectedValue = "InjectedBySecureFieldTest-\(suffix.prefix(8))"
        let taskId = "secure-field-dispatch-write-\(suffix)"

        let request = QActionRequest(
            toolName: "ui.set_text_value", toolFamily: "ui", riskLevel: .level2UserApproval,
            literalAction: "Set a semantically-identified text field's value",
            parameters: ["applicationName": fixture.applicationName, "role": "AXTextField",
                         "identifier": scene.secureField, "value": injectedValue]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: taskId))

        #expect(result.success == false)
        #expect(result.outputData["previousLength"] == nil)
        #expect(result.outputData["previousValueHash"] == nil)
        #expect(!result.summary.contains("previousLength"))
        #expect(!result.summary.contains(scene.secret))
        #expect(!result.summary.contains(injectedValue))
        #expect(result.summary.contains(secureDenialLabel))
        #expect(try await fixture.string(scene.secureField, "stringValue") == scene.secret)

        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords {
            // Audit records keep only a hash of the arguments; these are their free-text fields.
            let persisted = [record.executionSummary ?? "", record.error ?? ""].joined(separator: " ")
            #expect(!persisted.contains(scene.secret))
            #expect(!persisted.contains("previousLength"))
        }
    }

    // MARK: - B. Read

    @Test("B. read_element_value requested as AXTextField is refused for a real password field — no value, mask, or length")
    func readElementValueRefusesRealPasswordField() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)

        await #expect(throws: QAXInteractionError.secureFieldReadDenied(secureDenialLabel)) {
            _ = try await QBridgeAccessibility.shared.readElementValue(
                applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.secureField, title: nil
            )
        }

        let request = QActionRequest(
            toolName: "ui.read_element_value", toolFamily: "perception", riskLevel: .level0ReadOnly,
            literalAction: "Read a semantically-identified element's value",
            parameters: ["applicationName": fixture.applicationName, "role": "AXTextField", "identifier": scene.secureField]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "secure-field-dispatch-read-\(suffix)"))
        #expect(result.success == false)
        #expect(result.outputData["value"] == nil)
        // macOS masks a secure AXValue with U+F79A characters of the password's exact length; the
        // mask must never be returned in place of the value.
        #expect(!result.summary.contains("\u{F79A}"))
        #expect(!result.summary.contains(scene.secret))
    }

    // MARK: - C. Focused element

    @Test("C. A focused real password field keeps role AXTextField and subrole AXSecureTextField distinct and withholds its value")
    func focusedPasswordFieldWithholdsValue() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)

        try await focusFixtureControl(scene.secureField, in: fixture)
        let secureSnapshot = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: fixture.applicationName, windowTitle: nil
        )
        #expect(secureSnapshot.role == "AXTextField")
        #expect(secureSnapshot.subrole == "AXSecureTextField")
        #expect(secureSnapshot.identifier == scene.secureField)
        #expect(secureSnapshot.value == nil)

        // Regression: a focused ordinary text field still returns its value.
        try await focusFixtureControl(scene.plainField, in: fixture)
        let plainSnapshot = try await QBridgeAccessibility.shared.readFocusedElement(
            applicationName: fixture.applicationName, windowTitle: nil
        )
        #expect(plainSnapshot.role == "AXTextField")
        #expect(plainSnapshot.subrole == nil)
        #expect(plainSnapshot.identifier == scene.plainField)
        #expect(plainSnapshot.value == scene.plainValue)
    }

    // MARK: - D. Selection / length

    @Test("D. Selection state and insertion point of a focused real password field are refused, while a plain field still reports them")
    func selectionAndLengthReadsRefuseRealPasswordField() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)

        // Focused: AppKit then reports the whole password as selected (AXSelectedTextRange 0..N).
        try await focusFixtureControl(scene.secureField, in: fixture)
        await #expect(throws: QAXInteractionError.secureFieldReadDenied(secureDenialLabel)) {
            _ = try await QBridgeAccessibility.shared.readTextSelectionState(
                applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.secureField, title: nil
            )
        }
        await #expect(throws: QAXInteractionError.secureFieldReadDenied(secureDenialLabel)) {
            _ = try await QBridgeAccessibility.shared.readElementInsertionPointLine(
                applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.secureField, title: nil
            )
        }

        let plainSelection = try await QBridgeAccessibility.shared.readTextSelectionState(
            applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.plainField, title: nil
        )
        #expect(plainSelection?.totalCharacterCount == scene.plainValue.count)
    }

    // MARK: - E. Every audited read

    @Test("E. Every audited element read refuses a real password field requested as AXTextField and never refuses a plain field")
    func everyAuditedReadRefusesRealPasswordField() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)
        let bridge = QBridgeAccessibility.shared
        let applicationName = fixture.applicationName

        let auditedReads: [(name: String, read: (String) async throws -> Void)] = [
            ("readElementValue", { _ = try await bridge.readElementValue(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("listElementActions", { _ = try await bridge.listElementActions(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("listElementAttributes", { _ = try await bridge.listElementAttributes(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("listElementParameterizedAttributeNames", { _ = try await bridge.listElementParameterizedAttributeNames(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readElementRequiredState", { _ = try await bridge.readElementRequiredState(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readElementProtectedContentState", { _ = try await bridge.readElementProtectedContentState(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readTextSelectionState", { _ = try await bridge.readTextSelectionState(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readElementValueDescription", { _ = try await bridge.readElementValueDescription(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readElementRoleDescription", { _ = try await bridge.readElementRoleDescription(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readElementHelpText", { _ = try await bridge.readElementHelpText(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readElementPlaceholderValue", { _ = try await bridge.readElementPlaceholderValue(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readElementExpandedState", { _ = try await bridge.readElementExpandedState(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readElementEditedState", { _ = try await bridge.readElementEditedState(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readElementInsertionPointLine", { _ = try await bridge.readElementInsertionPointLine(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("listLinkedElements", { _ = try await bridge.listLinkedElements(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("listLabelServedElements", { _ = try await bridge.listLabelServedElements(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
            ("readElementTitleReference", { _ = try await bridge.readElementTitleReference(applicationName: applicationName, role: "AXTextField", identifier: $0, title: nil) }),
        ]

        for auditedRead in auditedReads {
            do {
                try await auditedRead.read(scene.secureField)
                Issue.record("\(auditedRead.name) returned a result for a real password field")
            } catch let error as QAXInteractionError {
                #expect(error == .secureFieldReadDenied(secureDenialLabel), "\(auditedRead.name) threw \(error)")
            } catch {
                Issue.record("\(auditedRead.name) threw an unexpected error: \(error)")
            }

            // Normal fields keep their existing behavior: whatever the read returns or throws for a
            // plain text field, it is never the secure-field refusal.
            do {
                try await auditedRead.read(scene.plainField)
            } catch let error as QAXInteractionError {
                #expect(!String(describing: error).contains(secureDenialLabel), "\(auditedRead.name) refused a plain field: \(error)")
            } catch {
                Issue.record("\(auditedRead.name) threw an unexpected error for a plain field: \(error)")
            }
        }
    }

    // MARK: - F. Recorder

    @Test("F. The flow recorder classifies the actual focused element: password keystrokes become a placeholder and never reach the recorded flow")
    func recorderNeverRecordsPasswordCharacters() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)
        let secureElement = try #require(accessibilityElement(in: fixture, identifier: scene.secureField))
        let plainElement = try #require(accessibilityElement(in: fixture, identifier: scene.plainField))
        let searchElement = try #require(accessibilityElement(in: fixture, identifier: scene.searchField))
        let typedWithoutReadableFocus = "TypedWithoutFocus-\(suffix.prefix(8))"

        let recorder = PaceFlowRecorder()
        recorder.start(flowName: "secure-field-recorder-\(suffix)")
        recorder.recordTypedCharactersForTesting(scene.secret, focusedElement: secureElement)
        recorder.recordTypedCharactersForTesting("plain typing", focusedElement: plainElement)
        recorder.recordTypedCharactersForTesting("search typing", focusedElement: searchElement)
        // No readable focused element: secure status is indeterminate, so it is treated as secure.
        recorder.recordTypedCharactersForTesting(typedWithoutReadableFocus, focusedElement: nil)
        let recordedFlow = try #require(recorder.stop(reason: .userCommand))

        #expect(recordedFlow.steps == [
            .typeText(text: "", secure: true),
            .typeText(text: "plain typing", secure: false),
            .typeText(text: "search typing", secure: false),
            .typeText(text: "", secure: true)
        ])
        // The durable recipe form (what PaceFlowStore writes to disk) carries no password characters.
        let encodedFlow = String(decoding: try JSONEncoder().encode(recordedFlow), as: UTF8.self)
        #expect(!encodedFlow.contains(scene.secret))
        #expect(!encodedFlow.contains(typedWithoutReadableFocus))
    }

    // MARK: - G. Normal fields

    @Test("G. Ordinary text and search fields still read, focus-read, and write exactly as before")
    func ordinaryFieldsKeepWorking() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)

        let plainRead = try await QBridgeAccessibility.shared.readElementValue(
            applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.plainField, title: nil
        )
        #expect(plainRead.value == scene.plainValue)
        let searchRead = try await QBridgeAccessibility.shared.readElementValue(
            applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.searchField, title: nil
        )
        #expect(searchRead.value == scene.searchValue)

        try await focusFixtureControl(scene.plainField, in: fixture)
        let plainWrite = try await QBridgeAccessibility.shared.setTextValue(
            applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.plainField, title: nil,
            newValue: "updated plain text"
        )
        #expect(plainWrite.valueChanged == true)
        #expect(plainWrite.previousLength == scene.plainValue.count)
        #expect(try await fixture.string(scene.plainField, "stringValue") == "updated plain text")

        try await focusFixtureControl(scene.searchField, in: fixture)
        let searchWrite = try await QBridgeAccessibility.shared.setTextValue(
            applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.searchField, title: nil,
            newValue: "updated search text"
        )
        #expect(searchWrite.valueChanged == true)
        #expect(try await fixture.string(scene.searchField, "stringValue") == "updated search text")
        #expect(try await fixture.string(scene.secureField, "stringValue") == scene.secret)
    }

    // MARK: - I. Focus, then mutation

    @Test("I. Focusing a real password field stays allowed, but never authorizes a programmatic write into it")
    func focusingPasswordFieldNeverAuthorizesWrite() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)
        try await fixture.activateApplication()

        // Focus remains permitted (the user may need the field focused to type into it themselves).
        _ = try await QBridgeAccessibility.shared.focusElement(
            applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.secureField, title: nil
        )
        try? await Task.sleep(nanoseconds: 200_000_000)

        await #expect(throws: QAXInteractionError.disallowedTargetRole(secureDenialLabel)) {
            _ = try await QBridgeAccessibility.shared.setTextValue(
                applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.secureField, title: nil,
                newValue: "InjectedAfterFocus-\(suffix.prefix(8))"
            )
        }
        #expect(try await fixture.string(scene.secureField, "stringValue") == scene.secret)
    }

    // MARK: - J. Ambiguous targets

    @Test("J. A password field and a plain field sharing one identifier fail closed as ambiguous — the plain field is never silently chosen")
    func ambiguousSecureAndPlainTargetsFailClosed() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let sharedIdentifier = "shared-\(suffix)"
        let secret = "QSyntheticPassword-\(suffix.prefix(8))"
        let windowToken = try await fixture.createWindow(title: "QSecureTextFieldAmbiguityFixture", width: 420, height: 140, styles: ["titled"])
        try await fixture.addControl(kind: "secureTextField", identifier: "ambiguous-secure-\(suffix)", windowToken: windowToken,
                                     frame: NSRect(x: 20, y: 90, width: 260, height: 24),
                                     properties: ["stringValue": secret, "accessibilityIdentifier": sharedIdentifier, "detachAction": true])
        try await fixture.addControl(kind: "textField", identifier: "ambiguous-plain-\(suffix)", windowToken: windowToken,
                                     frame: NSRect(x: 20, y: 50, width: 260, height: 24),
                                     properties: ["stringValue": "plain", "accessibilityIdentifier": sharedIdentifier, "detachAction": true])
        try await fixture.perform(windowToken, "makeKeyAndOrderFront")
        try? await Task.sleep(nanoseconds: 200_000_000)

        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.setTextValue(
                applicationName: fixture.applicationName, role: "AXTextField", identifier: sharedIdentifier, title: nil,
                newValue: "InjectedIntoAmbiguousTarget"
            )
        }
        await #expect(throws: QAXInteractionError.ambiguousTarget(count: 2)) {
            _ = try await QBridgeAccessibility.shared.readElementValue(
                applicationName: fixture.applicationName, role: "AXTextField", identifier: sharedIdentifier, title: nil
            )
        }
        #expect(try await fixture.string("ambiguous-secure-\(suffix)", "stringValue") == secret)
        #expect(try await fixture.string("ambiguous-plain-\(suffix)", "stringValue") == "plain")
    }

    // MARK: - K. References to a password field

    @Test("K. A label or title reference pointing at a real password field is never surfaced as a safe element")
    func referencesToPasswordFieldFailClosed() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)
        let labelIdentifier = "label-\(suffix)"
        try await fixture.addControl(kind: "label", identifier: labelIdentifier, windowToken: scene.window,
                                     frame: NSRect(x: 290, y: 150, width: 110, height: 24), properties: ["title": "Password:"])
        try await fixture.setAccessibility(labelIdentifier, "servesAsTitleForUIElements", [scene.secureField])
        try await fixture.setAccessibility(scene.plainField, "titleUIElement", scene.secureField)
        try? await Task.sleep(nanoseconds: 200_000_000)

        do {
            let served = try await QBridgeAccessibility.shared.listLabelServedElements(
                applicationName: fixture.applicationName, role: "AXStaticText", identifier: labelIdentifier, title: nil
            )
            Issue.record("A label serving a password field was surfaced: \(String(describing: served))")
        } catch let error as QAXInteractionError {
            guard case .servedElementsElementDisallowedRole = error else {
                Issue.record("Unexpected refusal for a label serving a password field: \(error)")
                return
            }
        }
        do {
            let reference = try await QBridgeAccessibility.shared.readElementTitleReference(
                applicationName: fixture.applicationName, role: "AXTextField", identifier: scene.plainField, title: nil
            )
            Issue.record("A title reference to a password field was surfaced: \(String(describing: reference))")
        } catch let error as QAXInteractionError {
            guard case .titleReferenceDisallowedRole = error else {
                Issue.record("Unexpected refusal for a title reference to a password field: \(error)")
                return
            }
        }
    }

    // MARK: - Planner screen context

    @Test("Screen reader: a real password field's masked AXValue never enters planner screen context, while plain and search field values still do")
    func screenReaderNeverCopiesPasswordFieldValueIntoPlannerContext() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)
        // PaceAXScreenReader reads the FRONTMOST application's focused window.
        try await fixture.activateApplication()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Precondition that makes this a real test rather than one satisfied by an empty value:
        // macOS exposes the password field's AXValue as a NON-empty mask with the password's
        // exact length. That mask is what must not propagate.
        let secureElement = try #require(accessibilityElement(in: fixture, identifier: scene.secureField))
        var rawSecureValue: CFTypeRef?
        let secureValueResult = AXUIElementCopyAttributeValue(secureElement, kAXValueAttribute as CFString, &rawSecureValue)
        let maskedSecureValue = try #require(secureValueResult == .success ? rawSecureValue as? String : nil)
        try #require(!maskedSecureValue.isEmpty && maskedSecureValue.count == scene.secret.count,
                     "Expected macOS to expose a length-preserving mask for the password field")
        #expect(!maskedSecureValue.contains(scene.secret))

        let screenElements = PaceAXScreenReader().readFocusedWindow()

        // Normal fields: the value appears exactly as before.
        #expect(screenElements.contains { $0.role == "text_field" && $0.text == scene.plainValue })
        #expect(screenElements.contains { $0.role == "text_field" && $0.text == scene.searchValue })

        // Password field: neither the mask, any mask character, nor the secret reaches planner context.
        for screenElement in screenElements {
            let screenText = screenElement.text ?? ""
            #expect(!screenText.contains(maskedSecureValue))
            #expect(!screenText.contains("\u{F79A}"))
            #expect(!screenText.contains(scene.secret))
            #expect(!screenElement.label.contains("\u{F79A}"))
            #expect(!screenElement.label.contains(scene.secret))
        }
    }

    // MARK: - Approval E2E

    @Test("Approval E2E: approving a ui.set_text_value step never writes into a real password field, on the first attempt or on any replanned retry")
    func approvalNeverAuthorizesPasswordFieldWrite() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)
        try await focusFixtureControl(scene.secureField, in: fixture)
        let injectedValue = "InjectedAfterApproval-\(suffix.prefix(8))"

        // More plans than the replan limit allows, so the mock never falls back to its default
        // (unrelated) plan: every attempt, including each replanned retry, targets the password field.
        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = Array(
            repeating: setTextValuePlanJSON(applicationName: fixture.applicationName, identifier: scene.secureField, value: injectedValue),
            count: 4
        )
        let store = try QDurableTaskStore(inMemory: true)
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store,
            endpointName: "secure-field-approval-\(UUID().uuidString)"
        )

        var task = try await runtime.submitIntent(prompt: "Fill in the field")
        var approvalsGranted = 0
        while case .awaitingApproval(let approvalRequest) = task.state, approvalsGranted < 4 {
            approvalsGranted += 1
            task = try await runtime.resolveApproval(taskId: task.taskId, approvalId: approvalRequest.id, decision: .approved)
            #expect(try await fixture.string(scene.secureField, "stringValue") == scene.secret, "approval \(approvalsGranted) must not write")
        }

        #expect(approvalsGranted >= 1, "The Level 2 step must reach the real approval path")
        if case .completed = task.state {
            Issue.record("A task whose only step writes into a password field completed")
        }
        #expect(try await fixture.string(scene.secureField, "stringValue") == scene.secret)

        let auditRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter { $0.taskId == task.taskId }
        #expect(!auditRecords.isEmpty)
        for record in auditRecords {
            // Audit records keep only a hash of the arguments; these are their free-text fields.
            let persisted = [record.executionSummary ?? "", record.error ?? ""].joined(separator: " ")
            #expect(!persisted.contains(scene.secret))
            #expect(!persisted.contains(injectedValue))
            #expect(!persisted.contains("previousLength"))
        }
        if let planId = try store.getTask(taskId: task.taskId)?.currentPlanId,
           let durablePlan = try store.getPlan(planId: planId) {
            for step in durablePlan.steps {
                let persisted = [step.resultSummary ?? "", step.verifiedEvidence ?? "", step.arguments.values.joined(separator: " ")].joined(separator: " ")
                #expect(!persisted.contains(scene.secret))
                #expect(!persisted.contains(injectedValue))
                #expect(!persisted.contains("previousLength"))
            }
        }
    }

    // MARK: - Recovery

    @Test("Recovery: an interrupted ui.set_text_value step targeting a real password field never writes when the task is resumed and approved")
    func recoveryNeverWritesPasswordField() async throws {
        try #require(AXIsProcessTrusted(), "Cross-process Accessibility is required for this security test")
        let suffix = UUID().uuidString
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        let scene = try await makeSecureFieldScene(in: fixture, suffix: suffix)
        try await focusFixtureControl(scene.secureField, in: fixture)
        let injectedValue = "InjectedAfterRecovery-\(suffix.prefix(8))"
        let taskId = "secure-field-recovery-\(suffix)"
        let planId = "secure-field-recovery-plan-\(suffix)"

        // The process "crashed" while this step was running, so recovery cannot know whether the
        // write happened and must resolve the uncertain step.
        let interruptedStep = QDurablePlanStepSnapshot(
            stepId: "secure-field-recovery-step-\(suffix)",
            index: 0,
            actionName: "ui.set_text_value",
            toolFamily: "ui",
            riskLevel: "level2UserApproval",
            literalAction: "Set a semantically-identified text field's value",
            targetResources: [],
            arguments: ["applicationName": fixture.applicationName, "role": "AXTextField",
                        "identifier": scene.secureField, "value": injectedValue],
            state: "running"
        )
        let store = try QDurableTaskStore(inMemory: true)
        try store.savePlan(QDurablePlanSnapshot(planId: planId, taskId: taskId, sessionId: "s-\(suffix)",
                                                goal: "Fill in the field", steps: [interruptedStep]))
        try store.saveTask(QDurableTaskState(taskId: taskId, sessionId: "s-\(suffix)", originalIntent: "Fill in the field",
                                             lifecycleState: .running, currentPlanId: planId, currentStepIndex: 0))

        let mockModel = MockAutonomousModelProvider()
        mockModel.structuredPlansToReturn = Array(
            repeating: setTextValuePlanJSON(applicationName: fixture.applicationName, identifier: scene.secureField, value: injectedValue),
            count: 4
        )
        let runtime = QCoreRuntime(
            modelProvider: mockModel,
            memoryProvider: try QSQLiteMemoryStore(inMemory: true),
            executionProvider: QExecutionService.shared,
            durableStore: store,
            endpointName: "secure-field-recovery-\(UUID().uuidString)"
        )

        var task = try await runtime.resumeTask(taskId: taskId)
        #expect(try await fixture.string(scene.secureField, "stringValue") == scene.secret, "recovery must not write")
        var approvalsGranted = 0
        while case .awaitingApproval(let approvalRequest) = task.state, approvalsGranted < 4 {
            approvalsGranted += 1
            task = try await runtime.resolveApproval(taskId: task.taskId, approvalId: approvalRequest.id, decision: .approved)
            #expect(try await fixture.string(scene.secureField, "stringValue") == scene.secret, "approval \(approvalsGranted) after recovery must not write")
        }
        if case .completed = task.state {
            Issue.record("A recovered task whose only step writes into a password field completed")
        }
        #expect(try await fixture.string(scene.secureField, "stringValue") == scene.secret)
    }
}
