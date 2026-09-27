//
//  PaceTestHostAuditIsolation.swift
//  leanring-buddy
//
//  Keeps unit-test runs out of the user's real audit logs
//  (~/Library/Application Support/Pace/q-audit.log and api-audit.jsonl).
//
//  Unit tests run inside Pace.app as their test host, and runtime code
//  reaches the audit loggers' shared singletons long before (or without)
//  any test-side hook. So each logger's default initializer asks this
//  helper where it may write. The decision is made once per process:
//
//    • no test-host signal      → the logger's unchanged production path
//    • valid XCTest test host   → one validated, freshly-created temp
//                                 directory shared by every audit log in
//                                 this process
//    • test host, but isolation → the logger keeps nothing on disk
//      cannot be proven safe      (never the production path)
//
//  Release builds compile the test-host branch out and never consult the
//  environment.
//

import Foundation

/// Outcome of the once-per-process directory decision.
nonisolated enum PaceTestHostAuditDirectory: Equatable, Sendable {
    /// No test-host signal at all: loggers use their production paths.
    case notRunningUnderTestHost
    /// A validated, freshly-created, per-process temporary directory.
    case isolatedDirectory(URL)
    /// A test-host signal is present but isolation could not be proven safe.
    case unavailable(reason: String)
}

/// Where one specific audit log file should go.
nonisolated enum PaceTestHostLogDestination: Equatable, Sendable {
    /// No test-host signal at all: the logger's unchanged production path.
    case notRunningUnderTestHost
    /// A validated log file inside the per-process temporary directory.
    case isolatedTemporaryLog(URL)
    /// Inside a test host but isolation could not be proven safe. The logger
    /// must keep nothing on disk; the production log is never used.
    case isolationUnavailable(reason: String)
}

nonisolated enum PaceTestHostAuditIsolation {

    /// Markers Xcode sets in the environment of a unit-test host process.
    /// Older toolchains put an absolute `.xctestconfiguration` path in
    /// `XCTestConfigurationFilePath`; current ones leave that key present but
    /// EMPTY and identify the run with a UUID in `XCTestSessionIdentifier`.
    /// Either well-formed marker is accepted; an empty/relative path or a
    /// non-UUID session id is not. `leanring_buddyApp.swift` also keys its
    /// test-host detection off `XCTestConfigurationFilePath` being present.
    static let xcTestConfigurationEnvironmentMarkerKey = "XCTestConfigurationFilePath"
    static let xcTestSessionIdentifierEnvironmentMarkerKey = "XCTestSessionIdentifier"

    /// Any of these means "this process is (probably) an XCTest host", even if
    /// neither marker above is well-formed. Their presence alone is enough to
    /// refuse the production logs; it is never enough to pick a disk
    /// destination.
    static let secondaryTestHostEnvironmentSignalKeys = [
        "XCTestBundlePath",
        "XCTestSessionIdentifier",
        "XCInjectBundleInto"
    ]

    static let isolatedTestAuditDirectoryNamePrefix = "pace-test-audit-"

    /// The production directory that holds every Pace audit log, computed
    /// without creating anything. Used only to reject test destinations
    /// that would land on or inside it.
    static func productionAuditDirectoryURL(applicationSupportDirectoryURL: URL) -> URL {
        applicationSupportDirectoryURL.appendingPathComponent("Pace", isDirectory: true)
    }

    /// Computed once, lazily and thread-safely (Swift `static let`), on the
    /// first audit logger construction in this process — so every audit log
    /// in one test process shares one isolated directory and one decision.
    static let currentProcessAuditDirectory: PaceTestHostAuditDirectory = resolveCurrentProcessAuditDirectory()

    /// What a logger's default (no custom URL) initializer should use for
    /// `logFileName` in this process.
    static func logDestinationForCurrentProcess(logFileName: String) -> PaceTestHostLogDestination {
        resolveLogFile(
            named: logFileName,
            in: currentProcessAuditDirectory,
            applicationSupportDirectoryURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
    }

    /// Reads the real process state. Debug-only: Release builds never consult
    /// the environment and always use the production paths.
    private static func resolveCurrentProcessAuditDirectory() -> PaceTestHostAuditDirectory {
        #if DEBUG
        return resolveTestHostAuditDirectory(
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

    /// Convenience for tests: the directory decision followed by the per-file
    /// decision, driven entirely by injected (fake) roots.
    static func resolveTestHostLogDestination(
        logFileName: String,
        environment: [String: String],
        isXCTestRuntimeLoaded: Bool,
        temporaryRootDirectoryURL: URL,
        applicationSupportDirectoryURL: URL?,
        homeDirectoryURL: URL,
        processIdentifier: Int32,
        uniqueToken: String
    ) -> PaceTestHostLogDestination {
        let directoryDecision = resolveTestHostAuditDirectory(
            environment: environment,
            isXCTestRuntimeLoaded: isXCTestRuntimeLoaded,
            temporaryRootDirectoryURL: temporaryRootDirectoryURL,
            applicationSupportDirectoryURL: applicationSupportDirectoryURL,
            homeDirectoryURL: homeDirectoryURL,
            processIdentifier: processIdentifier,
            uniqueToken: uniqueToken
        )
        return resolveLogFile(
            named: logFileName,
            in: directoryDecision,
            applicationSupportDirectoryURL: applicationSupportDirectoryURL
        )
    }

    /// Pure decision (apart from creating the isolated directory) so tests can
    /// drive every branch with fake roots. Once any test-host signal is seen,
    /// every failure returns `.unavailable` — there is no path from here back
    /// to the production logs.
    static func resolveTestHostAuditDirectory(
        environment: [String: String],
        isXCTestRuntimeLoaded: Bool,
        temporaryRootDirectoryURL: URL,
        applicationSupportDirectoryURL: URL?,
        homeDirectoryURL: URL,
        processIdentifier: Int32,
        uniqueToken: String
    ) -> PaceTestHostAuditDirectory {
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
            return .unavailable(reason: "XCTest marker missing or invalid")
        }

        guard let applicationSupportDirectoryURL else {
            return .unavailable(reason: "cannot locate Application Support to rule out the production path")
        }

        guard processIdentifier > 0 else {
            return .unavailable(reason: "invalid process identifier")
        }

        // The token becomes a path component: ASCII letters, digits, and
        // hyphens only, so it can never introduce `/` or `..`.
        guard !uniqueToken.isEmpty, uniqueToken.allSatisfy({ isSafePathComponentCharacter($0, allowingDot: false) }) else {
            return .unavailable(reason: "invalid unique token")
        }

        // Resolve symlinks up front so every containment check below compares
        // real locations — a temp root that is a symlink into Application
        // Support must be caught as Application Support.
        let resolvedTemporaryRootURL = temporaryRootDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        var temporaryRootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedTemporaryRootURL.path, isDirectory: &temporaryRootIsDirectory),
              temporaryRootIsDirectory.boolValue
        else {
            return .unavailable(reason: "temporary root does not exist or is not a directory")
        }

        guard resolvedTemporaryRootURL.pathComponents.count > 1 else {
            return .unavailable(reason: "temporary root resolves to the filesystem root")
        }

        let resolvedHomeDirectoryURL = homeDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedTemporaryRootURL.pathComponents != resolvedHomeDirectoryURL.pathComponents else {
            return .unavailable(reason: "temporary root resolves to the home directory")
        }

        let productionDirectoryURL = productionAuditDirectoryURL(applicationSupportDirectoryURL: applicationSupportDirectoryURL)
        guard !isPath(resolvedTemporaryRootURL, equalToOrInside: applicationSupportDirectoryURL),
              !isPath(resolvedTemporaryRootURL, equalToOrInside: productionDirectoryURL)
        else {
            return .unavailable(reason: "temporary root resolves into the production application data directory")
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
            return .unavailable(reason: "cannot create a fresh isolated audit directory")
        }

        // Re-validate what was actually created. `attributesOfItem` does not
        // follow a final symlink, so a swapped-in symlink is rejected here.
        guard let isolatedDirectoryAttributes = try? fileManager.attributesOfItem(atPath: isolatedDirectoryURL.path),
              isolatedDirectoryAttributes[.type] as? FileAttributeType == .typeDirectory
        else {
            return .unavailable(reason: "isolated audit directory is not a real directory")
        }

        let resolvedIsolatedDirectoryURL = isolatedDirectoryURL.resolvingSymlinksInPath()
        guard resolvedIsolatedDirectoryURL.pathComponents == resolvedTemporaryRootURL.pathComponents + [isolatedDirectoryName] else {
            return .unavailable(reason: "isolated audit directory escaped the temporary root")
        }

        // A brand-new directory must be empty.
        guard (try? fileManager.contentsOfDirectory(atPath: resolvedIsolatedDirectoryURL.path))?.isEmpty == true else {
            return .unavailable(reason: "isolated audit directory is not empty")
        }

        guard !isPath(resolvedIsolatedDirectoryURL, equalToOrInside: productionDirectoryURL),
              !isPath(resolvedIsolatedDirectoryURL, equalToOrInside: applicationSupportDirectoryURL)
        else {
            return .unavailable(reason: "isolated audit directory resolves to the production location")
        }

        return .isolatedDirectory(resolvedIsolatedDirectoryURL)
    }

    /// Maps the directory decision to one log file inside it. The directory
    /// is shared by every audit log in the process, so an existing regular
    /// file is expected (another instance of the same log already wrote);
    /// anything else at that path — a symlink, a directory — is refused.
    static func resolveLogFile(
        named logFileName: String,
        in directoryDecision: PaceTestHostAuditDirectory,
        applicationSupportDirectoryURL: URL?
    ) -> PaceTestHostLogDestination {
        switch directoryDecision {
        case .notRunningUnderTestHost:
            return .notRunningUnderTestHost
        case .unavailable(let reason):
            return .isolationUnavailable(reason: reason)
        case .isolatedDirectory(let isolatedDirectoryURL):
            guard !logFileName.isEmpty,
                  logFileName != ".", logFileName != "..",
                  logFileName.allSatisfy({ isSafePathComponentCharacter($0, allowingDot: true) })
            else {
                return .isolationUnavailable(reason: "invalid audit log file name")
            }

            guard let applicationSupportDirectoryURL else {
                return .isolationUnavailable(reason: "cannot locate Application Support to rule out the production path")
            }

            let isolatedLogFileURL = isolatedDirectoryURL.appendingPathComponent(logFileName)

            if let existingItemAttributes = try? FileManager.default.attributesOfItem(atPath: isolatedLogFileURL.path),
               existingItemAttributes[.type] as? FileAttributeType != .typeRegular {
                return .isolationUnavailable(reason: "isolated audit log path is occupied by a non-regular file")
            }

            let productionDirectoryURL = productionAuditDirectoryURL(applicationSupportDirectoryURL: applicationSupportDirectoryURL)
            guard !isPath(isolatedLogFileURL, equalToOrInside: productionDirectoryURL),
                  !isPath(isolatedLogFileURL, equalToOrInside: applicationSupportDirectoryURL)
            else {
                return .isolationUnavailable(reason: "isolated audit log resolves to the production location")
            }

            return .isolatedTemporaryLog(isolatedLogFileURL)
        }
    }

    private static func isSafePathComponentCharacter(_ character: Character, allowingDot: Bool) -> Bool {
        let asciiLettersDigitsAndHyphen = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
        if asciiLettersDigitsAndHyphen.contains(character) { return true }
        return allowingDot && (character == "." || character == "_")
    }

    /// Component-wise containment (not string-prefix), after resolving
    /// symlinks on both sides, so `/a/bc` is never treated as inside `/a/b`.
    private static func isPath(_ candidateURL: URL, equalToOrInside ancestorURL: URL) -> Bool {
        let candidatePathComponents = candidateURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let ancestorPathComponents = ancestorURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard candidatePathComponents.count >= ancestorPathComponents.count else { return false }
        return Array(candidatePathComponents.prefix(ancestorPathComponents.count)) == ancestorPathComponents
    }
}
