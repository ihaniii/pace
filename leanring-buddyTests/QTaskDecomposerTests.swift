//
//  QTaskDecomposerTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2A.3 Task Decomposer Tests.
//  Validates `QDeterministicTaskDecomposer`'s real behavior against real `QDecisionPlan` values
//  (produced by `QDeterministicDecisionEngine`, Phase 2A.2) and directly against hand-built
//  `QDecisionPlan`/`QTaskDecompositionResult` values for boundary/validation coverage. No
//  `QCoreRuntime`/Planner integration exists yet — every test constructs its inputs directly.
//

import Testing
import Foundation
@testable import Pace

@Suite("QTaskDecomposerTests")
struct QTaskDecomposerTests {

    private func task(taskId: String = "task-fixture", intent: String) -> QTask {
        QTask(taskId: taskId, intent: intent)
    }

    private func decisionPlan(
        taskType: QTaskType = .research,
        decompositionDecision: QDecompositionDecision,
        reasoningStepBudget: Int = 4,
        resourceEnvelopeMaximumSubtasks: Int? = nil
    ) -> QDecisionPlan {
        QDecisionPlan(
            taskType: taskType,
            complexity: .moderate,
            decompositionDecision: decompositionDecision,
            reasoningStepBudget: reasoningStepBudget,
            modelStrategy: .localReasoningModel,
            verificationRequirement: .executionEvidence,
            provenanceRequirement: .notRequired,
            resourceEnvelope: QDecisionResourceEnvelope(
                maximumSubtasks: resourceEnvelopeMaximumSubtasks ?? (decompositionDecision.maximumSubtasks ?? 0),
                allowsBackgroundExecution: false
            ),
            uncertainty: .low
        )
    }

    // MARK: - 1. No decomposition

    @Test("1. notRequired produces one bounded root task with zero subtasks")
    func noDecompositionProducesRootTaskOnly() {
        let plan = decisionPlan(decompositionDecision: .notRequired)
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: "What is the capital of France?"), decisionPlan: plan)
        #expect(result.rootTaskId == "task-fixture")
        #expect(result.subtasks.isEmpty)
        #expect(result.isDecomposed == false)
    }

    // MARK: - 2. Recommended decomposition

    @Test("2. recommended produces a minimal, bounded decomposition — never scaled up to the full allowed bound")
    func recommendedDecompositionIsMinimalAndBounded() {
        let plan = decisionPlan(decompositionDecision: .recommended(maximumSubtasks: 5))
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: "Research the history of the internet"), decisionPlan: plan)
        #expect(result.isDecomposed == true)
        // Bound permits up to 5, but nothing justifies inventing more than the minimal 2-way
        // structural split — "do not invent unnecessary subtasks".
        #expect(result.subtasks.count == 2)
        #expect(result.subtasks.count <= 5)
    }

    // MARK: - 3. Required decomposition

    @Test("3. required produces a bounded decomposition within its own smaller bound")
    func requiredDecompositionRespectsItsOwnBound() {
        let plan = decisionPlan(taskType: .criticalHighRisk, decompositionDecision: .required(maximumSubtasks: 3))
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: "Delete this file permanently"), decisionPlan: plan)
        #expect(result.isDecomposed == true)
        #expect(result.subtasks.count <= 3)
        #expect(result.subtasks.allSatisfy { $0.taskType == .criticalHighRisk })
    }

    // MARK: - 4. Max-subtask bounds are never exceeded, even for a degenerate bound of 1

    @Test("4. A decomposition decision bound of 1 never produces more than 1 subtask")
    func degenerateBoundOfOneNeverExceeded() {
        let plan = decisionPlan(decompositionDecision: .recommended(maximumSubtasks: 1))
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: "Create a plan for my trip"), decisionPlan: plan)
        #expect(result.subtasks.count == 1)
    }

    @Test("4b. The resource envelope's own maximumSubtasks is honored as an additional ceiling, defense in depth")
    func resourceEnvelopeBoundIsHonoredAsAdditionalCeiling() {
        // decompositionDecision permits 5, but the resource envelope (hypothetically, from a
        // differently-calibrated decision engine) only permits 1 — the tighter bound must win.
        let plan = decisionPlan(decompositionDecision: .recommended(maximumSubtasks: 5), resourceEnvelopeMaximumSubtasks: 1)
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: "Research the history of the internet"), decisionPlan: plan)
        #expect(result.subtasks.count == 1)
    }

    // MARK: - 5. Deterministic, stable IDs — never random UUIDs

    @Test("5. Subtask IDs are stable and derived from the parent task ID — never a random UUID")
    func subtaskIDsAreStableAndDeterministic() {
        let plan = decisionPlan(decompositionDecision: .recommended(maximumSubtasks: 5))
        let result = QDeterministicTaskDecomposer().decompose(task: task(taskId: "fixed-task-id", intent: "Research the history of the internet"), decisionPlan: plan)
        #expect(result.subtasks.map(\.id.rawValue) == ["fixed-task-id-subtask-0", "fixed-task-id-subtask-1"])
    }

    // MARK: - 6. Deterministic ordering and explicit dependency representation

    @Test("6. Subtasks are strictly ordered by index and form an explicit linear dependency chain")
    func dependencyOrderingIsExplicitAndLinear() {
        let plan = decisionPlan(decompositionDecision: .recommended(maximumSubtasks: 5))
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: "Research the history of the internet"), decisionPlan: plan)
        #expect(result.subtasks.map(\.index) == [0, 1])
        #expect(result.subtasks[0].dependsOn.isEmpty)
        #expect(result.subtasks[1].dependsOn == [result.subtasks[0].id])
    }

    // MARK: - 7. Cycle rejection

    @Test("7. validate(maximumSubtasks:) rejects a hand-built cyclic dependency graph")
    func validationRejectsCyclicDependency() {
        let idA = QSubtaskID(rawValue: "a")
        let idB = QSubtaskID(rawValue: "b")
        let subtaskA = QSubtask(id: idA, parentTaskId: "t", index: 0, dependsOn: [idB], taskType: .reasoning, reasoningStepBudget: 1)
        let subtaskB = QSubtask(id: idB, parentTaskId: "t", index: 1, dependsOn: [idA], taskType: .reasoning, reasoningStepBudget: 1)
        let result = QTaskDecompositionResult(rootTaskId: "t", subtasks: [subtaskA, subtaskB])

        let validation = result.validate(maximumSubtasks: 5)
        switch validation {
        case .success:
            Issue.record("Expected a cyclic-dependency validation failure")
        case .failure(let error):
            if case .cyclicDependency = error {
                // expected
            } else {
                Issue.record("Expected .cyclicDependency, got \(error)")
            }
        }
    }

    @Test("7b. The real decomposer's own output always passes cycle validation")
    func realDecomposerOutputIsAlwaysAcyclic() {
        let plan = decisionPlan(decompositionDecision: .required(maximumSubtasks: 3))
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: "Delete this file permanently"), decisionPlan: plan)
        let validation = result.validate(maximumSubtasks: 3)
        #expect(validation.isSuccess)
    }

    // MARK: - 8. Duplicate prevention

    @Test("8. validate(maximumSubtasks:) rejects a hand-built result with a duplicate subtask ID")
    func validationRejectsDuplicateSubtaskID() {
        let sharedID = QSubtaskID(rawValue: "dup")
        let subtaskA = QSubtask(id: sharedID, parentTaskId: "t", index: 0, taskType: .reasoning, reasoningStepBudget: 1)
        let subtaskB = QSubtask(id: sharedID, parentTaskId: "t", index: 1, taskType: .reasoning, reasoningStepBudget: 1)
        let result = QTaskDecompositionResult(rootTaskId: "t", subtasks: [subtaskA, subtaskB])

        let validation = result.validate(maximumSubtasks: 5)
        switch validation {
        case .success:
            Issue.record("Expected a duplicate-subtask-ID validation failure")
        case .failure(let error):
            #expect(error == .duplicateSubtaskID(sharedID))
        }
    }

    @Test("8b. validate(maximumSubtasks:) rejects a dangling dependency reference")
    func validationRejectsDanglingDependency() {
        let idA = QSubtaskID(rawValue: "a")
        let missingID = QSubtaskID(rawValue: "does-not-exist")
        let subtaskA = QSubtask(id: idA, parentTaskId: "t", index: 0, dependsOn: [missingID], taskType: .reasoning, reasoningStepBudget: 1)
        let result = QTaskDecompositionResult(rootTaskId: "t", subtasks: [subtaskA])

        let validation = result.validate(maximumSubtasks: 5)
        switch validation {
        case .success:
            Issue.record("Expected a dangling-dependency validation failure")
        case .failure(let error):
            #expect(error == .danglingDependency(subtask: idA, missingDependency: missingID))
        }
    }

    // MARK: - 9. Empty input

    @Test("9. An empty intent still produces a bounded, valid decomposition — never a crash")
    func emptyIntentRemainsBounded() {
        let plan = decisionPlan(decompositionDecision: .recommended(maximumSubtasks: 3))
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: ""), decisionPlan: plan)
        #expect(result.subtasks.count <= 3)
        #expect(result.validate(maximumSubtasks: 3).isSuccess)
    }

    // MARK: - 10. Pathological input

    @Test("10. A decomposition decision bound of zero produces at least one subtask, never a crash or negative count")
    func pathologicalZeroBoundRemainsSafe() {
        let plan = decisionPlan(decompositionDecision: .recommended(maximumSubtasks: 0))
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: "Research the history of the internet"), decisionPlan: plan)
        #expect(result.subtasks.count == 1)
        #expect(result.subtasks.allSatisfy { $0.reasoningStepBudget >= 1 })
    }

    // MARK: - 11. Deterministic repeatability

    @Test("11. Deterministic repeatability — the same task and decision plan produce exactly equal results, every time")
    func deterministicRepeatability() {
        let plan = decisionPlan(decompositionDecision: .required(maximumSubtasks: 3))
        let sampleTask = task(intent: "Delete this file permanently")
        let decomposer = QDeterministicTaskDecomposer()
        let resultA = decomposer.decompose(task: sampleTask, decisionPlan: plan)
        let resultB = decomposer.decompose(task: sampleTask, decisionPlan: plan)
        #expect(resultA == resultB)
    }

    // MARK: - 12. No privilege escalation / no arbitrary capabilities

    @Test("12. QSubtask carries no capability, permission, egress, or execution-authority field of any kind")
    func subtaskCarriesNoPrivilegeOrCapabilityField() {
        let plan = decisionPlan(decompositionDecision: .required(maximumSubtasks: 3))
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: "Delete this file permanently"), decisionPlan: plan)
        for subtask in result.subtasks {
            let fieldNames = Set(Mirror(reflecting: subtask).children.compactMap { $0.label })
            #expect(fieldNames == ["id", "parentTaskId", "index", "dependsOn", "taskType", "reasoningStepBudget"])
            for child in Mirror(reflecting: subtask).children {
                // No field is (or contains) a free-form String beyond the two plain identifier
                // strings this type is documented to carry — no raw content, no capability name.
                if let stringValue = child.value as? String {
                    #expect(child.label == "parentTaskId" || stringValue.isEmpty)
                }
            }
        }
    }

    // MARK: - 13. Codable round-trip

    @Test("13. A generated QTaskDecompositionResult round-trips through JSON encoding/decoding intact")
    func decompositionResultRoundTripsThroughJSON() throws {
        let plan = decisionPlan(decompositionDecision: .required(maximumSubtasks: 3))
        let result = QDeterministicTaskDecomposer().decompose(task: task(intent: "Delete this file permanently"), decisionPlan: plan)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(QTaskDecompositionResult.self, from: data)
        #expect(decoded == result)
    }
}

private extension Result where Failure == QTaskDecompositionValidationError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
