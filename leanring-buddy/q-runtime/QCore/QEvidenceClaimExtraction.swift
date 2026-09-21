//
//  QEvidenceClaimExtraction.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 2C Claim Extraction & Prompt-Injection Screening.
//  The typed boundary between untrusted text (model output, retrieved content) and the Evidence
//  Pool. Retrieved content is DATA, never instructions: this file's only job is to turn text into
//  bounded `QClaimProposition`s and to FLAG (never obey) instruction-shaped text.
//
//  Honest scope: `QEvidenceInstructionScanner` is a flagging aid, not the defense. The defense is
//  structural — no Phase 2C type has any field through which text could reach permission, egress,
//  strategy, model authority, execution, or approval (see `QEvidenceContracts.swift`). A pattern
//  list can always be evaded by rephrasing; that is fine, because an evaded line at worst becomes
//  an untrusted, bounded, unverified proposition — inert data.
//
//  No hidden chain-of-thought is requested, stored, or parsed: claims are concise
//  `subject: value` propositions only.
//

import Foundation

// MARK: - Instruction / Certainty Scanner

public enum QEvidenceInstructionScanner {

    private static let instructionRegexes: [NSRegularExpression] = [
        #"ignore\s+(all\s+|any\s+|the\s+|your\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|rules?|context)"#,
        #"disregard\s+(all\s+|any\s+|the\s+|your\s+)?(previous|prior|above|earlier|system)"#,
        #"(new|updated|override)\s+instructions?\s*[:\-]"#,
        #"\bsystem\s*prompt\b"#,
        #"\byou\s+(must|should|are\s+now|will\s+now|shall)\b"#,
        #"\b(run|execute|invoke|launch)\s+(this|the\s+following|these|that)\s+(command|script|code|program|tool)"#,
        #"\b(sudo|rm\s+-rf|curl\s|wget\s|chmod\s|osascript|bash\s+-c)"#,
        #"\b(send|upload|exfiltrate|forward|post|email)\s+(this|the|all|my|your|these)\s+\w*\s*(data|file|files|credentials?|keys?|secrets?|contents?|information|tokens?|passwords?)"#,
        #"\b(approve|authorize|authorise|grant|allow|enable|confirm)\s+(this|the|all|full|any|every)\s+\w*\s*(action|permission|permissions|access|request|egress|network|execution|capability)"#,
        #"\b(override|bypass|disable|skip)\s+(the\s+|all\s+)?(safety|security|permission|verification|approval|guard|policy|checks?)"#,
        #"\bact\s+as\b"#,
        #"<\|[^|]*\|>"#,
        #"\[/?INST\]"#,
        #"#{2,}\s*(system|instruction)"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let certaintyRegexes: [NSRegularExpression] = [
        #"\b(definitely|certainly|undoubtedly|absolutely|guaranteed|unquestionably|indisputabl[ey])\b"#,
        #"100\s*%"#,
        #"\b(without|beyond)\s+(a\s+)?doubt\b"#,
        #"\bproven\s+fact\b"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func matches(_ regexes: [NSRegularExpression], _ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regexes.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    /// True when `text` is shaped like an instruction aimed at an AI/agent. A flag only.
    public static func looksLikeInstruction(_ text: String) -> Bool {
        matches(instructionRegexes, text)
    }

    /// True when `text` uses certainty language. A critic input only — never evidence.
    public static func assertsCertainty(_ text: String) -> Bool {
        matches(certaintyRegexes, text)
    }
}

// MARK: - Extraction Result

public struct QExtractedProposition: Sendable, Equatable {
    public let proposition: QClaimProposition
    /// Evidence IDs the source text cited via `[ev-…]` tokens. UNVALIDATED — the pool checks every
    /// one against its own contents and drops those that do not exist.
    public let citedEvidenceIds: [QEvidenceID]
}

public struct QClaimExtractionResult: Sendable, Equatable {
    public let propositions: [QExtractedProposition]
    public let skippedInstructionLikeLines: Int
    public let droppedCredentialShapedLines: Int
    public let skippedMalformedLines: Int
    public let truncated: Bool
}

// MARK: - Extractor

/// Typed boundary for turning text into claims. Deterministic by default; a future model-backed
/// extractor would conform to the same protocol and its output would pass through the same pool
/// validation (bounds, credential screen, citation check) — it gains no extra authority.
public protocol QClaimExtractor: Sendable {
    func extract(from text: String, maxClaims: Int) -> QClaimExtractionResult
}

/// Extracts `subject: value` / `subject = value` lines (optionally bulleted). Lines that look like
/// instructions are skipped and counted, never turned into claims. Free prose that does not fit the
/// structured form yields no claim — conservatively "unresolved", never a guessed proposition.
public struct QDeterministicClaimExtractor: QClaimExtractor {

    public init() {}

    private static let linePattern = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•]\s*)?([^:=\n]{1,80}?)\s*[:=]\s*(.+?)\s*$"#,
        options: []
    )
    private static let citationPattern = try! NSRegularExpression(
        pattern: #"\[(ev-[0-9a-f]{16})\]"#,
        options: []
    )

    public func extract(from text: String, maxClaims: Int) -> QClaimExtractionResult {
        let bounded = String(text.prefix(QEvidenceLimits.maxContentCharactersScanned))
        let wasTruncated = text.count > QEvidenceLimits.maxContentCharactersScanned
        var propositions: [QExtractedProposition] = []
        var skippedInstructions = 0
        var droppedCredentials = 0
        var skippedMalformed = 0

        for line in bounded.split(whereSeparator: { $0.isNewline }) {
            let lineText = String(line)
            if lineText.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Instruction screening happens FIRST, on the whole line, so an injected
            // "subject: <instruction>" line can never become a claim.
            if QEvidenceInstructionScanner.looksLikeInstruction(lineText) {
                skippedInstructions += 1
                continue
            }
            // A credential-shaped line is never carried, redacted or otherwise.
            if QSecretRedactor.redact(lineText) != lineText {
                droppedCredentials += 1
                continue
            }
            guard propositions.count < maxClaims else { continue }

            let range = NSRange(location: 0, length: (lineText as NSString).length)
            guard let match = Self.linePattern.firstMatch(in: lineText, options: [], range: range),
                  match.numberOfRanges == 3 else {
                skippedMalformed += 1
                continue
            }
            let subject = (lineText as NSString).substring(with: match.range(at: 1))
            var value = (lineText as NSString).substring(with: match.range(at: 2))

            var cited: [QEvidenceID] = []
            let valueRange = NSRange(location: 0, length: (value as NSString).length)
            for citation in Self.citationPattern.matches(in: value, options: [], range: valueRange) where citation.numberOfRanges == 2 {
                if cited.count < QEvidenceLimits.maxCitedEvidencePerClaim {
                    cited.append(QEvidenceID(rawValue: (value as NSString).substring(with: citation.range(at: 1))))
                }
            }
            value = Self.citationPattern.stringByReplacingMatches(in: value, options: [], range: valueRange, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)

            guard let proposition = QClaimProposition(subject: subject, value: value) else {
                skippedMalformed += 1
                continue
            }
            propositions.append(QExtractedProposition(proposition: proposition, citedEvidenceIds: cited))
        }

        return QClaimExtractionResult(
            propositions: propositions,
            skippedInstructionLikeLines: skippedInstructions,
            droppedCredentialShapedLines: droppedCredentials,
            skippedMalformedLines: skippedMalformed,
            truncated: wasTruncated
        )
    }
}
