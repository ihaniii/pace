//
//  PaceTurnOrigin.swift
//  leanring-buddy
//
//  Where a turn came from (F-04b). A paired iPad is authenticated, but its
//  turns are not local turns: authentication answers "is this the paired
//  companion?", not "may this turn do what the person at the Mac may do?".
//  The origin is assigned once, at the trust boundary that accepted the
//  input, and travels with the turn's lease. Nothing the client sends and
//  nothing the planner outputs can set or change it.
//

import Foundation

/// One authenticated companion session, as minted by the Mac.
///
/// The wire protocol's `sessionIdentifier` is chosen by the iPad, so a
/// replacement device could present the same string. This value is created by
/// `PaceCompanionServer` each time a connection becomes the authenticated
/// session and never leaves the Mac, so it cannot be replayed or guessed.
nonisolated struct PaceCompanionSessionIdentity: Hashable, Sendable {
    private let serverMintedValue: UUID

    /// Only the companion server mints these, when a connection authenticates.
    static func mintForNewlyAuthenticatedSession() -> PaceCompanionSessionIdentity {
        PaceCompanionSessionIdentity(serverMintedValue: UUID())
    }

    private init(serverMintedValue: UUID) {
        self.serverMintedValue = serverMintedValue
    }
}

nonisolated enum PaceTurnOrigin: Equatable, Sendable {
    /// Input from the person at the Mac: push-to-talk, the chat field, a
    /// Mac-side control, or a `pace://` link opened on this Mac.
    case local
    /// An utterance from the paired iPad, received on this companion session.
    case remoteCompanion(sessionIdentity: PaceCompanionSessionIdentity)

    var isRemote: Bool {
        originatingCompanionSessionIdentity != nil
    }

    var originatingCompanionSessionIdentity: PaceCompanionSessionIdentity? {
        switch self {
        case .local:
            return nil
        case .remoteCompanion(let sessionIdentity):
            return sessionIdentity
        }
    }
}

/// A privileged voice command that runs before the planner and outside the
/// action-approval alert. The person at the Mac may speak these; a remote
/// companion turn may not.
nonisolated enum PaceRemoteTurnRefusedCommand: String, Equatable, Sendable, CaseIterable {
    case watchMode
    case alwaysListening
    case meetingRecording
    case memoryPreference
    case automationCatalog
    case shortcut
    case automationCreation
    case skill
    case recordedFlow
    case rememberedSite
    case scheduling
    case backgroundAgent
    case dictation
}

/// Decides which transcripts a remote companion turn may not act on.
///
/// It runs the same parsers the local pipeline uses, so "would this transcript
/// have triggered a privileged pre-planner command?" has exactly one answer.
/// It is deliberately stricter than the local routing order: a remote
/// transcript that ANY of these parsers recognises is refused, even where an
/// earlier local branch would have claimed it first.
@MainActor
enum PaceRemoteTurnCommandGate {
    static let refusalSpokenText = "that can only be done from the Mac."

    /// `recordedFlowExists` answers whether a flow with that name is stored.
    /// The flow parser claims every "run …" / "do …" sentence, so a remote
    /// "do you know …" must not be refused as a flow command: only a replay of
    /// a flow that really exists is. Recording and deleting are always refused.
    static func refusedCommand(
        forTranscript transcript: String,
        meetingNoteProfiles: [PaceMeetingNoteProfile],
        recordedFlowExists: (String) -> Bool
    ) -> PaceRemoteTurnRefusedCommand? {
        if PaceWatchModeCommandParser.parse(transcript) != nil {
            return .watchMode
        }
        if PaceAlwaysListeningCommandParser.parse(transcript) != nil {
            return .alwaysListening
        }
        if PaceMeetingModeCommandParser.parse(transcript, profiles: meetingNoteProfiles) != nil {
            return .meetingRecording
        }
        if PaceLocalMemoryCommandParser.parse(transcript) != nil {
            return .memoryPreference
        }
        if PaceAutomationCatalogCommandParser.parse(transcript) != nil {
            return .automationCatalog
        }
        if PaceShortcutCommandParser.parse(transcript) != nil {
            return .shortcut
        }
        if PaceAutomationCreationCommandParser.parse(transcript) != nil {
            return .automationCreation
        }
        if PaceSkillCommandParser.parse(transcript) != nil {
            return .skill
        }
        if let flowCommand = PaceFlowCommandParser.parse(transcript) {
            switch flowCommand {
            case .startRecording, .stopRecording, .delete:
                return .recordedFlow
            case .run(let flowName):
                if recordedFlowExists(flowName) {
                    return .recordedFlow
                }
            }
        }
        // "forget …" is claimed wholesale by this parser, so only saving a
        // site is refused outright. The pipeline skips the whole branch for a
        // remote turn, so a remote "forget …" removes nothing either.
        if case .remember = PaceRememberSiteCommandParser.parse(transcript: transcript) {
            return .rememberedSite
        }
        if PaceCronCommandParser.parse(transcript) != nil {
            return .scheduling
        }
        if PaceBackgroundAgentCommandParser.parse(transcript) != nil {
            return .backgroundAgent
        }
        if PaceDictationFastPath.extractDictationText(from: transcript) != nil {
            return .dictation
        }
        return nil
    }
}
