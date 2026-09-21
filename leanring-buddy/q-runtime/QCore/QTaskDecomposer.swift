//
//  QTaskDecomposer.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2A.3 First Real Deterministic Task Decomposer.
//  Produces a `QTaskDecompositionResult` (`QTaskDecomposition.swift`) from a `QTask` and the
//  `QDecisionPlan` a `QDecisionEngine` already produced for it (Phase 2A.2). No model
//  invocation, no network, no filesystem, no AX, no execution, no permission/resource/egress
//  authority — see this file's header comment set for the full non-authority list, identical in
//  spirit to `QDecisionEngine.swift`'s.
//
//  Architecture: `Task → Decision Engine → QDecisionPlan → Task Decomposer → bounded subtasks →
//  existing Planner/Model Router`. The decomposer never executes a subtask; it only ever
//  produces DATA describing a bounded plan for something else to act on later. Nothing here is
//  wired into `QCoreRuntime`/`QPlanExecutor`/`QModelRouter` yet.
//
//  Honesty constraint this design deliberately keeps: a base decomposer with no model access and
//  no permitted text heuristics (the same restrictions `QDecisionEngine` operates under) cannot
//  actually know the TRUE semantic shape of a task's subtasks — splitting "Research X, Y, and Z"
//  into "research X" / "research Y" / "research Z" requires understanding the task means
//  something this layer is not allowed to guess at via keyword/length tricks, and is not allowed
//  to ask a model to determine either (that's explicitly out of scope for the BASE
//  implementation). So rather than fabricate a plausible-looking but unjustified content split,
//  this decomposer produces a minimal, content-agnostic STRUCTURAL scaffold: a small, fixed
//  number of generically-linked subtasks (never scaled up to the full allowed bound just because
//  the bound permits it — "do not invent unnecessary subtasks"), each carrying only the parent's
//  own classification and a bounded share of its reasoning-step budget. A future, model-assisted
//  decomposer could conform to the same `QTaskDecomposer` protocol and produce real content
//  splits — that is out of scope for this phase.
//

import Foundation

// MARK: - Task Decomposer Protocol

/// Provider-independent contract for anything that can decompose a `QTask` (given the
/// `QDecisionPlan` already produced for it) into a `QTaskDecompositionResult`. Mirrors
/// `QDecisionEngine`'s own protocol shape. A conforming type only ever DECOMPOSES: it never
/// executes a subtask, never calls a model, and never grants permission, resource, or egress
/// authority.
public protocol QTaskDecomposer: Sendable {
    func decompose(task: QTask, decisionPlan: QDecisionPlan) -> QTaskDecompositionResult
}

// MARK: - Deterministic Task Decomposer

/// The first real `QTaskDecomposer` implementation. Purely rule-based — no model invocation, no
/// network, no learning. See this file's header for the full design rationale.
public struct QDeterministicTaskDecomposer: QTaskDecomposer, Sendable {

    /// The fixed, minimal subtask count this decomposer ever produces when decomposition is
    /// `.recommended` or `.required` — never scaled up toward the decision's own
    /// `maximumSubtasks` ceiling just because that ceiling permits more. Two is the smallest
    /// count that is meaningfully "decomposed" at all (one subtask is not a decomposition).
    fileprivate static let minimalDecomposedSubtaskCount = 2

    public init() {}

    /// Produces a `QTaskDecompositionResult` for `task`, given the `decisionPlan` a
    /// `QDecisionEngine` already computed for it. Pure and synchronous: performs no I/O, and is
    /// fully repeatable — equal input always produces an equal result, with the same subtask IDs
    /// in the same order.
    public func decompose(task: QTask, decisionPlan: QDecisionPlan) -> QTaskDecompositionResult {
        switch decisionPlan.decompositionDecision {
        case .notRequired:
            // The "one bounded root task" case — no subtasks, the task stands as a single unit.
            return QTaskDecompositionResult(rootTaskId: task.taskId, subtasks: [])

        case .recommended(let decisionMaximumSubtasks), .required(let decisionMaximumSubtasks):
            // Defense in depth: never exceed EITHER the decomposition decision's own bound OR
            // the decision plan's separately-carried resource-envelope bound, even though this
            // engine's own `QDeterministicDecisionEngine` always keeps them equal today — a
            // future, differently-calibrated `QDecisionEngine` might not.
            let effectiveMaximumSubtasks = min(decisionMaximumSubtasks, decisionPlan.resourceEnvelope.maximumSubtasks)
            let subtaskCount = max(1, min(Self.minimalDecomposedSubtaskCount, effectiveMaximumSubtasks))

            var subtasks: [QSubtask] = []
            subtasks.reserveCapacity(subtaskCount)
            var previousSubtaskID: QSubtaskID?
            let perSubtaskReasoningStepBudget = max(1, decisionPlan.reasoningStepBudget / subtaskCount)

            for index in 0..<subtaskCount {
                // Deterministic, stable ID — derived from the parent task's own ID and position,
                // never `UUID()`. The same task + decision plan always produce the same IDs.
                let id = QSubtaskID(rawValue: "\(task.taskId)-subtask-\(index)")
                let dependsOn: [QSubtaskID] = previousSubtaskID.map { [$0] } ?? []
                subtasks.append(
                    QSubtask(
                        id: id,
                        parentTaskId: task.taskId,
                        index: index,
                        dependsOn: dependsOn,
                        taskType: decisionPlan.taskType,
                        reasoningStepBudget: perSubtaskReasoningStepBudget
                    )
                )
                previousSubtaskID = id
            }

            return QTaskDecompositionResult(rootTaskId: task.taskId, subtasks: subtasks)
        }
    }
}
