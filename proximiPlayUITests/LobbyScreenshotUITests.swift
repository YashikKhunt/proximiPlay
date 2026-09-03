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
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else {
            throw XCTSkip("SCREENSHOT_DIR not set — screenshot capture not requested")
        }

        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 5))
        app.buttons["Start Game"].tap()
        XCTAssertTrue(app.navigationBars["Game Lobby"].waitForExistence(timeout: 5))

        // Let the mode picker settle before capturing.
        Thread.sleep(forTimeInterval: 1.0)
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("lobby-host.png"))
    }
}
