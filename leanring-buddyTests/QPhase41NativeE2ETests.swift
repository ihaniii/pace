//
//  QPhase41NativeE2ETests.swift
//  leanring-buddyTests
//
//  Phase 4.1: Native End-to-End Test Suite.
//  Proves the real pipeline:
//  User Turn -> CompanionManager -> QTurnExecutionRouter -> QAgent -> QCoreRuntime
//  using safe non-mutating intents under strict local security invariants.
//

import Testing
import Foundation
import AppKit
@testable import Pace

@Suite("QPhase41NativeE2ETests")
struct QPhase41NativeE2ETests {

    @Test("Native E2E: User turn dispatches via QTurnExecutionRouter to QAgent in qCoreAuthoritative mode")
    func testNativeE2EQCoreTurnFlow() async throws {
        let originalMode = PaceUserPreferencesStore.executionEngineMode()
        defer { PaceUserPreferencesStore.setExecutionEngineMode(originalMode) }

        // Enable Q-Core explicitly for this test turn
        PaceUserPreferencesStore.setExecutionEngineMode(.qCoreAuthoritative)
        #expect(PaceUserPreferencesStore.executionEngineMode() == .qCoreAuthoritative)

        let manager = await CompanionManager()

        // Bootstrap Q runtime if needed
        let bootstrap = QRuntimeBootstrap.shared
        _ = await bootstrap.bootstrap()

        // Verify model backend health
        let modelHealth = await QModelHealth.shared.checkAll()
        guard modelHealth.hasAnyLocalBackend else {
            // Report blocked honestly if no local model backend is active in this test runner environment
            print("⚠️ Native E2E BLOCKED: No local model backend active in test environment.")
            return
        }

        let testTranscript = "What applications are currently running?"
        let turnLease = await MainActor.run { manager.turnLeaseRegistry.beginTurn() }

        // Dispatch through the Phase 4.1 Turn Engine Router
        await manager.dispatchTurnWithEngineRouter(
            transcript: testTranscript,
            turnLease: turnLease,
            engineMode: .qCoreAuthoritative
        )

        let finalRuntimeState = await manager.qRuntimeState
        let finalHUD = await manager.currentTurnHUDState

        #expect(finalRuntimeState == .completed || finalRuntimeState == .ready)
        #expect(finalHUD.status == .done || finalHUD.status == .idle)

        // Verify that chat session received the completed turn
        let messages = await manager.chatSession.messages
        let userMessage = messages.first { $0.role == .user && $0.body == testTranscript }
        #expect(userMessage != nil)
        let assistantMessage = messages.first { $0.role == .pace }
        #expect(assistantMessage != nil)
    }

    @Test("Native E2E: User turn dispatches via QTurnExecutionRouter to Legacy Engine in legacyAuthoritative mode")
    func testNativeE2ELegacyTurnFlow() async throws {
        let originalMode = PaceUserPreferencesStore.executionEngineMode()
        defer { PaceUserPreferencesStore.setExecutionEngineMode(originalMode) }

        // Ensure legacy mode is set
        PaceUserPreferencesStore.setExecutionEngineMode(.legacyAuthoritative)
        #expect(PaceUserPreferencesStore.executionEngineMode() == .legacyAuthoritative)

        let router = QTurnExecutionRouter()
        let context = QAgentTurnContext(
            turnId: UUID().uuidString,
            transcript: "what time is it",
            conversationHistory: []
        )

        let request = QTurnExecutionRequest(
            turnId: context.turnId,
            transcript: "what time is it",
            engineMode: .legacyAuthoritative,
            context: context
        )

        var legacyExecuted = false
        var qCoreExecuted = false

        let result = await router.routeTurn(
            request: request,
            legacyEngine: {
                legacyExecuted = true
                return .success(summary: "Legacy handled")
            },
            qCoreEngine: {
                qCoreExecuted = true
                return .success(summary: "Q-Core handled")
            }
        )

        #expect(legacyExecuted == true)
        #expect(qCoreExecuted == false)
        #expect(result == .success(summary: "Legacy handled"))
    }
}
