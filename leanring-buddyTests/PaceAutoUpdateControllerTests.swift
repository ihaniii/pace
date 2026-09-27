//
//  PaceAutoUpdateControllerTests.swift
//  leanring-buddyTests
//
//  Proves Sparkle can never start inside a Debug build or a unit-test host,
//  while the Release decision and the production update configuration are
//  unchanged. Before this guard, the test host (and every Xcode Debug build)
//  started Sparkle at launch, fetched the appcast, and installed the
//  published release over the running development app / test host.
//
//  Nothing here starts an updater or touches the network: the decision is a
//  pure function, and constructing a controller in this (Debug) build creates
//  no Sparkle object.
//

import Foundation
import Testing
@testable import Pace

@MainActor
@Suite("PaceAutoUpdateController Debug/test-host guard")
struct PaceAutoUpdateControllerTests {

    // MARK: - Decision matrix

    @Test("A. A test host never starts the updater, in any build configuration")
    func testHostNeverStartsUpdater() {
        #expect(!PaceAutoUpdateController.shouldStartAutomaticUpdater(isDebugBuild: false, isRunningUnderTestHost: true))
        #expect(!PaceAutoUpdateController.shouldStartAutomaticUpdater(isDebugBuild: true, isRunningUnderTestHost: true))
    }

    @Test("B. A Debug build never starts the updater")
    func debugBuildNeverStartsUpdater() {
        #expect(!PaceAutoUpdateController.shouldStartAutomaticUpdater(isDebugBuild: true, isRunningUnderTestHost: false))
        #expect(!PaceAutoUpdateController.shouldStartAutomaticUpdater(isDebugBuild: true, isRunningUnderTestHost: true))
    }

    @Test("C. A Release build outside a test host starts the updater")
    func releaseOutsideTestHostStartsUpdater() {
        #expect(PaceAutoUpdateController.shouldStartAutomaticUpdater(isDebugBuild: false, isRunningUnderTestHost: false))
    }

    // MARK: - Production update configuration unchanged

    @Test("D. The production appcast feed URL is unchanged")
    func productionFeedURLIsUnchanged() {
        let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        #expect(feedURLString == "https://raw.githubusercontent.com/HeyPace/pace/main/appcast.xml")
    }

    @Test("E. The Sparkle EdDSA public key is unchanged")
    func sparklePublicKeyIsUnchanged() {
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        #expect(publicKey == "UGbOz43wfHeH3fwSu45Z0dNFIlomd1Tra+B9mjOFdSI=")
    }

    @Test("F. Production automatic-update Info.plist settings are unchanged")
    func productionAutomaticUpdateSettingsAreUnchanged() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int == 86400)
    }

    // MARK: - This compiled Debug / test-host build

    @Test("G. This Debug test-host build cannot create or start an updater")
    func compiledDebugTestHostBuildCannotStartUpdater() {
        #expect(PaceAutoUpdateController.isDebugBuild)
        #expect(PaceTestHostDataIsolation.isRunningUnderTestHost)
        #expect(!PaceAutoUpdateController.shouldStartAutomaticUpdater(
            isDebugBuild: PaceAutoUpdateController.isDebugBuild,
            isRunningUnderTestHost: PaceTestHostDataIsolation.isRunningUnderTestHost
        ))
        // The launch-time instance (created by the host app) and a fresh one.
        #expect(!PaceAutoUpdateController.shared.isAutomaticUpdaterRunning)
        #expect(!PaceAutoUpdateController().isAutomaticUpdaterRunning)
    }

    @Test("H. The running test host is the development build, not an installed release")
    func runningTestHostWasNotReplacedByAnUpdate() {
        // A Sparkle install replaces the host bundle with the published
        // release: identifier `com.pace.app`, and no embedded test bundle.
        #expect(Bundle.main.bundleIdentifier != "com.pace.app")
        let embeddedTestBundleURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("leanring-buddyTests.xctest")
        #expect(embeddedTestBundleURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        // With no updater object, nothing can schedule a check or an install.
        #expect(!PaceAutoUpdateController.shared.isAutomaticUpdaterRunning)
    }
}
