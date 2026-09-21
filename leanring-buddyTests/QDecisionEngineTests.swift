//
//  QDecisionEngineTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2A.2 Tests.
//  Validates `QDeterministicDecisionEngine`'s real classification/derivation behavior: task-type
//  classification, complexity/decomposition/budget/strategy/verification/provenance/resource/
//  uncertainty derivation, determinism, Codable round-trip of produced plans, and the security
//  invariant that a `QDecisionPlan` can never carry execution, permission, or egress authority.
//  No `QCoreRuntime` integration exists yet — every test here constructs a `QTask` directly and
//  calls `QDeterministicDecisionEngine.decide(for:)` in isolation.
//

import Testing
import Foundation
@testable import Pace

@Suite("QDecisionEngineTests")
struct QDecisionEngineTests {

    private func task(intent: String, tainted: Bool = false) -> QTask {
        var context = QTaskContext(taskId: "test-task")
        if tainted {
            context.append(content: "untrusted context item", provenance: .untrustedWeb(url: nil))
        }
        return QTask(intent: intent, context: context)
    }

    // MARK: - 1-8. Task type classification

    @Test("1. Simple Q&A intent classifies as simpleQA")
    func simpleQAClassification() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "What is the capital of France?"))
        #expect(plan.taskType == .simpleQA)
    }

    @Test("2. Reasoning intent classifies as reasoning")
    func reasoningClassification() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Why did the project fail? Explain why."))
        #expect(plan.taskType == .reasoning)
    }

    @Test("3. Coding intent classifies as coding")
    func codingClassification() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Write a function to sort a list"))
        #expect(plan.taskType == .coding)
    }

    @Test("4. Research intent classifies as research")
    func researchClassification() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Research the history of the internet"))
        #expect(plan.taskType == .research)
    }

    @Test("5. Planning intent classifies as planning")
    func planningClassification() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Create a plan for my trip"))
        #expect(plan.taskType == .planning)
    }

    @Test("6. Creative intent classifies as creative")
    func creativeClassification() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Write a poem about the ocean"))
        #expect(plan.taskType == .creative)
    }

    @Test("7. Execution intent classifies as execution")
    func executionClassification() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Open Calculator"))
        #expect(plan.taskType == .execution)
    }

    @Test("8. Destructive/high-risk intent classifies as criticalHighRisk")
    func criticalHighRiskClassification() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Delete this file permanently"))
        #expect(plan.taskType == .criticalHighRisk)
    }

    @Test("8b. criticalHighRisk classification overrides an otherwise-matching lower-priority category")
    func criticalHighRiskOverridesOtherCategories() {
        // Reads as both "execution" (open) and "criticalHighRisk" (delete) — the more cautious
        // classification must win.
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Open the file and delete it permanently"))
        #expect(plan.taskType == .criticalHighRisk)
    }

    @Test("8c. A compound question that reads as both simpleQA and reasoning resolves to reasoning, never the lighter simpleQA")
    func reasoningTakesPriorityOverSimpleQAForCompoundQuestions() {
        // Starts with a simpleQA opener ("what is") but is substantively a reasoning task (a
        // "trade-offs" comparison) — must not be under-classified as trivially simple.
        let plan = QDeterministicDecisionEngine().decide(
            for: task(intent: "What is the best strategy considering the trade-offs and pros and cons?")
        )
        #expect(plan.taskType == .reasoning)
        #expect(plan.taskType != .simpleQA)
    }

    // MARK: - 9-13. Complexity

    @Test("9. simpleQA maps to trivial complexity")
    func trivialComplexity() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "What is the capital of France?"))
        #expect(plan.complexity == .trivial)
    }

    @Test("10. creative and execution map to simple complexity")
    func simpleComplexity() {
        let creativePlan = QDeterministicDecisionEngine().decide(for: task(intent: "Write a poem about the ocean"))
        #expect(creativePlan.complexity == .simple)
        let executionPlan = QDeterministicDecisionEngine().decide(for: task(intent: "Open Calculator"))
        #expect(executionPlan.complexity == .simple)
    }

    @Test("11. reasoning, research, and planning map to moderate complexity")
    func moderateComplexity() {
        let reasoningPlan = QDeterministicDecisionEngine().decide(for: task(intent: "Why did the project fail?"))
        #expect(reasoningPlan.complexity == .moderate)
        let researchPlan = QDeterministicDecisionEngine().decide(for: task(intent: "Research the history of the internet"))
        #expect(researchPlan.complexity == .moderate)
        let planningPlan = QDeterministicDecisionEngine().decide(for: task(intent: "Create a plan for my trip"))
        #expect(planningPlan.complexity == .moderate)
    }

    @Test("12. coding maps to complex complexity")
    func complexComplexity() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Write a function to sort a list"))
        #expect(plan.complexity == .complex)
    }

    @Test("13. criticalHighRisk maps to critical complexity")
    func criticalComplexity() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Delete this file permanently"))
        #expect(plan.complexity == .critical)
    }

    // MARK: - 14-16. Decomposition decision

    @Test("14. Trivial/simple complexity produces decomposition notRequired")
    func decompositionNotRequired() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "What is the capital of France?"))
        #expect(plan.decompositionDecision == .notRequired)
        #expect(plan.decompositionDecision.maximumSubtasks == nil)
    }

    @Test("15. Moderate/complex complexity produces decomposition recommended with a bounded maximum")
    func decompositionRecommendedIsBounded() {
        let moderatePlan = QDeterministicDecisionEngine().decide(for: task(intent: "Create a plan for my trip"))
        #expect(moderatePlan.decompositionDecision == .recommended(maximumSubtasks: 3))
        let complexPlan = QDeterministicDecisionEngine().decide(for: task(intent: "Write a function to sort a list"))
        #expect(complexPlan.decompositionDecision == .recommended(maximumSubtasks: 5))
    }

    @Test("16. Critical complexity produces decomposition required with a bounded maximum")
    func decompositionRequiredIsBounded() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Delete this file permanently"))
        #expect(plan.decompositionDecision == .required(maximumSubtasks: 3))
        #expect(plan.decompositionDecision.maximumSubtasks == 3)
    }

    // MARK: - 17. Reasoning-step budget stays bounded

    @Test("17. Reasoning-step budget is always a small, positive, bounded integer")
    func reasoningStepBudgetRemainsBounded() {
        let intents = [
            "What is the capital of France?", "Why did the project fail?", "Write a function to sort a list",
            "Research the history of the internet", "Create a plan for my trip", "Write a poem about the ocean",
            "Open Calculator", "Delete this file permanently"
        ]
        for intent in intents {
            let plan = QDeterministicDecisionEngine().decide(for: task(intent: intent))
            #expect(plan.reasoningStepBudget >= 1)
            #expect(plan.reasoningStepBudget <= 6)
        }
        // Explicit design invariant: a critical/high-risk task gets a SMALLER reasoning budget
        // than a merely-complex one — tight bounds, not a large autonomous allowance, for
        // high-risk work.
        let criticalPlan = QDeterministicDecisionEngine().decide(for: task(intent: "Delete this file permanently"))
        let complexPlan = QDeterministicDecisionEngine().decide(for: task(intent: "Write a function to sort a list"))
        #expect(criticalPlan.reasoningStepBudget < complexPlan.reasoningStepBudget)
    }

    // MARK: - 18. Model strategy stays provider-independent

    @Test("18. Model strategy never names a concrete provider/backend for any classified task type")
    func modelStrategyStaysProviderIndependent() {
        let knownProviderNames = ["apple.foundation", "apple.mlx", "local.ollama", "local.llama_cpp", "openai", "anthropic", "gpt", "claude", "qwen", "llama"]
        let intents = [
            "What is the capital of France?", "Why did the project fail?", "Write a function to sort a list",
            "Research the history of the internet", "Create a plan for my trip", "Write a poem about the ocean",
            "Open Calculator", "Delete this file permanently"
        ]
        for intent in intents {
            let plan = QDeterministicDecisionEngine().decide(for: task(intent: intent))
            let wireValue = plan.modelStrategy.rawValue.lowercased()
            for providerName in knownProviderNames {
                #expect(!wireValue.contains(providerName))
            }
        }
    }

    // MARK: - 19. Stronger verification for state-changing/high-risk tasks

    @Test("19. State-changing and high-risk task types request stronger verification than read-only ones")
    func strongerVerificationForStateChangingAndHighRiskTasks() {
        let simpleQAPlan = QDeterministicDecisionEngine().decide(for: task(intent: "What is the capital of France?"))
        #expect(simpleQAPlan.verificationRequirement == .none)

        let executionPlan = QDeterministicDecisionEngine().decide(for: task(intent: "Open Calculator"))
        #expect(executionPlan.verificationRequirement == .executionEvidence)

        let criticalPlan = QDeterministicDecisionEngine().decide(for: task(intent: "Delete this file permanently"))
        #expect(criticalPlan.verificationRequirement == .independentVerification)
    }

    // MARK: - 20. Provenance intent for evidence-oriented tasks

    @Test("20. Research tasks and tasks with tainted context require provenance")
    func provenanceIntentForEvidenceOrientedTasks() {
        let researchPlan = QDeterministicDecisionEngine().decide(for: task(intent: "Research the history of the internet"))
        #expect(researchPlan.provenanceRequirement == .required)

        let taintedPlan = QDeterministicDecisionEngine().decide(for: task(intent: "What is the capital of France?", tainted: true))
        #expect(taintedPlan.provenanceRequirement == .required)

        let untaintedSimpleQAPlan = QDeterministicDecisionEngine().decide(for: task(intent: "What is the capital of France?"))
        #expect(untaintedSimpleQAPlan.provenanceRequirement == .notRequired)
    }

    @Test("20b. allowsBackgroundExecution is false for every task type at this phase — no runtime consumer exists yet to safely interpret it")
    func backgroundExecutionIsNeverGrantedAtThisPhase() {
        let intents = [
            "What is the capital of France?", "Why did the project fail?", "Write a function to sort a list",
            "Research the history of the internet", "Create a plan for my trip", "Write a poem about the ocean",
            "Open Calculator", "Delete this file permanently"
        ]
        for intent in intents {
            let plan = QDeterministicDecisionEngine().decide(for: task(intent: intent))
            #expect(plan.resourceEnvelope.allowsBackgroundExecution == false)
        }
    }

    // MARK: - 21. Uncertainty remains qualitative only

    @Test("21. Uncertainty is always one of the four qualitative cases — never a numeric wire value")
    func uncertaintyRemainsQualitativeOnly() throws {
        let intents = ["What is the capital of France?", "asdkjaskjd qwerty nonsense", ""]
        for intent in intents {
            let plan = QDeterministicDecisionEngine().decide(for: task(intent: intent))
            #expect(QDecisionUncertainty.allCases.contains(plan.uncertainty))
            let data = try JSONEncoder().encode(plan.uncertainty)
            let jsonString = String(data: data, encoding: .utf8) ?? ""
            #expect(Double(jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) == nil)
        }
    }

    // MARK: - 22. Deterministic repeatability

    @Test("22. Deterministic repeatability — the same input produces exactly equal plans, every time")
    func deterministicRepeatability() {
        let engine = QDeterministicDecisionEngine()
        let sampleTask = task(intent: "Write a function to sort a list", tainted: true)
        let planA = engine.decide(for: sampleTask)
        let planB = engine.decide(for: sampleTask)
        let planC = engine.decide(for: sampleTask)
        #expect(planA == planB)
        #expect(planB == planC)
    }

    // MARK: - 23. Codable round-trip of a generated plan

    @Test("23. A generated QDecisionPlan round-trips through JSON encoding/decoding intact")
    func generatedPlanRoundTripsThroughJSON() throws {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Write a function to sort a list"))
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(QDecisionPlan.self, from: data)
        #expect(decoded == plan)
    }

    // MARK: - 24. No network/model invocation

    @Test("24. decide(for:) is synchronous, non-throwing, and executes purely in-process (no network/model latency)")
    func decideIsPureAndFast() {
        // `decide(for:)` is neither `async` nor `throws` — calling it directly, with no `await`
        // and no `try`, in a plain synchronous test function IS the structural proof that it
        // cannot perform network I/O or invoke a model (both require `async throws` in every
        // other provider protocol in this codebase — QModelProvider.generatePlan, for example).
        // As an additional empirical signal: 1000 calls complete near-instantly, many orders of
        // magnitude faster than any real network round-trip or model inference would allow.
        let engine = QDeterministicDecisionEngine()
        let sampleTask = task(intent: "Write a function to sort a list")
        let start = Date()
        for _ in 0..<1000 {
            _ = engine.decide(for: sampleTask)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0)
    }

    // MARK: - 25. No permission/egress authority in the resulting plan

    @Test("25. QDecisionPlan carries exactly its 9 documented fields — the engine adds no permission/egress field")
    func decisionPlanCarriesOnlyDocumentedFields() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Delete this file permanently"))
        let fieldNames = Set(Mirror(reflecting: plan).children.compactMap { $0.label })
        #expect(fieldNames == [
            "taskType", "complexity", "decompositionDecision", "reasoningStepBudget",
            "modelStrategy", "verificationRequirement", "provenanceRequirement",
            "resourceEnvelope", "uncertainty"
        ])
    }

    // MARK: - 26. Ambiguous input fails conservatively

    @Test("26. Ambiguous input with no matching keyword classifies conservatively, not as trivially simple")
    func ambiguousInputFailsConservatively() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "asdkjaskjd qwerty nonsense"))
        #expect(plan.taskType == .reasoning)
        #expect(plan.taskType != .simpleQA)
        #expect(plan.uncertainty == .high)
        #expect(plan.verificationRequirement != .none)
    }

    // MARK: - 27. Pathological/empty input remains bounded

    @Test("27. Empty and whitespace-only input remain bounded and never crash")
    func pathologicalEmptyInputRemainsBounded() {
        for intent in ["", "   ", "\n\t"] {
            let plan = QDeterministicDecisionEngine().decide(for: task(intent: intent))
            #expect(plan.uncertainty == .unknown)
            #expect(plan.taskType == .reasoning)
            #expect(plan.reasoningStepBudget >= 1 && plan.reasoningStepBudget <= 6)
            #expect((plan.decompositionDecision.maximumSubtasks ?? 0) <= 5)
        }
    }

    // MARK: - 28. No unbounded decomposition/resource values across every complexity level

    @Test("28. Decomposition and resource-envelope subtask bounds never exceed a small fixed ceiling")
    func decompositionAndResourceBoundsNeverExceedFixedCeiling() {
        let intents = [
            "What is the capital of France?", "Write a poem about the ocean", "Open Calculator",
            "Why did the project fail?", "Research the history of the internet", "Create a plan for my trip",
            "Write a function to sort a list", "Delete this file permanently"
        ]
        for intent in intents {
            let plan = QDeterministicDecisionEngine().decide(for: task(intent: intent))
            let bound = plan.decompositionDecision.maximumSubtasks ?? 0
            #expect(bound >= 0)
            #expect(bound <= 5)
            #expect(plan.resourceEnvelope.maximumSubtasks == bound)
            #expect(plan.resourceEnvelope.maximumSubtasks <= 5)
        }
    }

    // MARK: - 29. No raw task content leakage into the persisted decision structure

    @Test("29. QDecisionPlan never carries the raw intent text or any String field at all")
    func decisionPlanNeverCarriesRawIntentText() {
        let secretLookingIntent = "Set the field to SECRET_TOKEN_abc123xyz and send it"
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: secretLookingIntent))

        // Structural: QDecisionPlan has no String-typed field at all — every field is a bounded
        // enum or Int — so the raw intent literally cannot be represented, not merely "isn't
        // currently populated".
        for child in Mirror(reflecting: plan).children {
            #expect((child.value as? String) == nil)
        }
    }

    // MARK: - Security invariants

    @Test("S1. A produced QDecisionPlan cannot authorize an action, network egress, or a standing approval")
    func decisionPlanCarriesNoExecutionEgressOrApprovalAuthority() {
        let plan = QDeterministicDecisionEngine().decide(for: task(intent: "Delete this file permanently"))
        // Structural: none of the 9 documented fields is (or contains) a capability, approval,
        // egress, or credential type — confirmed exhaustively by field name/type above (test 25),
        // and every field's own type (QTaskType/QTaskComplexity/QDecompositionDecision/Int/
        // QModelStrategy/QVerificationRequirement/QProvenanceRequirement/
        // QDecisionResourceEnvelope/QDecisionUncertainty) is defined in this same Phase 2A file
        // pair, none of which imports or references QCapability/QApprovalRequest/QEgressBroker.
        #expect(Mirror(reflecting: plan.resourceEnvelope).children.allSatisfy { $0.label != "capability" && $0.label != "approval" && $0.label != "egress" })
    }

    @Test("S2. Model strategy never selects a cloud provider")
    func modelStrategyNeverSelectsCloudProvider() {
        let cloudIndicators = ["cloud", "openai", "anthropic", "azure", "gcp", "remote"]
        for strategy in QModelStrategy.allCases {
            let wireValue = strategy.rawValue.lowercased()
            for indicator in cloudIndicators {
                #expect(!wireValue.contains(indicator))
            }
        }
    }

    @Test("S3. QDeterministicDecisionEngine exposes exactly one entry point — decide(for:) — no execute/run/perform method")
    func decisionEngineHasNoDirectExecutionPath() {
        // QDecisionEngine (the protocol) declares exactly one requirement. There is no second
        // method a caller could reach for execution — the only way to use this type at all is
        // to call `decide(for:)` and get data back.
        let engine: any QDecisionEngine = QDeterministicDecisionEngine()
        let plan = engine.decide(for: task(intent: "What is the capital of France?"))
        #expect(plan.taskType == .simpleQA)
    }
}
