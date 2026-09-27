//
//  PaceMemoryStore.swift
//  leanring-buddy
//
//  On-device persistence for the unified memory index (see
//  docs/prds/unified-memory.md, Phase 1). The whole entry list — including
//  per-entry `[Float]` embeddings — is persisted as one atomic JSON file at
//  `~/Library/Application Support/Pace/memory-index.json`.
//
//  Mirrors `PaceThreadMemoryStore`: this is the ONLY thing that touches disk
//  for the memory index. `PaceMemoryIndex` stays I/O-free. Writes are atomic
//  (`Data.write(.atomic)` does temp-file + rename on the same volume) so a
//  crash mid-write can never leave a half-written index behind. A corrupt or
//  missing file loads as an empty list rather than throwing — memory must
//  never block launch.
//
//  Privacy: the file stays on this Mac and is removed by `clear()` on an
//  explicit reset — same on-device posture as the rest of Pace.
//

import Foundation

@MainActor
final class PaceMemoryStore {
    private let fileURL: URL?

    init() {
        // Unit tests run inside Pace.app as their test host; a test that
        // builds a CompanionManager must never load or overwrite the user's
        // real file. Test hosts get an isolated temp file, or no persistence
        // (nil) when isolation can't be proven safe. Release builds always
        // take the production path below.
        switch PaceTestHostDataIsolation.fileDestinationForCurrentProcess(relativePath: "memory-index.json") {
        case .isolatedTemporaryFile(let isolatedFileURL):
            fileURL = isolatedFileURL
            return
        case .isolationUnavailable:
            fileURL = nil
            return
        case .notRunningUnderTestHost:
            break
        }
        let applicationSupportRootURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        fileURL = applicationSupportRootURL?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("memory-index.json", isDirectory: false)
    }

    /// Read-only view of where this store persists (`nil` means it does
    /// not). Exists so tests can prove a test host never points at the
    /// user's real file.
    var persistedFileURL: URL? {
        fileURL
    }

    /// Load the persisted entries, or an empty list when nothing has been
    /// saved yet / the file is unreadable. A decode failure returns `[]`
    /// (start fresh) rather than throwing — a corrupt file must never block
    /// launch.
    func load() -> [PaceMemoryEntry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PaceMemoryEntry].self, from: data)) ?? []
    }

    /// Persist the current entry list. Best-effort: any failure is swallowed
    /// so a memory write never blocks or fails a user-facing turn. Creates
    /// the `Pace` support directory on first write.
    func save(_ entries: [PaceMemoryEntry]) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }

        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

}
