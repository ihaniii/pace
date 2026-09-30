//
//  FixtureCustomKinds.swift
//  PaceAXFixtureHost
//
//  Custom NSAccessibility-overriding AppKit controls that QBridge tests target. Each class is
//  moved VERBATIM (same name, same overrides) from the test file that used to build it inside the
//  XCTest host — except the three container views, which additionally report
//  isAccessibilityElement() == true (an approved test-fixture fix, see their comments); the doc comments explaining why each exists stay with those test files. Tests now
//  ask the fixture for one by name — control kind "custom:<ClassName>" — so the identical control
//  lives in this separate process and QBridge reaches it through genuine cross-process AX.
//

import AppKit

// MARK: - From QSemanticTabSelectionTests

@MainActor
final class QTabFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        .radioButton
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        // `.tabButton` is not exposed as a pre-defined static member on this Swift SDK's
        // `NSAccessibility.Subrole` overlay (confirmed empirically — it fails to resolve at
        // compile time, unlike `.radioButton`/`.disclosureTriangle`), even though
        // `NSAccessibilityTabButtonSubrole` ("AXTabButton") is a real, header-confirmed ObjC
        // constant. Constructing directly from the raw string is the standard, fully-supported
        // way to obtain any `NS_TYPED_ENUM`-backed value, pre-defined static member or not.
        NSAccessibility.Subrole(rawValue: "AXTabButton")
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

@MainActor
final class QOrdinaryRadioButtonFixture: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        .radioButton
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

// MARK: - From QSemanticSegmentedControlSelectionTests

@MainActor
final class QSegmentedControlContainerFixtureView: NSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXSegmentedControl")
    }
    // Approved fix (2026-09-29): overriding the role alone left this plain NSView OUT of the AX
    // tree (NSView is not an accessibility element by default), so rows/segments inside it
    // reported the window as their AX parent and every table/outline/segmented-context check
    // failed. Reporting itself as an element makes the container genuinely appear with its role.
    override func isAccessibilityElement() -> Bool {
        true
    }
}

@MainActor
final class QDisallowedRadioGroupContainerFixtureView: NSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRadioGroup")
    }
}

@MainActor
final class QSegmentItemFixtureButton: NSButton {
    private let customRole: String
    private let customSubrole: String?

    init(role: String = "AXRadioButton", subrole: String? = nil, isSelected: Bool = false) {
        self.customRole = role
        self.customSubrole = subrole
        super.init(frame: .zero)
        self.state = isSelected ? .on : .off
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: customRole)
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        customSubrole.map { NSAccessibility.Subrole(rawValue: $0) }
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func isAccessibilityEnabled() -> Bool {
        isEnabled
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

// MARK: - From QSemanticTableRowSelectionTests

@MainActor
final class QTableContainerFixtureView: NSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXTable")
    }
    // Approved fix (2026-09-29): overriding the role alone left this plain NSView OUT of the AX
    // tree (NSView is not an accessibility element by default), so rows/segments inside it
    // reported the window as their AX parent and every table/outline/segmented-context check
    // failed. Reporting itself as an element makes the container genuinely appear with its role.
    override func isAccessibilityElement() -> Bool {
        true
    }
}

@MainActor
final class QTableRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        NSAccessibility.Subrole(rawValue: "AXTableRow")
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

@MainActor
final class QUnqualifiedRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

@MainActor
final class QOutlineRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        NSAccessibility.Subrole(rawValue: "AXOutlineRow")
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

// MARK: - From QSemanticOutlineRowSelectionTests

@MainActor
final class QOutlineContainerFixtureView: NSView {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXOutline")
    }
    // Approved fix (2026-09-29): overriding the role alone left this plain NSView OUT of the AX
    // tree (NSView is not an accessibility element by default), so rows/segments inside it
    // reported the window as their AX parent and every table/outline/segmented-context check
    // failed. Reporting itself as an element makes the container genuinely appear with its role.
    override func isAccessibilityElement() -> Bool {
        true
    }
}

@MainActor
final class QOutlineTreeRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        NSAccessibility.Subrole(rawValue: "AXOutlineRow")
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

@MainActor
final class QUnqualifiedOutlineRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

@MainActor
final class QTableRowSubroleOnOutlineFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        NSAccessibility.Subrole(rawValue: "AXTableRow")
    }

    override func isAccessibilitySelected() -> Bool {
        state == .on
    }

    override func setAccessibilitySelected(_ accessibilitySelected: Bool) {
        state = accessibilitySelected ? .on : .off
    }
}

// MARK: - From QSemanticDisclosureToggleTests

@MainActor
final class QDisclosureTriangleFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        .disclosureTriangle
    }
}

// MARK: - From QSemanticElementDisclosureLevelReadTests

@MainActor
final class QDisclosureLevelRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }
}

// MARK: - From QSemanticElementIndexReadTests

@MainActor
final class QElementIndexRowFixtureButton: NSButton, NSAccessibilityRow {
    var testIndex: Int = 0

    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }

    override func accessibilityIndex() -> Int {
        testIndex
    }
}

@MainActor
final class QElementIndexAbsentRowFixtureButton: NSButton {
    override func accessibilityRole() -> NSAccessibility.Role? {
        NSAccessibility.Role(rawValue: "AXRow")
    }
}

// MARK: - Factory

enum FixtureCustomKinds {
    /// Builds the named custom control with `frame`. Construction mirrors exactly what the test
    /// files did: `init(frame:)`, except QSegmentItemFixtureButton, whose designated initializer
    /// takes its role/subrole/selection (then its frame is assigned, as before). Returns nil for an
    /// unknown name so the caller fails closed.
    @MainActor
    static func make(className: String, frame: NSRect, properties: [String: Any]) -> NSView? {
        switch className {
        case "QTabFixtureButton": return QTabFixtureButton(frame: frame)
        case "QOrdinaryRadioButtonFixture": return QOrdinaryRadioButtonFixture(frame: frame)
        case "QSegmentedControlContainerFixtureView": return QSegmentedControlContainerFixtureView(frame: frame)
        case "QDisallowedRadioGroupContainerFixtureView": return QDisallowedRadioGroupContainerFixtureView(frame: frame)
        case "QSegmentItemFixtureButton":
            let segmentItem = QSegmentItemFixtureButton(
                role: properties["customRole"] as? String ?? "AXRadioButton",
                subrole: properties["customSubrole"] as? String,
                isSelected: properties["customIsSelected"] as? Bool ?? false
            )
            segmentItem.frame = frame
            return segmentItem
        case "QTableContainerFixtureView": return QTableContainerFixtureView(frame: frame)
        case "QTableRowFixtureButton": return QTableRowFixtureButton(frame: frame)
        case "QUnqualifiedRowFixtureButton": return QUnqualifiedRowFixtureButton(frame: frame)
        case "QOutlineRowFixtureButton": return QOutlineRowFixtureButton(frame: frame)
        case "QOutlineContainerFixtureView": return QOutlineContainerFixtureView(frame: frame)
        case "QOutlineTreeRowFixtureButton": return QOutlineTreeRowFixtureButton(frame: frame)
        case "QUnqualifiedOutlineRowFixtureButton": return QUnqualifiedOutlineRowFixtureButton(frame: frame)
        case "QTableRowSubroleOnOutlineFixtureButton": return QTableRowSubroleOnOutlineFixtureButton(frame: frame)
        case "QDisclosureTriangleFixtureButton": return QDisclosureTriangleFixtureButton(frame: frame)
        case "QDisclosureLevelRowFixtureButton": return QDisclosureLevelRowFixtureButton(frame: frame)
        case "QElementIndexRowFixtureButton":
            let indexRow = QElementIndexRowFixtureButton(frame: frame)
            indexRow.testIndex = properties["testIndex"] as? Int ?? 0
            return indexRow
        case "QElementIndexAbsentRowFixtureButton": return QElementIndexAbsentRowFixtureButton(frame: frame)
        default: return nil
        }
    }
}
