//
//  PaceActionApprovalTests.swift
//  leanring-buddyTests
//

import AppKit
import Foundation
import Testing
@testable import Pace

struct PaceActionApprovalTests {
    @Test func approvalRequestRequiresEnabledPreferenceAndNonEmptySummary() async throws {
        let summary = "1: [system mutation] Open app Safari"

        let enabledRequest = PaceActionApprovalRequest(
            approvalSummary: summary,
            requiresActionApproval: true
        )
        #expect(enabledRequest?.approvalSummary == summary)

        let disabledRequest = PaceActionApprovalRequest(
            approvalSummary: summary,
            requiresActionApproval: false
        )
        #expect(disabledRequest == nil)

        let emptyRequest = PaceActionApprovalRequest(
            approvalSummary: "   ",
            requiresActionApproval: true
        )
        #expect(emptyRequest == nil)
    }

    @Test func approvalRequestBuildsPopupCopyWithRiskSummary() async throws {
        let request = try #require(PaceActionApprovalRequest(
            approvalSummary: "1: [input injection] Type text",
            requiresActionApproval: true
        ))

        #expect(request.messageText == "Approve Que actions?")
        #expect(request.informativeText.contains("Que wants to control your Mac:"))
        #expect(request.informativeText.contains("[input injection] Type text"))
        #expect(request.informativeText.contains("Only approve this if it matches what you asked for."))
    }

    @Test func cancellationBlocksExecution() async throws {
        let request = try #require(PaceActionApprovalRequest(
            approvalSummary: "1: [system mutation] Open app Music",
            requiresActionApproval: true
        ))

        let shouldExecute = PaceActionApprovalPolicy.shouldExecuteActions(
            request: request,
            decision: .cancel
        )

        #expect(shouldExecute == false)
    }

    @Test func allowOncePermitsExecution() async throws {
        let request = try #require(PaceActionApprovalRequest(
            approvalSummary: "1: [read-only] Read calendar",
            requiresActionApproval: true
        ))

        let shouldExecute = PaceActionApprovalPolicy.shouldExecuteActions(
            request: request,
            decision: .allowOnce
        )

        #expect(shouldExecute == true)
    }

    @Test func missingApprovalRequestPassesThrough() async throws {
        #expect(PaceActionApprovalPolicy.shouldExecuteActions(
            request: nil,
            decision: .cancel
        ))
    }

    @Test func routineLocalActionsDoNotRequireExplicitApproval() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Raycast"),
            .openURL("https://example.com"),
            .snapWindow(PaceWindowSnapRequest(position: .left)),
            .readClipboard,
            .undoLastMutation
        ])

        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: actionPlan) == false)
    }

    @Test func routineLocalActionsSuppressInitialSpokenFeedback() async throws {
        // Phase 2H remediation: .pressKey moved out of this plan — it now requires explicit
        // approval (see PaceActionApprovalPolicy's keyboard-input fix), so it's no longer
        // "routine" in this sense either. A blocking approval dialog is about to interrupt the
        // flow regardless of whether Pace spoke first, so — consistent with every OTHER
        // approval-required action (composeMail, createNote, ...) — it correctly no longer
        // suppresses initial spoken feedback; see keyboardInputActionsRequiringApprovalDoNotSuppressInitialSpokenFeedback below.
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Raycast"),
            .snapWindow(PaceWindowSnapRequest(position: .left)),
            .readClipboard
        ])

        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: actionPlan))
    }

    @Test func keyboardInputActionsRequiringApprovalDoNotSuppressInitialSpokenFeedback() async throws {
        // Phase 2H remediation: .pressKey/.type/.setTextValue/.editSelectedText now require
        // explicit approval (a blocking dialog), so — like composeMail/createNote/etc. below —
        // they must not suppress the initial spoken acknowledgment either.
        let pressKeyPlan = PaceActionExecutionPlan.serial(actions: [
            .pressKey(name: "s", modifiers: [.command])
        ])
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: pressKeyPlan) == false)

        let typePlan = PaceActionExecutionPlan.serial(actions: [.type("hello")])
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: typePlan) == false)
    }

    @Test func emptyOrRiskyPlansDoNotSuppressInitialSpokenFeedback() async throws {
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
            for: PaceActionExecutionPlan(steps: [])
        ) == false)

        let mailDraftPlan = PaceActionExecutionPlan.serial(actions: [
            .composeMail(PaceMailDraft(
                recipients: ["alex@example.com"],
                subject: "Status",
                body: "Draft body"
            ))
        ])

        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: mailDraftPlan) == false)
    }

    @Test func routinePlannerResponseTextSuppressesInitialSpokenFeedback() async throws {
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
            forPlannerResponseText: "clicking it. [CLICK:400,300]"
        ))

        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
            forPlannerResponseText: """
            {"spokenText":"Opening Safari.","intent":"action","payload":{"name":"App.launch","args":{"name":"Safari"}}}
            """
        ))
    }

    @Test func answerAndRiskyPlannerResponseTextDoNotSuppressInitialSpokenFeedback() async throws {
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
            forPlannerResponseText: "html stands for hypertext markup language."
        ) == false)

        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(
            forPlannerResponseText: """
            {"spokenText":"Adding that.","intent":"action","payload":{"name":"Reminders.add","args":{"title":"send invoice"}}}
            """
        ) == false)
    }

    @Test func nonUndoableAndExternalActionsRequireExplicitApproval() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .composeMail(PaceMailDraft(
                recipients: ["alex@example.com"],
                subject: "Status",
                body: "Draft body"
            )),
            .createNote(PaceNoteRequest(title: "Idea", body: "Ship it")),
            .runShortcut("Publish"),
            .mcp(PaceMCPToolCall(serverName: "altic", toolName: "notes_create", arguments: [:]))
        ])

        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: actionPlan))
    }

    @Test func messagesWithDraftTextRequireExplicitApproval() async throws {
        let openOnlyPlan = PaceActionExecutionPlan.serial(actions: [
            .openMessages(PaceMessageRequest(recipient: "Alex", text: nil))
        ])
        let draftTextPlan = PaceActionExecutionPlan.serial(actions: [
            .openMessages(PaceMessageRequest(recipient: "Alex", text: "running late"))
        ])

        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: openOnlyPlan) == false)
        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: draftTextPlan))
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: openOnlyPlan))
        #expect(PaceActionApprovalPolicy.suppressesInitialSpokenFeedback(for: draftTextPlan) == false)
    }

    @Test func blockingPreflightIssueRequiresExplicitApproval() async throws {
        let actionPlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Raycast")
        ])
        let preflightIssues = [
            PaceToolPreflightIssue(
                severity: .blocking,
                title: "Accessibility permission missing",
                repairHint: "Grant Accessibility."
            )
        ]

        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(
            for: actionPlan,
            preflightIssues: preflightIssues
        ))
    }

    // MARK: - F-01 Legacy Approval Bypass Remediation Tests

    @Test func shouldExecutePlanFailsClosedWhenApprovalRequiredButRequestIsNil() async throws {
        let approvalRequiredPlans: [PaceActionExecutionPlan] = [
            .serial(actions: [.runShortcut("Publish")]),
            .serial(actions: [.downloadFile(PaceFileDownloadRequest(url: URL(string: "https://example.com/payload.sh")!, suggestedFilename: nil))]),
            .serial(actions: [.type("secret text")]),
            .serial(actions: [.pressKey(name: "return", modifiers: [])]),
            .serial(actions: [.setTextValue(PaceSetTextValueRequest(value: "edit", target: .focused))]),
            .serial(actions: [.editSelectedText(PaceVoiceEditRequest(operation: .shorten))]),
            .serial(actions: [.composeMail(PaceMailDraft(recipients: ["alex@example.com"], subject: "Hi", body: "Draft"))]),
            .serial(actions: [.createNote(PaceNoteRequest(title: "Note", body: "Body"))]),
            .serial(actions: [.mcp(PaceMCPToolCall(serverName: "altic", toolName: "notes_create", arguments: [:]))])
        ]

        for plan in approvalRequiredPlans {
            #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: plan) == true)
            // Even if an attacker or caller supplies decision: .allowOnce, without a valid approval request it MUST fail closed.
            #expect(PaceActionApprovalPolicy.shouldExecutePlan(plan, request: nil, decision: .allowOnce) == false)
            #expect(PaceActionApprovalPolicy.shouldExecutePlan(plan, request: nil, decision: .cancel) == false)
            #expect(PaceActionApprovalPolicy.shouldExecutePlan(plan, request: nil, decision: nil) == false)
        }
    }

    @Test func shouldExecutePlanFailsClosedWhenSummaryIsEmptyOnApprovalRequiredPlan() async throws {
        let plan = PaceActionExecutionPlan.serial(actions: [.runShortcut("Publish")])
        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: plan) == true)

        let emptySummaryRequest = PaceActionApprovalRequest(
            approvalSummary: "   ",
            requiresActionApproval: true
        )
        #expect(emptySummaryRequest == nil)

        let shouldExecute = PaceActionApprovalPolicy.shouldExecutePlan(
            plan,
            request: emptySummaryRequest,
            decision: .allowOnce
        )
        #expect(shouldExecute == false)
    }

    @Test func shouldExecutePlanPermitsRoutineLocalActionsWithoutRequest() async throws {
        let routinePlans: [PaceActionExecutionPlan] = [
            .serial(actions: [.openApplication("Raycast")]),
            .serial(actions: [.openURL("https://example.com")]),
            .serial(actions: [.snapWindow(PaceWindowSnapRequest(position: .left))]),
            .serial(actions: [.readClipboard]),
            .serial(actions: [.undoLastMutation]),
            .serial(actions: [.click(ScreenshotPixelLocation(xInScreenshotPixels: 100, yInScreenshotPixels: 100, screenNumber: 1))]),
            .serial(actions: [.controlMusic(.playPause)]),
            .serial(actions: [.openMessages(PaceMessageRequest(recipient: "Alex", text: nil))])
        ]

        for plan in routinePlans {
            #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: plan) == false)
            // Routine actions do not require approval requests and execute cleanly
            #expect(PaceActionApprovalPolicy.shouldExecutePlan(plan, request: nil, decision: nil) == true)
            #expect(PaceActionApprovalPolicy.shouldExecutePlan(plan, request: nil, decision: .allowOnce) == true)
        }
    }

    @Test func blockingPreflightIssueFailsClosedWithoutValidApproval() async throws {
        let routinePlan = PaceActionExecutionPlan.serial(actions: [.openApplication("Raycast")])
        let blockingIssue = PaceToolPreflightIssue(
            severity: .blocking,
            title: "Permission Missing",
            repairHint: "Grant permission."
        )

        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(
            for: routinePlan,
            preflightIssues: [blockingIssue]
        ) == true)

        // Without approval request: fails closed
        #expect(PaceActionApprovalPolicy.shouldExecutePlan(
            routinePlan,
            preflightIssues: [blockingIssue],
            request: nil,
            decision: .allowOnce
        ) == false)

        // With valid approval request and allowOnce: permitted
        let validRequest = try #require(PaceActionApprovalRequest(
            approvalSummary: routinePlan.approvalSummary,
            preflightSummary: PaceToolPreflightIssue.formatForApproval([blockingIssue])
        ))
        #expect(PaceActionApprovalPolicy.shouldExecutePlan(
            routinePlan,
            preflightIssues: [blockingIssue],
            request: validRequest,
            decision: .allowOnce
        ) == true)

        // With valid approval request and cancel: rejected
        #expect(PaceActionApprovalPolicy.shouldExecutePlan(
            routinePlan,
            preflightIssues: [blockingIssue],
            request: validRequest,
            decision: .cancel
        ) == false)
    }

    @Test @MainActor func companionManagerApprovalGateCannotBeBypassedByRequiresActionApprovalFlag() async throws {
        let manager = CompanionManager()
        // Simulate disabling action approval preference
        manager.requiresActionApproval = false

        // 1. Routine action proceeds without approval popup
        let routinePlan = PaceActionExecutionPlan.serial(actions: [
            .openApplication("Safari"),
            .openURL("https://example.com")
        ])
        let routineAllowed = manager.requestUserApprovalForActionPlan(routinePlan)
        #expect(routineAllowed == true)

        // 2. Risky action (shortcut) MUST NOT bypass approval even when requiresActionApproval == false.
        // It enters the approval flow, invokes the modal runner, and if cancelled, returns false.
        var modalPresentedForShortcut = false
        let shortcutPlan = PaceActionExecutionPlan.serial(actions: [
            .runShortcut("HarmfulShortcut")
        ])
        let shortcutDenied = manager.requestUserApprovalForActionPlan(
            shortcutPlan,
            approvalModalRunner: { alert in
                modalPresentedForShortcut = true
                #expect(alert.messageText == "Approve Que actions?")
                return .alertFirstButtonReturn // Cancel
            }
        )
        #expect(modalPresentedForShortcut == true)
        #expect(shortcutDenied == false)

        // 3. Risky action (keyboard input) MUST NOT bypass approval.
        var modalPresentedForTyping = false
        let typePlan = PaceActionExecutionPlan.serial(actions: [
            .type("injected text")
        ])
        let typeAllowed = manager.requestUserApprovalForActionPlan(
            typePlan,
            approvalModalRunner: { alert in
                modalPresentedForTyping = true
                #expect(alert.messageText == "Approve Que actions?")
                return .alertSecondButtonReturn // Allow Once
            }
        )
        #expect(modalPresentedForTyping == true)
        #expect(typeAllowed == true)

        // 4. Empty summary on an approval-required action MUST FAIL CLOSED without modal presentation.
        var modalPresentedForEmpty = false
        let emptyPlan = PaceActionExecutionPlan(steps: [])
        let preflightBlocked = [PaceToolPreflightIssue(severity: .blocking, title: "Blocked", repairHint: "None")]
        let emptyBlockedAllowed = manager.requestUserApprovalForActionPlan(
            emptyPlan,
            preflightIssues: preflightBlocked,
            approvalModalRunner: { _ in
                modalPresentedForEmpty = true
                return .alertSecondButtonReturn
            }
        )
        #expect(modalPresentedForEmpty == false)
        #expect(emptyBlockedAllowed == false)
    }
}
