//
//  NavigationUITests.swift
//  proximiPlayUITests
//

import XCTest

final class NavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHostFlowNavigatesToLobbyAndBack() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 5))
        app.buttons["Start Game"].tap()

        XCTAssertTrue(app.navigationBars["Game Lobby"].waitForExistence(timeout: 5))

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testJoinFlowNavigatesToJoinViewAndBack() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Join Game"].waitForExistence(timeout: 5))
        app.buttons["Join Game"].tap()

        XCTAssertTrue(app.navigationBars["Find a Game"].waitForExistence(timeout: 5))

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Join Game"].waitForExistence(timeout: 5))
    }
}
