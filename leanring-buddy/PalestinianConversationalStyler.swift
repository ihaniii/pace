//
//  PalestinianConversationalStyler.swift
//  leanring-buddy
//
//  Presentation-only seam for Que's Palestinian Arabic conversational style.
//
//  Position in the architecture (the ONLY permitted direction):
//
//      classification / security / execution (QDecisionEngine, QPermissionGate,
//      QResourceGuard, QExecutionService)  →  grounded answer or result
//          →  PalestinianConversationalStyler (this file)  →  display / TTS / history
//
//  Its output is never parsed, never classified and never executed, so
//  "model output → style → parser → action" cannot be assembled from it.
//
//  Contract, enforced by construction and by tests:
//   - Pure `String → String`. No network, filesystem, process/shell, permission,
//     TTS, memory or settings access; it never sees a plan, intent, tool or target.
//   - Clause-local: text is styled one punctuation-bounded unit at a time, so styling
//     a streamed chunk and styling the final answer produce the same text
//     (spoken = displayed = remembered). Style rules must never span a unit boundary.
//   - Fail-closed to meaning: every styled unit is checked by
//     `PalestinianStyleInvariants`; any violation keeps the original unit.
//
//  Phase 1: `restyle` is intentionally the identity. The reviewed Palestinian phrase
//  table (user-approved; preferred variant "هلأ") lands behind this seam in Phase 2.
//

import Foundation

enum PalestinianConversationalStyler {

    /// Restyles ONE punctuation-bounded unit. Phase 1: identity — no reviewed rules yet.
    static func restyle(_ sentenceUnit: String) -> String {
        sentenceUnit
    }

    /// The user-facing form of `text` (an answer, or a sentence-bounded streamed chunk).
    ///
    /// - Parameters:
    ///   - protectedTerms: terms that must survive verbatim (e.g. an Arabic app name the
    ///     structured result explicitly named); Latin tokens, numbers, paths, URLs, codes
    ///     and quoted text are protected automatically.
    ///   - styleUnit: the per-unit style function. Defaults to `restyle`; tests inject
    ///     hostile functions to prove the invariant guard.
    static func presentationText(
        for text: String,
        protectedTerms: [String] = [],
        styleUnit: (String) -> String = restyle
    ) -> String {
        splitIntoStyleUnits(text).map { unit in
            let styledUnit = styleUnit(unit)
            let isMeaningPreserved = PalestinianStyleInvariants.violations(
                original: unit,
                styled: styledUnit,
                protectedTerms: protectedTerms
            ).isEmpty
            return isMeaningPreserved ? styledUnit : unit
        }.joined()
    }

    /// Punctuation that ends a style unit: the streaming pipeline's sentence AND clause
    /// terminators, so every chunk the pipeline dispatches is a whole number of units.
    static let unitTerminators: Set<Character> = [".", "!", "?", "؟", "\n", ",", ";", "—", ":", "،", "؛"]

    /// Splits `text` into units, each ending with a terminator that is followed by
    /// whitespace or the end of the text (the pipeline's own boundary rule, so "3.14",
    /// "v2.5" and "~/.ssh" never split), plus that trailing whitespace. Concatenating the
    /// units reproduces `text` exactly.
    static func splitIntoStyleUnits(_ text: String) -> [String] {
        var units: [String] = []
        var currentUnit = ""
        var isJustAfterTerminator = false
        var isInTrailingWhitespaceAfterTerminator = false
        for character in text {
            if isInTrailingWhitespaceAfterTerminator && !character.isWhitespace {
                units.append(currentUnit)
                currentUnit = ""
                isInTrailingWhitespaceAfterTerminator = false
            }
            if isJustAfterTerminator {
                isJustAfterTerminator = false
                if character.isWhitespace {
                    isInTrailingWhitespaceAfterTerminator = true
                }
            }
            currentUnit.append(character)
            if unitTerminators.contains(character) && !isInTrailingWhitespaceAfterTerminator {
                isJustAfterTerminator = true
            }
        }
        if !currentUnit.isEmpty {
            units.append(currentUnit)
        }
        return units
    }
}
