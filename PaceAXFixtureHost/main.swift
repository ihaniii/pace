//
//  main.swift
//  PaceAXFixtureHost
//
//  Test-only helper app: a separate process that hosts real AppKit controls so
//  QBridgeAccessibility tests drive genuine cross-process Accessibility instead of
//  AX calls back into the XCTest host's own process (which deadlocks in AppKit's
//  text system and menu locks). Phase 0 spike of docs plan "out-of-process fixture host".
//
//  Control channel: newline-delimited JSON on stdin (requests) and stdout (responses),
//  one response per request, matched by "id". Nothing else is ever written to stdout.
//  No network, no sockets, no files, no UserDefaults writes, no Keychain.
//
//  Lifetime: exits when stdin reaches EOF (the test host closed the pipe or died), when
//  the parent process exits (dispatch process source), or after a hard lifetime cap —
//  so a crashed test run can never leave it running.
//

import AppKit
import Foundation

private let maximumLifetimeSeconds: TimeInterval = 600

/// Carries one response from the main thread back to the stdin reader thread.
private final class PendingResponse: @unchecked Sendable {
    var response: [String: Any] = [:]
}

private func writeResponseLine(_ response: [String: Any]) {
    guard let responseData = try? JSONSerialization.data(withJSONObject: response),
          var responseLine = String(data: responseData, encoding: .utf8) else { return }
    responseLine += "\n"
    FileHandle.standardOutput.write(Data(responseLine.utf8))
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
// Top-level code runs on the main thread before the run loop starts.
let fixtureHostController = MainActor.assumeIsolated { FixtureHostController() }

// Every teardown path calls exit() from a background queue or thread, never through the
// main queue: AppKit does not drain the main queue while a modal session runs, so a
// main-queue teardown would leave a fixture that shows a modal window running forever.

// Teardown 1: parent death. If the launching process is already gone we were orphaned
// before we started; otherwise exit the moment it exits.
let launchingParentPid = getppid()
if launchingParentPid <= 1 { exit(0) }
let parentExitSource = DispatchSource.makeProcessSource(
    identifier: launchingParentPid,
    eventMask: .exit,
    queue: DispatchQueue(label: "PaceAXFixtureHost.parentExit")
)
parentExitSource.setEventHandler { exit(0) }
parentExitSource.resume()

// Teardown 2: hard lifetime cap.
DispatchQueue.global().asyncAfter(deadline: .now() + maximumLifetimeSeconds) { exit(0) }

// Control channel. Teardown 3: stdin EOF.
Thread.detachNewThread {
    while let requestLine = readLine(strippingNewline: true) {
        let pendingResponse = PendingResponse()
        let responseReady = DispatchSemaphore(value: 0)
        // RunLoop.perform with explicit modes instead of DispatchQueue.main.sync: the main queue
        // is not serviced while AppKit runs a modal session (.modalPanel) or tracks a menu or
        // control (.eventTracking), and the channel must keep answering in exactly those states.
        RunLoop.main.perform(inModes: [.default, .common, .modalPanel, .eventTracking]) {
            pendingResponse.response = MainActor.assumeIsolated { fixtureHostController.handle(requestLine: requestLine) }
            responseReady.signal()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        responseReady.wait()
        writeResponseLine(pendingResponse.response)
    }
    exit(0)
}

application.run()
