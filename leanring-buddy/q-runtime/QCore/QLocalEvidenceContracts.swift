//
//  QLocalEvidenceContracts.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 3 (Verified Response Path), third slice: shared contracts for
//  bounded LOCAL evidence collection.
//
//      Structured Answer Request
//            ↓
//      Local Evidence Collector (QMemoryEvidenceCollector / QFileEvidenceCollector, this slice)
//            ↓
//      QEvidenceDraft(s)                    ← untrusted DATA, never instructions
//            ↓
//      QEvidencePool                        ← unchanged; sole authority over trust (Phase 2C)
//            ↓
//      existing verification / critic / synthesis (unchanged)
//            ↓
//      QVerifiedResponse (Phase 3 slice 1, unchanged)
//
//  A collector is an EVIDENCE PRODUCER ONLY:
//   - it never decides truth, never raises trust, never verifies its own output — those remain
//     `QEvidencePool`'s job exactly as in Phase 2C; nothing here writes to `QEvidenceItem.trust` or
//     `.verification`, and no draft this slice builds ever carries `initialVerification: .verified`;
//   - it never executes an action, never reaches the network, and never touches
//     `QPermissionGate`/`QResourceGuard`'s execution authority or the egress broker (there is no
//     network egress path here to mediate: this slice performs zero network I/O of any kind);
//   - retrieved content — memory or a local file — is DATA, never instructions. An instruction-shaped
//     line ("ignore previous instructions", "run this command", "approve this action") is flagged and
//     skipped by the existing Phase 2C claim extractor exactly as any other retrieved evidence is;
//     nothing here gives such text a path to permissions, execution, egress, or backend selection;
//   - collection is opt-in and OFF by default (`QLocalEvidenceCollectionConfiguration`), wired only
//     into the Phase 3 structured-answer pipeline run — never the primary run whose metadata feeds
//     outcome learning, and never a new persistence path: the Evidence Pool remains transient and
//     in-memory, exactly as in Phase 2C. Collected evidence is never automatically written back to
//     memory — verified-memory write-back (slice 1) stays a wholly separate, opt-in, verification-
//     gated operation that a collector cannot trigger merely by finding something.
//

import Foundation

// MARK: - Configuration (default OFF)

/// Opt-in for local evidence collection inside the Phase 3 structured-answer pipeline run. Default:
/// disabled — with no configuration, no memory query and no file read happens.
public struct QLocalEvidenceCollectionConfiguration: Sendable, Equatable {
    public let isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public static let disabled = QLocalEvidenceCollectionConfiguration(isEnabled: false)
}

// MARK: - Bounds

/// Conservative, source-level constants — never derived from model output or task parameters. The
/// pool's own `QEvidenceLimits.maxEvidenceItems` (64) remains the final, authoritative cap on total
/// evidence regardless of anything below.
public enum QLocalEvidenceLimits {
    public static let maxMemoryEvidenceRecords = 20
    public static let maxSelectedFilesPerRequest = 5
    public static let maxFileSizeBytes = 10 * 1024 * 1024
    public static let maxExtractedCharactersPerFile = 50_000
    public static let maxTotalExtractedCharacters = 100_000

    /// Extensions this slice can safely decode without any third-party or from-scratch parser: plain
    /// UTF-8 text only. Anything else (PDF, DOCX, images, …) is an explicit unsupported-format
    /// outcome — never guessed, never partially parsed.
    public static let allowedPlainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "log", "json", "yaml", "yml"
    ]
}

// MARK: - Selected file (minimal, explicit-authorization contract)

/// A file the CALLER has already explicitly selected — e.g. via a native Open panel presented
/// entirely outside Q's own code. Constructing this value IS the authorization boundary for this
/// slice: nothing in this codebase presents a file picker, resolves a security-scoped bookmark, or
/// otherwise decides what counts as "selected". The collector itself never walks a directory, never
/// expands a folder, and never accepts anything the caller did not name explicitly here.
public struct QSelectedFileHandle: Sendable, Equatable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

// MARK: - Composite collector

/// Combines several collectors into the single `QEvidenceCollector` the pipeline's
/// `QEvidencePipelineInput.collector` slot accepts. A failing sub-collector contributes nothing and
/// is skipped — one collector's failure never blacks out another's evidence — but cancellation of
/// the composite still propagates immediately, so nothing keeps running after the caller cancels.
public struct QCompositeEvidenceCollector: QEvidenceCollector {
    private let collectors: [any QEvidenceCollector]

    public init(_ collectors: [any QEvidenceCollector]) {
        self.collectors = collectors
    }

    public func collect(taskId: String, limit: Int) async throws -> [QEvidenceDraft] {
        var combined: [QEvidenceDraft] = []
        for collector in collectors {
            try Task.checkCancellation()
            let remaining = limit - combined.count
            guard remaining > 0 else { break }
            do {
                let drafts = try await collector.collect(taskId: taskId, limit: remaining)
                combined.append(contentsOf: drafts.prefix(remaining))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return combined
    }
}
