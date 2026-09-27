//
//  PaceAutoUpdateController.swift
//  leanring-buddy
//
//  Wires Sparkle into Pace so the app silently checks for updates
//  against the GitHub-hosted appcast and downloads / installs them on
//  user approval. No Apple Developer Program / notarization needed —
//  Sparkle verifies update authenticity with its own EdDSA signature
//  (private key kept in the Mac's keychain on the release machine;
//  public key embedded in Info.plist as SUPublicEDKey).
//
//  Lifecycle: created at launch by CompanionAppDelegate. Release builds
//  start the updater exactly as before. Debug builds (every Xcode Cmd+R
//  build and every unit-test build) and any XCTest host never create an
//  updater at all: development builds carry a lower build number than the
//  published release, so Sparkle would otherwise download the release and
//  install it over the running development app or test host.
//

import Foundation
import Sparkle

@MainActor
final class PaceAutoUpdateController: NSObject {
    static let shared = PaceAutoUpdateController()

    /// `nil` when automatic updating is disabled for this build/process. No
    /// Sparkle object exists then, so nothing can check, download, or install.
    private let updaterController: SPUStandardUpdaterController?

    /// Whether this process created (and started) a Sparkle updater.
    var isAutomaticUpdaterRunning: Bool {
        updaterController != nil
    }

    /// Compile-time: true in every Debug build, false in Release.
    nonisolated static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Pure decision so tests can prove every combination. Release builds
    /// outside a test host are the only case that starts the updater.
    nonisolated static func shouldStartAutomaticUpdater(isDebugBuild: Bool, isRunningUnderTestHost: Bool) -> Bool {
        !isDebugBuild && !isRunningUnderTestHost
    }

    override init() {
        let shouldStartUpdater = Self.shouldStartAutomaticUpdater(
            isDebugBuild: Self.isDebugBuild,
            isRunningUnderTestHost: PaceTestHostDataIsolation.isRunningUnderTestHost
        )
        guard shouldStartUpdater else {
            self.updaterController = nil
            super.init()
            print("🔄 PaceAutoUpdateController: automatic updates disabled (Debug build or unit-test host) — no updater created")
            return
        }

        // startingUpdater: true → automatic background check kicks off
        // as soon as the controller is constructed, with the cadence
        // Sparkle's defaults / Info.plist drive (SUEnableAutomaticChecks,
        // SUScheduledCheckInterval).
        let startedUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = startedUpdaterController
        super.init()
        print("🔄 PaceAutoUpdateController: started (feed=\(startedUpdaterController.updater.feedURL?.absoluteString ?? "unset"))")
    }
}
