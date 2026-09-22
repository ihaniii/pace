//
//  QFileEvidenceCollector.swift
//  leanring-buddy
//
//  Q × Pace Decision Engine — Phase 3 (Verified Response Path), third slice: the Local File Evidence
//  Collector. Reads ONLY files the caller explicitly named via `QSelectedFileHandle` — never a
//  directory listing, never a scan of Desktop/Documents/Downloads/home/iCloud/any mounted volume.
//
//  Deliberately narrow, matching this slice's spec exactly:
//   - explicit selection only. There is no code path anywhere in this file (or reachable from it)
//     that enumerates a directory; `FileManager.fileExists`/`attributesOfItem`/`Data(contentsOf:)`
//     are used on the SUPPLIED path and nothing else;
//   - `QResourceGuard.validate(path:)` (the existing absolute-denylist + sensitive-filename/extension
//     check — Phase 1c.4, unmodified) is re-applied as defense in depth even though the caller
//     already "selected" the path: a confused caller or a misdirected selection must still never
//     reach `~/.ssh`, a credential-store file, `.env`, etc.;
//   - only genuinely plain-text formats are extracted (`QLocalEvidenceLimits.allowedPlainTextExtensions`,
//     strict UTF-8 decode only — no encoding fallback, no third-party parser, no from-scratch
//     PDF/DOCX/OCR). Anything else is an explicit, typed `.unsupportedFormat` outcome; a decode
//     failure is `.decodeFailed`. Neither is ever guessed past;
//   - every bound (file count, byte size, per-file and total extracted characters) is enforced BEFORE
//     the corresponding read happens where practical, and is reported per-file via `QFileEvidenceResult`
//     — nothing is silently and invisibly truncated;
//   - the read content is DATA, never instructions, and it is TRANSIENT: it exists only long enough to
//     become a `QEvidenceDraft`'s `content` (which the Evidence Pool hashes and bounds on ingestion,
//     exactly like any other retrieved evidence — Phase 2C, unmodified); this collector persists
//     nothing itself, and the evidence pool it feeds is transient/in-memory, never a second database;
//   - `path` never appears in an evidence draft's provenance (`.untrustedFile(path: nil)`, always
//     `nil`) or its metadata — only the bare filename (bounded, credential-redacted) does, for
//     traceability, and even that is metadata, never content the claim extractor scans as prose;
//   - this collector never sets `trust`/`verification` and never calls anything execution-, egress-,
//     or permission-related — it only ever returns `QEvidenceDraft`s, exactly like
//     `QMemoryEvidenceCollector`.
//

import Foundation

// MARK: - Per-file outcome

public enum QFileEvidenceStatus: Sendable, Equatable {
    case included
    case emptyPath
    case rejectedPath(reason: String)
    case notARegularFile
    case tooLarge(sizeBytes: Int)
    case unsupportedFormat(fileExtension: String)
    case decodeFailed
    /// Beyond `QLocalEvidenceLimits.maxSelectedFilesPerRequest` or the pipeline's remaining capacity
    /// for this collection call — the handle was never even opened.
    case skippedOverLimit
    /// The total-extracted-character budget was already spent by earlier handles in this same call.
    case skippedBudgetExhausted
}

/// One handle's outcome. `path` is transient (present only for caller/test introspection of what
/// happened to each supplied handle) and is never itself placed in any persisted structure.
public struct QFileEvidenceResult: Sendable, Equatable {
    public let path: String
    public let status: QFileEvidenceStatus
    public let truncated: Bool
    public let extractedCharacterCount: Int
}

// MARK: - Collector

public struct QFileEvidenceCollector: QEvidenceCollector {
    public let handles: [QSelectedFileHandle]
    private let fileManager: FileManager

    public init(handles: [QSelectedFileHandle], fileManager: FileManager = .default) {
        self.handles = handles
        self.fileManager = fileManager
    }

    public func collect(taskId: String, limit: Int) async throws -> [QEvidenceDraft] {
        try Task.checkCancellation()
        return Self.process(handles: handles, taskId: taskId, limit: limit, fileManager: fileManager).drafts
    }

    /// Pure and synchronous (no `async` boundary needed for local, bounded reads), so it is directly
    /// unit-testable without a running pipeline. `limit` bounds how many drafts this call may
    /// produce — independent of, and in addition to, `QLocalEvidenceLimits.maxSelectedFilesPerRequest`.
    public static func process(
        handles: [QSelectedFileHandle],
        taskId: String,
        limit: Int,
        fileManager: FileManager = .default
    ) -> (drafts: [QEvidenceDraft], results: [QFileEvidenceResult]) {
        var drafts: [QEvidenceDraft] = []
        var results: [QFileEvidenceResult] = []
        var totalExtractedCharacters = 0

        for (index, handle) in handles.enumerated() {
            guard index < QLocalEvidenceLimits.maxSelectedFilesPerRequest, drafts.count < limit else {
                results.append(QFileEvidenceResult(path: handle.path, status: .skippedOverLimit, truncated: false, extractedCharacterCount: 0))
                continue
            }

            let trimmedPath = handle.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else {
                results.append(QFileEvidenceResult(path: handle.path, status: .emptyPath, truncated: false, extractedCharacterCount: 0))
                continue
            }

            // Defense in depth: the existing path-jail/denylist, unmodified. A "selected" path still
            // cannot reach a credential file or a protected system directory.
            let validation = QResourceGuard.validate(path: trimmedPath)
            guard case .allowed(let canonicalPath) = validation else {
                let reason: String
                if case .denied(let denyReason, _) = validation { reason = denyReason } else { reason = "denied" }
                results.append(QFileEvidenceResult(path: trimmedPath, status: .rejectedPath(reason: reason), truncated: false, extractedCharacterCount: 0))
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: canonicalPath, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let attributes = try? fileManager.attributesOfItem(atPath: canonicalPath),
                  (attributes[.type] as? FileAttributeType) == .typeRegular else {
                results.append(QFileEvidenceResult(path: canonicalPath, status: .notARegularFile, truncated: false, extractedCharacterCount: 0))
                continue
            }

            let sizeBytes = (attributes[.size] as? Int) ?? Int.max
            guard sizeBytes <= QLocalEvidenceLimits.maxFileSizeBytes else {
                results.append(QFileEvidenceResult(path: canonicalPath, status: .tooLarge(sizeBytes: sizeBytes), truncated: false, extractedCharacterCount: 0))
                continue
            }

            let fileExtension = (canonicalPath as NSString).pathExtension.lowercased()
            guard QLocalEvidenceLimits.allowedPlainTextExtensions.contains(fileExtension) else {
                results.append(QFileEvidenceResult(path: canonicalPath, status: .unsupportedFormat(fileExtension: fileExtension), truncated: false, extractedCharacterCount: 0))
                continue
            }

            guard totalExtractedCharacters < QLocalEvidenceLimits.maxTotalExtractedCharacters else {
                results.append(QFileEvidenceResult(path: canonicalPath, status: .skippedBudgetExhausted, truncated: false, extractedCharacterCount: 0))
                continue
            }

            // Strict UTF-8 only — never guessed past. A bounded read (size already checked above).
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: canonicalPath), options: [.mappedIfSafe]),
                  let fullText = String(data: data, encoding: .utf8) else {
                results.append(QFileEvidenceResult(path: canonicalPath, status: .decodeFailed, truncated: false, extractedCharacterCount: 0))
                continue
            }

            let remainingTotalBudget = QLocalEvidenceLimits.maxTotalExtractedCharacters - totalExtractedCharacters
            let perFileBudget = min(QLocalEvidenceLimits.maxExtractedCharactersPerFile, remainingTotalBudget)
            let extracted = String(fullText.prefix(perFileBudget))
            let wasTruncated = fullText.count > extracted.count
            totalExtractedCharacters += extracted.count

            let filename = (canonicalPath as NSString).lastPathComponent
            // Deterministic given the same file: filename + size + a hash of the (bounded) extracted
            // content — never a random UUID, never dependent on collection order or wall-clock time.
            let identity = QEvidenceText.shortHash([filename, String(sizeBytes), QEvidenceText.sha256Hex(extracted)])

            drafts.append(
                QEvidenceDraft(
                    taskId: taskId,
                    sourceId: "file-" + identity,
                    kind: .retrievedExternal,
                    provenance: .untrustedFile(path: nil),
                    content: extracted,
                    metadata: [
                        "filename": QEvidenceText.boundedSafe(filename, maxCharacters: 64),
                        "extension": fileExtension,
                        "sizeBytes": String(sizeBytes),
                        "truncated": String(wasTruncated)
                    ]
                )
            )
            results.append(QFileEvidenceResult(path: canonicalPath, status: .included, truncated: wasTruncated, extractedCharacterCount: extracted.count))
        }

        return (drafts, results)
    }
}
