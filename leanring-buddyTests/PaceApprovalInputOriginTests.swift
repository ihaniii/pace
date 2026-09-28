//
//  PaceApprovalInputOriginTests.swift
//  leanring-buddyTests
//
//  Proves Que cannot resolve its own pending Q approval with a mouse or keyboard
//  event its own process synthesized (PaceApprovalInputOrigin + the HUD entry
//  point CompanionManager.resolveClarification), while genuine input — hardware,
//  other processes, and Accessibility presses (no event) — still resolves it, and
//  the approval's single-use grant semantics are untouched.
//
//  Every event here is either built in-process and never posted, or posted ONLY to
//  this test process (CGEventPostToPid) and swallowed by a local monitor before any
//  window sees it — nothing moves the real cursor or types into another app.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Pace

/// Marks the events this suite posts so the local monitor swallows only those.
private let approvalOriginTestEventMarker: Int64 = 0x5041_4345_4F52_4731 // "PACEORG1"

/// kVK_F19 — a key no app binds by default, used for the in-process key event.
private let unboundTestKeyCode: CGKeyCode = 80

private func makeSelfSynthesizedMouseUpEvent() -> NSEvent? {
    guard let mouseUp = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: CGPoint(x: 1, y: 1),
        mouseButton: .left
    ) else { return nil }
    return NSEvent(cgEvent: mouseUp)
}

private func makeSelfSynthesizedKeyDownEvent(stateID: CGEventSourceStateID? = nil) -> NSEvent? {
    let eventSource = stateID.flatMap { CGEventSource(stateID: $0) }
    guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: unboundTestKeyCode, keyDown: true) else {
        return nil
    }
    return NSEvent(cgEvent: keyDown)
}

/// Posts `event` to THIS process only and returns it as AppKit received it, swallowed by a
/// local monitor so it never reaches a window. Nil if it did not arrive within `timeout`.
@MainActor
private func postToOwnProcessAndCapture(
    _ event: CGEvent,
    matching eventTypeMask: NSEvent.EventTypeMask,
    timeout: TimeInterval = 3.0
) async -> NSEvent? {
    event.setIntegerValueField(.eventSourceUserData, value: approvalOriginTestEventMarker)
    var capturedEvent: NSEvent?
    let monitor = NSEvent.addLocalMonitorForEvents(matching: eventTypeMask) { receivedEvent in
        guard receivedEvent.cgEvent?.getIntegerValueField(.eventSourceUserData) == approvalOriginTestEventMarker else {
            return receivedEvent
        }
        capturedEvent = receivedEvent
        return nil
    }
    defer { if let monitor { NSEvent.removeMonitor(monitor) } }

    event.postToPid(ProcessInfo.processInfo.processIdentifier)
    let deadline = Date().addingTimeInterval(timeout)
    while capturedEvent == nil, Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return capturedEvent
}

/// Submits a Level 2 clipboard write that halts awaiting approval, and returns what the HUD
/// would hold for it.
@MainActor
private func submitPendingClipboardApproval(marker: String) async throws -> (task: QTask, snapshot: QRuntimeUISnapshot)? {
    let mockModel = MockAutonomousModelProvider()
    mockModel.structuredPlansToReturn = [
        """
        {
          "taskPrompt": "Write approval-origin marker",
          "steps": [
            {
              "actionName": "system.clipboard.write",
              "toolFamily": "system",
              "description": "Write approval-origin marker to clipboard",
              "parameters": {"text": "\(marker)"}
            }
          ]
        }
        """
    ]
    let observer = MockQPlanUIObserver()
    let runtime = QCoreRuntime(
        modelProvider: mockModel,
        memoryProvider: try QSQLiteMemoryStore(inMemory: true),
        executionProvider: QExecutionService.shared,
        durableStore: QDurableTaskStore.shared,
        endpointName: "approval-origin-\(UUID().uuidString)"
    )
    let task = try await runtime.submitIntent(prompt: "Write approval-origin marker", observer: observer)
    guard case .awaitingApproval = task.state,
          let snapshot = observer.recordedSnapshots.last(where: { $0.pendingApproval != nil }) else {
        Issue.record("Expected the clipboard write to halt awaiting approval, got: \(task.state)")
        return nil
    }
    return (task, snapshot)
}

@MainActor
private func durableLifecycleState(taskId: String) -> QDurableTaskLifecycleState? {
    try? QDurableTaskStore.shared.getTask(taskId: taskId)?.lifecycleState
}

@Suite("PaceApprovalInputOriginTests")
struct PaceApprovalInputOriginTests {

    // MARK: - Pure decision

    @Test("1. Only an event sourced from Que's own pid is rejected; hardware (0) and other processes are allowed")
    func pureDecisionRejectsOnlyOwnProcess() {
        let ownProcessIdentifier: Int64 = 4242
        #expect(PaceApprovalInputOrigin.verdict(eventSourceProcessIdentifier: 4242, ownProcessIdentifier: ownProcessIdentifier) == .rejectedSelfSynthesizedEvent)
        #expect(PaceApprovalInputOrigin.verdict(eventSourceProcessIdentifier: 0, ownProcessIdentifier: ownProcessIdentifier) == .allowed)
        #expect(PaceApprovalInputOrigin.verdict(eventSourceProcessIdentifier: 4243, ownProcessIdentifier: ownProcessIdentifier) == .allowed)
        #expect(PaceApprovalInputOrigin.verdict(eventSourceProcessIdentifier: 1, ownProcessIdentifier: ownProcessIdentifier) == .allowed)
    }

    @Test("2. No triggering event (an Accessibility press, e.g. VoiceOver) is allowed")
    func accessibilityPressWithNoEventIsAllowed() {
        #expect(PaceApprovalInputOrigin.verdict(forTriggeringEvent: nil) == .allowed)
    }

    // MARK: - Real in-process events

    @Test("3. A mouse click Que synthesizes carries Que's pid and is rejected")
    func selfSynthesizedMouseEventIsRejected() throws {
        let mouseUp = try #require(makeSelfSynthesizedMouseUpEvent())
        #expect(mouseUp.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == PaceApprovalInputOrigin.currentProcessIdentifier)
        #expect(PaceApprovalInputOrigin.verdict(forTriggeringEvent: mouseUp) == .rejectedSelfSynthesizedEvent)
    }

    @Test("4. A keystroke Que synthesizes is rejected — even when built to claim the HID system source state")
    func selfSynthesizedKeyboardEventIsRejectedRegardlessOfSourceState() throws {
        let plainKeyDown = try #require(makeSelfSynthesizedKeyDownEvent())
        #expect(PaceApprovalInputOrigin.verdict(forTriggeringEvent: plainKeyDown) == .rejectedSelfSynthesizedEvent)

        // eventSourceStateID is poster-chosen: a hidSystemState source reports the same state as
        // hardware, and must not change the verdict.
        let hidStateKeyDown = try #require(makeSelfSynthesizedKeyDownEvent(stateID: .hidSystemState))
        #expect(hidStateKeyDown.cgEvent?.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue))
        #expect(PaceApprovalInputOrigin.verdict(forTriggeringEvent: hidStateKeyDown) == .rejectedSelfSynthesizedEvent)
    }

    @Test("5. A non-input current event (app-defined) says nothing about who pressed the chip and is allowed")
    func nonInputEventIsNotTreatedAsTheTrigger() throws {
        let appDefinedEvent = try #require(NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ))
        #expect(PaceApprovalInputOrigin.verdict(forTriggeringEvent: appDefinedEvent) == .allowed)
    }

    // MARK: - Posted round trip: what Que receives when it posts an event to itself

    @Test(
        "6. A keystroke Que posts and then receives still carries Que's pid and is rejected",
        .enabled(if: CGPreflightPostEventAccess(), "Posting events needs Accessibility for the test host")
    )
    @MainActor
    func postedKeyboardEventRoundTripIsRejected() async throws {
        let keyDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: unboundTestKeyCode, keyDown: true))
        let received = try #require(await postToOwnProcessAndCapture(keyDown, matching: .keyDown))
        #expect(received.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == PaceApprovalInputOrigin.currentProcessIdentifier)
        #expect(PaceApprovalInputOrigin.verdict(forTriggeringEvent: received) == .rejectedSelfSynthesizedEvent)
    }

    @Test(
        "7. A mouse click Que posts and then receives still carries Que's pid and is rejected",
        .enabled(if: CGPreflightPostEventAccess(), "Posting events needs Accessibility for the test host")
    )
    @MainActor
    func postedMouseEventRoundTripIsRejected() async throws {
        let mouseUp = try #require(CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: CGPoint(x: 1, y: 1), mouseButton: .left
        ))
        let received = try #require(await postToOwnProcessAndCapture(mouseUp, matching: .leftMouseUp))
        #expect(received.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == PaceApprovalInputOrigin.currentProcessIdentifier)
        #expect(PaceApprovalInputOrigin.verdict(forTriggeringEvent: received) == .rejectedSelfSynthesizedEvent)
    }

    // MARK: - End to end through the real HUD entry point

    @Test("8. A Que-synthesized click on Allow resolves nothing; the approval stays pending and a genuine press still works")
    @MainActor
    func selfSynthesizedAllowLeavesApprovalPendingAndGenuinePressStillResolves() async throws {
        let marker = "approval-origin-allow-\(UUID().uuidString)"
        guard let pendingApproval = try await submitPendingClipboardApproval(marker: marker) else { return }
        let task = pendingApproval.task
        let snapshot = pendingApproval.snapshot
        let pendingApprovalId = try #require(snapshot.pendingApproval?.id)

        let manager = CompanionManager()
        manager.activeQPlanSnapshot = snapshot
        let selfSynthesizedClick = try #require(makeSelfSynthesizedMouseUpEvent())

        manager.resolveClarification(option: "Allow", triggeringEvent: selfSynthesizedClick)

        // Give any (wrongly) dispatched resolution time to run before asserting nothing happened.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(durableLifecycleState(taskId: task.taskId) == .awaitingApproval)
        #expect(QApprovalCoordinator.shared.pendingRequest(id: pendingApprovalId) != nil)
        #expect(NSPasteboard.general.string(forType: .string) != marker)
        let refusalRecords = QAuditLogger.shared.getRecentRecords(limit: 500).filter {
            $0.taskId == task.taskId && $0.error == "self_synthesized_approval_input"
        }
        #expect(refusalRecords.count == 1)
        #expect(refusalRecords.first?.authorizationResult == "deny")

        // The same pending approval, pressed with no synthetic event (an Accessibility press),
        // still resolves and executes — the refusal did not consume or alter it.
        manager.resolveClarification(option: "Allow", triggeringEvent: nil)
        var finalState: QDurableTaskLifecycleState?
        for _ in 0..<50 {
            finalState = durableLifecycleState(taskId: task.taskId)
            if finalState == .completed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(finalState == .completed)
        #expect(NSPasteboard.general.string(forType: .string) == marker)
    }

    @Test("9. A Que-synthesized keystroke on Deny resolves nothing either; the HUD still offers the choice")
    @MainActor
    func selfSynthesizedDenyLeavesApprovalPending() async throws {
        let marker = "approval-origin-deny-\(UUID().uuidString)"
        guard let pendingApproval = try await submitPendingClipboardApproval(marker: marker) else { return }
        let task = pendingApproval.task
        let snapshot = pendingApproval.snapshot
        let pendingApprovalId = try #require(snapshot.pendingApproval?.id)

        let manager = CompanionManager()
        manager.activeQPlanSnapshot = snapshot
        let hudStateBefore = manager.currentTurnHUDState
        let selfSynthesizedKeystroke = try #require(makeSelfSynthesizedKeyDownEvent())

        manager.resolveClarification(option: "Deny", triggeringEvent: selfSynthesizedKeystroke)

        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(manager.currentTurnHUDState == hudStateBefore)
        #expect(durableLifecycleState(taskId: task.taskId) == .awaitingApproval)
        #expect(QApprovalCoordinator.shared.pendingRequest(id: pendingApprovalId) != nil)

        // Clean up: resolve the pending approval genuinely so no pending state leaks.
        manager.resolveClarification(option: "Deny", triggeringEvent: nil)
        var finalState: QDurableTaskLifecycleState?
        for _ in 0..<20 {
            finalState = durableLifecycleState(taskId: task.taskId)
            if finalState == .failed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(finalState == .failed)
        #expect(NSPasteboard.general.string(forType: .string) != marker)
    }
}
