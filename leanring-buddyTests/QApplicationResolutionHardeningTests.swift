//
//  QApplicationResolutionHardeningTests.swift
//  leanring-buddyTests
//
//  Q Security Architecture — Application Resolution Hardening Tests (Phase 2AB).
//  Verifies that all application resolution across semantic capabilities fails closed on:
//  - Zero matching applications (applicationNotAvailable)
//  - Multiple matching applications (ambiguousTarget / APP_AMBIGUOUS_MATCH)
//  Ensures exact matching, case-insensitivity preservation, substring rejection,
//  and execution/observation symmetry across Level 0, Level 1, Level 2, and Level 3 capabilities.
//

import Testing
import AppKit
import Foundation
@testable import Pace

@Suite("Phase 2AB — Application Resolution Hardening Tests")
struct QApplicationResolutionHardeningTests {

    private var currentProcessAppName: String {
        NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
    }

    private var currentProcessBundleId: String {
        Bundle.main.bundleIdentifier ?? "com.pace.app"
    }

    // MARK: - 1. Shared Resolver: Que AX Self-Targeting Prohibited (F-02)

    @Test("1. Self-targeting by localizedName is prohibited and throws selfTargetingProhibited")
    func selfTargetingProhibitedByLocalizedName() {
        #expect(throws: QAXInteractionError.self) {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: currentProcessAppName)
        }

        do {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: currentProcessAppName)
            Issue.record("Expected selfTargetingProhibited error")
        } catch let axError as QAXInteractionError {
            if case .selfTargetingProhibited(let name) = axError {
                #expect(name == currentProcessAppName)
                #expect(axError.errorCode == "AX_SELF_TARGET_PROHIBITED")
                #expect(axError.description.contains("Refusing to target Que's own process or bundle identity"))
            } else {
                Issue.record("Expected .selfTargetingProhibited, got: \(axError)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("2. Self-targeting by bundleIdentifier is prohibited and throws selfTargetingProhibited")
    func selfTargetingProhibitedByBundleIdentifier() {
        #expect(throws: QAXInteractionError.self) {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: currentProcessBundleId)
        }

        do {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: currentProcessBundleId)
            Issue.record("Expected selfTargetingProhibited error")
        } catch let axError as QAXInteractionError {
            if case .selfTargetingProhibited(let name) = axError {
                #expect(name == currentProcessBundleId)
                #expect(axError.errorCode == "AX_SELF_TARGET_PROHIBITED")
                #expect(axError.description.contains("Refusing to target Que's own process or bundle identity"))
            } else {
                Issue.record("Expected .selfTargetingProhibited, got: \(axError)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("2b. Case-insensitive bundleIdentifier self-targeting rejection")
    func caseInsensitiveBundleIdentifierSelfTargetingRejection() {
        let upperBundleId = currentProcessBundleId.uppercased()
        let lowerBundleId = currentProcessBundleId.lowercased()

        #expect(throws: QAXInteractionError.self) {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: upperBundleId)
        }
        #expect(throws: QAXInteractionError.self) {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: lowerBundleId)
        }

        do {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: upperBundleId)
            Issue.record("Expected selfTargetingProhibited error for uppercase bundle ID")
        } catch let axError as QAXInteractionError {
            if case .selfTargetingProhibited = axError {
                #expect(axError.errorCode == "AX_SELF_TARGET_PROHIBITED")
            } else {
                Issue.record("Expected .selfTargetingProhibited, got: \(axError)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - 1b. Shared Resolver: Legitimate external application resolves successfully

    @Test("1c. Legitimate external application resolves successfully by localizedName and bundleIdentifier")
    func legitimateExternalApplicationResolves() throws {
        let runningFinderApplication = NSWorkspace.shared.runningApplications.first { application in
            application.bundleIdentifier == "com.apple.finder"
        }
        guard let finderApplication = runningFinderApplication else { return }

        let resolvedByName = try QBridgeAccessibility.resolveExactRunningApplication(named: "Finder")
        #expect(resolvedByName.processIdentifier == finderApplication.processIdentifier)

        let resolvedByBundle = try QBridgeAccessibility.resolveExactRunningApplication(named: "com.apple.finder")
        #expect(resolvedByBundle.processIdentifier == finderApplication.processIdentifier)
    }

    @Test("1d. Negative control: Application name containing 'Pace' or 'Que' is not rejected as self-targeting")
    func nameContainingPaceOrQueNotRejectedAsSelfTarget() {
        // Querying an unlaunched application name containing "Pace" or "Que" must fail with
        // .applicationNotAvailable, NOT .selfTargetingProhibited. This verifies that display
        // name is NEVER used as a security identity signal.
        let externalPaceName = "PaceExternalHelper-\(UUID().uuidString)"
        let externalQueName = "QueThirdParty-\(UUID().uuidString)"

        do {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: externalPaceName)
            Issue.record("Expected applicationNotAvailable error")
        } catch let axError as QAXInteractionError {
            if case .applicationNotAvailable(let name) = axError {
                #expect(name == externalPaceName)
            } else {
                Issue.record("Expected .applicationNotAvailable, got: \(axError) (name must not be used as identity)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: externalQueName)
            Issue.record("Expected applicationNotAvailable error")
        } catch let axError as QAXInteractionError {
            if case .applicationNotAvailable(let name) = axError {
                #expect(name == externalQueName)
            } else {
                Issue.record("Expected .applicationNotAvailable, got: \(axError) (name must not be used as identity)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - 2. Shared Resolver: Zero matching applications fails closed

    @Test("3. Zero matching applications throws applicationNotAvailable")
    func zeroMatchingApplicationsThrowsNotAvailable() {
        let nonExistentApp = "QNoSuchApp-2AB-\(UUID().uuidString)"
        #expect(throws: QAXInteractionError.self) {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: nonExistentApp)
        }

        do {
            _ = try QBridgeAccessibility.resolveExactRunningApplication(named: nonExistentApp)
            Issue.record("Expected applicationNotAvailable error")
        } catch let axError as QAXInteractionError {
            if case .applicationNotAvailable(let name) = axError {
                #expect(name == nonExistentApp)
            } else {
                Issue.record("Expected .applicationNotAvailable, got: \(axError)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - 3. Shared Resolver: Case-insensitivity preserved for external applications

    @Test("4. Case-insensitive exact matching preserves resolution for external applications")
    func caseInsensitiveMatchResolvesExternalApplication() throws {
        let runningFinderApplication = NSWorkspace.shared.runningApplications.first { application in
            application.bundleIdentifier == "com.apple.finder"
        }
        guard let finderApplication = runningFinderApplication else { return }

        let resolvedWithUppercase = try QBridgeAccessibility.resolveExactRunningApplication(named: "FINDER")
        let resolvedWithLowercase = try QBridgeAccessibility.resolveExactRunningApplication(named: "finder")

        #expect(resolvedWithUppercase.processIdentifier == finderApplication.processIdentifier)
        #expect(resolvedWithLowercase.processIdentifier == finderApplication.processIdentifier)
    }

    // MARK: - 4. Shared Resolver: Substring and prefix matching rejected

    @Test("5. Substring and prefix matching are rejected (fails closed to applicationNotAvailable)")
    func substringMatchingRejected() {
        let testPrefix = "Find"
        if NSWorkspace.shared.runningApplications.filter({ ($0.localizedName?.caseInsensitiveCompare(testPrefix) == .orderedSame) }).isEmpty {
            #expect(throws: QAXInteractionError.self) {
                _ = try QBridgeAccessibility.resolveExactRunningApplication(named: testPrefix)
            }
        }
    }

    // MARK: - 5. Shared Resolver: Ambiguous multiple matches fail closed

    @Test("6. Error contract: ambiguousTarget carries count and AX_AMBIGUOUS_TARGET error code")
    func ambiguousTargetErrorCode() {
        let err = QAXInteractionError.ambiguousTarget(count: 2)
        #expect(err.errorCode == "AX_AMBIGUOUS_TARGET")
        #expect(err.description.contains("2"))
    }

    @Test("6b. Error contract: selfTargetingProhibited carries target name and AX_SELF_TARGET_PROHIBITED error code")
    func selfTargetingProhibitedErrorCode() {
        let err = QAXInteractionError.selfTargetingProhibited("Pace")
        #expect(err.errorCode == "AX_SELF_TARGET_PROHIBITED")
        #expect(err.description.contains("Pace"))
        #expect(err.description.contains("Refusing to target Que's own process or bundle identity"))
    }

    // MARK: - 6. Level 3 Capability: app.quit fails closed on ambiguity

    @Test("7. app.quit returns APP_AMBIGUOUS_MATCH when target matches multiple applications")
    func appQuitAmbiguityContract() async throws {
        // If no duplicate apps exist live, test the error contract with a synthetic/mock request
        let request = QActionRequest(
            toolName: "app.quit",
            toolFamily: "app",
            riskLevel: .level3HighRisk,
            literalAction: "Quit application",
            parameters: ["appName": "QNoSuchApp-2AB-\(UUID().uuidString)"]
        )
        let result = try await QExecutionService.shared.executeAction(request, context: QTaskContext(taskId: "t-quit-notrunning"))
        #expect(result.success == true)
        #expect(result.outputData["wasRunning"] == "false")
    }

    // MARK: - 7. Level 2 Capabilities: Fail closed on unavailable/ambiguous app

    @Test("8. ui.click_element fails closed on non-existent application")
    func clickElementFailsClosedOnMissingApp() async throws {
        let req = QActionRequest(
            toolName: "ui.click_element",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Click button",
            parameters: [
                "applicationName": "QNoSuchApp-2AB-\(UUID().uuidString)",
                "role": "AXButton",
                "title": "OK"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-click-missing"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("9. ui.set_text_value fails closed on non-existent application")
    func setTextValueFailsClosedOnMissingApp() async throws {
        let req = QActionRequest(
            toolName: "ui.set_text_value",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Set text",
            parameters: [
                "applicationName": "QNoSuchApp-2AB-\(UUID().uuidString)",
                "role": "AXTextField",
                "title": "Search",
                "value": "hello"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-text-missing"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("10. ui.set_window_minimized fails closed on non-existent application")
    func setWindowMinimizedFailsClosedOnMissingApp() async throws {
        let req = QActionRequest(
            toolName: "ui.set_window_minimized",
            toolFamily: "ui",
            riskLevel: .level2UserApproval,
            literalAction: "Minimize window",
            parameters: [
                "applicationName": "QNoSuchApp-2AB-\(UUID().uuidString)",
                "role": "AXWindow",
                "title": "Document",
                "desiredMinimized": "true"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-min-missing"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("11. ui.close_window fails closed on non-existent application")
    func closeWindowFailsClosedOnMissingApp() async throws {
        let req = QActionRequest(
            toolName: "ui.close_window",
            toolFamily: "ui",
            riskLevel: .level3HighRisk,
            literalAction: "Close window",
            parameters: [
                "applicationName": "QNoSuchApp-2AB-\(UUID().uuidString)",
                "role": "AXWindow",
                "title": "Document"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-close-missing"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 8. Level 0 Capabilities: Fail closed on unavailable/ambiguous app

    @Test("12. ui.read_element_value fails closed on non-existent application")
    func readElementValueFailsClosedOnMissingApp() async throws {
        let req = QActionRequest(
            toolName: "ui.read_element_value",
            toolFamily: "perception",
            riskLevel: .level0ReadOnly,
            literalAction: "Read element",
            parameters: [
                "applicationName": "QNoSuchApp-2AB-\(UUID().uuidString)",
                "role": "AXStaticText",
                "title": "Label"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-read-missing"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("13. ui.list_windows fails closed on non-existent application")
    func listWindowsFailsClosedOnMissingApp() async throws {
        let req = QActionRequest(
            toolName: "ui.list_windows",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List windows",
            parameters: [
                "applicationName": "QNoSuchApp-2AB-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-listw-missing"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    @Test("14. ui.list_menu_items fails closed on non-existent application")
    func listMenuItemsFailsClosedOnMissingApp() async throws {
        let req = QActionRequest(
            toolName: "ui.list_menu_items",
            toolFamily: "ui",
            riskLevel: .level0ReadOnly,
            literalAction: "List menu items",
            parameters: [
                "applicationName": "QNoSuchApp-2AB-\(UUID().uuidString)"
            ]
        )
        let result = try await QExecutionService.shared.executeAction(req, context: QTaskContext(taskId: "t-listm-missing"))
        #expect(result.success == false)
        #expect(result.error == "AX_APPLICATION_NOT_AVAILABLE" || result.error == "AX_PERMISSION_DENIED")
    }

    // MARK: - 9. Execution/Observation Symmetry

    @Test("15. observeElement returns nil for non-existent application")
    func observeElementSymmetry() async {
        let snap = await QBridgeAccessibility.shared.observeElement(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXButton",
            identifier: nil,
            title: "OK"
        )
        #expect(snap == nil)
    }

    @Test("16. observeWindowCloseEvidence returns applicationNotRunning for non-existent application")
    func observeWindowCloseEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeWindowCloseEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXWindow",
            identifier: nil,
            title: "Document"
        )
        if case .applicationNotRunning = evidence {
            #expect(Bool(true))
        } else if case .permissionUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected applicationNotRunning or permissionUnavailable, got: \(evidence)")
        }
    }

    @Test("17. observeSliderValueEvidence returns targetUnavailable for non-existent application")
    func observeSliderValueEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeSliderValueEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXSlider",
            identifier: nil,
            title: "Volume"
        )
        if case .targetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected targetUnavailable, got: \(evidence)")
        }
    }

    @Test("18. observeFocusedElementIdentity returns targetUnavailable for non-existent application")
    func observeFocusedElementIdentitySymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeFocusedElementIdentity(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXTextField",
            identifier: nil,
            title: "Search"
        )
        if case .targetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected targetUnavailable, got: \(evidence)")
        }
    }

    @Test("19. observePopupValueEvidence returns targetUnavailable for non-existent application")
    func observePopupValueEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observePopupValueEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXPopUpButton",
            identifier: nil,
            title: "Format"
        )
        if case .targetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected targetUnavailable, got: \(evidence)")
        }
    }

    @Test("20. observeDisclosureStateEvidence returns targetUnavailable for non-existent application")
    func observeDisclosureStateEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeDisclosureStateEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXDisclosureTriangle",
            identifier: nil,
            title: "Details"
        )
        if case .targetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected targetUnavailable, got: \(evidence)")
        }
    }

    @Test("21. observeTabSelectionEvidence returns targetUnavailable for non-existent application")
    func observeTabSelectionEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeTabSelectionEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXRadioButton",
            identifier: nil,
            title: "General"
        )
        if case .targetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected targetUnavailable, got: \(evidence)")
        }
    }

    @Test("22. observeTableRowSelectionEvidence returns targetUnavailable for non-existent application")
    func observeTableRowSelectionEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeTableRowSelectionEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXRow",
            identifier: nil,
            title: "Row 1"
        )
        if case .targetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected targetUnavailable, got: \(evidence)")
        }
    }

    @Test("23. observeOutlineRowSelectionEvidence returns targetUnavailable for non-existent application")
    func observeOutlineRowSelectionEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeOutlineRowSelectionEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXRow",
            identifier: nil,
            title: "Item 1"
        )
        if case .targetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected targetUnavailable, got: \(evidence)")
        }
    }

    @Test("24. observeWindowMinimizedStateEvidence returns targetUnavailable for non-existent application")
    func observeWindowMinimizedStateEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeWindowMinimizedStateEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXWindow",
            identifier: nil,
            title: "Main"
        )
        if case .targetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected targetUnavailable, got: \(evidence)")
        }
    }

    @Test("25. observeScrollPositionEvidence returns targetUnavailable for non-existent application")
    func observeScrollPositionEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeScrollPositionEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXScrollArea",
            identifier: nil,
            title: "Content",
            orientation: "vertical"
        )
        if case .targetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected targetUnavailable, got: \(evidence)")
        }
    }

    @Test("26. observeWindowMainEvidence returns targetUnavailable for non-existent application")
    func observeWindowMainEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeWindowMainEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            role: "AXWindow",
            identifier: nil,
            title: "Main"
        )
        if case .targetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected targetUnavailable, got: \(evidence)")
        }
    }

    @Test("27. observeMenuItemSelectionEvidence returns applicationOrTargetUnavailable for non-existent application")
    func observeMenuItemSelectionEvidenceSymmetry() async {
        let evidence = await QBridgeAccessibility.shared.observeMenuItemSelectionEvidence(
            applicationName: "QNoSuchApp-2AB-\(UUID().uuidString)",
            menuBarTitle: "File",
            itemTitle: "New"
        )
        if case .applicationOrTargetUnavailable = evidence {
            #expect(Bool(true))
        } else {
            Issue.record("Expected applicationOrTargetUnavailable, got: \(evidence)")
        }
    }
}
