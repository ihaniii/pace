//
//  PaceAXFixtureHostSpikeTests.swift
//  leanring-buddyTests
//
//  Phase 0 spike for the out-of-process QBridge AX fixture host. Proves that the
//  PaceAXFixtureHost helper app:
//    - runs as a separate process (its pid is not this XCTest host's pid),
//    - carries an exact, dedicated bundle identity outside the Que/Pace family,
//      discoverable through QBridgeAccessibility's own application resolution,
//    - answers a deterministic stdin/stdout JSON-lines handshake,
//    - hosts real AppKit controls that QBridgeAccessibility reads and mutates through
//      genuine cross-process Accessibility (no coordinates, no CGEvent),
//    - reports ground truth from its own AppKit objects, independent of AX,
//    - exits on stdin EOF and on parent death.
//
//  The suite is serialized: each test launches its own fixture instance, and two live
//  instances would make bundle-identifier resolution ambiguous (which QBridge fails closed on).
//  The process harness lives in Support/PaceAXFixture.swift; every launch goes through its
//  process-wide lease, so fixtures from other suites never overlap with these either.
//

import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Pace

/// True once `processIdentifier` no longer exists (exited and reaped).
private func processHasExited(_ processIdentifier: pid_t) -> Bool {
    kill(processIdentifier, 0) != 0 && errno == ESRCH
}

private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

/// Raw AX read of the system-wide focused element's (pid, AXIdentifier) — test-side evidence
/// independent of the QBridge code under test.
private func systemFocusedElementPidAndIdentifier() -> (pid: pid_t, identifier: String?)? {
    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
          let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
    let focusedElement = focusedValue as! AXUIElement
    var focusedPid: pid_t = 0
    guard AXUIElementGetPid(focusedElement, &focusedPid) == .success else { return nil }
    var identifierValue: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(focusedElement, "AXIdentifier" as CFString, &identifierValue)
    return (focusedPid, identifierValue as? String)
}

/// Launches a fixture, completes the handshake, and waits until the system registers it under
/// its bundle identifier (which is what QBridgeAccessibility resolves against).
@MainActor
private func launchRegisteredFixture() async throws -> (fixture: PaceAXFixtureHostProcess, pid: pid_t) {
    let fixture = try await PaceAXFixtureHostProcess.launch()
    let handshake = try await fixture.request("ping")
    let fixturePid = pid_t(try #require(handshake["pid"] as? Int))
    let registered = await waitUntil(timeout: 5) {
        NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier == fixturePid && $0.bundleIdentifier == PaceAXFixtureHostProcess.bundleIdentifier
        }
    }
    #expect(registered, "fixture never appeared in NSWorkspace.runningApplications under its bundle identifier")
    return (fixture, fixturePid)
}

@Suite("PaceAXFixtureHostSpikeTests", .serialized)
struct PaceAXFixtureHostSpikeTests {

    @Test("1. Handshake: separate pid, exact dedicated bundle identity, resolvable by QBridge, parented by the test host")
    @MainActor
    func handshakeIdentityAndProcessSeparation() async throws {
        let (fixture, fixturePid) = try await launchRegisteredFixture()
        defer { fixture.forceStop() }

        let handshake = try await fixture.request("ping")
        let testHostPid = ProcessInfo.processInfo.processIdentifier
        #expect(fixturePid == fixture.process.processIdentifier)
        #expect(fixturePid != testHostPid)
        #expect(handshake["parentPid"] as? Int == Int(testHostPid))
        #expect(handshake["bundleIdentifier"] as? String == "test.qbridge.axfixturehost")

        // System-reported identity, not just what the fixture says about itself.
        let runningFixture = try #require(NSRunningApplication(processIdentifier: fixturePid))
        #expect(runningFixture.bundleIdentifier == "test.qbridge.axfixturehost")
        #expect(runningFixture.bundleIdentifier != Bundle.main.bundleIdentifier)
        #expect(runningFixture.bundleIdentifier?.hasPrefix("com.pace") == false)

        // QBridge's own exact-resolution path lands on exactly this fixture process.
        let resolvedByQBridge = try QBridgeAccessibility.resolveExactRunningApplication(named: PaceAXFixtureHostProcess.bundleIdentifier)
        #expect(resolvedByQBridge.processIdentifier == fixturePid)
    }

    @Test(
        "2. Genuine cross-process AX read: QBridge reads a real AppKit text field in the fixture",
        .enabled(if: AXIsProcessTrusted(), "Needs Accessibility for the test host")
    )
    @MainActor
    func genuineCrossProcessAXRead() async throws {
        let (fixture, _) = try await launchRegisteredFixture()
        defer { fixture.forceStop() }
        let identifier = "spike-read-\(UUID().uuidString)"
        let expectedValue = "fixture value \(UUID().uuidString)"
        _ = try await fixture.request("createTextFieldWindow", ["identifier": identifier, "value": expectedValue])

        let readResult = try await QBridgeAccessibility.shared.readElementValue(
            applicationName: PaceAXFixtureHostProcess.bundleIdentifier,
            role: "AXTextField",
            identifier: identifier,
            title: nil
        )
        #expect(readResult.value == expectedValue)
    }

    @Test(
        "3. Genuine cross-process AX mutation (AXPress): QBridge presses a real button; the fixture's own AppKit state confirms it",
        .enabled(if: AXIsProcessTrusted(), "Needs Accessibility for the test host")
    )
    @MainActor
    func genuineCrossProcessAXPress() async throws {
        let (fixture, _) = try await launchRegisteredFixture()
        defer { fixture.forceStop() }
        let identifier = "spike-press-\(UUID().uuidString)"
        _ = try await fixture.request("createButtonWindow", ["identifier": identifier, "title": "Spike Press"])
        let pressesBefore = try await fixture.request("query", ["identifier": identifier, "property": "pressCount"])
        #expect(pressesBefore["value"] as? Int == 0)

        _ = try await QBridgeAccessibility.shared.clickElement(
            applicationName: PaceAXFixtureHostProcess.bundleIdentifier,
            role: "AXButton",
            identifier: identifier,
            title: nil
        )

        let pressesAfter = try await fixture.request("query", ["identifier": identifier, "property": "pressCount"])
        #expect(pressesAfter["value"] as? Int == 1)
    }

    @Test(
        "4. Genuine cross-process AX mutation (set value): the in-process deadlock shape, now cross-process",
        .enabled(if: AXIsProcessTrusted(), "Needs Accessibility for the test host")
    )
    @MainActor
    func genuineCrossProcessAXSetTextValue() async throws {
        let (fixture, fixturePid) = try await launchRegisteredFixture()
        defer { fixture.forceStop() }
        let identifier = "spike-set-\(UUID().uuidString)"
        _ = try await fixture.request("createTextFieldWindow", ["identifier": identifier, "value": "original"])

        // setTextValue requires the target to be the system's genuinely focused element.
        var fixtureFieldIsFocused = false
        for _ in 0..<40 {
            _ = try await fixture.request("focus", ["identifier": identifier])
            NSRunningApplication(processIdentifier: fixturePid)?.activate()
            if let focused = systemFocusedElementPidAndIdentifier(), focused.pid == fixturePid, focused.identifier == identifier {
                fixtureFieldIsFocused = true
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        #expect(fixtureFieldIsFocused, "the fixture's text field never became the system-wide focused element")
        guard fixtureFieldIsFocused else { return }

        let newValue = "set across processes \(UUID().uuidString)"
        let outcome = try await QBridgeAccessibility.shared.setTextValue(
            applicationName: PaceAXFixtureHostProcess.bundleIdentifier,
            role: "AXTextField",
            identifier: identifier,
            title: nil,
            newValue: newValue
        )
        #expect(outcome.valueChanged)
        let fixtureTruth = try await fixture.request("query", ["identifier": identifier, "property": "stringValue"])
        #expect(fixtureTruth["value"] as? String == newValue)
    }

    @Test("5. Teardown: the fixture exits on stdin EOF and disappears from the running applications")
    @MainActor
    func fixtureExitsOnStdinEOF() async throws {
        let (fixture, fixturePid) = try await launchRegisteredFixture()
        defer { fixture.forceStop() }

        fixture.closeStdin()
        let exited = await waitUntil(timeout: 5) { !fixture.process.isRunning }
        #expect(exited)
        #expect(fixture.process.terminationReason == .exit)
        #expect(fixture.process.terminationStatus == 0)
        let unregistered = await waitUntil(timeout: 5) {
            !NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == fixturePid }
        }
        #expect(unregistered)
    }

    @Test("6. Teardown: the fixture exits when its parent dies, even though its stdin is still open")
    @MainActor
    func fixtureExitsOnParentDeath() async throws {
        let fixtureViaShell = try await PaceAXFixtureHostProcess.launch(viaIntermediateShell: true)
        defer { fixtureViaShell.forceStop() }

        let handshake = try await fixtureViaShell.request("ping")
        let fixturePid = pid_t(try #require(handshake["pid"] as? Int))
        let shellPid = fixtureViaShell.process.processIdentifier
        #expect(handshake["parentPid"] as? Int == Int(shellPid))
        #expect(fixturePid != shellPid)

        // Kill only the intermediate parent. This test still holds the fixture's stdin open,
        // so an exit here can only come from the parent-death path.
        kill(shellPid, SIGKILL)
        let fixtureExited = await waitUntil(timeout: 5) { processHasExited(fixturePid) }
        #expect(fixtureExited)
    }
}
