//
//  PaceApprovalInputOrigin.swift
//  leanring-buddy
//
//  Decides whether the input event that triggered a Q approval decision (the
//  HUD's Allow/Deny chip) may resolve it. The single rule: an approval is never
//  resolved by a mouse-button or key event that Que's own process synthesized.
//  Que's executors post synthetic clicks and keystrokes into the system event
//  stream, and nothing else stops one of them from landing on Que's own panel
//  while an approval is pending — this closes that self-approval path at the
//  one place every such event must pass through.
//
//  The signal is the CGEvent source Unix process ID, which the system stamps
//  with the posting process's pid (observed on real hardware: physical input
//  reports 0, every event this process posted reports this process's pid).
//  Deliberately NOT used:
//   - eventSourceStateID — any poster can choose it (a synthetic event built
//     from a `.hidSystemState` source reports the same value as hardware).
//   - "source pid must be 0" — that would also reject assistive technology
//     and other legitimate external input; this rule only removes Que's own
//     execution machinery as an approver.
//
//  An approval triggered with no current input event (an Accessibility press
//  from VoiceOver or Switch Control, or a direct in-process call) is allowed:
//  Accessibility presses carry no event, and Que driving its own UI through
//  Accessibility is a separate boundary (the QBridge self-target guard).
//

import AppKit

enum PaceApprovalInputOrigin {

    enum Verdict: Equatable {
        case allowed
        case rejectedSelfSynthesizedEvent
    }

    /// The input event kinds that can press a button. Only these are treated as
    /// the event that triggered an approval; anything else (app-defined,
    /// periodic, mouse movement, …) says nothing about who pressed the chip.
    static let buttonTriggeringEventTypes: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .keyDown, .keyUp
    ]

    static var currentProcessIdentifier: Int64 {
        Int64(ProcessInfo.processInfo.processIdentifier)
    }

    /// Verdict for the event that triggered an approval decision.
    static func verdict(
        forTriggeringEvent triggeringEvent: NSEvent?,
        ownProcessIdentifier: Int64 = currentProcessIdentifier
    ) -> Verdict {
        guard let triggeringEvent,
              buttonTriggeringEventTypes.contains(triggeringEvent.type),
              let triggeringCGEvent = triggeringEvent.cgEvent else {
            return .allowed
        }
        return verdict(
            eventSourceProcessIdentifier: triggeringCGEvent.getIntegerValueField(.eventSourceUnixProcessID),
            ownProcessIdentifier: ownProcessIdentifier
        )
    }

    /// The pure decision: only an event sourced from this very process is rejected.
    static func verdict(eventSourceProcessIdentifier: Int64, ownProcessIdentifier: Int64) -> Verdict {
        eventSourceProcessIdentifier == ownProcessIdentifier ? .rejectedSelfSynthesizedEvent : .allowed
    }
}
