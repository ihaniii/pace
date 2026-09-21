//
//  QDecisionEngineContractsTests.swift
//  leanring-buddyTests
//
//  Q × Pace Decision Engine — Phase 2A.1 Contracts Tests.
//  Validates construction, Codable round-tripping, Equatable determinism, and fail-closed
//  decoding for every Phase 2A.1 contract type. No Decision Engine implementation exists yet —
//  these tests exercise the data contracts only, exactly like the contracts themselves.
//

import Testing
import Foundation
@testable import Pace

@Suite("QDecisionEngineContractsTests")
struct QDecisionEngineContractsTests {

    // MARK: - 1. Every QTaskType case can be constructed and round-trips through Codable

    @Test("1. Every QTaskType case constructs and round-trips through JSON")
    func everyTaskTypeCaseConstructsAndRoundTrips() throws {
        #expect(QTaskType.allCases.count == 8)
        for taskType in QTaskType.allCases {
            let data = try JSONEncoder().encode(taskType)
            let decoded = try JSONDecoder().decode(QTaskType.self, from: data)
            #expect(decoded == taskType)
        }
    }

    // MARK: - 2. Every QTaskComplexity case can be constructed and round-trips through Codable

    @Test("2. Every QTaskComplexity case constructs and round-trips through JSON — no numeric score")
    func everyTaskComplexityCaseConstructsAndRoundTrips() throws {
        #expect(QTaskComplexity.allCases.count == 5)
        for complexity in QTaskComplexity.allCases {
            let data = try JSONEncoder().encode(complexity)
            let decoded = try JSONDecoder().decode(QTaskComplexity.self, from: data)
            #expect(decoded == complexity)
            // The wire representation must be the qualitative case name, never a bare number —
            // proves no numeric "complexity score" is smuggled in via the raw value.
            let jsonString = String(data: data, encoding: .utf8) ?? ""
            #expect(Int(jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) == nil)
        }
    }

    // MARK: - 3. QDecompositionDecision: every case constructs, and the bound survives Codable

    @Test("3. QDecompositionDecision.notRequired constructs and round-trips, with no subtask bound")
    func decompositionNotRequiredRoundTrips() throws {
        let decision = QDecompositionDecision.notRequired
        #expect(decision.maximumSubtasks == nil)

        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(QDecompositionDecision.self, from: data)
        #expect(decoded == decision)
    }

    @Test("4. QDecompositionDecision.recommended carries and round-trips its explicit bound")
    func decompositionRecommendedRoundTripsBound() throws {
        let decision = QDecompositionDecision.recommended(maximumSubtasks: 4)
        #expect(decision.maximumSubtasks == 4)

        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(QDecompositionDecision.self, from: data)
        #expect(decoded == decision)
        #expect(decoded.maximumSubtasks == 4)
    }

    @Test("5. QDecompositionDecision.required carries and round-trips its explicit bound")
    func decompositionRequiredRoundTripsBound() throws {
        let decision = QDecompositionDecision.required(maximumSubtasks: 7)
        #expect(decision.maximumSubtasks == 7)

        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(QDecompositionDecision.self, from: data)
        #expect(decoded == decision)
        #expect(decoded.maximumSubtasks == 7)

        // The bound must not silently disappear or coalesce during serialization: a decision
        // with a different bound must decode to a DIFFERENT value, never compare equal.
        let differentBound = QDecompositionDecision.required(maximumSubtasks: 3)
        #expect(decoded != differentBound)
    }

    // MARK: - 6. QModelStrategy: every case constructs, round-trips, and names no provider

    @Test("6. Every QModelStrategy case constructs, round-trips, and requires no provider-specific model name")
    func everyModelStrategyCaseConstructsAndNamesNoProvider() throws {
        #expect(QModelStrategy.allCases.count == 3)
        #expect(QModelStrategy.allCases == [.singleLocalModel, .localReasoningModel, .localPlannerModel])

        let knownProviderNames = ["apple.foundation", "apple.mlx", "local.ollama", "local.llama_cpp", "openai", "anthropic", "gpt", "claude", "qwen", "llama"]
        for strategy in QModelStrategy.allCases {
            let data = try JSONEncoder().encode(strategy)
            let decoded = try JSONDecoder().decode(QModelStrategy.self, from: data)
            #expect(decoded == strategy)

            // No case's wire representation may name a concrete provider/backend/model — proves
            // QModelStrategy stays provider-independent at the data level, not just by convention.
            let wireValue = strategy.rawValue.lowercased()
            for providerName in knownProviderNames {
                #expect(!wireValue.contains(providerName))
            }
        }
    }

    // MARK: - 7. QVerificationRequirement: every case constructs and round-trips

    @Test("7. Every QVerificationRequirement case constructs and round-trips through JSON")
    func everyVerificationRequirementCaseConstructsAndRoundTrips() throws {
        #expect(QVerificationRequirement.allCases.count == 3)
        for requirement in QVerificationRequirement.allCases {
            let data = try JSONEncoder().encode(requirement)
            let decoded = try JSONDecoder().decode(QVerificationRequirement.self, from: data)
            #expect(decoded == requirement)
        }
    }

    // MARK: - 8. QProvenanceRequirement: every case constructs and round-trips

    @Test("8. Every QProvenanceRequirement case constructs and round-trips through JSON")
    func everyProvenanceRequirementCaseConstructsAndRoundTrips() throws {
        #expect(QProvenanceRequirement.allCases.count == 2)
        for requirement in QProvenanceRequirement.allCases {
            let data = try JSONEncoder().encode(requirement)
            let decoded = try JSONDecoder().decode(QProvenanceRequirement.self, from: data)
            #expect(decoded == requirement)
        }
    }

    // MARK: - 9. QDecisionUncertainty: every case constructs and round-trips — no numeric confidence

    @Test("9. Every QDecisionUncertainty case constructs and round-trips through JSON — no numeric confidence")
    func everyDecisionUncertaintyCaseConstructsAndRoundTrips() throws {
        #expect(QDecisionUncertainty.allCases.count == 4)
        for uncertainty in QDecisionUncertainty.allCases {
            let data = try JSONEncoder().encode(uncertainty)
            let decoded = try JSONDecoder().decode(QDecisionUncertainty.self, from: data)
            #expect(decoded == uncertainty)
            let jsonString = String(data: data, encoding: .utf8) ?? ""
            #expect(Double(jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) == nil)
        }
    }

    // MARK: - 10. QDecisionResourceEnvelope: constructs, round-trips, and the bound survives serialization

    @Test("10. QDecisionResourceEnvelope round-trips through JSON with its bounds intact")
    func resourceEnvelopeRoundTripsWithBoundsIntact() throws {
        let envelope = QDecisionResourceEnvelope(maximumSubtasks: 5, allowsBackgroundExecution: true)

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(QDecisionResourceEnvelope.self, from: data)

        #expect(decoded == envelope)
        #expect(decoded.maximumSubtasks == 5)
        #expect(decoded.allowsBackgroundExecution == true)

        // A different bound must decode to something that compares unequal — the bound cannot
        // silently disappear or coalesce to a default during serialization.
        let differentEnvelope = QDecisionResourceEnvelope(maximumSubtasks: 1, allowsBackgroundExecution: true)
        #expect(decoded != differentEnvelope)
    }

    @Test("11. QDecisionResourceEnvelope defaults are conservative (no subtasks, no background execution)")
    func resourceEnvelopeDefaultsAreConservative() {
        let envelope = QDecisionResourceEnvelope()
        #expect(envelope.maximumSubtasks == 0)
        #expect(envelope.allowsBackgroundExecution == false)
    }

    // MARK: - 12. QDecisionPlan: full round-trip through JSON with every field intact

    @Test("12. QDecisionPlan round-trips through JSON encoding/decoding with every field intact")
    func decisionPlanRoundTripsWithEveryFieldIntact() throws {
        let originalPlan = QDecisionPlan(
            taskType: .coding,
            complexity: .complex,
            decompositionDecision: .required(maximumSubtasks: 6),
            reasoningStepBudget: 12,
            modelStrategy: .localReasoningModel,
            verificationRequirement: .independentVerification,
            provenanceRequirement: .required,
            resourceEnvelope: QDecisionResourceEnvelope(maximumSubtasks: 6, allowsBackgroundExecution: false),
            uncertainty: .medium
        )

        let data = try JSONEncoder().encode(originalPlan)
        let decodedPlan = try JSONDecoder().decode(QDecisionPlan.self, from: data)

        #expect(decodedPlan == originalPlan)
        #expect(decodedPlan.taskType == .coding)
        #expect(decodedPlan.complexity == .complex)
        #expect(decodedPlan.decompositionDecision == .required(maximumSubtasks: 6))
        #expect(decodedPlan.decompositionDecision.maximumSubtasks == 6)
        #expect(decodedPlan.reasoningStepBudget == 12)
        #expect(decodedPlan.modelStrategy == .localReasoningModel)
        #expect(decodedPlan.verificationRequirement == .independentVerification)
        #expect(decodedPlan.provenanceRequirement == .required)
        #expect(decodedPlan.resourceEnvelope.maximumSubtasks == 6)
        #expect(decodedPlan.resourceEnvelope.allowsBackgroundExecution == false)
        #expect(decodedPlan.uncertainty == .medium)
    }

    // MARK: - 13. Equatable behavior is deterministic — same inputs always compare equal

    @Test("13. QDecisionPlan Equatable behavior is deterministic across repeated construction")
    func decisionPlanEquatableIsDeterministic() {
        func makePlan() -> QDecisionPlan {
            QDecisionPlan(
                taskType: .research,
                complexity: .moderate,
                decompositionDecision: .recommended(maximumSubtasks: 3),
                reasoningStepBudget: 5,
                modelStrategy: .localPlannerModel,
                verificationRequirement: .executionEvidence,
                provenanceRequirement: .required,
                resourceEnvelope: QDecisionResourceEnvelope(maximumSubtasks: 3, allowsBackgroundExecution: true),
                uncertainty: .low
            )
        }
        let planA = makePlan()
        let planB = makePlan()
        #expect(planA == planB)

        let differentPlan = QDecisionPlan(
            taskType: .research,
            complexity: .moderate,
            decompositionDecision: .recommended(maximumSubtasks: 3),
            reasoningStepBudget: 5,
            modelStrategy: .localPlannerModel,
            verificationRequirement: .executionEvidence,
            provenanceRequirement: .required,
            resourceEnvelope: QDecisionResourceEnvelope(maximumSubtasks: 3, allowsBackgroundExecution: true),
            uncertainty: .high // only uncertainty differs
        )
        #expect(planA != differentPlan)
    }

    // MARK: - 14. Unknown/invalid serialized enum values fail closed, never silently default

    @Test("14. An unrecognized QTaskType raw value fails closed through normal Codable decoding")
    func unrecognizedTaskTypeFailsClosedOnDecode() {
        let invalidJSON = "\"totallyMadeUpTaskType\"".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(QTaskType.self, from: invalidJSON)
        }
    }

    @Test("15. An unrecognized QModelStrategy raw value fails closed through normal Codable decoding")
    func unrecognizedModelStrategyFailsClosedOnDecode() {
        let invalidJSON = "\"gpt5EnsembleRacing\"".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(QModelStrategy.self, from: invalidJSON)
        }
    }

    @Test("16. A malformed QDecompositionDecision payload fails closed through normal Codable decoding")
    func malformedDecompositionDecisionFailsClosedOnDecode() {
        // Neither a recognized case key nor a valid shape for the associated-value payload.
        let invalidJSON = "{\"unknownCase\": {\"maximumSubtasks\": 5}}".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(QDecompositionDecision.self, from: invalidJSON)
        }
    }

    // MARK: - 17. Structural check: QDecisionPlan carries exactly its documented fields — nothing more

    @Test("17. QDecisionPlan carries exactly its 9 documented fields — no permission, egress, or credential field exists")
    func decisionPlanCarriesOnlyDocumentedFields() {
        let plan = QDecisionPlan(
            taskType: .simpleQA,
            complexity: .trivial,
            decompositionDecision: .notRequired,
            reasoningStepBudget: 1,
            modelStrategy: .singleLocalModel,
            verificationRequirement: .none,
            provenanceRequirement: .notRequired,
            resourceEnvelope: QDecisionResourceEnvelope(),
            uncertainty: .unknown
        )
        let fieldNames = Set(Mirror(reflecting: plan).children.compactMap { $0.label })
        #expect(fieldNames == [
            "taskType", "complexity", "decompositionDecision", "reasoningStepBudget",
            "modelStrategy", "verificationRequirement", "provenanceRequirement",
            "resourceEnvelope", "uncertainty"
        ])
    }

    // MARK: - 18. Contracts construct independently of any concrete model/provider/permission type

    @Test("18. QDecisionPlan constructs using only this file's own contract types — no QModelRouter/QCapability/QPermissionGate dependency")
    func decisionPlanConstructsWithoutConcreteModelOrPermissionDependency() {
        // If this compiles and runs using nothing but Foundation + the Phase 2A.1 contract
        // types themselves, the contracts are provider- and permission-independent by
        // construction — no QModelRouter, QCapability, or QPermissionGate reference is needed
        // anywhere in this initializer call.
        let plan = QDecisionPlan(
            taskType: .planning,
            complexity: .simple,
            decompositionDecision: .notRequired,
            reasoningStepBudget: 2,
            modelStrategy: .singleLocalModel,
            verificationRequirement: .none,
            provenanceRequirement: .notRequired,
            resourceEnvelope: QDecisionResourceEnvelope(),
            uncertainty: .unknown
        )
        #expect(plan.taskType == .planning)
    }
}
