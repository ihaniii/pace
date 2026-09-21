//
//  QTaskDecomposition.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2A.3 Task Decomposition Contracts.
//  Defines the additive data contracts a Task Decomposer produces — a bounded, deterministic,
//  auditable decomposition of a `QTask` into `QSubtask`s. DATA ONLY: nothing here executes a
//  subtask, calls a model, touches the network, the filesystem, AX, or grants any permission,
//  resource, or egress authority. See `QTaskDecomposer.swift` for the (also non-executing)
//  deterministic implementation that produces this data from a `QTask` + `QDecisionPlan`.
//

import Foundation

// MARK: - Subtask Identifier

/// A stable, deterministic subtask identifier — never a random `UUID()`. The same parent task
/// and decomposition always produce the same `QSubtaskID` values, in the same order, every time
/// (required for `QDeterministicTaskDecomposer`'s repeatability guarantee).
public struct QSubtaskID: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - Subtask

/// One bounded unit of a decomposition. Carries only safe, structured metadata — no raw
/// secrets, no raw screen content, no free-form model output. A base (non-model) decomposer
/// cannot know the true semantic content of a subtask without understanding the parent task's
/// meaning, so `QSubtask` intentionally carries only structural information (identity, position,
/// explicit dependency, inherited classification, and its own bounded share of the parent's
/// reasoning-step budget) — never a fabricated description of "what this subtask does".
public struct QSubtask: Codable, Sendable, Equatable, Identifiable {
    public let id: QSubtaskID
    /// The originating `QTask.taskId` this subtask was decomposed from.
    public let parentTaskId: String
    /// Zero-based position within the decomposition — deterministic ordering, never re-sorted.
    public let index: Int
    /// Explicit dependency representation: the subtasks (if any) that must complete before this
    /// one may begin. The base deterministic decomposer always produces a simple linear chain
    /// (each subtask depends on the one before it) — the most conservative, content-agnostic
    /// dependency shape it can honestly claim without understanding the task's actual meaning.
    public let dependsOn: [QSubtaskID]
    /// Inherited directly from the parent `QDecisionPlan.taskType` — the base decomposer has no
    /// independent, per-subtask classification signal.
    public let taskType: QTaskType
    /// This subtask's own bounded share of the parent `QDecisionPlan.reasoningStepBudget` —
    /// never a value that could exceed the parent's own total.
    public let reasoningStepBudget: Int

    public init(
        id: QSubtaskID,
        parentTaskId: String,
        index: Int,
        dependsOn: [QSubtaskID] = [],
        taskType: QTaskType,
        reasoningStepBudget: Int
    ) {
        self.id = id
        self.parentTaskId = parentTaskId
        self.index = index
        self.dependsOn = dependsOn
        self.taskType = taskType
        self.reasoningStepBudget = reasoningStepBudget
    }
}

// MARK: - Decomposition Result

/// The output of decomposing one `QTask`. When decomposition was not required, `subtasks` is
/// empty and `rootTaskId` alone represents the task as a single bounded unit — the "one bounded
/// root task" case. Decomposition never executes anything; this is DATA describing a plan for a
/// future consumer (e.g. the existing Planner/Model Router) to act on.
public struct QTaskDecompositionResult: Codable, Sendable, Equatable {
    public let rootTaskId: String
    public let subtasks: [QSubtask]

    public init(rootTaskId: String, subtasks: [QSubtask] = []) {
        self.rootTaskId = rootTaskId
        self.subtasks = subtasks
    }

    public var isDecomposed: Bool {
        !subtasks.isEmpty
    }
}

// MARK: - Decomposition Validation

/// Every way a `QTaskDecompositionResult` can be structurally unsafe to act on. Fail-closed:
/// callers must treat any of these as a reason to refuse the decomposition entirely, never to
/// silently drop the offending subtask(s) and proceed with the rest.
public enum QTaskDecompositionValidationError: Error, Equatable, Sendable {
    case duplicateSubtaskID(QSubtaskID)
    case danglingDependency(subtask: QSubtaskID, missingDependency: QSubtaskID)
    case cyclicDependency(involving: QSubtaskID)
    case subtaskCountExceedsBound(count: Int, bound: Int)
}

extension QTaskDecompositionResult {
    /// Validates structural safety only — never re-derives or second-guesses the decision-level
    /// classification. Checks, in order: no duplicate subtask IDs, no dependency referencing a
    /// subtask ID that doesn't exist in this same result, no dependency cycle (depth-first
    /// search over the explicit `dependsOn` graph), and the total subtask count never exceeds
    /// `maximumSubtasks`. Returns `.success(())` only if every check passes.
    public func validate(maximumSubtasks: Int) -> Result<Void, QTaskDecompositionValidationError> {
        guard subtasks.count <= maximumSubtasks else {
            return .failure(.subtaskCountExceedsBound(count: subtasks.count, bound: maximumSubtasks))
        }

        var seenIDs = Set<QSubtaskID>()
        for subtask in subtasks {
            guard !seenIDs.contains(subtask.id) else {
                return .failure(.duplicateSubtaskID(subtask.id))
            }
            seenIDs.insert(subtask.id)
        }

        let subtasksByID = Dictionary(uniqueKeysWithValues: subtasks.map { ($0.id, $0) })
        for subtask in subtasks {
            for dependency in subtask.dependsOn {
                guard subtasksByID[dependency] != nil else {
                    return .failure(.danglingDependency(subtask: subtask.id, missingDependency: dependency))
                }
            }
        }

        enum VisitState {
            case visiting
            case resolved
        }
        var visitState: [QSubtaskID: VisitState] = [:]

        func detectCycle(startingAt id: QSubtaskID) -> QSubtaskID? {
            if visitState[id] == .resolved { return nil }
            if visitState[id] == .visiting { return id }
            visitState[id] = .visiting
            guard let subtask = subtasksByID[id] else { return nil }
            for dependency in subtask.dependsOn {
                if let cycleID = detectCycle(startingAt: dependency) {
                    return cycleID
                }
            }
            visitState[id] = .resolved
            return nil
        }

        for subtask in subtasks {
            if let cycleID = detectCycle(startingAt: subtask.id) {
                return .failure(.cyclicDependency(involving: cycleID))
            }
        }

        return .success(())
    }
}
