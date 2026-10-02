//
//  PaceCompanionPairingWindow.swift
//  leanring-buddy
//
//  Pairing-lifecycle policy for the iPad companion server (F-04a).
//
//  The six-digit pairing code is a weak secret, so it is only ever accepted
//  inside an explicit pairing window: opened by a local action in Settings,
//  bounded in time, and bounded in failed attempts. Outside a window the
//  listener carries no pairing key at all, and a pairing that does get through
//  still needs an explicit confirmation on the Mac before anything is stored.
//
//  These types are pure so the bounds can be tested without a network.
//

import Foundation

nonisolated enum PaceCompanionPairingPolicy {
    /// How long a pairing window stays open after the user opens it.
    static let pairingWindowDurationSeconds: TimeInterval = 120

    /// How many failed pairing attempts one window tolerates before it closes.
    /// With a six-digit code, five guesses per locally-opened window keeps an
    /// online guessing attack at a 5-in-1,000,000 chance per user action.
    static let maximumFailedPairingAttemptsPerWindow = 5

    /// How long an inbound connection may stay unauthenticated before it is
    /// dropped. A connection waiting on the Mac-side pairing confirmation is
    /// exempt; it is bounded by the pairing window instead.
    static let unauthenticatedConnectionDeadlineSeconds: TimeInterval = 10

    /// How many unauthenticated connections may exist at once.
    static let maximumUnauthenticatedConnectionCount = 4

    static let maximumDisplayedDeviceNameCharacterCount = 48
    static let displayedDeviceIdentifierSuffixCharacterCount = 6

    /// The client-provided device name as it may be shown on the Mac: one
    /// line, bounded, no control characters. It is a label only — it never
    /// takes part in any authorization decision.
    static func displayName(forClientProvidedDeviceName clientProvidedDeviceName: String) -> String {
        let singleLineScalars = clientProvidedDeviceName.unicodeScalars.map { scalar -> Character in
            let isControlOrLineBreak =
                CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
            return isControlOrLineBreak ? " " : Character(scalar)
        }
        let collapsedName = String(singleLineScalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let boundedName = String(collapsedName.prefix(maximumDisplayedDeviceNameCharacterCount))
        return boundedName.isEmpty ? "Unnamed device" : boundedName
    }

    /// A short, display-only tail of the client-provided device identifier.
    static func displaySuffix(forClientProvidedDeviceIdentifier clientProvidedDeviceIdentifier: String) -> String {
        let alphanumericIdentifier = clientProvidedDeviceIdentifier.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            .map(String.init)
            .joined()
        return String(alphanumericIdentifier.suffix(displayedDeviceIdentifierSuffixCharacterCount))
    }
}

/// One explicit pairing session. Value type: the server holds at most one,
/// and holds none when pairing is closed.
nonisolated struct PaceCompanionPairingWindow: Equatable {
    let pairingCode: String
    let openedAt: Date
    let expiresAt: Date
    private(set) var failedAttemptCount = 0

    init(pairingCode: String, openedAt: Date) {
        self.pairingCode = pairingCode
        self.openedAt = openedAt
        self.expiresAt = openedAt.addingTimeInterval(PaceCompanionPairingPolicy.pairingWindowDurationSeconds)
    }

    func hasExpired(now: Date) -> Bool {
        now >= expiresAt
    }

    var hasReachedFailedAttemptLimit: Bool {
        failedAttemptCount >= PaceCompanionPairingPolicy.maximumFailedPairingAttemptsPerWindow
    }

    mutating func recordFailedAttempt() {
        failedAttemptCount += 1
    }
}

/// Why the most recent pairing window closed. Shown in Settings so a window
/// that closed on its own is never mistaken for one that is still open.
nonisolated enum PaceCompanionPairingWindowCloseReason: Equatable {
    case paired
    case expired
    case tooManyFailedAttempts
    case cancelled
    case declined
    case companionDisabled
    case serverStopped
}

/// A pairing request that reached the Mac inside an open window and is waiting
/// for the user to allow or deny it. Every field is display-only.
nonisolated struct PaceCompanionPendingPairingConfirmation: Equatable, Identifiable {
    let id: UUID
    /// Sanitized client-provided name. Untrusted: shown as a claim, not a fact.
    let deviceDisplayName: String
    /// Sanitized tail of the client-provided identifier. Untrusted.
    let deviceIdentifierDisplaySuffix: String
    /// The currently paired device this pairing would replace, if any.
    let replacedPairedDeviceName: String?
}
