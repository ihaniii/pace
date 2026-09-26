//
//  CompanionManager+QAgent.swift
//  leanring-buddy
//
//  Q Security Architecture — Companion QAgent & QPlan UI Pipeline (Phase 2A.2).
//  Connects live QPlanExecutor events to the Pace Notch / Turn HUD, manages read-only
//  UI snapshots, and routes user permission decisions strictly through QPermissionGate.
//

import Foundation
import AppKit

extension CompanionManager: QAgentStateObserver, QPlanExecutionObserver {

    // MARK: - QAgentStateObserver

    public func agentDidTransition(state: QAgentUIState, message: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.qRuntimeState = state
            switch state {
            case .offline:
                self.currentTurnHUDState = .idle
            case .starting:
                self.currentTurnHUDState = .understanding("Q Starting…")
            case .ready:
                self.currentTurnHUDState = PaceTurnHUDState(status: .idle, title: "Q", detail: "READY", options: [])
            case .thinking:
                self.currentTurnHUDState = PaceTurnHUDState(status: .understanding, title: "Q THINKING", detail: message, options: [])
            case .requestingPermission:
                // Prefer the richer, risk-aware rendering (Phase 2F) when a reconstructable
                // approval request is already available on the current plan snapshot — this
                // observer callback only carries a plain reason string, but planDidUpdate/
                // stepDidTransition (fired moments earlier for the same halt) already populate
                // activeQPlanSnapshot with everything qApprovalRequest needs. Falls back to the
                // plain generic clarification if that snapshot isn't available yet.
                if let approval = self.activeQPlanSnapshot?.pendingApproval {
                    self.currentTurnHUDState = PaceTurnHUDState.qApprovalRequest(approval)
                } else {
                    self.currentTurnHUDState = PaceTurnHUDState.clarification(question: message, options: ["Allow", "Deny"])
                }
            case .executing:
                self.currentTurnHUDState = PaceTurnHUDState(status: .acting, title: "Q EXECUTING", detail: message, options: [])
            case .verifying:
                self.currentTurnHUDState = PaceTurnHUDState(status: .acting, title: "Q VERIFYING", detail: message, options: [])
            case .completed:
                self.currentTurnHUDState = PaceTurnHUDState.done(message)
            case .blocked:
                self.currentTurnHUDState = PaceTurnHUDState.unsupported(message)
            case .error:
                self.currentTurnHUDState = PaceTurnHUDState.failed(message)
            }
        }
    }

    public func agentDidReceiveStreamEvent(_ event: QCoreStreamEvent) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch event {
            case .textDelta(let delta):
                self.qCoreStreamedAccumulatedText.append(delta)
                await self.streamingSentenceTTSPipeline.acceptStreamedText(self.qCoreStreamedAccumulatedText)
            case .completed:
                await self.streamingSentenceTTSPipeline.flushFinal(finalSpokenText: self.qCoreStreamedAccumulatedText)
            case .cancelled, .failed:
                self.streamingSentenceTTSPipeline.drainQueueAndStopForBargeIn()
                self.ttsClient.stopPlayback()
            }
        }
    }

    // MARK: - QPlanExecutionObserver

    public func planDidUpdate(plan: QPlan) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = QRuntimeUISnapshot.from(plan: plan)
            self.activeQPlanSnapshot = snapshot
            self.applyPlanSnapshotToHUD(snapshot: snapshot)

            // Phase 4.7E: Safe, deterministic parity with Current Activity / Now projection
            switch plan.state {
            case .running, .executing, .verifying:
                self.recordQCoreExecutionStarted(taskId: plan.taskId, taskPrompt: plan.taskPrompt)
            case .completed:
                self.recordQCoreExecutionCompleted(taskId: plan.taskId)
            case .cancelled:
                self.recordQCoreExecutionCancelled(taskId: plan.taskId)
            case .failed(let reason, _), .blocked(let reason, _):
                self.recordQCoreExecutionFailed(taskId: plan.taskId, reason: reason)
            case .pending, .waitingForPermission:
                break
            }
        }
    }

    public func stepDidTransition(step: QPlanStep, planId: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let currentSnapshot = self.activeQPlanSnapshot, currentSnapshot.planId == planId {
                var updatedSteps = currentSnapshot.steps
                if let idx = updatedSteps.firstIndex(where: { $0.id == step.id }) {
                    updatedSteps[idx] = QRuntimeStepSnapshot(
                        id: step.id,
                        index: step.index,
                        description: step.description,
                        actionName: step.action.actionName,
                        riskLevel: step.action.riskLevel.description,
                        state: step.state,
                        verifiedEvidence: step.result?.verifiedEvidence,
                        riskLevelValue: step.action.riskLevel,
                        targetResources: step.action.targetResources
                    )
                    self.activeQPlanSnapshot = QRuntimeUISnapshot(
                        planId: currentSnapshot.planId,
                        taskId: currentSnapshot.taskId,
                        taskPrompt: currentSnapshot.taskPrompt,
                        planState: currentSnapshot.planState,
                        currentStepIndex: step.index,
                        totalSteps: currentSnapshot.totalSteps,
                        currentStepDescription: step.description,
                        currentStepState: step.state,
                        statusMessage: currentSnapshot.statusMessage,
                        steps: updatedSteps,
                        timestamp: Date()
                    )
                }
            }
        }
    }

    // MARK: - HUD Mapping

    private func applyPlanSnapshotToHUD(snapshot: QRuntimeUISnapshot) {
        guard let planState = snapshot.planState else { return }

        switch planState {
        case .pending:
            currentTurnHUDState = PaceTurnHUDState(
                status: .understanding,
                title: "Q",
                detail: "Planning \(snapshot.totalSteps) step(s)…",
                options: []
            )

        case .running:
            currentTurnHUDState = PaceTurnHUDState(
                status: .understanding,
                title: "Q THINKING",
                detail: "Planning \(snapshot.totalSteps) step(s)…",
                options: []
            )

        case .waitingForPermission(let idx, _):
            if let approval = snapshot.pendingApproval {
                currentTurnHUDState = PaceTurnHUDState.qApprovalRequest(approval)
            } else {
                let stepName = snapshot.steps.indices.contains(idx) ? snapshot.steps[idx].description : "Action"
                currentTurnHUDState = PaceTurnHUDState.clarification(
                    question: "Q needs permission: \(stepName)",
                    options: ["Allow", "Deny"]
                )
            }

        case .executing(let idx):
            let desc = snapshot.steps.indices.contains(idx) ? snapshot.steps[idx].description : "Executing…"
            currentTurnHUDState = PaceTurnHUDState(
                status: .acting,
                title: "STEP \(idx + 1) / \(snapshot.totalSteps)",
                detail: desc,
                options: []
            )

        case .verifying(let idx):
            let desc = snapshot.steps.indices.contains(idx) ? snapshot.steps[idx].description : "Verifying…"
            currentTurnHUDState = PaceTurnHUDState(
                status: .acting,
                title: "VERIFYING (\(idx + 1)/\(snapshot.totalSteps))",
                detail: desc,
                options: []
            )

        case .completed(let summary):
            currentTurnHUDState = PaceTurnHUDState.done(summary)

        case .blocked(let reason, _):
            currentTurnHUDState = PaceTurnHUDState.unsupported("Security Blocked: \(reason)")

        case .failed(let reason, _):
            currentTurnHUDState = PaceTurnHUDState.failed("Failed: \(reason)")

        case .cancelled(let reason):
            currentTurnHUDState = PaceTurnHUDState.failed("Cancelled: \(reason)")
        }
    }

    // MARK: - Permission UX Resolution (Phase 2F)

    /// Handles user clicking "Allow" or "Deny" in the permission HUD.
    ///
    /// Resolves the pending approval through the real Phase 2E API
    /// (`QAgent.approve` → `QCoreRuntime.resolveApproval` → `QApprovalCoordinator`) rather than
    /// minting a standing `QPermissionGate` capability grant — a standing grant would authorize
    /// ANY future call to the same tool name, not just the one specific action the user actually
    /// saw and approved, which is exactly the blanket-approval pattern Phase 2E's approval
    /// architecture was built to avoid. `activeQPlanSnapshot.pendingApproval` reconstructs the
    /// same execution-identity-bound request `QPlanExecutor` recorded when it halted (see
    /// `QRuntimeUISnapshot.pendingApproval`), so the `approvalId` passed here always matches
    /// `QApprovalCoordinator`'s own live record — resolution is re-validated there regardless of
    /// what this reconstruction contains, so this UI layer carries no execution authority itself.
    ///
    /// This actually resumes and completes (or fails/blocks) the halted task — the pre-2F version
    /// of this method never did, because `QCoreRuntime.submitIntent` returns immediately on a
    /// `.waitingForPermission` halt rather than blocking in place; there was no live call left to
    /// "resume." Reuses the SAME `QAgentStateObserver` callbacks (`agentDidTransition`) that drive
    /// `executeQAgentTurn`'s HUD updates, so intermediate execute/verify states render the same way.
    @MainActor
    public func resolveQPermissionApproval(approved: Bool) async {
        guard let snapshot = activeQPlanSnapshot,
              let taskId = snapshot.taskId,
              let request = snapshot.pendingApproval else {
            currentTurnHUDState = PaceTurnHUDState.failed("No pending approval to resolve.")
            return
        }

        let decision: QApprovalDecision = approved ? .approved : .denied(reason: "Denied by user via HUD")
        let userTranscript = approved ? "Allow: \(request.expectedEffect)" : "Deny: \(request.expectedEffect)"

        if approved {
            currentTurnHUDState = PaceTurnHUDState(
                status: .acting,
                title: "RESUMING",
                detail: request.expectedEffect,
                options: []
            )
        } else {
            recordQCoreExecutionCancelled(taskId: taskId)
        }
        // Denial's immediate HUD feedback is set synchronously by the caller
        // (CompanionManager+AgentLoop.resolveClarification) before this async call is dispatched,
        // so the UI reads as instant — nothing is actually executing on a denial. This call still
        // performs the real resolution below so the durable task/coordinator record the denial.

        do {
            let result = try await QAgent.shared.approve(
                taskId: taskId,
                approvalId: request.id,
                decision: decision,
                observer: self
            )

            switch result.status {
            case .completed:
                recordQCoreExecutionCompleted(taskId: taskId)
            case .cancelled:
                recordQCoreExecutionCancelled(taskId: taskId)
            case .failed(let reason):
                recordQCoreExecutionFailed(taskId: taskId, reason: reason)
            default:
                break
            }

            if case .completed = result.status, !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recordConversationTurn(userTranscript: userTranscript, assistantResponse: result.summary)
            } else {
                chatSession.appendCompletedTurn(userTranscript: userTranscript, assistantResponse: result.summary)
            }
            if !chatSession.isChatTTSMuted {
                try? await ttsClient.speakText(result.summary)
            }
        } catch {
            recordQCoreExecutionFailed(taskId: taskId, reason: error.localizedDescription)
            currentTurnHUDState = PaceTurnHUDState.failed(error.localizedDescription)
            chatSession.appendCompletedTurn(userTranscript: userTranscript, assistantResponse: "Q Error: \(error.localizedDescription)")
        }

        voiceState = .idle
    }

    // MARK: - Agent Execution Dispatch

    /// Primary execution method for local agent turns via QAgent.
    @discardableResult
    public func executeQAgentTurn(
        transcript: String,
        context: QAgentTurnContext? = nil,
        turnLease: PaceTurnLease? = nil
    ) async -> QAgentResult {
        let detectedTurnLocale = PaceSpeechVoiceResolver.detectLanguage(for: transcript).flatMap { raw -> String? in
            let base = raw.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init) ?? raw
            switch base {
            case "en": return "en-US"
            case "sv": return "sv-SE"
            case "ar": return "ar"
            default: return raw
            }
        } ?? "en-US"

        qCoreStreamedAccumulatedText = ""
        streamingSentenceTTSPipeline.resetForNewTurn(locale: detectedTurnLocale)
        streamingSentenceTTSPipeline.markIntentCommitted()
        streamingSentenceTTSPipeline.setMutedForCurrentTurn(chatSession.isChatTTSMuted)

        if (turnLease != nil && !isActiveTurn(turnLease!)) || Task.isCancelled {
            streamingSentenceTTSPipeline.drainQueueAndStopForBargeIn()
            return QAgentResult(
                taskId: turnLease?.turnId ?? UUID().uuidString,
                sessionId: "cancelled_session",
                intent: transcript,
                status: .cancelled(reason: "Turn cancelled before execution"),
                summary: "Turn cancelled"
            )
        }

        qRuntimeState = .thinking
        currentTurnHUDState = PaceTurnHUDState(status: .understanding, title: "Q THINKING", detail: "Reasoning locally…", options: [])

        do {
            let result = try await QAgent.shared.run(
                task: transcript,
                sessionId: context?.turnId ?? UUID().uuidString,
                observer: self,
                turnContext: context
            )

            await handleQAgentTurnResult(result, transcript: transcript, detectedTurnLocale: detectedTurnLocale)

            voiceState = .idle
            return result
        } catch {
            recordQCoreExecutionFailed(taskId: context?.turnId ?? UUID().uuidString, reason: error.localizedDescription)
            streamingSentenceTTSPipeline.drainQueueAndStopForBargeIn()
            ttsClient.stopPlayback()
            qRuntimeState = .error
            currentTurnHUDState = PaceTurnHUDState.failed(error.localizedDescription)
            chatSession.appendCompletedTurn(userTranscript: transcript, assistantResponse: "Q Error: \(error.localizedDescription)")
            voiceState = .idle
            return QAgentResult(
                taskId: context?.turnId ?? UUID().uuidString,
                sessionId: "error_session",
                intent: transcript,
                status: .failed(reason: error.localizedDescription),
                summary: "Error: \(error.localizedDescription)"
            )
        }
    }

    func handleQAgentTurnResult(_ result: QAgentResult, transcript: String, detectedTurnLocale: String? = nil) async {
        switch result.status {
        case .directAnswer(let text):
            // Direct conversational answers MUST NOT mutate Current Activity
            streamingSentenceTTSPipeline.finalizeInFlightStreamedTextForTurn()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recordConversationTurn(userTranscript: transcript, assistantResponse: text)
            } else {
                chatSession.appendCompletedTurn(userTranscript: transcript, assistantResponse: text)
            }
            // Through the pipeline's deduplicated cursor: streamed sentences
            // may still be mid-dispatch, so speaking the full answer directly
            // here played it a second time. Mute and barge-in are enforced
            // inside the pipeline.
            await streamingSentenceTTSPipeline.speakFinalAnswerIfNeeded(text)

        case .completed:
            recordQCoreExecutionCompleted(taskId: result.taskId)
            streamingSentenceTTSPipeline.finalizeInFlightStreamedTextForTurn()
            if !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recordConversationTurn(userTranscript: transcript, assistantResponse: result.summary)
            } else {
                chatSession.appendCompletedTurn(userTranscript: transcript, assistantResponse: result.summary)
            }
            await streamingSentenceTTSPipeline.speakFinalAnswerIfNeeded(result.summary)

        case .cancelled(let reason):
            recordQCoreExecutionCancelled(taskId: result.taskId)
            streamingSentenceTTSPipeline.drainQueueAndStopForBargeIn()
            ttsClient.stopPlayback()

        case .failed(let reason):
            recordQCoreExecutionFailed(taskId: result.taskId, reason: reason)
            streamingSentenceTTSPipeline.drainQueueAndStopForBargeIn()
            ttsClient.stopPlayback()
            chatSession.appendCompletedTurn(userTranscript: transcript, assistantResponse: "Q Failed: \(reason)")

        case .awaitingApproval:
            break
        }
    }
}
