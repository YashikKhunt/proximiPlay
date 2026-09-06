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

    @MainActor
    func testCaptureHostLobbyFrame() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 5))
        app.buttons["Start Game"].tap()
        XCTAssertTrue(app.navigationBars["Game Lobby"].waitForExistence(timeout: 5))

        // Let the mode picker settle before capturing.
        Thread.sleep(forTimeInterval: 1.0)
        try capture(named: "lobby-host")
    }

    /// Captures `JoinView`'s "still searching" state — no host is actually
    /// nearby in the test environment, so `connectionState` stays `.browsing`
    /// with an empty `discoveredHosts`, which is exactly the frame this is
    /// after.
    @MainActor
    func testCaptureJoinSearchingFrame() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Join Game"].waitForExistence(timeout: 5))
        app.buttons["Join Game"].tap()
        XCTAssertTrue(app.navigationBars["Find a Game"].waitForExistence(timeout: 5))

        // Let browsing actually start before capturing.
        Thread.sleep(forTimeInterval: 1.0)
        try capture(named: "join-searching")
    }

    /// Writes `name`.png to `SCREENSHOT_DIR` when the orchestrator has set
    /// it (skipped otherwise), and always keeps the same PNG as an
    /// `XCTAttachment` on the test record — the latter is visible from any
    /// `.xcresult` produced by this run (e.g. via `xcresulttool`) with no
    /// extra environment plumbing required.
    @MainActor
    private func capture(named name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        try screenshot.pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
