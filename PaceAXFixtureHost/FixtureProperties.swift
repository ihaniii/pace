//
//  FixtureProperties.swift
//  PaceAXFixtureHost
//
//  The allowlisted read ("get"), write ("set"), action ("perform") and accessibility-override
//  ("setAccessibility") operations on fixture windows and controls.
//
//  Why explicit switches instead of Key-Value Coding: a test can only ever touch the exact
//  properties listed here, every value is type-checked before it reaches AppKit, and an
//  unknown key fails closed instead of silently reaching some unrelated Objective-C property.
//
//  "get" reads straight from this process's own AppKit objects, never through Accessibility,
//  so it is independent ground truth for whatever the test host did through QBridge.
//

import AppKit
import Foundation

extension FixtureScene {

    // MARK: - get

    func value(forKey key: String, identifier: String) throws -> Any {
        if let window = window(forTokenOrIdentifier: identifier) {
            return try windowValue(forKey: key, window: window, identifier: identifier)
        }
        guard let view = viewsByIdentifier[identifier] else { throw FixtureSceneError.unknownIdentifier(identifier) }
        switch key {
        case "isHidden":
            return view.isHidden
        case "accessibilityRole":
            // Cell-based controls (buttons, text fields, sliders, pop-ups, ...) report
            // AXUnknown at the view level; AppKit serves their real role from the cell.
            if let control = view as? NSControl, let cellRole = control.cell?.accessibilityRole() {
                return cellRole.rawValue
            }
            return view.accessibilityRole()?.rawValue ?? ""
        case "isFirstResponder":
            return isFirstResponder(view)
        case "customActionInvoked":
            guard let invoked = customActionInvokedByIdentifier[identifier] else { break }
            return invoked
        // AppKit-side accessibility values, read exactly as the migrated tests read them in-process
        // (view-level NSAccessibility accessors).
        case "accessibility:help": return view.accessibilityHelp() ?? NSNull()
        case "accessibility:index": return view.accessibilityIndex()
        case "accessibility:expanded": return view.isAccessibilityExpanded()
        case "accessibility:edited": return view.isAccessibilityEdited()
        case "accessibility:insertionPointLineNumber": return view.accessibilityInsertionPointLineNumber()
        case "accessibility:disclosureLevel": return view.accessibilityDisclosureLevel()
        case "accessibility:valueDescription": return view.accessibilityValueDescription() ?? NSNull()
        case "accessibility:roleDescription": return view.accessibilityRoleDescription() ?? NSNull()
        case "accessibility:rowCount": return view.accessibilityRowCount()
        case "accessibility:columnCount": return view.accessibilityColumnCount()
        // The header element's class name, or null when there is none — lets a test compare the
        // AppKit-side accessor's presence against the AX read without shipping the object itself.
        case "accessibility:header":
            return view.accessibilityHeader().map { String(describing: type(of: $0)) } ?? NSNull()
        // A stable per-object token for the table's current NSTableHeaderView, so a test can
        // prove the header object was never replaced (the in-process tests compared with ===).
        case "headerViewObjectIdentity":
            guard let tableView = view as? NSTableView else { break }
            return tableView.headerView.map { String(describing: ObjectIdentifier($0)) } ?? NSNull()
        case "tableColumnCount":
            guard let tableView = view as? NSTableView else { break }
            return tableView.tableColumns.count
        case "tableColumnTitles":
            guard let tableView = view as? NSTableView else { break }
            return tableView.tableColumns.map { $0.title }
        case "accessibility:allowedValues":
            return view.accessibilityAllowedValues()?.map { $0.doubleValue } ?? NSNull()
        case "accessibility:servesAsTitleForUIElements":
            return view.accessibilityServesAsTitleForUIElements().map { handles(forAccessibilityObjects: $0) } ?? NSNull()
        case "accessibility:linkedUIElements":
            return view.accessibilityLinkedUIElements().map { handles(forAccessibilityObjects: $0) } ?? NSNull()
        case "accessibility:visibleChildren":
            return view.accessibilityVisibleChildren().map { handles(forAccessibilityObjects: $0) } ?? NSNull()
        case "actionCount", "pressCount":
            guard let actionCount = actionCountsByIdentifier[identifier] else { break }
            return actionCount
        default:
            break
        }
        if let textField = view as? NSTextField {
            switch key {
            case "placeholderString": return textField.placeholderString ?? NSNull()
            case "fieldEditorSelectedRange":
                guard let selectedRange = textField.currentEditor()?.selectedRange else { return NSNull() }
                return [selectedRange.location, selectedRange.length]
            default: break
            }
        }
        if let textView = view as? NSTextView {
            switch key {
            case "string": return textView.string
            case "selectedRange": return [textView.selectedRange().location, textView.selectedRange().length]
            default: break
            }
        }
        if let tabView = view as? NSTabView {
            switch key {
            case "selectedTabIndex":
                guard let selectedTabViewItem = tabView.selectedTabViewItem else { return -1 }
                return tabView.indexOfTabViewItem(selectedTabViewItem)
            default: break
            }
        }
        if let scrollView = view as? NSScrollView {
            switch key {
            case "verticalScrollOffset": return Double(scrollView.contentView.bounds.origin.y)
            // The live NSScroller's knob position, or null when AppKit instantiated no vertical
            // scroller (tests branch on that existence, so it must stay observable).
            case "verticalScrollerValue": return scrollView.verticalScroller.map { $0.doubleValue } ?? NSNull()
            case "horizontalScrollerValue": return scrollView.horizontalScroller.map { $0.doubleValue } ?? NSNull()
            default: break
            }
        }
        if let splitView = view as? NSSplitView {
            switch key {
            case "firstPaneExtent":
                guard let firstPane = splitView.arrangedSubviews.first else { break }
                return Double(splitView.isVertical ? firstPane.frame.width : firstPane.frame.height)
            default: break
            }
        }
        if let control = view as? NSControl {
            switch key {
            case "isEnabled": return control.isEnabled
            case "stringValue": return control.stringValue
            case "doubleValue": return control.doubleValue
            case "integerValue": return control.integerValue
            default: break
            }
        }
        if let button = view as? NSButton {
            switch key {
            case "state": return button.state.rawValue
            case "title": return button.title
            default: break
            }
        }
        if let popUpButton = view as? NSPopUpButton {
            switch key {
            case "indexOfSelectedItem": return popUpButton.indexOfSelectedItem
            case "titleOfSelectedItem": return popUpButton.titleOfSelectedItem ?? ""
            default: break
            }
        }
        if let comboBox = view as? NSComboBox {
            switch key {
            case "indexOfSelectedItem": return comboBox.indexOfSelectedItem
            default: break
            }
        }
        if let segmentedControl = view as? NSSegmentedControl {
            switch key {
            case "selectedSegment": return segmentedControl.selectedSegment
            default: break
            }
        }
        if let stepper = view as? NSStepper {
            switch key {
            case "increment": return stepper.increment
            default: break
            }
        }
        throw FixtureSceneError.unsupportedKey(key: key, target: String(describing: type(of: view)))
    }

    private func windowValue(forKey key: String, window: NSWindow, identifier: String) throws -> Any {
        switch key {
        case "title": return window.title
        case "isVisible": return window.isVisible
        case "isMiniaturized": return window.isMiniaturized
        case "isZoomed": return window.isZoomed
        case "isKeyWindow": return window.isKeyWindow
        case "isMainWindow": return window.isMainWindow
        case "isFullScreen": return window.styleMask.contains(.fullScreen)
        case "isSheet": return window.isSheet
        case "hasToolbar": return window.toolbar != nil
        case "isMiniaturizable": return window.styleMask.contains(.miniaturizable)
        case "isResizable": return window.styleMask.contains(.resizable)
        case "isFullScreenPrimary": return window.collectionBehavior.contains(.fullScreenPrimary)
        case "hasAttachedSheet": return window.attachedSheet != nil
        default: throw FixtureSceneError.unsupportedKey(key: key, target: "window '\(identifier)'")
        }
    }

    /// A text field being edited is not itself the first responder — AppKit makes the shared
    /// field editor first responder with the text field as its delegate.
    private func isFirstResponder(_ view: NSView) -> Bool {
        guard let firstResponder = view.window?.firstResponder else { return false }
        if firstResponder === view { return true }
        if let fieldEditor = firstResponder as? NSText, fieldEditor.delegate === view as AnyObject { return true }
        return false
    }

    // MARK: - set

    func setValue(_ value: Any, forKey key: String, identifier: String) throws {
        if let window = window(forTokenOrIdentifier: identifier) {
            switch key {
            case "title":
                window.title = try requireString(value, key: key)
            case "defaultButton":
                // Exactly `window.defaultButtonCell = button.cell as? NSButtonCell` for a fixture button.
                guard let button = viewsByIdentifier[try requireString(value, key: key)] as? NSButton else {
                    throw FixtureSceneError.invalidValue(key: key)
                }
                window.defaultButtonCell = button.cell as? NSButtonCell
            default:
                throw FixtureSceneError.unsupportedKey(key: key, target: "window '\(identifier)'")
            }
            return
        }
        guard let view = viewsByIdentifier[identifier] else { throw FixtureSceneError.unknownIdentifier(identifier) }
        if key == "isHidden" {
            view.isHidden = try requireBool(value, key: key)
            return
        }
        if let textField = view as? NSTextField {
            switch key {
            case "placeholderString":
                textField.placeholderString = try requireString(value, key: key)
                return
            case "fieldEditorSelectedRange":
                // Exactly what the migrated helper did: make the field first responder in its
                // window, then select within its field editor.
                guard let rangeParts = value as? [Int], rangeParts.count == 2 else { throw FixtureSceneError.invalidValue(key: key) }
                _ = textField.window?.makeFirstResponder(textField)
                if let editor = textField.currentEditor() {
                    editor.selectedRange = NSRange(location: rangeParts[0], length: rangeParts[1])
                }
                return
            case "recordActions":
                try attachActionRecorder(identifier: identifier)
                return
            default:
                break
            }
        }
        if key == "recordActions" {
            try attachActionRecorder(identifier: identifier)
            return
        }
        if let textView = view as? NSTextView {
            switch key {
            case "string":
                textView.string = try requireString(value, key: key)
                return
            case "selectedRange":
                guard let rangeParts = value as? [Int], rangeParts.count == 2 else { throw FixtureSceneError.invalidValue(key: key) }
                textView.setSelectedRange(NSRange(location: rangeParts[0], length: rangeParts[1]))
                return
            default:
                break
            }
        }
        if let tabView = view as? NSTabView, key == "selectedTabIndex" {
            let tabIndex = try requireInt(value, key: key)
            guard tabView.tabViewItems.indices.contains(tabIndex) else { throw FixtureSceneError.invalidValue(key: key) }
            tabView.selectTabViewItem(at: tabIndex)
            return
        }
        if let scrollView = view as? NSScrollView, key == "verticalScrollOffset" {
            let verticalOffset = try requireDouble(value, key: key)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: verticalOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }
        if let popUpButton = view as? NSPopUpButton, key == "appendMenuItemWithTitle" {
            // Adds a raw NSMenuItem straight to the pop-up's menu, bypassing NSPopUpButton's own
            // title de-duplication — how a genuine duplicate-item-title menu is produced.
            popUpButton.menu?.addItem(withTitle: try requireString(value, key: key), action: nil, keyEquivalent: "")
            return
        }
        if let popUpButton = view as? NSPopUpButton, key == "indexOfSelectedItem" {
            let itemIndex = try requireInt(value, key: key)
            guard popUpButton.itemArray.indices.contains(itemIndex) else { throw FixtureSceneError.invalidValue(key: key) }
            popUpButton.selectItem(at: itemIndex)
            return
        }
        if let comboBox = view as? NSComboBox, key == "indexOfSelectedItem" {
            let itemIndex = try requireInt(value, key: key)
            guard itemIndex >= 0, itemIndex < comboBox.numberOfItems else { throw FixtureSceneError.invalidValue(key: key) }
            comboBox.selectItem(at: itemIndex)
            return
        }
        if let segmentedControl = view as? NSSegmentedControl, key == "selectedSegment" {
            let segmentIndex = try requireInt(value, key: key)
            guard segmentIndex >= -1, segmentIndex < segmentedControl.segmentCount else { throw FixtureSceneError.invalidValue(key: key) }
            segmentedControl.selectedSegment = segmentIndex
            return
        }
        if let stepper = view as? NSStepper, key == "increment" {
            stepper.increment = try requireDouble(value, key: key)
            return
        }
        if let button = view as? NSButton {
            switch key {
            case "state":
                button.state = NSControl.StateValue(rawValue: try requireInt(value, key: key))
                return
            case "title":
                button.title = try requireString(value, key: key)
                return
            default:
                break
            }
        }
        if let control = view as? NSControl {
            switch key {
            case "isEnabled":
                control.isEnabled = try requireBool(value, key: key)
                return
            case "stringValue":
                control.stringValue = try requireString(value, key: key)
                return
            case "doubleValue":
                control.doubleValue = try requireDouble(value, key: key)
                return
            case "integerValue":
                control.integerValue = try requireInt(value, key: key)
                return
            default:
                break
            }
        }
        throw FixtureSceneError.unsupportedKey(key: key, target: String(describing: type(of: view)))
    }

    // MARK: - perform

    func perform(action: String, identifier: String) throws {
        if let window = window(forTokenOrIdentifier: identifier) {
            try performWindowAction(action, window: window, identifier: identifier)
            return
        }
        guard let view = viewsByIdentifier[identifier] else { throw FixtureSceneError.unknownIdentifier(identifier) }
        switch action {
        case "layoutSubtreeIfNeeded":
            view.layoutSubtreeIfNeeded()
        case "attemptMakeFirstResponder":
            // Exactly `_ = window.makeFirstResponder(view)` — the Bool result is ignored, as the
            // migrated tests ignored it.
            _ = view.window?.makeFirstResponder(view)
        case "makeFirstResponderInWindow":
            // Exactly `window.makeFirstResponder(view)` — no app activation, no reordering.
            guard let window = view.window else { throw FixtureSceneError.invalidValue(key: "window") }
            guard window.makeFirstResponder(view) else { throw FixtureSceneError.invalidValue(key: "makeFirstResponderInWindow") }
        case "makeFirstResponder":
            guard let window = view.window else { throw FixtureSceneError.invalidValue(key: "window") }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            guard window.makeFirstResponder(view) else { throw FixtureSceneError.invalidValue(key: "makeFirstResponder") }
        default:
            throw FixtureSceneError.unsupportedAction(action: action, target: String(describing: type(of: view)))
        }
    }

    private func performWindowAction(_ action: String, window: NSWindow, identifier: String) throws {
        switch action {
        case "makeKeyAndOrderFront":
            // Exactly the AppKit call the migrated in-process helpers made — no app activation.
            // Tests that need the fixture app active say so with the "activate" app operation.
            window.makeKeyAndOrderFront(nil)
        case "orderFront":
            window.orderFrontRegardless()
        case "makeMain":
            window.makeMain()
        case "installToolbar":
            // Exactly `window.toolbar = NSToolbar(identifier:)` — a real, empty toolbar.
            window.toolbar = NSToolbar(identifier: NSToolbar.Identifier("PaceAXFixtureToolbar"))
        case "addFullScreenPrimaryBehavior":
            window.collectionBehavior.insert(.fullScreenPrimary)
        case "orderOut":
            window.orderOut(nil)
        case "miniaturize":
            window.miniaturize(nil)
        case "deminiaturize":
            window.deminiaturize(nil)
        case "zoom":
            window.zoom(nil)
        case "toggleFullScreen":
            window.toggleFullScreen(nil)
        case "makeFirstResponderNil":
            // Exactly `window.makeFirstResponder(nil)`.
            window.makeFirstResponder(nil)
        case "blockClose":
            closeBlockedWindows.insert(ObjectIdentifier(window))
        case "allowClose":
            closeBlockedWindows.remove(ObjectIdentifier(window))
        case "performClose":
            window.performClose(nil)
        case "close":
            window.close()
        default:
            throw FixtureSceneError.unsupportedAction(action: action, target: "window '\(identifier)'")
        }
    }

    // MARK: - setAccessibility

    /// Applies one allowlisted NSAccessibility override. Element-reference attributes take the
    /// identifier(s) of other fixture controls, resolved here to the real AppKit objects.
    func setAccessibility(attribute: String, value: Any, identifier: String) throws {
        let targetElement: NSObject & NSAccessibilityProtocol
        if let window = window(forTokenOrIdentifier: identifier) {
            targetElement = window
        } else if let view = viewsByIdentifier[identifier] {
            targetElement = view
        } else {
            throw FixtureSceneError.unknownIdentifier(identifier)
        }
        switch attribute {
        case "label":
            targetElement.setAccessibilityLabel(try requireString(value, key: attribute))
        case "title":
            targetElement.setAccessibilityTitle(try requireString(value, key: attribute))
        case "help":
            targetElement.setAccessibilityHelp(try requireString(value, key: attribute))
        case "placeholderValue":
            targetElement.setAccessibilityPlaceholderValue(try requireString(value, key: attribute))
        case "valueDescription":
            targetElement.setAccessibilityValueDescription(try requireString(value, key: attribute))
        case "roleDescription":
            targetElement.setAccessibilityRoleDescription(try requireString(value, key: attribute))
        case "role":
            targetElement.setAccessibilityRole(NSAccessibility.Role(rawValue: try requireString(value, key: attribute)))
        case "subrole":
            targetElement.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: try requireString(value, key: attribute)))
        case "required":
            targetElement.setAccessibilityRequired(try requireBool(value, key: attribute))
        case "protectedContent":
            targetElement.setAccessibilityProtectedContent(try requireBool(value, key: attribute))
        case "edited":
            targetElement.setAccessibilityEdited(try requireBool(value, key: attribute))
        case "expanded":
            targetElement.setAccessibilityExpanded(try requireBool(value, key: attribute))
        case "selected":
            targetElement.setAccessibilitySelected(try requireBool(value, key: attribute))
        case "disclosureLevel":
            targetElement.setAccessibilityDisclosureLevel(try requireInt(value, key: attribute))
        case "index":
            targetElement.setAccessibilityIndex(try requireInt(value, key: attribute))
        case "insertionPointLineNumber":
            targetElement.setAccessibilityInsertionPointLineNumber(try requireInt(value, key: attribute))
        case "allowedValues":
            guard let allowedValues = value as? [Double] else { throw FixtureSceneError.invalidValue(key: attribute) }
            targetElement.setAccessibilityAllowedValues(allowedValues.map { NSNumber(value: $0) })
        case "titleUIElement":
            targetElement.setAccessibilityTitleUIElement(try referencedView(value, key: attribute))
        case "servesAsTitleForUIElements":
            targetElement.setAccessibilityServesAsTitleForUIElements(try referencedViews(value, key: attribute))
        case "linkedUIElements":
            targetElement.setAccessibilityLinkedUIElements(try referencedViews(value, key: attribute))
        case "rowHeaderUIElements":
            targetElement.setAccessibilityRowHeaderUIElements(try referencedViews(value, key: attribute))
        case "rowCount":
            targetElement.setAccessibilityRowCount(try requireInt(value, key: attribute))
        case "columnCount":
            targetElement.setAccessibilityColumnCount(try requireInt(value, key: attribute))
        case "identifier":
            targetElement.setAccessibilityIdentifier(try requireString(value, key: attribute))
        case "customActionNames":
            // NSAccessibilityCustomAction(name:handler: { true }) per name — exactly what the
            // migrated helper attached.
            // Each handler also records that it ran, so a test can prove an action was never
            // executed as a side effect of merely discovering it.
            guard let actionNames = value as? [String] else { throw FixtureSceneError.invalidValue(key: attribute) }
            customActionInvokedByIdentifier[identifier] = false
            targetElement.setAccessibilityCustomActions(actionNames.map { actionName in
                NSAccessibilityCustomAction(name: actionName, handler: { [weak self] in
                    self?.customActionInvokedByIdentifier[identifier] = true
                    return true
                })
            })
        default:
            throw FixtureSceneError.unsupportedAccessibilityAttribute(attribute)
        }
    }

    private func referencedView(_ value: Any, key: String) throws -> NSView {
        let referencedIdentifier = try requireString(value, key: key)
        guard let referencedView = viewsByIdentifier[referencedIdentifier] else { throw FixtureSceneError.unknownIdentifier(referencedIdentifier) }
        return referencedView
    }

    private func referencedViews(_ value: Any, key: String) throws -> [NSView] {
        guard let referencedIdentifiers = value as? [String] else { throw FixtureSceneError.invalidValue(key: key) }
        return try referencedIdentifiers.map { try referencedView($0, key: key) }
    }

    // MARK: - Application operations

    func performApplicationOperation(_ operation: String) throws -> [String: Any] {
        switch operation {
        case "activate":
            NSApp.activate()
        case "hide":
            NSApp.hide(nil)
        case "unhide":
            NSApp.unhide(nil)
        case "clearFirstResponderInAllWindows":
            // Exactly `for window in NSApp.windows { _ = window.makeFirstResponder(nil) }`.
            for window in NSApp.windows {
                _ = window.makeFirstResponder(nil)
            }
        case "pumpModalSession":
            // Exactly one non-blocking `NSApp.runModalSession(_:)` pump of the running session,
            // as the in-process tests did right after beginModalSession(for:).
            try pumpModalSession()
        case "state":
            break
        default:
            throw FixtureSceneError.unsupportedAction(action: operation, target: "application")
        }
        return ["isActive": NSApp.isActive, "isHidden": NSApp.isHidden]
    }

    // MARK: - Value checking

    private func requireString(_ value: Any, key: String) throws -> String {
        guard let stringValue = value as? String else { throw FixtureSceneError.invalidValue(key: key) }
        return stringValue
    }

    private func requireBool(_ value: Any, key: String) throws -> Bool {
        guard let boolValue = value as? Bool else { throw FixtureSceneError.invalidValue(key: key) }
        return boolValue
    }

    private func requireInt(_ value: Any, key: String) throws -> Int {
        guard let intValue = value as? Int else { throw FixtureSceneError.invalidValue(key: key) }
        return intValue
    }

    private func requireDouble(_ value: Any, key: String) throws -> Double {
        guard let doubleValue = value as? Double else { throw FixtureSceneError.invalidValue(key: key) }
        return doubleValue
    }
}
