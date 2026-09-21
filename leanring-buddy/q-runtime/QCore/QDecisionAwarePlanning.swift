//
//  QDecisionAwarePlanning.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2A.4 Planner Integration Bridge.
//  The single, additive extension point connecting a `QDecisionPlan` (Phase 2A.2) to the existing
//  Planner/Model Router (`QModelRouter`). A provider that conforms to this protocol ADDITIONALLY
//  receives the `QDecisionPlan` already computed for a task as ADVISORY input alongside its
//  existing `QStructuredModelProvider` conformance — conforming does not replace, duplicate, or
//  change `generateStructuredPlan(for:memoryContext:failureContext:)`'s existing required
//  behavior for any caller that does not know about this protocol (every existing conformer and
//  test double is untouched; see `QModelRouter.swift`'s own conformance for how it stays additive).
//
//  Non-authority, exactly like `QDecisionPlan` itself (see `QDecisionEngineContracts.swift`):
//  conforming to this protocol grants nothing. It does not select a concrete model backend
//  (`QModelRouter`'s own `priorityOrder`/`selectBestBackend` remain untouched and authoritative —
//  see Phase 2A "Decision Engine ≠ Model Router"), does not bypass `QPermissionGate`/
//  `QResourceGuard`/`QEgressBroker`/`QActionVerifier` (every `QPlan` this produces still flows
//  through the exact same, unmodified, security pipeline as any other `QPlan` returned from
//  `generateStructuredPlan`), and does not grant permission, egress, capability, AX, CGEvent, or
//  shell authority of any kind.
//

import Foundation

/// A `QStructuredModelProvider` that can additionally accept the `QDecisionPlan` already computed
/// for a task as advisory planning context. `QCoreRuntime` prefers this path when the configured
/// model provider conforms to it; providers that don't conform are entirely unaffected and keep
/// using their existing `QStructuredModelProvider` conformance exactly as before.
public protocol QDecisionContextAwareModelProvider: QStructuredModelProvider {
    /// Identical contract to `QStructuredModelProvider.generateStructuredPlan(for:memoryContext:
    /// failureContext:)`, with one additional, optional, advisory parameter: the `QDecisionPlan`
    /// already computed for `task` (`nil` when no decision context is available, e.g. a replan
    /// iteration that intentionally does not recompute one — see `QCoreRuntime.submitIntent`'s
    /// integration comment for the exact scope). Implementations MUST NOT treat this parameter as
    /// authority of any kind — it is a strategy hint only, and the returned `QPlan` is still
    /// subject to the full, unmodified, existing plan-validation and security pipeline.
    func generateStructuredPlan(
        for task: QTask,
        memoryContext: String?,
        failureContext: String?,
        decisionPlan: QDecisionPlan?
    ) async throws -> QPlan
}
