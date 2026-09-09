//
//  LobbyScreenshotUITests.swift
//  proximiPlayUITests
//
//  Captures rendered frames for the orchestrator's visual verification.
//  Simulator test runners execute natively on macOS, so writing to the
//  host filesystem is possible; the output path comes from the
//  SCREENSHOT_DIR environment variable (skipped when absent).
//

import XCTest

final class LobbyScreenshotUITests: XCTestCase {

    /// These are on-demand capture tools, not assertions about behaviour —
    /// nothing here would catch a regression that `NavigationUITests` doesn't
    /// already cover. Running them in every suite invocation just adds a
    /// second UI-test class driving the app in a parallel clone, which is
    /// flaky by construction (observed: this class failing in a full-suite
    /// run while passing in isolation). So they skip entirely unless a
    /// capture was actually asked for.
    ///
    /// Request one with:
    ///   SIMCTL_CHILD_SCREENSHOT_DIR=/some/dir xcodebuild test \
    ///     -only-testing:proximiPlayUITests/LobbyScreenshotUITests ...
    /// (the SIMCTL_CHILD_ prefix is what forwards the variable into the
    /// simulator-hosted test process; a bare export does not reach it).
    private func screenshotDirectory() throws -> String {
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else {
            throw XCTSkip("SCREENSHOT_DIR not set — frame capture not requested")
        }
        return dir
    }

    @MainActor
    func testCaptureHostLobbyFrame() throws {
        let directory = try screenshotDirectory()
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 5))
        app.buttons["Start Game"].tap()
        XCTAssertTrue(app.navigationBars["Game Lobby"].waitForExistence(timeout: 5))

        // Let the mode picker settle before capturing.
        Thread.sleep(forTimeInterval: 1.0)
        try capture(named: "lobby-host", into: directory)
    }

    /// Captures a host lobby with a populated roster — the frame that was
    /// previously impossible to review without two physical devices, and so
    /// the frame in which a broken roster row went unnoticed.
    ///
    /// The peers come from `AppState.seedDemoRosterIfRequested()`, a
    /// DEBUG-only seed gated behind the `-demo-roster` launch argument. No
    /// Multipeer session is started.
    @MainActor
    func testCaptureHostLobbyWithPlayersFrame() throws {
        let directory = try screenshotDirectory()
        let app = XCUIApplication()
        app.launchArguments += ["-demo-roster"]
        app.launch()

        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 5))
        app.buttons["Start Game"].tap()
        XCTAssertTrue(app.navigationBars["Game Lobby"].waitForExistence(timeout: 5))

        // Let the seeded roster's arrival animation settle before capturing.
        Thread.sleep(forTimeInterval: 1.5)
        try capture(named: "lobby-host-with-players", into: directory)
    }

    /// Captures the host's swipe-to-remove action revealed on a roster row
    /// (Guideline 1.2). Uses the same `-demo-roster` seed as the frame above.
    @MainActor
    func testCaptureLobbyRemoveActionFrame() throws {
        let directory = try screenshotDirectory()
        let app = XCUIApplication()
        app.launchArguments += ["-demo-roster"]
        app.launch()

        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 5))
        app.buttons["Start Game"].tap()
        XCTAssertTrue(app.navigationBars["Game Lobby"].waitForExistence(timeout: 5))

        let row = app.cells.containing(.staticText, identifier: "Bo").element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        Thread.sleep(forTimeInterval: 1.0)

        try capture(named: "lobby-remove-action", into: directory)
    }

    /// Captures `JoinView`'s "still searching" state — no host is actually
    /// nearby in the test environment, so `connectionState` stays `.browsing`
    /// with an empty `discoveredHosts`, which is exactly the frame this is
    /// after.
    @MainActor
    func testCaptureJoinSearchingFrame() throws {
        let directory = try screenshotDirectory()
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Join Game"].waitForExistence(timeout: 5))
        app.buttons["Join Game"].tap()
        XCTAssertTrue(app.navigationBars["Find a Game"].waitForExistence(timeout: 5))

        // Let browsing actually start before capturing.
        Thread.sleep(forTimeInterval: 1.0)
        try capture(named: "join-searching", into: directory)
    }

    /// Writes `name`.png into `directory` and also keeps the same PNG as an
    /// `XCTAttachment` on the test record, so the frame is recoverable from
    /// the `.xcresult` (via `xcresulttool export attachments`) even if the
    /// disk write path is unavailable.
    @MainActor
    private func capture(named name: String, into directory: String) throws {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        try screenshot.pngRepresentation
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
