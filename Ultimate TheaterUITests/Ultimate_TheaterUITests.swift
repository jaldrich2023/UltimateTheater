//
//  Ultimate_TheaterUITests.swift
//  Ultimate TheaterUITests
//
//  Launch smoke test. The app is started in UI-test mode (the `-uitest` argument and the
//  `UITEST` environment variable) so it uses scratch data instead of the user's library:
//  in-memory stores, no Keychain, and no remote-control listener.
//
//  Caution: XCUIApplication terminates any running copy of the app before launching (the
//  test and the app share one bundle ID), so quit a real viewing session first. These tests
//  are skipped in the test plan's "Default" configuration and run in "Realtime".
//

import XCTest

final class Ultimate_TheaterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // Opt-in, because launching quits a running copy of the app (see above).
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UT_RUN_REALTIME_TESTS"] == "1",
                          "UI tests run in the Realtime test plan configuration")
    }

    @MainActor
    func testLaunchShowsAWindow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest"]
        app.launchEnvironment["UITEST"] = "1"
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the app did not come to the foreground")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared after launch")
    }
}
