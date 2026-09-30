//
//  FixtureScene.swift
//  PaceAXFixtureHost
//
//  Owns every window and control the fixture has created, addressed by string identifiers
//  the test host chooses. Tests describe a scene over the control channel ("createWindow",
//  "addControl"); this file turns those descriptions into real AppKit objects in THIS
//  process, so QBridgeAccessibility in the test host reaches them through genuine
//  cross-process Accessibility.
//
//  Only an explicit, allowlisted set of window styles and control kinds can be built.
//  Anything else fails closed with an error response rather than being guessed at.
//

import AppKit
import Foundation

enum FixtureSceneError: Error, CustomStringConvertible {
    case missingParameter(String)
    case unknownControlKind(String)
    case unknownWindowStyle(String)
    case unknownWindowKind(String)
    case unknownIdentifier(String)
    case duplicateIdentifier(String)
    case unsupportedParent(String)
    case unsupportedKey(key: String, target: String)
    case unsupportedAction(action: String, target: String)
    case unsupportedAccessibilityAttribute(String)
    case invalidValue(key: String)

    var description: String {
        switch self {
        case .missingParameter(let name): return "missing parameter '\(name)'"
        case .unknownControlKind(let kind): return "unknown control kind '\(kind)'"
        case .unknownWindowStyle(let style): return "unknown window style '\(style)'"
        case .unknownWindowKind(let kind): return "unknown window kind '\(kind)'"
        case .unknownIdentifier(let identifier): return "unknown identifier '\(identifier)'"
        case .duplicateIdentifier(let identifier): return "identifier '\(identifier)' is already in use"
        case .unsupportedParent(let identifier): return "'\(identifier)' cannot contain child controls"
        case .unsupportedKey(let key, let target): return "key '\(key)' is not allowlisted for \(target)"
        case .unsupportedAction(let action, let target): return "action '\(action)' is not allowlisted for \(target)"
        case .unsupportedAccessibilityAttribute(let attribute): return "accessibility attribute '\(attribute)' is not allowlisted"
        case .invalidValue(let key): return "invalid value for '\(key)'"
        }
    }
}

@MainActor
final class FixtureScene: NSObject {
    /// Every control kind a test may ask for. Kept explicit so a typo in a test fails loudly.
    static let supportedControlKinds: Set<String> = [
        "button", "checkbox", "radio", "textField", "label", "secureTextField", "searchField",
        "textView", "slider", "stepper", "popUpButton", "comboBox", "segmentedControl",
        "tabView", "scrollView", "splitView", "view"
    ]

    private static let buttonTypesByName: [String: NSButton.ButtonType] = [
        "pushOnPushOff": .pushOnPushOff,
        "toggle": .toggle,
        "momentaryPushIn": .momentaryPushIn,
        "switch": .switch,
        "radio": .radio
    ]

    private static let windowStyleMasksByName: [String: NSWindow.StyleMask] = [
        "titled": .titled,
        "closable": .closable,
        "miniaturizable": .miniaturizable,
        "resizable": .resizable,
        "fullSizeContentView": .fullSizeContentView
    ]

    private(set) var windowsByToken: [String: NSWindow] = [:]
    private var windowTokensByIdentifier: [String: String] = [:]
    private(set) var viewsByIdentifier: [String: NSView] = [:]
    /// Number of times each control's action fired, keyed by identifier. The spike's
    /// "pressCount" query reads this, and it is the fixture's own ground truth — it never
    /// comes from Accessibility, which is the code under test.
    private(set) var actionCountsByIdentifier: [String: Int] = [:]
    /// Ordered record of control actions and window callbacks, for tests that need to prove
    /// exactly what happened inside the fixture.
    private(set) var eventLog: [[String: Any]] = []
    private var nextWindowNumber = 0
    private var nextDefaultControlSlotByWindowToken: [String: Int] = [:]
    private var activeModalSession: NSApplication.ModalSession?
    private var menuSelectionCountsByMenuBarTitle: [String: Int] = [:]
    /// Whether any custom accessibility action attached via "customActionNames" has run.
    var customActionInvokedByIdentifier: [String: Bool] = [:]
    /// Windows whose close is refused by `windowShouldClose` (see the "blockClose" action).
    var closeBlockedWindows: Set<ObjectIdentifier> = []
    /// Reverse of viewsByIdentifier, so action callbacks are attributed to the fixture handle
    /// even when several controls share one AX identifier.
    private var handlesByViewObject: [ObjectIdentifier: String] = [:]
    /// Controls that change their own AX identity when pressed (a real, observable self-diffing
    /// state change, like Calculator's Clear/AllClear button).
    private var identityChangesOnPressByHandle: [String: (accessibilityIdentifier: String, title: String?)] = [:]

    // MARK: - Windows

    /// Creates and shows a window. Returns its token; the optional `identifier` also becomes
    /// the window's AXIdentifier and can be used anywhere an identifier is accepted.
    func createWindow(
        identifier: String?,
        title: String?,
        width: Double,
        height: Double,
        styleNames: [String]?,
        kind: String
    ) throws -> String {
        if let identifier { try requireUnusedIdentifier(identifier) }
        var styleMask: NSWindow.StyleMask = []
        for styleName in styleNames ?? ["titled", "closable", "miniaturizable", "resizable"] {
            guard let style = Self.windowStyleMasksByName[styleName] else { throw FixtureSceneError.unknownWindowStyle(styleName) }
            styleMask.insert(style)
        }
        let contentRect = NSRect(x: 80, y: 80, width: width, height: height)
        let window: NSWindow
        switch kind {
        case "window":
            window = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        case "panel":
            window = NSPanel(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        default:
            throw FixtureSceneError.unknownWindowKind(kind)
        }
        nextWindowNumber += 1
        let windowToken = "window-\(nextWindowNumber)"
        configureThrowawayWindow(window)
        window.title = title ?? "PaceAXFixtureHost \(windowToken)"
        if styleMask.contains(.resizable) {
            // Needed for the full-screen window operation; harmless otherwise.
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        if let identifier {
            window.setAccessibilityIdentifier(identifier)
            windowTokensByIdentifier[identifier] = windowToken
        }
        window.delegate = self
        window.orderFrontRegardless()
        windowsByToken[windowToken] = window
        return windowToken
    }

    /// Resolves a window from either its token or the identifier it was created with.
    func window(forTokenOrIdentifier tokenOrIdentifier: String) -> NSWindow? {
        if let window = windowsByToken[tokenOrIdentifier] { return window }
        if let windowToken = windowTokensByIdentifier[tokenOrIdentifier] { return windowsByToken[windowToken] }
        return nil
    }

    func removeWindow(token windowToken: String) -> NSWindow? {
        guard let window = windowsByToken.removeValue(forKey: windowToken) else { return nil }
        windowTokensByIdentifier = windowTokensByIdentifier.filter { $0.value != windowToken }
        return window
    }

    /// Presents a sheet window (with its own identifier and one "OK" button whose identifier
    /// is `<identifier>-ok`) attached to an existing window.
    func presentSheet(parentTokenOrIdentifier: String, identifier: String, title: String?) throws -> String {
        guard let parentWindow = window(forTokenOrIdentifier: parentTokenOrIdentifier) else {
            throw FixtureSceneError.unknownIdentifier(parentTokenOrIdentifier)
        }
        let sheetToken = try createWindow(
            identifier: identifier,
            title: title,
            width: 260,
            height: 90,
            styleNames: ["titled"],
            kind: "window"
        )
        guard let sheetWindow = windowsByToken[sheetToken] else { throw FixtureSceneError.unknownIdentifier(identifier) }
        // createWindow ordered it front as a normal window; a sheet must not be on screen yet.
        sheetWindow.orderOut(nil)
        try addControl(
            kind: "button",
            identifier: "\(identifier)-ok",
            windowTokenOrIdentifier: sheetToken,
            parentIdentifier: nil,
            frame: NSRect(x: 150, y: 20, width: 90, height: 32),
            properties: ["title": "OK"]
        )
        parentWindow.beginSheet(sheetWindow) { _ in }
        return sheetToken
    }

    func endSheet(identifier: String) throws {
        guard let sheetWindow = window(forTokenOrIdentifier: identifier),
              let parentWindow = sheetWindow.sheetParent else { throw FixtureSceneError.unknownIdentifier(identifier) }
        parentWindow.endSheet(sheetWindow)
    }

    /// Puts the application into a modal session for the window (NSApp.modalWindow is set and
    /// the window is shown modally). Uses the non-blocking beginModalSession API rather than
    /// runModal(for:): runModal nests a run loop that never returns to the control channel's
    /// dispatch, so the fixture would stop answering until the session ended.
    func startModalSession(tokenOrIdentifier: String) throws {
        guard let modalWindow = window(forTokenOrIdentifier: tokenOrIdentifier) else {
            throw FixtureSceneError.unknownIdentifier(tokenOrIdentifier)
        }
        guard activeModalSession == nil else { throw FixtureSceneError.invalidValue(key: "modal session already running") }
        activeModalSession = NSApp.beginModalSession(for: modalWindow)
    }

    func stopModalSession() {
        guard let activeModalSession else { return }
        NSApp.endModalSession(activeModalSession)
        self.activeModalSession = nil
    }

    // MARK: - Controls

    /// Creates a control of an allowlisted kind and registers it under `identifier`, which is
    /// also set as its AXIdentifier. The control goes into `parentIdentifier` (a container
    /// control) when given, otherwise straight into the window's content view.
    func addControl(
        kind: String,
        identifier: String,
        windowTokenOrIdentifier: String?,
        parentIdentifier: String?,
        frame requestedFrame: NSRect?,
        properties: [String: Any]
    ) throws {
        guard Self.supportedControlKinds.contains(kind) || kind.hasPrefix("custom:") else { throw FixtureSceneError.unknownControlKind(kind) }
        try requireUnusedIdentifier(identifier)

        let containerView: NSView
        let slotWindowToken: String
        if let parentIdentifier {
            guard let parentView = viewsByIdentifier[parentIdentifier] else { throw FixtureSceneError.unknownIdentifier(parentIdentifier) }
            containerView = try childContainer(of: parentView, parentIdentifier: parentIdentifier, properties: properties)
            slotWindowToken = "parent:\(parentIdentifier)"
        } else {
            guard let windowTokenOrIdentifier else { throw FixtureSceneError.missingParameter("windowToken or parentIdentifier") }
            guard let window = window(forTokenOrIdentifier: windowTokenOrIdentifier),
                  let contentView = window.contentView else { throw FixtureSceneError.unknownIdentifier(windowTokenOrIdentifier) }
            containerView = contentView
            slotWindowToken = windowTokenOrIdentifier
        }

        let frame = requestedFrame ?? defaultFrame(forKind: kind, slotKey: slotWindowToken)
        let (registeredView, viewAddedToContainer) = try makeControl(kind: kind, frame: frame, properties: properties)
        // "detachAction": the control gets no target/action at all — exactly like controls the
        // migrated helpers created with `target: nil, action: nil` (or never set one).
        if properties["detachAction"] as? Bool == true, let control = registeredView as? NSControl {
            control.target = nil
            control.action = nil
        }
        // Button type first, before any state is applied — the same setButtonType-then-state order
        // the migrated in-process helpers used.
        if let buttonTypeName = properties["buttonType"] as? String {
            guard let button = registeredView as? NSButton, let buttonType = Self.buttonTypesByName[buttonTypeName] else {
                throw FixtureSceneError.invalidValue(key: "buttonType")
            }
            button.setButtonType(buttonType)
        }
        // `identifier` is the fixture's own unique handle for this control. The AX identifier is
        // the same unless the test asks for a different one — which is how a test builds two
        // controls that deliberately share one AX identifier (ambiguous-target tests).
        registeredView.setAccessibilityIdentifier(properties["accessibilityIdentifier"] as? String ?? identifier)
        containerView.addSubview(viewAddedToContainer)
        viewsByIdentifier[identifier] = registeredView
        handlesByViewObject[ObjectIdentifier(registeredView)] = identifier
        if let identifierAfterPress = properties["onPressSetAccessibilityIdentifier"] as? String {
            identityChangesOnPressByHandle[identifier] = (identifierAfterPress, properties["onPressSetTitle"] as? String)
        }
        if registeredView is NSControl || registeredView is NSTabView {
            actionCountsByIdentifier[identifier] = 0
        }

        // Every remaining property goes through the same allowlist the "set" command uses,
        // so creation-time and later mutations can never diverge.
        let creationOnlyKeys: Set<String> = ["hasVerticalScroller", "detachAction", "testIndex", "buttonType", "customRole", "customSubrole", "customIsSelected", "accessibilityIdentifier", "inScrollView", "onPressSetAccessibilityIdentifier", "onPressSetTitle", "hasHorizontalScroller", "scrollerStyle", "documentWidth", "title", "items", "segments", "tabs", "minValue", "maxValue", "documentHeight", "paneCount", "isVertical", "paneIndex", "tabIndex"]
        for (key, value) in properties where !creationOnlyKeys.contains(key) {
            try setValue(value, forKey: key, identifier: identifier)
        }
    }

    private func makeControl(kind: String, frame: NSRect, properties: [String: Any]) throws -> (registered: NSView, addedToContainer: NSView) {
        let title = properties["title"] as? String ?? ""
        if kind.hasPrefix("custom:") {
            // Custom NSAccessibility-overriding classes (FixtureCustomKinds), built exactly as the
            // test files built them — deliberately with no target/action attached, as before.
            let className = String(kind.dropFirst("custom:".count))
            guard let customView = FixtureCustomKinds.make(className: className, frame: frame, properties: properties) else {
                throw FixtureSceneError.unknownControlKind(kind)
            }
            if let button = customView as? NSButton, properties["title"] != nil {
                button.title = title
            }
            return (customView, customView)
        }
        switch kind {
        case "button":
            let button = NSButton(title: title.isEmpty ? "Fixture Button" : title, target: self, action: #selector(controlActionFired(_:)))
            button.frame = frame
            return (button, button)
        case "checkbox":
            let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(controlActionFired(_:)))
            checkbox.frame = frame
            return (checkbox, checkbox)
        case "radio":
            let radioButton = NSButton(radioButtonWithTitle: title, target: self, action: #selector(controlActionFired(_:)))
            radioButton.frame = frame
            return (radioButton, radioButton)
        case "textField":
            let textField = NSTextField(frame: frame)
            textField.isEditable = true
            textField.target = self
            textField.action = #selector(controlActionFired(_:))
            return (textField, textField)
        case "label":
            let label = NSTextField(labelWithString: title)
            label.frame = frame
            return (label, label)
        case "secureTextField":
            let secureTextField = NSSecureTextField(frame: frame)
            secureTextField.target = self
            secureTextField.action = #selector(controlActionFired(_:))
            return (secureTextField, secureTextField)
        case "searchField":
            let searchField = NSSearchField(frame: frame)
            searchField.target = self
            searchField.action = #selector(controlActionFired(_:))
            return (searchField, searchField)
        case "textView":
            // By default hosted inside a scroll view, as real apps do; "inScrollView": false gives
            // a bare NSTextView added straight to its container. Either way the text view itself
            // is the registered (identified) element.
            if properties["inScrollView"] as? Bool == false {
                let textView = NSTextView(frame: frame)
                textView.isEditable = true
                return (textView, textView)
            }
            let scrollView = NSTextView.scrollableTextView()
            scrollView.frame = frame
            guard let textView = scrollView.documentView as? NSTextView else { throw FixtureSceneError.invalidValue(key: "textView") }
            return (textView, scrollView)
        case "slider":
            let minimumValue = properties["minValue"] as? Double ?? 0
            let maximumValue = properties["maxValue"] as? Double ?? 100
            let slider = NSSlider(value: minimumValue, minValue: minimumValue, maxValue: maximumValue, target: self, action: #selector(controlActionFired(_:)))
            slider.frame = frame
            return (slider, slider)
        case "stepper":
            let stepper = NSStepper(frame: frame)
            stepper.minValue = properties["minValue"] as? Double ?? 0
            stepper.maxValue = properties["maxValue"] as? Double ?? 100
            stepper.target = self
            stepper.action = #selector(controlActionFired(_:))
            return (stepper, stepper)
        case "popUpButton":
            let popUpButton = NSPopUpButton(frame: frame, pullsDown: false)
            popUpButton.addItems(withTitles: properties["items"] as? [String] ?? [])
            popUpButton.target = self
            popUpButton.action = #selector(controlActionFired(_:))
            return (popUpButton, popUpButton)
        case "comboBox":
            let comboBox = NSComboBox(frame: frame)
            comboBox.addItems(withObjectValues: properties["items"] as? [String] ?? [])
            comboBox.target = self
            comboBox.action = #selector(controlActionFired(_:))
            return (comboBox, comboBox)
        case "segmentedControl":
            let segmentedControl = NSSegmentedControl(
                labels: properties["segments"] as? [String] ?? [],
                trackingMode: .selectOne,
                target: self,
                action: #selector(controlActionFired(_:))
            )
            segmentedControl.frame = frame
            return (segmentedControl, segmentedControl)
        case "tabView":
            let tabView = NSTabView(frame: frame)
            for tabLabel in properties["tabs"] as? [String] ?? [] {
                let tabViewItem = NSTabViewItem(identifier: tabLabel)
                tabViewItem.label = tabLabel
                tabViewItem.view = NSView(frame: .zero)
                tabView.addTabViewItem(tabViewItem)
            }
            tabView.delegate = self
            return (tabView, tabView)
        case "scrollView":
            let scrollView = NSScrollView(frame: frame)
            scrollView.hasVerticalScroller = properties["hasVerticalScroller"] as? Bool ?? true
            scrollView.hasHorizontalScroller = properties["hasHorizontalScroller"] as? Bool ?? false
            if properties["scrollerStyle"] as? String == "legacy" {
                // Always-visible (not fade-in overlay) scrollers.
                scrollView.scrollerStyle = .legacy
            }
            let documentWidth = properties["documentWidth"] as? Double ?? Double(frame.width)
            let documentHeight = properties["documentHeight"] as? Double ?? 2000
            scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight))
            return (scrollView, scrollView)
        case "splitView":
            let splitView = NSSplitView(frame: frame)
            splitView.isVertical = properties["isVertical"] as? Bool ?? true
            let paneCount = properties["paneCount"] as? Int ?? 2
            for _ in 0..<max(paneCount, 2) {
                splitView.addArrangedSubview(NSView(frame: .zero))
            }
            splitView.adjustSubviews()
            return (splitView, splitView)
        case "view":
            let containerView = NSView(frame: frame)
            return (containerView, containerView)
        default:
            throw FixtureSceneError.unknownControlKind(kind)
        }
    }

    /// Where a child control goes inside a container control.
    private func childContainer(of parentView: NSView, parentIdentifier: String, properties: [String: Any]) throws -> NSView {
        if let scrollView = parentView as? NSScrollView, let documentView = scrollView.documentView {
            return documentView
        }
        if let splitView = parentView as? NSSplitView {
            let paneIndex = properties["paneIndex"] as? Int ?? 0
            guard splitView.arrangedSubviews.indices.contains(paneIndex) else { throw FixtureSceneError.invalidValue(key: "paneIndex") }
            return splitView.arrangedSubviews[paneIndex]
        }
        if let tabView = parentView as? NSTabView {
            let tabIndex = properties["tabIndex"] as? Int ?? 0
            guard tabView.tabViewItems.indices.contains(tabIndex), let tabContentView = tabView.tabViewItems[tabIndex].view else {
                throw FixtureSceneError.invalidValue(key: "tabIndex")
            }
            return tabContentView
        }
        // Plain NSViews and custom container views (e.g. QTableContainerFixtureView) hold their
        // children directly; controls never do.
        if !(parentView is NSControl) {
            return parentView
        }
        throw FixtureSceneError.unsupportedParent(parentIdentifier)
    }

    /// Stacks controls top-down when a test does not care about exact geometry.
    private func defaultFrame(forKind kind: String, slotKey: String) -> NSRect {
        let slotIndex = nextDefaultControlSlotByWindowToken[slotKey, default: 0]
        nextDefaultControlSlotByWindowToken[slotKey] = slotIndex + 1
        let height: CGFloat
        switch kind {
        case "textView", "tabView", "scrollView", "splitView", "view": height = 120
        default: height = 26
        }
        return NSRect(x: 20, y: 20 + CGFloat(slotIndex) * 34, width: 220, height: height)
    }

    private func requireUnusedIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty else { throw FixtureSceneError.missingParameter("identifier") }
        if viewsByIdentifier[identifier] != nil || windowTokensByIdentifier[identifier] != nil {
            throw FixtureSceneError.duplicateIdentifier(identifier)
        }
    }

    private func configureThrowawayWindow(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        // Never persist window state for this throwaway fixture.
        window.isRestorable = false
        window.animationBehavior = .none
    }

    // MARK: - Event recording

    // MARK: - Menus

    /// Mirrors the migrated test helper `installTestMenu` exactly: ensures a main menu exists,
    /// inserts a "TestAppRoot" placeholder root item if the menu bar is empty, then adds one
    /// top-level menu-bar item whose submenu holds one direct item. When `countsSelections` is
    /// true the item's action records each selection (the fixture's own ground truth).
    func installMenu(menuBarTitle: String, itemTitle: String, itemEnabled: Bool, countsSelections: Bool) {
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = NSMenu()
        }
        guard let mainMenu = NSApp.mainMenu else { return }
        if mainMenu.items.isEmpty {
            let placeholder = NSMenuItem(title: "TestAppRoot", action: nil, keyEquivalent: "")
            placeholder.submenu = NSMenu(title: "TestAppRoot")
            mainMenu.addItem(placeholder)
        }
        let menuBarItem = NSMenuItem(title: menuBarTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: menuBarTitle)
        let item = NSMenuItem(title: itemTitle, action: countsSelections ? #selector(menuItemSelected(_:)) : nil, keyEquivalent: "")
        item.target = countsSelections ? self : nil
        item.isEnabled = itemEnabled
        submenu.addItem(item)
        menuBarItem.submenu = submenu
        mainMenu.addItem(menuBarItem)
        menuSelectionCountsByMenuBarTitle[menuBarTitle] = 0
    }

    /// Appends a raw NSMenuItem with no action to an existing top-level menu's submenu.
    func appendMenuItem(menuBarTitle: String, itemTitle: String) throws {
        guard let submenu = NSApp.mainMenu?.items.first(where: { $0.title == menuBarTitle })?.submenu else {
            throw FixtureSceneError.unknownIdentifier(menuBarTitle)
        }
        submenu.addItem(NSMenuItem(title: itemTitle, action: nil, keyEquivalent: ""))
    }

    /// Inserts a menu-bar item at index 0 (the application's own root menu, by macOS convention)
    /// whose submenu holds one item — exactly what the root-menu rejection test built in-process.
    func insertRootMenu(title: String, itemTitle: String) {
        if NSApp.mainMenu == nil { NSApp.mainMenu = NSMenu() }
        let rootItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let rootSubmenu = NSMenu(title: title)
        rootSubmenu.addItem(NSMenuItem(title: itemTitle, action: nil, keyEquivalent: ""))
        rootItem.submenu = rootSubmenu
        NSApp.mainMenu?.insertItem(rootItem, at: 0)
    }

    func menuSelectionCount(menuBarTitle: String) throws -> Int {
        guard let selectionCount = menuSelectionCountsByMenuBarTitle[menuBarTitle] else {
            throw FixtureSceneError.unknownIdentifier(menuBarTitle)
        }
        return selectionCount
    }

    @objc func menuItemSelected(_ sender: NSMenuItem) {
        guard let menuBarTitle = sender.menu?.title else { return }
        menuSelectionCountsByMenuBarTitle[menuBarTitle, default: 0] += 1
        recordEvent(["event": "menuItemSelected", "menu": menuBarTitle, "item": sender.title])
    }

    /// Re-attaches the fixture's own action recorder to a control (e.g. one created with
    /// "detachAction"), so presses from then on are counted in `actionCount`.
    func attachActionRecorder(identifier: String) throws {
        guard let control = viewsByIdentifier[identifier] as? NSControl else { throw FixtureSceneError.unknownIdentifier(identifier) }
        control.target = self
        control.action = #selector(controlActionFired(_:))
        actionCountsByIdentifier[identifier] = 0
    }

    /// Fixture handles for AppKit objects returned by accessibility accessors (unknown → "").
    func handles(forAccessibilityObjects objects: [Any]) -> [String] {
        objects.map { object in
            guard let view = object as? NSView else { return "" }
            return handlesByViewObject[ObjectIdentifier(view)] ?? ""
        }
    }

    func recordEvent(_ event: [String: Any]) {
        eventLog.append(event)
    }

    func clearEventLog() {
        eventLog.removeAll()
    }

    @objc func controlActionFired(_ sender: NSView) {
        guard let identifier = handlesByViewObject[ObjectIdentifier(sender)] else { return }
        actionCountsByIdentifier[identifier, default: 0] += 1
        recordEvent(["event": "action", "identifier": identifier])
        if let identityChange = identityChangesOnPressByHandle[identifier] {
            sender.setAccessibilityIdentifier(identityChange.accessibilityIdentifier)
            if let newTitle = identityChange.title, let button = sender as? NSButton {
                button.title = newTitle
            }
        }
    }
}

extension FixtureScene: NSWindowDelegate {
    /// Windows marked with the "blockClose" action refuse to close — an honest, clearly-labeled
    /// PROXY for "something is blocking this close" (e.g. a real save/discard sheet in a
    /// document-based app), which a plain AppKit fixture cannot genuinely produce.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard closeBlockedWindows.contains(ObjectIdentifier(sender)) else { return true }
        recordEvent(["event": "windowCloseRefused", "window": windowToken(for: sender)])
        return false
    }

    /// Identifies the window from the fixture's own records. Deliberately never calls an
    /// NSAccessibility API on the window here: doing so while the window closes in response to a
    /// cross-process AXPress makes that press reply kAXErrorAttributeUnsupported (-25205) even
    /// though the close happened — a fixture artifact real apps do not have.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        recordEvent(["event": "windowWillClose", "window": windowToken(for: window)])
    }

    private func windowToken(for window: NSWindow) -> String {
        windowsByToken.first { $0.value === window }?.key ?? ""
    }
}

extension FixtureScene: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let identifier = handlesByViewObject[ObjectIdentifier(tabView)] else { return }
        actionCountsByIdentifier[identifier, default: 0] += 1
        recordEvent(["event": "tabSelected", "identifier": identifier, "label": tabViewItem?.label ?? ""])
    }
}
