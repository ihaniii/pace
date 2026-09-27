//
//  QAuditLogger.swift
//  leanring-buddy
//
//  Q Security Architecture — Append-Only Local Audit Log & Secret Redactor (Phase 1c.5).
//  Records structured audit events with cryptographic argument hashing and
//  aggressive pattern-based secret redaction (API keys, private keys, passwords).
//

import Foundation
import CryptoKit

// MARK: - Secret Redactor

public enum QSecretRedactor {

    private static let secretRegexes: [NSRegularExpression] = [
        // OpenAI / Anthropic / Generic AI API Keys
        try! NSRegularExpression(pattern: #"(sk-[a-zA-Z0-9_-]{20,})"#, options: []),
        try! NSRegularExpression(pattern: #"(ant-[a-zA-Z0-9_-]{20,})"#, options: []),
        // Google AI Studio / Cloud Keys
        try! NSRegularExpression(pattern: #"(AIza[0-9A-Za-z-_]{35})"#, options: []),
        // GitHub Personal Access Tokens
        try! NSRegularExpression(pattern: #"(ghp_[a-zA-Z0-9]{36})"#, options: []),
        try! NSRegularExpression(pattern: #"(github_pat_[a-zA-Z0-9_]{40,})"#, options: []),
        // Slack Tokens
        try! NSRegularExpression(pattern: #"(xox[baprs]-[0-9A-Za-z-]+)"#, options: []),
        // Bearer Authorization Headers
        try! NSRegularExpression(pattern: #"(?i)Bearer\s+([a-zA-Z0-9_\-\.]{15,})"#, options: []),
        // PEM Private Keys (RSA, EC, PKCS8)
        try! NSRegularExpression(pattern: #"-----BEGIN [A-Z ]+ PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+ PRIVATE KEY-----"#, options: []),
        // Generic Password / Secret / Token assignments in JSON, YAML, or CLI args
        try! NSRegularExpression(pattern: #"(?i)["']?(password|secret|token|api_?key)["']?\s*[:=]\s*["']?([^\s"',;]+)["']?"#, options: [])
    ]

    /// Redacts all detected credentials, private keys, and tokens from the string.
    public static func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var result = input

        for regex in secretRegexes {
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length))
            // Replace in reverse order to preserve string indices
            for match in matches.reversed() {
                let matchRange = match.range
                if match.numberOfRanges > 1 && match.range(at: match.numberOfRanges - 1).location != NSNotFound {
                    // Replace the captured secret group
                    let secretRange = match.range(at: match.numberOfRanges - 1)
                    result = (result as NSString).replacingCharacters(in: secretRange, with: "[REDACTED_SECRET]")
                } else {
                    // Replace entire match (e.g. PEM block)
                    result = (result as NSString).replacingCharacters(in: matchRange, with: "[REDACTED_SECRET]")
                }
            }
        }

        return result
    }
}

// MARK: - Audit Record

public struct QAuditRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let sessionId: String
    public let taskId: String
    public let tool: String
    public let capabilityId: UUID?
    public let riskLevel: QCapabilityLevel
    public let argumentsHash: String
    public let authorizationResult: String
    public let provenance: String
    public let executionSummary: String?
    public let error: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionId: String,
        taskId: String,
        tool: String,
        capabilityId: UUID? = nil,
        riskLevel: QCapabilityLevel,
        rawArguments: String,
        authorizationResult: String,
        provenance: String,
        executionSummary: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.taskId = taskId
        self.tool = tool
        self.capabilityId = capabilityId
        self.riskLevel = riskLevel

        // Hash arguments with SHA-256 so raw arguments with sensitive info are not stored plaintext
        let digest = SHA256.hash(data: Data(rawArguments.utf8))
        self.argumentsHash = digest.map { String(format: "%02hhx", $0) }.joined()

        self.authorizationResult = authorizationResult
        self.provenance = provenance
        self.executionSummary = executionSummary.map { Self.boundedSafeField(QSecretRedactor.redact($0)) }
        self.error = error.map { Self.boundedSafeField(QSecretRedactor.redact($0)) }
    }

    /// Audit records must carry safe, bounded metadata — never near-verbatim
    /// user content. `QSecretRedactor.redact` only strips *credential-shaped*
    /// substrings (API keys, PEM blocks, password/token assignments) by its
    /// own design; it cannot and does not generically identify arbitrary
    /// sensitive free text. Confirmed in production: `screen.ocr` and
    /// `agent.completed` entries reached 2,000-5,000+ characters of
    /// near-verbatim OCR'd screen text / spoken response text, none of which
    /// is credential-shaped and so passed the redactor unchanged.
    ///
    /// This is the second, independent guard: redact first (so a credential
    /// pattern anywhere in the string is still caught before truncation could
    /// cut it in half), then hard-cap the length. A truncated field keeps a
    /// short, genuinely useful prefix for a human skimming the log, plus a
    /// SHA-256 hash of the FULL (post-redaction) string and its original
    /// length — real forensic value (an investigator can confirm two records
    /// came from identical content, or match a hash against other evidence)
    /// without ever persisting the sensitive content itself.
    private static let maxAuditFieldCharacterCount = 200

    private static func boundedSafeField(_ redactedValue: String) -> String {
        guard redactedValue.count > maxAuditFieldCharacterCount else { return redactedValue }
        let visiblePrefix = String(redactedValue.prefix(maxAuditFieldCharacterCount))
        let fullContentDigest = SHA256.hash(data: Data(redactedValue.utf8))
        let fullContentHash = fullContentDigest.map { String(format: "%02hhx", $0) }.joined()
        return "\(visiblePrefix)… [truncated: \(redactedValue.count) chars total, sha256=\(fullContentHash)]"
    }

    /// For call sites that KNOW they're about to hand audit logging a
    /// specific, named category of user content that must never appear even
    /// as a truncated excerpt (raw OCR/screen text, raw model prompts or
    /// responses, raw document contents) — construct a pure-metadata
    /// descriptor instead, up front, rather than relying on
    /// `boundedSafeField`'s generic truncate-and-hash backstop to catch it
    /// after the fact. Both use the identical hash/length evidence shape so
    /// there is exactly one "how do we describe omitted content" pattern in
    /// this codebase, not two competing ones.
    public static func safeDescriptor(omittedContent content: String, label: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        let hash = digest.map { String(format: "%02hhx", $0) }.joined()
        return "[\(label) omitted from audit log — \(content.count) chars, sha256=\(hash)]"
    }
}

// MARK: - Audit Logger

public final class QAuditLogger: @unchecked Sendable {
    public static let shared = QAuditLogger()

    private let lock = NSLock()
    private var inMemoryRecords: [QAuditRecord] = []
    private let maxMemoryRecords = 1000
    private let logFileURL: URL?

    /// Bounded rotation: confirmed in production that this file grows
    /// without limit otherwise (reached ~717 MB / 1.58M lines from ordinary
    /// use). 25 MB keeps each file a manageable size for review while
    /// `maxRotatedFileCount` retains a bounded amount of real history for
    /// genuine forensic value — this is retention, not deletion-on-write.
    private let maxLogFileSizeBytes = 25 * 1024 * 1024
    private let maxRotatedFileCount = 3

    public init(customLogURL: URL? = nil) {
        // Only the default (no custom URL) path can ever be redirected. In
        // Release builds `testHostLogDestinationForCurrentProcess()` is
        // compiled down to `.notRunningUnderTestHost`, so production always
        // falls through to the unchanged production branch below.
        let testHostLogDestination: QAuditTestHostLogDestination = customLogURL == nil
            ? Self.testHostLogDestinationForCurrentProcess()
            : .notRunningUnderTestHost

        if let custom = customLogURL {
            self.logFileURL = custom
        } else if case .isolatedTemporaryLog(let isolatedLogFileURL) = testHostLogDestination {
            self.logFileURL = isolatedLogFileURL
        } else if case .memoryOnly(let memoryOnlyReason) = testHostLogDestination {
            // Inside a test host but isolation could not be proven safe:
            // keep auditing in memory only. Never fall back to production.
            print("🛡️ QAuditLogger: test-host audit isolation unavailable (\(memoryOnlyReason)) — audit records are memory-only for this process")
            self.logFileURL = nil
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let paceDir = appSupport?.appendingPathComponent("Pace", isDirectory: true)
            if let paceDir = paceDir {
                try? FileManager.default.createDirectory(at: paceDir, withIntermediateDirectories: true)
                self.logFileURL = paceDir.appendingPathComponent("q-audit.log")
            } else {
                self.logFileURL = nil
            }
        }
    }

    public func record(_ record: QAuditRecord) {
        lock.lock()
        defer { lock.unlock() }

        inMemoryRecords.append(record)
        if inMemoryRecords.count > maxMemoryRecords {
            inMemoryRecords.removeFirst(inMemoryRecords.count - maxMemoryRecords)
        }

        // Append line to disk if log file is configured
        if let logFileURL = logFileURL {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(record)
                if let line = String(data: data, encoding: .utf8) {
                    let logLine = line + "\n"
                    if let lineData = logLine.data(using: .utf8) {
                        // Rotation happens BEFORE the write, and is itself
                        // entirely best-effort (every step uses `try?`): if
                        // any step fails (e.g. a rename fails), the original
                        // file is simply left in place and the write below
                        // still proceeds against it. Auditing itself must
                        // never stop just because rotation couldn't.
                        rotateLogFileIfNeeded(at: logFileURL)

                        if FileManager.default.fileExists(atPath: logFileURL.path) {
                            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                                handle.seekToEndOfFile()
                                handle.write(lineData)
                                handle.closeFile()
                            }
                        } else {
                            try? lineData.write(to: logFileURL, options: .atomic)
                            // Owner-only: this file can carry redacted-but-
                            // still-meaningful operational text (see
                            // boundedSafeField). Applied on every fresh file
                            // (first-ever creation and every post-rotation
                            // recreation) so rotated logs never regress to
                            // more permissive default bits.
                            try? FileManager.default.setAttributes(
                                [.posixPermissions: 0o600],
                                ofItemAtPath: logFileURL.path
                            )
                        }
                    }
                }
            } catch {
                // Fail-safe: Audit file writing error must not crash the agent
            }
        }
    }

    /// Best-effort size-bounded rotation. Every filesystem operation here
    /// uses `try?` deliberately: a failure at any step (permissions, disk
    /// full, concurrent access) must leave the existing log file usable and
    /// must never throw out of `record()` — rotation failing is acceptable,
    /// auditing failing is not.
    private func rotateLogFileIfNeeded(at logFileURL: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let currentFileSize = attributes[.size] as? Int,
              currentFileSize >= maxLogFileSizeBytes
        else {
            return
        }

        let fileManager = FileManager.default

        // Drop whatever is at the oldest retained slot, then shift every
        // remaining rotated file up by one, oldest first, so no rename ever
        // overwrites a file still holding real history.
        let oldestRetainedPath = "\(logFileURL.path).\(maxRotatedFileCount)"
        try? fileManager.removeItem(atPath: oldestRetainedPath)

        var index = maxRotatedFileCount - 1
        while index >= 1 {
            let sourcePath = "\(logFileURL.path).\(index)"
            let destinationPath = "\(logFileURL.path).\(index + 1)"
            if fileManager.fileExists(atPath: sourcePath) {
                try? fileManager.moveItem(atPath: sourcePath, toPath: destinationPath)
            }
            index -= 1
        }

        let firstRotatedPath = "\(logFileURL.path).1"
        try? fileManager.moveItem(atPath: logFileURL.path, toPath: firstRotatedPath)
        // Preserve the same restrictive permissions on the rotated-out file
        // — it still holds real (redacted, bounded) audit content.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: firstRotatedPath)
    }

    /// Read-only view of where this logger persists records (`nil` means
    /// memory-only). Exists so tests can prove the test-host logger never
    /// points at the production `q-audit.log`.
    nonisolated var persistedLogFileURL: URL? {
        logFileURL
    }

    public func getRecentRecords(limit: Int = 100) -> [QAuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        let count = min(limit, inMemoryRecords.count)
        return Array(inMemoryRecords.suffix(count))
    }

    public func clearMemory() {
        lock.lock()
        defer { lock.unlock() }
        inMemoryRecords.removeAll()
    }
}

// MARK: - Test-Host Audit Isolation

/// Where the default (`customLogURL == nil`) logger writes when the process
/// might be an XCTest host. Unit tests run inside Pace.app as their test host,
/// and the host's own launch bootstraps the Q runtime (which touches
/// `QAuditLogger.shared`) before any test code can run — so isolation has to be
/// decided here, at construction, not from a test-side hook.
nonisolated enum QAuditTestHostLogDestination: Equatable, Sendable {
    /// No test-host signal at all: the unchanged production path is used.
    case notRunningUnderTestHost
    /// A validated, freshly-created, per-process temporary audit log.
    case isolatedTemporaryLog(URL)
    /// A test-host signal is present but isolation could not be proven safe.
    /// Records stay in memory; the production log is never used.
    case memoryOnly(reason: String)
}

extension QAuditLogger {

    /// Markers Xcode sets in the environment of a unit-test host process.
    /// Older toolchains put an absolute `.xctestconfiguration` path in
    /// `XCTestConfigurationFilePath`; current ones leave that key present but
    /// EMPTY and identify the run with a UUID in `XCTestSessionIdentifier`.
    /// Either well-formed marker is accepted; an empty/relative path or a
    /// non-UUID session id is not. `leanring_buddyApp.swift` also keys its
    /// test-host detection off `XCTestConfigurationFilePath` being present.
    nonisolated static let xcTestConfigurationEnvironmentMarkerKey = "XCTestConfigurationFilePath"
    nonisolated static let xcTestSessionIdentifierEnvironmentMarkerKey = "XCTestSessionIdentifier"

    /// Any of these means "this process is (probably) an XCTest host", even if
    /// neither marker above is well-formed. Their presence alone is enough to
    /// refuse the production log; it is never enough to pick a disk
    /// destination.
    nonisolated static let secondaryTestHostEnvironmentSignalKeys = [
        "XCTestBundlePath",
        "XCTestSessionIdentifier",
        "XCInjectBundleInto"
    ]

    nonisolated static let isolatedTestAuditDirectoryNamePrefix = "pace-test-q-audit-"

    /// The production default location, computed without creating anything.
    /// Must stay in sync with the production branch of `init(customLogURL:)`;
    /// used here only to reject test destinations that would land on it.
    nonisolated static func productionDefaultLogFileURL(applicationSupportDirectoryURL: URL) -> URL {
        applicationSupportDirectoryURL
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("q-audit.log")
    }

    /// Reads the real process state. Debug-only: Release builds never consult
    /// the environment and always use the production path.
    nonisolated private static func testHostLogDestinationForCurrentProcess() -> QAuditTestHostLogDestination {
        #if DEBUG
        return resolveTestHostLogDestination(
            environment: ProcessInfo.processInfo.environment,
            isXCTestRuntimeLoaded: NSClassFromString("XCTestCase") != nil,
            temporaryRootDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            applicationSupportDirectoryURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            uniqueToken: UUID().uuidString
        )
        #else
        return .notRunningUnderTestHost
        #endif
    }

    /// Pure decision (apart from creating the isolated directory) so tests can
    /// drive every branch with fake roots. Once any test-host signal is seen,
    /// every failure returns `.memoryOnly` — there is no path from here back to
    /// the production log.
    nonisolated static func resolveTestHostLogDestination(
        environment: [String: String],
        isXCTestRuntimeLoaded: Bool,
        temporaryRootDirectoryURL: URL,
        applicationSupportDirectoryURL: URL?,
        homeDirectoryURL: URL,
        processIdentifier: Int32,
        uniqueToken: String
    ) -> QAuditTestHostLogDestination {
        let fileManager = FileManager.default

        let hasPrimaryMarkerKey = environment[xcTestConfigurationEnvironmentMarkerKey] != nil
        let hasSecondaryEnvironmentSignal = secondaryTestHostEnvironmentSignalKeys.contains { environment[$0] != nil }
        let hasInjectedXCTestLibrary = environment["DYLD_INSERT_LIBRARIES"]?.contains("XCTest") ?? false
        guard hasPrimaryMarkerKey || hasSecondaryEnvironmentSignal || hasInjectedXCTestLibrary || isXCTestRuntimeLoaded else {
            return .notRunningUnderTestHost
        }

        // From here on this is (probably) a test host. Fail closed.

        let configurationFilePathMarker = environment[xcTestConfigurationEnvironmentMarkerKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasValidConfigurationFilePathMarker = configurationFilePathMarker.hasPrefix("/")
        let sessionIdentifierMarker = environment[xcTestSessionIdentifierEnvironmentMarkerKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasValidSessionIdentifierMarker = UUID(uuidString: sessionIdentifierMarker) != nil
        guard hasValidConfigurationFilePathMarker || hasValidSessionIdentifierMarker else {
            return .memoryOnly(reason: "XCTest marker missing or invalid")
        }

        guard let applicationSupportDirectoryURL else {
            return .memoryOnly(reason: "cannot locate Application Support to rule out the production path")
        }

        guard processIdentifier > 0 else {
            return .memoryOnly(reason: "invalid process identifier")
        }

        // The token becomes a path component: ASCII letters, digits, and
        // hyphens only, so it can never introduce `/` or `..`.
        let allowedTokenCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !uniqueToken.isEmpty, uniqueToken.allSatisfy({ allowedTokenCharacters.contains($0) }) else {
            return .memoryOnly(reason: "invalid unique token")
        }

        // Resolve symlinks up front so every containment check below compares
        // real locations — a temp root that is a symlink into Application
        // Support must be caught as Application Support.
        let resolvedTemporaryRootURL = temporaryRootDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        var temporaryRootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedTemporaryRootURL.path, isDirectory: &temporaryRootIsDirectory),
              temporaryRootIsDirectory.boolValue
        else {
            return .memoryOnly(reason: "temporary root does not exist or is not a directory")
        }

        guard resolvedTemporaryRootURL.pathComponents.count > 1 else {
            return .memoryOnly(reason: "temporary root resolves to the filesystem root")
        }

        let resolvedHomeDirectoryURL = homeDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedTemporaryRootURL.pathComponents != resolvedHomeDirectoryURL.pathComponents else {
            return .memoryOnly(reason: "temporary root resolves to the home directory")
        }

        let productionLogFileURL = productionDefaultLogFileURL(applicationSupportDirectoryURL: applicationSupportDirectoryURL)
        let productionAuditDirectoryURL = productionLogFileURL.deletingLastPathComponent()

        guard !isPath(resolvedTemporaryRootURL, equalToOrInside: applicationSupportDirectoryURL),
              !isPath(resolvedTemporaryRootURL, equalToOrInside: productionAuditDirectoryURL)
        else {
            return .memoryOnly(reason: "temporary root resolves into the production application data directory")
        }

        let isolatedDirectoryName = "\(isolatedTestAuditDirectoryNamePrefix)\(processIdentifier)-\(uniqueToken)"
        let isolatedDirectoryURL = resolvedTemporaryRootURL.appendingPathComponent(isolatedDirectoryName, isDirectory: true)

        // `withIntermediateDirectories: false` makes an existing item at this
        // path an error, so a collision can never reuse someone else's dir.
        do {
            try fileManager.createDirectory(
                at: isolatedDirectoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .memoryOnly(reason: "cannot create a fresh isolated audit directory")
        }

        // Re-validate what was actually created. `attributesOfItem` does not
        // follow a final symlink, so a swapped-in symlink is rejected here.
        guard let isolatedDirectoryAttributes = try? fileManager.attributesOfItem(atPath: isolatedDirectoryURL.path),
              isolatedDirectoryAttributes[.type] as? FileAttributeType == .typeDirectory
        else {
            return .memoryOnly(reason: "isolated audit directory is not a real directory")
        }

        let resolvedIsolatedDirectoryURL = isolatedDirectoryURL.resolvingSymlinksInPath()
        guard resolvedIsolatedDirectoryURL.pathComponents == resolvedTemporaryRootURL.pathComponents + [isolatedDirectoryName] else {
            return .memoryOnly(reason: "isolated audit directory escaped the temporary root")
        }

        let isolatedLogFileURL = resolvedIsolatedDirectoryURL.appendingPathComponent("q-audit.log")

        // A brand-new directory must be empty; anything already at the log
        // path (including a dangling symlink) is refused.
        guard (try? fileManager.attributesOfItem(atPath: isolatedLogFileURL.path)) == nil else {
            return .memoryOnly(reason: "isolated audit log path is already occupied")
        }

        guard isolatedLogFileURL.standardizedFileURL.path != productionLogFileURL.standardizedFileURL.path,
              !isPath(isolatedLogFileURL, equalToOrInside: productionAuditDirectoryURL),
              !isPath(isolatedLogFileURL, equalToOrInside: applicationSupportDirectoryURL)
        else {
            return .memoryOnly(reason: "isolated audit log resolves to the production location")
        }

        return .isolatedTemporaryLog(isolatedLogFileURL)
    }

    /// Component-wise containment (not string-prefix), after resolving
    /// symlinks on both sides, so `/a/bc` is never treated as inside `/a/b`.
    nonisolated private static func isPath(_ candidateURL: URL, equalToOrInside ancestorURL: URL) -> Bool {
        let candidatePathComponents = candidateURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let ancestorPathComponents = ancestorURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard candidatePathComponents.count >= ancestorPathComponents.count else { return false }
        return Array(candidatePathComponents.prefix(ancestorPathComponents.count)) == ancestorPathComponents
    }
}
