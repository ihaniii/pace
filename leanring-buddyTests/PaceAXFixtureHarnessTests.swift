//
//  PaceAXFixtureHarnessTests.swift
//  leanring-buddyTests
//
//  Self-tests for the out-of-process AX fixture harness (Support/PaceAXFixture.swift plus the
//  PaceAXFixtureHost app). Before any QBridge test is migrated onto the fixture, these prove:
//    - every generic control kind the fixture builds is reachable through genuine cross-process
//      Accessibility, with the role AppKit itself assigned,
//    - the fixture's own ground truth ("get") agrees with what Accessibility reports,
//    - allowlisted accessibility overrides are visible cross-process,
//    - window operations performed by the fixture are visible cross-process,
//    - the control channel keeps answering while a sheet or an app-modal session is up,
//    - unknown commands, kinds, keys, actions and attributes fail closed,
//    - the process-wide lease never lets two fixtures overlap, and teardown always runs.
//
//  Independent evidence: AX reads here use raw AXUIElement calls from this test, not QBridge,
//  except where a test deliberately exercises QBridge's own resolution against the fixture.
//

import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Pace

// MARK: - Raw cross-process AX helpers (test-side evidence, independent of QBridge)

private func rawAttribute(_ element: AXUIElement, _ attributeName: String) -> CFTypeRef? {
    var attributeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &attributeValue) == .success else { return nil }
    return attributeValue
}

private func rawChildren(_ element: AXUIElement) -> [AXUIElement] {
    rawAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}

/// Breadth-first search of the fixture process's AX tree for the element whose AXIdentifier
/// matches. Bounded so a malformed tree can never loop forever.
private func rawElement(inProcess processIdentifier: pid_t, withIdentifier identifier: String) -> AXUIElement? {
    var elementsToVisit = [AXUIElementCreateApplication(processIdentifier)]
    var visitedCount = 0
    while !elementsToVisit.isEmpty, visitedCount < 5000 {
        let element = elementsToVisit.removeFirst()
        visitedCount += 1
        if rawAttribute(element, "AXIdentifier") as? String == identifier { return element }
        elementsToVisit.append(contentsOf: rawChildren(element))
    }
    return nil
}

private func waitUntil(timeout: TimeInterval, _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return try await condition()
}

private func processHasExited(_ processIdentifier: pid_t) -> Bool {
    kill(processIdentifier, 0) != 0 && errno == ESRCH
}

/// Records when each concurrent fixture holder was inside its body.
private actor HoldIntervalRecorder {
    private(set) var intervals: [(start: Date, end: Date)] = []
    private(set) var fixturePids: [pid_t] = []

    func record(start: Date, end: Date, fixturePid: pid_t) {
        intervals.append((start, end))
        fixturePids.append(fixturePid)
    }
}

@Suite("PaceAXFixtureHarnessTests", .serialized)
struct PaceAXFixtureHarnessTests {

    /// Every generic control kind the fixture can build (the "view" container is excluded:
    /// a plain NSView is not an accessibility element, so it has no AX node to find).
    static let reachableControlKinds = [
        "button", "checkbox", "radio", "textField", "label", "secureTextField", "searchField",
        "textView", "slider", "stepper", "popUpButton", "comboBox", "segmentedControl",
        "tabView", "scrollView", "splitView"
    ]

    @Test(
        "Every generic control kind is reachable cross-process with the role AppKit assigned it",
        .enabled(if: AXIsProcessTrusted(), "Needs Accessibility for the test host"),
        arguments: reachableControlKinds
    )
    func everyControlKindIsReachableCrossProcess(kind: String) async throws {
        try await PaceAXFixture.withFixture { fixture in
            let windowToken = try await fixture.createWindow(identifier: "harness-window-\(kind)")
            let controlIdentifier = "harness-\(kind)-\(UUID().uuidString)"
            try await fixture.addControl(
                kind: kind,
                identifier: controlIdentifier,
                windowToken: windowToken,
                properties: ["items": ["One", "Two"], "segments": ["Left", "Right"], "tabs": ["First", "Second"], "title": "Harness"]
            )
            let roleAppKitAssigned = try await fixture.string(controlIdentifier, "accessibilityRole")
            #expect(!roleAppKitAssigned.isEmpty)

            let rawElementInFixture = try #require(rawElement(inProcess: fixture.processIdentifier, withIdentifier: controlIdentifier))
            var elementPid: pid_t = 0
            #expect(AXUIElementGetPid(rawElementInFixture, &elementPid) == .success)
            #expect(elementPid == fixture.processIdentifier)
            #expect(elementPid != ProcessInfo.processInfo.processIdentifier)
            #expect(rawAttribute(rawElementInFixture, kAXRoleAttribute as String) as? String == roleAppKitAssigned)
        }
    }

    @Test(
        "A control inside a container control is reachable cross-process",
        .enabled(if: AXIsProcessTrusted(), "Needs Accessibility for the test host"),
        arguments: ["scrollView", "splitView", "tabView", "view"]
    )
    func childControlInsideContainerIsReachable(containerKind: String) async throws {
        try await PaceAXFixture.withFixture { fixture in
            let windowToken = try await fixture.createWindow()
            let containerIdentifier = "harness-container-\(containerKind)"
            try await fixture.addControl(kind: containerKind, identifier: containerIdentifier, windowToken: windowToken, properties: ["tabs": ["First"]])
            let childIdentifier = "harness-child-in-\(containerKind)"
            try await fixture.addControl(
                kind: "button",
                identifier: childIdentifier,
                parentIdentifier: containerIdentifier,
                frame: NSRect(x: 10, y: 10, width: 120, height: 28),
                properties: ["title": "Child"]
            )
            #expect(rawElement(inProcess: fixture.processIdentifier, withIdentifier: childIdentifier) != nil)
        }
    }

    @Test(
        "Fixture ground truth agrees with the AXValue that Accessibility reports cross-process",
        .enabled(if: AXIsProcessTrusted(), "Needs Accessibility for the test host")
    )
    func groundTruthAgreesWithCrossProcessAXValue() async throws {
        try await PaceAXFixture.withFixture { fixture in
            let windowToken = try await fixture.createWindow()
            try await fixture.addControl(kind: "slider", identifier: "harness-slider", windowToken: windowToken, properties: ["minValue": 0.0, "maxValue": 100.0])
            try await fixture.addControl(kind: "checkbox", identifier: "harness-checkbox", windowToken: windowToken, properties: ["title": "Check"])
            try await fixture.addControl(kind: "textField", identifier: "harness-field", windowToken: windowToken)

            try await fixture.set("harness-slider", "doubleValue", 42.0)
            try await fixture.set("harness-checkbox", "state", 1)
            try await fixture.set("harness-field", "stringValue", "harness value")

            #expect(try await fixture.double("harness-slider", "doubleValue") == 42)
            #expect(try await fixture.int("harness-checkbox", "state") == 1)
            #expect(try await fixture.string("harness-field", "stringValue") == "harness value")

            let sliderElement = try #require(rawElement(inProcess: fixture.processIdentifier, withIdentifier: "harness-slider"))
            let checkboxElement = try #require(rawElement(inProcess: fixture.processIdentifier, withIdentifier: "harness-checkbox"))
            let fieldElement = try #require(rawElement(inProcess: fixture.processIdentifier, withIdentifier: "harness-field"))
            #expect((rawAttribute(sliderElement, kAXValueAttribute as String) as? NSNumber)?.doubleValue == 42)
            #expect((rawAttribute(checkboxElement, kAXValueAttribute as String) as? NSNumber)?.intValue == 1)
            #expect(rawAttribute(fieldElement, kAXValueAttribute as String) as? String == "harness value")

            // QBridge's own read path against the fixture agrees too.
            let readResult = try await QBridgeAccessibility.shared.readElementValue(
                applicationName: fixture.applicationName,
                role: "AXTextField",
                identifier: "harness-field",
                title: nil
            )
            #expect(readResult.value == "harness value")
        }
    }

    @Test(
        "Accessibility overrides set in the fixture are visible cross-process",
        .enabled(if: AXIsProcessTrusted(), "Needs Accessibility for the test host")
    )
    func accessibilityOverridesAreVisibleCrossProcess() async throws {
        try await PaceAXFixture.withFixture { fixture in
            let windowToken = try await fixture.createWindow()
            try await fixture.addControl(kind: "label", identifier: "harness-label", windowToken: windowToken, properties: ["title": "Name"])
            try await fixture.addControl(kind: "textField", identifier: "harness-input", windowToken: windowToken)
            try await fixture.addControl(kind: "button", identifier: "harness-linked", windowToken: windowToken, properties: ["title": "Linked"])

            try await fixture.setAccessibility("harness-input", "label", "Harness description")
            try await fixture.setAccessibility("harness-input", "help", "Harness help")
            try await fixture.setAccessibility("harness-input", "placeholderValue", "Harness placeholder")
            try await fixture.setAccessibility("harness-input", "required", true)
            try await fixture.setAccessibility("harness-input", "titleUIElement", "harness-label")
            try await fixture.setAccessibility("harness-input", "linkedUIElements", ["harness-linked"])

            let inputElement = try #require(rawElement(inProcess: fixture.processIdentifier, withIdentifier: "harness-input"))
            #expect(rawAttribute(inputElement, kAXDescriptionAttribute as String) as? String == "Harness description")
            #expect(rawAttribute(inputElement, kAXHelpAttribute as String) as? String == "Harness help")
            #expect(rawAttribute(inputElement, "AXPlaceholderValue") as? String == "Harness placeholder")
            #expect((rawAttribute(inputElement, "AXRequired") as? NSNumber)?.boolValue == true)

            let titleElementValue = try #require(rawAttribute(inputElement, kAXTitleUIElementAttribute as String))
            #expect(CFGetTypeID(titleElementValue) == AXUIElementGetTypeID())
            let titleElement = titleElementValue as! AXUIElement
            #expect(rawAttribute(titleElement, "AXIdentifier") as? String == "harness-label")

            let linkedElements = rawAttribute(inputElement, kAXLinkedUIElementsAttribute as String) as? [AXUIElement] ?? []
            #expect(linkedElements.compactMap { rawAttribute($0, "AXIdentifier") as? String } == ["harness-linked"])
        }
    }

    @Test(
        "Window operations performed by the fixture are visible cross-process",
        .enabled(if: AXIsProcessTrusted(), "Needs Accessibility for the test host")
    )
    func windowOperationsAreVisibleCrossProcess() async throws {
        try await PaceAXFixture.withFixture { fixture in
            try await fixture.createWindow(identifier: "harness-window")
            let windowElement = try #require(rawElement(inProcess: fixture.processIdentifier, withIdentifier: "harness-window"))
            #expect(rawAttribute(windowElement, kAXRoleAttribute as String) as? String == kAXWindowRole as String)
            #expect(try await fixture.bool("harness-window", "isMiniaturized") == false)

            try await fixture.perform("harness-window", "miniaturize")
            let miniaturizedInFixture = try await waitUntil(timeout: 5) { try await fixture.bool("harness-window", "isMiniaturized") }
            #expect(miniaturizedInFixture)
            #expect((rawAttribute(windowElement, kAXMinimizedAttribute as String) as? NSNumber)?.boolValue == true)

            try await fixture.perform("harness-window", "deminiaturize")
            let restoredInFixture = try await waitUntil(timeout: 5) { try await fixture.bool("harness-window", "isMiniaturized") == false }
            #expect(restoredInFixture)
            #expect((rawAttribute(windowElement, kAXMinimizedAttribute as String) as? NSNumber)?.boolValue == false)
        }
    }

    @Test(
        "A control action triggered through QBridge is recorded in the fixture's own event log",
        .enabled(if: AXIsProcessTrusted(), "Needs Accessibility for the test host")
    )
    func controlActionIsRecordedInEventLog() async throws {
        try await PaceAXFixture.withFixture { fixture in
            let windowToken = try await fixture.createWindow()
            try await fixture.addControl(kind: "button", identifier: "harness-press", windowToken: windowToken, properties: ["title": "Press"])
            try await fixture.clearEvents()

            _ = try await QBridgeAccessibility.shared.clickElement(
                applicationName: fixture.applicationName,
                role: "AXButton",
                identifier: "harness-press",
                title: nil
            )

            let events = try await fixture.events()
            #expect(events.filter { $0["event"] as? String == "action" && $0["identifier"] as? String == "harness-press" }.count == 1)
            #expect(try await fixture.int("harness-press", "actionCount") == 1)
        }
    }

    @Test("The control channel keeps answering while a sheet is attached")
    func channelAnswersWhileSheetIsAttached() async throws {
        try await PaceAXFixture.withFixture { fixture in
            try await fixture.createWindow(identifier: "harness-sheet-parent")
            try await fixture.presentSheet(parentIdentifier: "harness-sheet-parent", identifier: "harness-sheet")
            let sheetAttached = try await waitUntil(timeout: 5) { try await fixture.bool("harness-sheet-parent", "hasAttachedSheet") }
            #expect(sheetAttached)
            #expect(try await fixture.bool("harness-sheet", "isSheet"))
            _ = try await fixture.hostProcess.request("ping")

            try await fixture.endSheet(identifier: "harness-sheet")
            let sheetDetached = try await waitUntil(timeout: 5) { try await fixture.bool("harness-sheet-parent", "hasAttachedSheet") == false }
            #expect(sheetDetached)
        }
    }

    @Test("The control channel keeps answering during an application-modal session, and the session can be stopped")
    func channelAnswersDuringModalSession() async throws {
        try await PaceAXFixture.withFixture { fixture in
            try await fixture.createWindow(identifier: "harness-modal", styles: ["titled"])
            try await fixture.startModalSession(identifier: "harness-modal")
            let modalRunning = try await waitUntil(timeout: 5) { try await fixture.isModalSessionRunning() }
            #expect(modalRunning)

            // Answered from inside the modal run loop.
            _ = try await fixture.hostProcess.request("ping")
            #expect(try await fixture.bool("harness-modal", "isVisible"))

            try await fixture.stopModalSession()
            let modalStopped = try await waitUntil(timeout: 5) { try await fixture.isModalSessionRunning() == false }
            #expect(modalStopped)
        }
    }

    @Test("A fixture in an application-modal session still exits when its stdin closes")
    func fixtureExitsOnStdinEOFDuringModalSession() async throws {
        let fixture = try await PaceAXFixture.launch()
        defer { fixture.stop() }
        try await fixture.createWindow(identifier: "harness-modal-eof", styles: ["titled"])
        try await fixture.startModalSession(identifier: "harness-modal-eof")
        let modalRunning = try await waitUntil(timeout: 5) { try await fixture.isModalSessionRunning() }
        #expect(modalRunning)

        fixture.hostProcess.closeStdin()
        let exited = await waitUntil(timeout: 5) { !fixture.hostProcess.process.isRunning }
        #expect(exited)
    }

    @Test("Unknown commands, control kinds, keys, actions and accessibility attributes fail closed")
    func unknownRequestsFailClosed() async throws {
        try await PaceAXFixture.withFixture { fixture in
            let windowToken = try await fixture.createWindow()
            try await fixture.addControl(kind: "slider", identifier: "harness-allowlist", windowToken: windowToken)

            await #expect(throws: PaceAXFixtureError.self) { _ = try await fixture.hostProcess.request("notACommand") }
            await #expect(throws: PaceAXFixtureError.self) {
                try await fixture.addControl(kind: "notAControlKind", identifier: "harness-bad-kind", windowToken: windowToken)
            }
            await #expect(throws: PaceAXFixtureError.self) { _ = try await fixture.value("harness-allowlist", "notAKey") }
            await #expect(throws: PaceAXFixtureError.self) { try await fixture.set("harness-allowlist", "notAKey", 1) }
            await #expect(throws: PaceAXFixtureError.self) { try await fixture.set("harness-allowlist", "doubleValue", "not a number") }
            await #expect(throws: PaceAXFixtureError.self) { try await fixture.perform("harness-allowlist", "notAnAction") }
            await #expect(throws: PaceAXFixtureError.self) { try await fixture.setAccessibility("harness-allowlist", "notAnAttribute", "x") }
            await #expect(throws: PaceAXFixtureError.self) { _ = try await fixture.value("harness-unknown-identifier", "doubleValue") }
            await #expect(throws: PaceAXFixtureError.self) {
                try await fixture.addControl(kind: "button", identifier: "harness-allowlist", windowToken: windowToken)
            }
            await #expect(throws: PaceAXFixtureError.self) { try await fixture.createWindow(styles: ["notAStyle"]) }

            // The channel is still healthy after every rejection.
            _ = try await fixture.hostProcess.request("ping")
        }
    }

    @Test("The process-wide lease never lets two fixture holders overlap")
    func leaseNeverLetsTwoFixturesOverlap() async throws {
        let recorder = HoldIntervalRecorder()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await PaceAXFixture.withFixture { fixture in
                        let holdStart = Date()
                        _ = try await fixture.hostProcess.request("ping")
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        await recorder.record(start: holdStart, end: Date(), fixturePid: fixture.processIdentifier)
                    }
                }
            }
            try await group.waitForAll()
        }
        let intervals = await recorder.intervals.sorted { $0.start < $1.start }
        #expect(intervals.count == 3)
        for (earlier, later) in zip(intervals, intervals.dropFirst()) {
            #expect(earlier.end <= later.start)
        }
        let fixturePids = await recorder.fixturePids
        #expect(Set(fixturePids).count == 3)
    }

    @Test("withFixture stops the fixture and frees the lease even when its body throws")
    func withFixtureTearsDownWhenBodyThrows() async throws {
        struct DeliberateBodyFailure: Error {}
        var fixturePidFromFailedBody: pid_t = 0
        await #expect(throws: DeliberateBodyFailure.self) {
            try await PaceAXFixture.withFixture { fixture in
                fixturePidFromFailedBody = fixture.processIdentifier
                throw DeliberateBodyFailure()
            }
        }
        let exited = await waitUntil(timeout: 5) { processHasExited(fixturePidFromFailedBody) }
        #expect(exited)

        // The lease came back: the next fixture launches without waiting on the leaked holder.
        try await PaceAXFixture.withFixture { fixture in
            #expect(fixture.processIdentifier != fixturePidFromFailedBody)
        }
    }
}
