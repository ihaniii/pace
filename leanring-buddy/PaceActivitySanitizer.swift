//
//  PaceActivitySanitizer.swift
//  leanring-buddy
//
//  Phase 4.7E — Privacy-preserving sanitization for Q-Core Current Activity subjects.
//  Enforces strict bounds: no raw JSON, no credentials, no URLs, no screen coordinates,
//  no multi-line conversation context, and hard maximum character limits.
//

import Foundation

public enum PaceActivitySanitizer {
    /// Strict upper bound for Current Activity subject display length.
    public static let maximumSubjectLength: Int = 80

    /// Sanitizes raw user prompts or plan step descriptions into a clean, bounded,
    /// privacy-safe subject string suitable for Current Activity / Now projection.
    public static func sanitizeSubject(_ rawInput: String) -> String {
        var text = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Q Task" }

        // Strip leading markdown code blocks e.g. ```json or ```
        if text.hasPrefix("```") {
            let lines = text.components(separatedBy: .newlines)
            let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            text = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Take only the first non-empty line
        let firstLine = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        guard !firstLine.isEmpty else { return "Q Task" }

        // If it starts with JSON syntax or resembles raw planner JSON, redact to safe generic label
        if firstLine.hasPrefix("{") || firstLine.hasPrefix("[") ||
           firstLine.contains("\"action\":") || firstLine.contains("\"parameters\":") ||
           firstLine.contains("\"literalAction\":") || firstLine.contains("\"toolName\":") ||
           firstLine.contains("\"thought\":") {
            return "Structured Action"
        }

        var sanitized = firstLine

        // Redact URLs (http://, https://, www.)
        if let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s]+|www\.[^\s]+"#, options: .caseInsensitive) {
            sanitized = urlRegex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: NSRange(location: 0, length: sanitized.utf16.count),
                withTemplate: "[URL]"
            )
        }

        // Redact credentials, API keys, tokens, and passwords
        let credentialPatterns = [
            #"(?i)bearer\s+[a-zA-Z0-9_\-\.]+"#,
            #"(?i)(password|passwd|pwd|token|api[_-]?key|secret)\s*[:=]\s*[^\s]+"#,
            #"(?i)ghp_[a-zA-Z0-9]+"#,
            #"(?i)sk-[a-zA-Z0-9]+"#
        ]
        for pattern in credentialPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                sanitized = regex.stringByReplacingMatches(
                    in: sanitized,
                    options: [],
                    range: NSRange(location: 0, length: sanitized.utf16.count),
                    withTemplate: "[REDACTED]"
                )
            }
        }

        // Strip raw screen coordinates / UI coordinate dumps e.g. "(120, 450)" or "{x: 100, y: 200}"
        if let coordRegex = try? NSRegularExpression(pattern: #"(\(\s*\d+\s*,\s*\d+\s*\)|\{\s*x:?\s*\d+\s*,\s*y:?\s*\d+\s*\})"#, options: .caseInsensitive) {
            sanitized = coordRegex.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: NSRange(location: 0, length: sanitized.utf16.count),
                withTemplate: ""
            )
        }

        // Strip trailing punctuation
        while sanitized.hasSuffix(".") || sanitized.hasSuffix(";") || sanitized.hasSuffix(",") {
            sanitized.removeLast()
            sanitized = sanitized.trimmingCharacters(in: .whitespaces)
        }

        // Hard truncation to maximumSubjectLength
        if sanitized.count > maximumSubjectLength {
            sanitized = String(sanitized.prefix(maximumSubjectLength)).trimmingCharacters(in: .whitespaces)
        }

        return sanitized.isEmpty ? "Q Task" : sanitized
    }
}
