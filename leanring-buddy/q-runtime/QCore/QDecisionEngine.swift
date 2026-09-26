//
//  QDecisionEngine.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2A.2 First Real Deterministic Implementation.
//  Produces a `QDecisionPlan` (Phase 2A.1, `QDecisionEngineContracts.swift`) from a `QTask` —
//  the same canonical task representation `QCoreRuntime.submitIntent` already constructs
//  (`QTask(sessionId:intent:)`) and every existing `QModelProvider`/`QExecutionProvider` already
//  consumes. No new task/input type is introduced.
//
//  Architectural rule this file exists to honor: Decision Engine ≠ Model Router. This type
//  answers "what kind of task is this, how complex, does it need decomposition, what execution
//  strategy/verification/provenance/resource intent applies?" — never "which concrete
//  model/backend should run inference?" (that remains `QModelRouter`'s job, entirely untouched
//  here) and never "should this be allowed to happen?" (that remains `QPermissionGate`/
//  `QApprovalCoordinator`/`QResourceGuard`, entirely untouched here).
//
//  NOT part of this phase: no `QCoreRuntime` integration (nothing here is called from the
//  runtime yet), no Task Decomposer implementation (`QDecompositionDecision` is only ever
//  produced, never acted on), no `QModelRouter`/`QPlanExecutor` change, no permission/egress/
//  resource/provenance/security-boundary change.
//
//  Design: pure, deterministic, synchronous. No filesystem writes, no network, no Keychain, no
//  audit-log writes, no model calls, no subprocesses, no UI calls, no AX calls. `decide(for:)`'s
//  entire output is a function of `task.intent` (text) and `task.context.isTainted` (the
//  existing, already-computed provenance-taint signal from `QProvenance.swift` — not a new
//  provenance system). Calling it twice with equal input always produces an equal `QDecisionPlan`.
//
//  Classification deliberately does NOT use response length, code-block detection, lexical-
//  overlap, or arbitrary token counts as a capability-score proxy — see
//  `PaceQueryComplexityEstimator.swift` for the existing, different-pipeline precedent that DOES
//  use word-count thresholds; that pattern is intentionally not reused here. Instead, task-type
//  classification uses a small, fully-enumerated, documented set of explicit keyword/phrase
//  indicators per category (any match → that category, checked in a fixed, safety-ordered
//  priority so an ambiguous task never quietly lands in a category that under-claims its risk),
//  and every other field (complexity, decomposition, reasoning-step budget, model strategy,
//  verification, provenance, resource envelope, uncertainty) is DERIVED from that classification
//  plus the existing taint signal through fixed, explicit, testable mapping tables — never a
//  second independent text re-analysis, never a numeric score of any kind.
//

import Foundation

// MARK: - Decision Engine Protocol

/// Provider-independent contract for anything that can produce a `QDecisionPlan` for a task —
/// mirrors this codebase's existing `QModelProvider`/`QExecutionProvider`-style provider
/// protocols. A conforming type only ever DECIDES: it never executes a task, never selects a
/// concrete model/provider, and never grants permission, resource, or egress authority.
public protocol QDecisionEngine: Sendable {
    func decide(for task: QTask) -> QDecisionPlan
}

// MARK: - Deterministic Decision Engine

/// The first real `QDecisionEngine` implementation. Purely rule-based — no model invocation, no
/// network, no learning, no retraining. See this file's header for the full design rationale.
public struct QDeterministicDecisionEngine: QDecisionEngine, Sendable {

    public init() {}

    /// Produces a `QDecisionPlan` for `task`. Pure and synchronous: reads only `task.intent` and
    /// `task.context.isTainted`, performs no I/O, and is fully repeatable — equal input always
    /// produces an equal `QDecisionPlan`.
    public func decide(for task: QTask) -> QDecisionPlan {
        let trimmedIntent = task.intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let isContextTainted = task.context.isTainted
        let classification = Self.classifyTaskType(intent: trimmedIntent)
        let taskType = classification.taskType

        var complexity = Self.baseComplexity(for: taskType)
        if isContextTainted {
            complexity = Self.escalateComplexity(complexity)
        }

        let decompositionDecision = Self.decompositionDecision(for: complexity)
        let reasoningStepBudget = Self.reasoningStepBudget(for: complexity)
        let modelStrategy = Self.modelStrategy(for: taskType)

        var verificationRequirement = Self.baseVerificationRequirement(for: taskType)
        if isContextTainted {
            verificationRequirement = Self.escalateVerificationRequirement(verificationRequirement)
        }

        let provenanceRequirement = Self.provenanceRequirement(taskType: taskType, isContextTainted: isContextTainted)
        let resourceEnvelope = Self.resourceEnvelope(decompositionDecision: decompositionDecision)

        let uncertainty: QDecisionUncertainty
        if trimmedIntent.isEmpty {
            // Nothing to classify at all — this is not merely "low confidence", there is no
            // signal to be confident or unconfident about. `.unknown` is the honest answer.
            uncertainty = .unknown
        } else {
            uncertainty = Self.uncertainty(
                taskType: taskType,
                matchedExplicitKeyword: classification.matchedExplicitKeyword,
                isContextTainted: isContextTainted
            )
        }

        return QDecisionPlan(
            taskType: taskType,
            complexity: complexity,
            decompositionDecision: decompositionDecision,
            reasoningStepBudget: reasoningStepBudget,
            modelStrategy: modelStrategy,
            verificationRequirement: verificationRequirement,
            provenanceRequirement: provenanceRequirement,
            resourceEnvelope: resourceEnvelope,
            uncertainty: uncertainty
        )
    }

    // MARK: - Task Type Classification

    /// The result of classifying an intent string: the resolved `QTaskType`, and whether that
    /// resolution came from an explicit keyword match (`true`) or the conservative fallback with
    /// no match at all (`false`) — the latter feeds directly into `uncertainty`.
    fileprivate struct TaskTypeClassification {
        let taskType: QTaskType
        let matchedExplicitKeyword: Bool
    }

    /// Classifies `intent` by checking a small, fully-enumerated, documented set of explicit
    /// phrase indicators per category, in a FIXED priority order chosen so that an intent
    /// matching more than one category's indicators always resolves to the more cautious one
    /// (e.g. an intent that reads as both "coding" and "criticalHighRisk" resolves to
    /// `.criticalHighRisk`). `reasoning` is deliberately checked BEFORE `simpleQA` — a compound
    /// question such as "what is the best strategy considering the trade-offs and pros and
    /// cons" must resolve to `.reasoning`, not the lighter-weight `.simpleQA`, since checking
    /// `simpleQA`'s generic question-openers first would silently under-claim a task that is
    /// substantively a reasoning task just because it happens to start with "what is". An intent
    /// matching none of them — including an empty intent — conservatively resolves to
    /// `.reasoning` (never `.simpleQA`, which would under-claim simplicity for something
    /// genuinely unclassified) with `matchedExplicitKeyword: false`.
    fileprivate static func classifyTaskType(intent: String) -> TaskTypeClassification {
        let normalizedIntent = QArabicIntentNormalizer.NormalizedIntent(rawIntent: intent)
        func matches(_ indicators: [String]) -> Bool {
            QArabicIntentNormalizer.containsSubstringIndicator(indicators, in: normalizedIntent)
        }

        if matches(criticalHighRiskIndicators) {
            return TaskTypeClassification(taskType: .criticalHighRisk, matchedExplicitKeyword: true)
        }
        if QArabicIntentNormalizer.containsExecutionIndicator(executionIndicators, in: normalizedIntent) {
            return TaskTypeClassification(taskType: .execution, matchedExplicitKeyword: true)
        }
        if matches(codingIndicators) {
            return TaskTypeClassification(taskType: .coding, matchedExplicitKeyword: true)
        }
        if matches(planningIndicators) {
            return TaskTypeClassification(taskType: .planning, matchedExplicitKeyword: true)
        }
        if matches(researchIndicators) {
            return TaskTypeClassification(taskType: .research, matchedExplicitKeyword: true)
        }
        if matches(creativeIndicators) {
            return TaskTypeClassification(taskType: .creative, matchedExplicitKeyword: true)
        }
        if matches(reasoningIndicators) {
            return TaskTypeClassification(taskType: .reasoning, matchedExplicitKeyword: true)
        }
        if matches(simpleQAIndicators) {
            return TaskTypeClassification(taskType: .simpleQA, matchedExplicitKeyword: true)
        }
        return TaskTypeClassification(taskType: .reasoning, matchedExplicitKeyword: false)
    }

    /// Mirrors `QCapabilityLevel.level3HighRisk`'s own already-documented scope (destructive,
    /// external, or high-blast-radius actions — see `QCapabilityModel.swift`) rather than
    /// inventing a new, separate risk taxonomy. Checked FIRST: any match here overrides every
    /// other category, per the "fail conservatively toward... no privileged authority" principle.
    /// Mirrors `QCapabilityLevel.level3HighRisk`'s own already-documented scope (destructive,
    /// external, or high-blast-radius actions — see `QCapabilityModel.swift`) rather than
    /// inventing a new, separate risk taxonomy. Checked FIRST: any match here overrides every
    /// other category, per the "fail conservatively toward... no privileged authority" principle.
    public static let criticalHighRiskIndicators: [String] = [
        "delete", "remove permanently", "erase", "wipe", "format the disk", "uninstall",
        "force quit", "shut down", "restart the computer", "factory reset",
        "send money", "make a payment", "transfer funds", "wire transfer", "buy ", "purchase",
        "send an email", "send a message to", "send this message", "send message", "post publicly", "publish", "share my",
        "delete account", "close my account", "cancel my subscription",
        "sudo ", "rm -rf", "git push --force", "drop table", "deploy to production",
        // Arabic critical indicators
        "احذف", "امسح", "فرمت", "أرسل الرسالة", "ارسل الرسالة", "ابعث الرسالة"
    ]

    /// State-changing but not inherently high-risk actions — the `ui.*`/`app.*`/`fs.write_sandbox`
    /// shape of capability already registered elsewhere in this codebase (Level 1–2), not a new
    /// action taxonomy.
    public static let executionIndicators: [String] = [
        "open ", "close ", "click ", "type ", "set the", "select ", "toggle ", "enable ",
        "disable ", "run ", "execute ", "launch ", "start ", "stop ", "move ", "copy ",
        "rename ", "save ", "create a file", "write to the file", "write to ", "write data", "quit ",
        // Folder and directory operations
        "create a folder", "create folder", "create a directory", "create directory", "make a folder", "make a directory", "new folder",
        // File reading operations requiring computer file access
        "read this file", "read the file", "read file", "read from ",
        // Volume / system media operations
        "change the volume", "set the volume", "adjust the volume", "turn up the volume", "turn down the volume", "mute", "unmute",
        // Arabic execution indicators
        "افتح", "اغلق", "سكر", "شغل", "انقر", "اضغط", "اكتب", "غير الصوت", "عدل الصوت", "انشئ مجلد", "اعمل مجلد"
    ]

    public static let codingIndicators: [String] = [
        "write a function", "write code", "write a script", "write a program",
        "write a class", "write a method", "implement ", "debug ", "fix the bug",
        "refactor", "compile", "write a unit test", "write tests for", "write a component"
    ]

    public static let planningIndicators: [String] = [
        "create a plan", "make a plan", "project plan", "roadmap", "schedule ",
        "outline a plan", "organize my", "itinerary", "plan a", "plan the", "plan for"
    ]

    public static let researchIndicators: [String] = [
        "research ", "find information about", "look up", "search for", "gather sources",
        "investigate", "find out about", "compile a list of sources", "find articles about",
        "search the web", "search google"
    ]

    public static let creativeIndicators: [String] = [
        "write a story", "write a poem", "brainstorm", "creative writing", "compose a song",
        "write lyrics", "generate ideas for", "design a logo", "come up with names",
        "write a song", "invent a", "write a short", "write an explanation", "write an essay"
    ]

    public static let simpleQAIndicators: [String] = [
        "what is ", "what's ", "who is ", "who's ", "when is ", "when did ", "where is ",
        "define ", "how many ", "how much ", "what does ", "what time ", "which ", "tell me ",
        "what programming language", "what did i ", "do you remember",
        "give me examples", "give me three examples", "examples of ",
        // Arabic conversational question indicators
        "ما هو", "ما هي", "شو ", "مين ", "وين ", "كم ", "متى ", "ايش ", "كيف ", "تذكر ", "احكيلي", "أخبرني", "هل ", "اعطيني امثلة", "أعطني أمثلة"
    ]

    public static let reasoningIndicators: [String] = [
        "why ", "explain why", "explain in ", "explain how ", "explain the difference", "explain this", "explain ",
        "analyze", "analyse", "compare ", "evaluate the",
        "what are the implications", "reason about", "think through", "pros and cons",
        "trade-offs", "tradeoffs", "how does ",
        // Arabic reasoning indicators
        "ليش", "لماذا", "فسر", "اشرح"
    ]

    /// Evaluates whether an intent string contains deterministic computer-side execution or mutation indicators.
    /// Used as defense-in-depth to ensure non-conversational execution routing even if taskType is advisory reasoning.
    public static func containsExecutionIndicators(intent: String) -> Bool {
        let normalizedIntent = QArabicIntentNormalizer.NormalizedIntent(rawIntent: intent)
        func matches(_ indicators: [String]) -> Bool {
            QArabicIntentNormalizer.containsSubstringIndicator(indicators, in: normalizedIntent)
        }
        return matches(criticalHighRiskIndicators) ||
               QArabicIntentNormalizer.containsExecutionIndicator(executionIndicators, in: normalizedIntent) ||
               matches(codingIndicators) ||
               matches(planningIndicators) ||
               matches(researchIndicators)
    }

    // MARK: - Complexity

    /// A fixed, documented mapping from task type to a default complexity band — never a
    /// numeric score, never re-derived from text length. `.execution` defaults to `.simple`
    /// because most single UI/file actions are atomic; genuinely dangerous actions are already
    /// routed to `.criticalHighRisk` by classification, not left for complexity to catch.
    fileprivate static func baseComplexity(for taskType: QTaskType) -> QTaskComplexity {
        switch taskType {
        case .simpleQA:
            return .trivial
        case .creative, .execution:
            return .simple
        case .reasoning, .research, .planning:
            return .moderate
        case .coding:
            return .complex
        case .criticalHighRisk:
            return .critical
        }
    }

    /// Moves a complexity one band more cautious — used only when the task's context carries
    /// untrusted (tainted) content, per the "fail conservatively toward higher uncertainty"
    /// principle. `.critical` is already the most cautious band and does not escalate further.
    fileprivate static func escalateComplexity(_ complexity: QTaskComplexity) -> QTaskComplexity {
        switch complexity {
        case .trivial: return .simple
        case .simple: return .moderate
        case .moderate: return .complex
        case .complex, .critical: return .critical
        }
    }

    // MARK: - Decomposition Decision

    /// Named, documented bounds — never bare magic numbers — for how many subtasks a
    /// decomposition decision may ever propose. Deliberately small and fixed; tune here, in one
    /// place, rather than in the switch statement below.
    fileprivate static let moderateComplexityMaximumSubtasks = 3
    fileprivate static let complexComplexityMaximumSubtasks = 5
    fileprivate static let criticalComplexityMaximumSubtasks = 3

    /// Decomposition intent is derived from complexity alone, with small, fixed, explicit
    /// bounds — never an unbounded or model-directed subtask count. `.critical` REQUIRES
    /// decomposition (so each risky step can be individually approved/verified rather than one
    /// opaque high-risk action) but is bounded even smaller than `.complex`, keeping
    /// high-risk plans tightly scoped rather than sprawling.
    fileprivate static func decompositionDecision(for complexity: QTaskComplexity) -> QDecompositionDecision {
        switch complexity {
        case .trivial, .simple:
            return .notRequired
        case .moderate:
            return .recommended(maximumSubtasks: moderateComplexityMaximumSubtasks)
        case .complex:
            return .recommended(maximumSubtasks: complexComplexityMaximumSubtasks)
        case .critical:
            return .required(maximumSubtasks: criticalComplexityMaximumSubtasks)
        }
    }

    // MARK: - Reasoning Step Budget

    /// Named, documented per-complexity reasoning-step ceilings — never bare magic numbers.
    /// `.critical`'s budget is deliberately LOWER than `.complex`'s: a high-risk task should be
    /// tightly constrained and heavily verified, not given a large autonomous reasoning
    /// allowance. These are an execution/planning budget only, never a disclosure of model
    /// internal reasoning.
    fileprivate static let trivialComplexityReasoningStepBudget = 1
    fileprivate static let simpleComplexityReasoningStepBudget = 2
    fileprivate static let moderateComplexityReasoningStepBudget = 4
    fileprivate static let complexComplexityReasoningStepBudget = 6
    fileprivate static let criticalComplexityReasoningStepBudget = 3

    fileprivate static func reasoningStepBudget(for complexity: QTaskComplexity) -> Int {
        switch complexity {
        case .trivial: return trivialComplexityReasoningStepBudget
        case .simple: return simpleComplexityReasoningStepBudget
        case .moderate: return moderateComplexityReasoningStepBudget
        case .complex: return complexComplexityReasoningStepBudget
        case .critical: return criticalComplexityReasoningStepBudget
        }
    }

    // MARK: - Model Strategy (provider-independent)

    /// Conceptual execution strategy only — never a concrete backend/model identifier. Which
    /// actual local model/backend serves a given strategy remains `QModelRouter`'s job entirely.
    fileprivate static func modelStrategy(for taskType: QTaskType) -> QModelStrategy {
        switch taskType {
        case .simpleQA, .creative, .execution:
            return .singleLocalModel
        case .reasoning, .research, .coding, .criticalHighRisk:
            return .localReasoningModel
        case .planning:
            return .localPlannerModel
        }
    }

    // MARK: - Verification Requirement

    /// A decision-level REQUEST only — never a substitute for `QActionVerifier`'s real,
    /// mandatory, execution-level verification, which this type never touches. State-changing
    /// (`execution`) and high-risk (`criticalHighRisk`) task types get the strongest requested
    /// tiers, per the explicit Phase 2A.2 instruction to prefer stronger verification intent for
    /// state-changing/high-risk tasks.
    fileprivate static func baseVerificationRequirement(for taskType: QTaskType) -> QVerificationRequirement {
        switch taskType {
        case .simpleQA, .creative:
            return .none
        case .reasoning, .research, .planning, .coding, .execution:
            return .executionEvidence
        case .criticalHighRisk:
            return .independentVerification
        }
    }

    /// Moves a verification requirement one tier stronger — used only when the task's context
    /// carries untrusted (tainted) content. `.independentVerification` is already the strongest
    /// tier and does not escalate further.
    fileprivate static func escalateVerificationRequirement(_ requirement: QVerificationRequirement) -> QVerificationRequirement {
        switch requirement {
        case .none: return .executionEvidence
        case .executionEvidence, .independentVerification: return .independentVerification
        }
    }

    // MARK: - Provenance Requirement

    /// Declares intent only — the existing `QProvenanceKind`/`QProvenanceTag`/`QTaskContext`
    /// model (`QProvenance.swift`) remains the sole, authoritative implementation and is never
    /// duplicated or replaced here. Research tasks (externally sourced evidence) and any task
    /// whose context is already tainted both require provenance to be present.
    fileprivate static func provenanceRequirement(taskType: QTaskType, isContextTainted: Bool) -> QProvenanceRequirement {
        (taskType == .research || isContextTainted) ? .required : .notRequired
    }

    // MARK: - Resource Envelope

    /// Bounded intent only — never a second `QResourceGuard`, never a grant of anything.
    /// `maximumSubtasks` mirrors the decomposition decision's own explicit bound rather than
    /// introducing an independent, potentially-looser number. `allowsBackgroundExecution` is
    /// deliberately `false` for every task type at this phase — no runtime consumer of this
    /// field exists yet, and asserting `true` for any category now (e.g. `.research`, which
    /// seems superficially safe as "unattended information-gathering") would establish a default
    /// behavior a future integrator could inherit uncritically, before the real safety analysis
    /// (resource contention, notification surfacing, and — for `.research` specifically — this
    /// project's on-device-only posture) can actually happen at the point it takes effect. That
    /// judgment belongs to whichever future phase implements a real consumer, not to this one.
    fileprivate static func resourceEnvelope(decompositionDecision: QDecompositionDecision) -> QDecisionResourceEnvelope {
        QDecisionResourceEnvelope(
            maximumSubtasks: decompositionDecision.maximumSubtasks ?? 0,
            allowsBackgroundExecution: false
        )
    }

    // MARK: - Uncertainty

    /// Qualitative only — never a fabricated probability. A confident (explicit-keyword) match
    /// starts at `.low`; an unmatched/ambiguous intent starts at `.high` (never silently treated
    /// as if it were well-understood). Tainted context or a `.criticalHighRisk` classification
    /// each raise the floor to at least `.medium`, since consequences matter even when the
    /// classification itself was confident.
    fileprivate static func uncertainty(taskType: QTaskType, matchedExplicitKeyword: Bool, isContextTainted: Bool) -> QDecisionUncertainty {
        var level: QDecisionUncertainty = matchedExplicitKeyword ? .low : .high
        if level == .low, isContextTainted || taskType == .criticalHighRisk {
            level = .medium
        }
        return level
    }
}

// MARK: - Arabic-Aware Indicator Matching

/// Arabic orthographic normalization and indicator matching for `QDeterministicDecisionEngine`.
///
/// Why this exists: plain substring matching on raw text both MISSED ordinary Arabic requests
/// (`إفتح`, `شغّل`, `فتحلي`, `بدي تفتح سفاري`) and FALSELY treated conversation as execution
/// because short Arabic verbs occur inside unrelated words (`شو شغلك؟` "what's your job",
/// `سكر الدم` "blood sugar", `العسكري` "the soldier"). See the Arabic golden set in
/// `QArabicGoldenSet.swift` for every case this is measured against.
///
/// Safety shape (unchanged authority, deterministic, no model involvement):
/// - English indicators keep their exact original lowercase-substring semantics.
/// - Critical/high-risk and conversational categories keep SUBSTRING matching on normalized
///   text, so normalization can only widen them — critical detection never narrows.
/// - Only ARABIC EXECUTION indicators use whole-word matching with a reviewed set of attached
///   clitics. Narrowing execution is fail-safe: a conversational turn never executes anything.
public enum QArabicIntentNormalizer {

    /// Normalizes text for indicator matching only (never shown to the user or sent to a model):
    /// lowercases, strips Arabic diacritics (including shadda) and tatweel, maps `إ`/`آ`/`ٱ` to
    /// bare alef, and alef maqsura to ya. Non-Arabic text is only lowercased.
    ///
    /// `أ` (hamza ABOVE) is deliberately kept: it marks the first person (`أفتح` "I open", as in
    /// `بحب أفتح قلبي إلك`), which must not merge with the imperative `افتح`. `إفتح` is the
    /// common misspelling of the imperative, so `إ` is normalized.
    public static func normalizeForIntentMatching(_ text: String) -> String {
        var normalizedScalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640:
                continue
            case 0x0622, 0x0625, 0x0671:
                normalizedScalars.append(Unicode.Scalar(0x0627)!)
            case 0x0649:
                normalizedScalars.append(Unicode.Scalar(0x064A)!)
            default:
                normalizedScalars.append(scalar)
            }
        }
        return String(normalizedScalars)
    }

    /// An intent normalized once and split into word tokens, shared by every category check.
    public struct NormalizedIntent: Sendable {
        public let normalizedText: String
        public let tokens: [String]

        public init(rawIntent: String) {
            normalizedText = QArabicIntentNormalizer.normalizeForIntentMatching(rawIntent)
            tokens = normalizedText
                .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
                .filter { !$0.isEmpty }
        }
    }

    static func containsArabicLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0621...0x064A).contains($0.value) }
    }

    /// Substring semantics on normalized text (both sides normalized). For English indicators
    /// this is identical to the original `lowercased().contains(indicator)` behaviour.
    static func containsSubstringIndicator(_ indicators: [String], in intent: NormalizedIntent) -> Bool {
        indicators.contains { indicator in
            intent.normalizedText.contains(normalizeForIntentMatching(indicator))
        }
    }

    /// Execution matching: English entries keep substring semantics; Arabic entries match whole
    /// words (see `tokenMatchesArabicImperative`), and multi-word Arabic entries match as a
    /// consecutive token sequence.
    static func containsExecutionIndicator(_ indicators: [String], in intent: NormalizedIntent) -> Bool {
        indicators.contains { indicator in
            let normalizedIndicator = normalizeForIntentMatching(indicator)
            guard containsArabicLetter(normalizedIndicator) else {
                return intent.normalizedText.contains(normalizedIndicator)
            }
            let indicatorTokens = NormalizedIntent(rawIntent: normalizedIndicator).tokens
            if indicatorTokens.count > 1 {
                return containsConsecutiveTokens(indicatorTokens, in: intent.tokens)
            }
            guard let imperativeStem = indicatorTokens.first else { return false }
            return intent.tokens.indices.contains { tokenIndex in
                tokenMatchesArabicImperative(imperativeStem, atTokenIndex: tokenIndex, in: intent.tokens)
            }
        }
    }

    private static func containsConsecutiveTokens(_ sequence: [String], in tokens: [String]) -> Bool {
        guard !sequence.isEmpty, tokens.count >= sequence.count else { return false }
        return (0...(tokens.count - sequence.count)).contains { startIndex in
            Array(tokens[startIndex..<(startIndex + sequence.count)]) == sequence
        }
    }

    // MARK: Reviewed Arabic tables

    /// Imperatives that are also common nouns: `شغل` "run" / "work", `سكر` "close" / "sugar".
    /// A bare form only counts as a request when a recognisable target follows; with a
    /// benefactive clitic (`شغللي`, `سكرلي`) it is unambiguous.
    static let homographImperativeStems: Set<String> = ["شغل", "سكر"]

    /// Attached pronoun/benefactive endings accepted on unambiguous imperatives
    /// (`افتحلي`, `افتحي`, `افتحوا`, `افتحه`, `احذفهم`). Longest first.
    static let unambiguousImperativeSuffixes: [String] = ["يلي", "ولي", "لنا", "لها", "لي", "لك", "له", "وا", "ها", "هم", "ي", "و", "ه", ""]

    /// Only benefactive endings are accepted on homographs: `شغلي`/`شغلك`/`شغله` are "my/your/
    /// his work" and `سكري` is "diabetic", so those endings must never count as requests.
    static let homographImperativeSuffixes: [String] = ["لنا", "لي", "لك", ""]

    /// Conjunctions that may attach to the front of a request: `وافتح`, `فافتح`.
    static let attachedConjunctionPrefixes: [String] = ["و", "ف", ""]

    /// Second-person request forms mapped to their imperative (`بدي تفتح سفاري`). The bare form
    /// requires a request cue immediately before it (`الدكانة بتفتح` / `الوردة تفتح` are not
    /// requests); with a benefactive clitic (`تفتحلي`) it is a request on its own.
    static let secondPersonRequestForms: [String: String] = ["تفتح": "افتح", "تشغل": "شغل", "تسكر": "سكر", "تغلق": "اغلق"]

    /// Colloquial imperatives that drop the initial alef; only valid with a clitic (`فتحلي`),
    /// since bare `فتح` is the past tense "he opened".
    static let alefDroppedImperatives: [String: String] = ["فتح": "افتح"]

    static let requestCueTokens: Set<String> = normalizedTable(["بدي", "بدك", "ممكن", "بتقدر", "فيك", "فيكي", "لو", "رجاء", "please", "بليز", "ياريت"])

    /// Words skipped between a homograph imperative and its target (`سكر لي سفاري`, `سكر كل التطبيقات`).
    static let targetSearchSkippableTokens: Set<String> = normalizedTable(["لي", "لك", "هلق", "هلا", "هسا", "كل", "please", "بليز"])

    /// Nouns that make a bare homograph imperative a request. Any Latin-script word also counts
    /// (app names are commonly said in English: `شغل Calculator`).
    static let homographTargetNouns: Set<String> = normalizedTable([
        "الحاسبة", "حاسبة", "الآلة", "سفاري", "النوتس", "الملاحظات", "فايندر", "الفايندر",
        "التطبيق", "تطبيق", "التطبيقات", "البرنامج", "برنامج", "البرامج", "النافذة", "الشباك",
        "الملف", "المجلد", "الموسيقى", "موسيقى", "اغنية", "الاغنية", "الصوت", "الجهاز", "الماك",
        "الكمبيوتر", "البلوتوث", "الواي"
    ])

    /// Tables are written in natural spelling and normalized exactly like the intent, so a
    /// table entry can never silently fail to match because of alef maqsura, madda or diacritics.
    private static func normalizedTable(_ entries: [String]) -> Set<String> {
        Set(entries.map(normalizeForIntentMatching))
    }

    // MARK: Imperative matching

    static func tokenMatchesArabicImperative(_ imperativeStem: String, atTokenIndex tokenIndex: Int, in tokens: [String]) -> Bool {
        let token = tokens[tokenIndex]
        let isHomograph = homographImperativeStems.contains(imperativeStem)
        let allowedSuffixes = isHomograph ? homographImperativeSuffixes : unambiguousImperativeSuffixes

        for conjunctionPrefix in attachedConjunctionPrefixes where token.hasPrefix(conjunctionPrefix) {
            let tokenWithoutConjunction = String(token.dropFirst(conjunctionPrefix.count))
            for suffix in allowedSuffixes where tokenWithoutConjunction.hasSuffix(suffix) {
                let base = String(tokenWithoutConjunction.dropLast(suffix.count))
                let hasClitic = !suffix.isEmpty

                let isDirectImperative = base == imperativeStem
                let isSecondPersonRequest = secondPersonRequestForms[base] == imperativeStem
                    && (hasClitic || precedingTokenIsRequestCue(tokenIndex: tokenIndex, in: tokens))
                let isAlefDroppedImperative = hasClitic && alefDroppedImperatives[base] == imperativeStem

                guard isDirectImperative || isSecondPersonRequest || isAlefDroppedImperative else { continue }
                if isHomograph && !hasClitic {
                    return followingTokenIsRecognisableTarget(tokenIndex: tokenIndex, in: tokens)
                }
                return true
            }
        }
        return false
    }

    private static func precedingTokenIsRequestCue(tokenIndex: Int, in tokens: [String]) -> Bool {
        tokenIndex > 0 && requestCueTokens.contains(tokens[tokenIndex - 1])
    }

    private static func followingTokenIsRecognisableTarget(tokenIndex: Int, in tokens: [String]) -> Bool {
        var candidateIndex = tokenIndex + 1
        while candidateIndex < tokens.count && targetSearchSkippableTokens.contains(tokens[candidateIndex]) {
            candidateIndex += 1
        }
        guard candidateIndex < tokens.count else { return false }
        let candidate = tokens[candidateIndex]
        let isLatinWord = candidate.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) }
        return isLatinWord || homographTargetNouns.contains(candidate)
    }
}
