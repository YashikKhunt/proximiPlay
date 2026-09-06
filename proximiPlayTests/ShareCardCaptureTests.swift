//
//  ShareCardCaptureTests.swift
//  proximiPlayTests
//
//  On-demand rasterization of `ShareCardView` so the actual shared image can
//  be inspected, rather than trusted from a preview. The card is the one
//  artefact of this app that leaves the device and gets seen by people who
//  don't have it installed, so it's worth looking at directly.
//
//  Skipped unless a capture is requested, matching
//  `LobbyScreenshotUITests`:
//
//      SIMCTL_CHILD_SCREENSHOT_DIR=/some/dir xcodebuild test \
//        -only-testing:proximiPlayTests/ShareCardCaptureTests ...
//
//  (The SIMCTL_CHILD_ prefix is what forwards the variable into the
//  simulator-hosted test process; a bare export does not reach it.)
//

import Testing
import Foundation
import SwiftUI
import UIKit
@testable import proximiPlay

@MainActor
struct ShareCardCaptureTests {

    private func outputDirectory() -> String? {
        ProcessInfo.processInfo.environment["SCREENSHOT_DIR"]
    }

    private func entries(_ count: Int, votes: Bool = false) -> [ShareCardEntry] {
        let names = ["Ari", "Bo", "Priyanka Chandrasekaran", "Deepak",
                     "Emi", "Farid", "Grace", "Hana"]
        let colors: [PlayerColor] = [.blue, .green, .purple, .orange,
                                     .pink, .teal, .indigo, .red]
        let values = votes ? [3, 2, 2, 1, 1, 0, 0, 0] : [450, 380, 320, 300, 260, 210, 180, 90]
        let slice = Array(values.prefix(count))
        let top = slice.max() ?? 0
        return (0..<count).map { index in
            ShareCardEntry(
                id: UUID(),
                displayName: names[index],
                color: colors[index],
                value: slice[index],
                isHighlighted: slice[index] == top
            )
        }
    }

    private func write(_ image: UIImage?, named name: String, to directory: String) throws {
        let image = try #require(image, "ImageRenderer produced no image for \(name)")
        let data = try #require(image.pngData(), "No PNG data for \(name)")
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    @Test func captureShareCards() throws {
        guard let directory = outputDirectory() else { return }

        // Two players and eight: the layout derives row height from the
        // available space, so both extremes have to stay legible in the
        // same fixed frame.
        try write(
            ShareCardView(mode: .quickTrivia, isVoteBattle: false, entries: entries(2), subtitle: nil)
                .rendered(colorScheme: .light),
            named: "sharecard-2p", to: directory
        )
        try write(
            ShareCardView(mode: .quickTrivia, isVoteBattle: false, entries: entries(8), subtitle: nil)
                .rendered(colorScheme: .light),
            named: "sharecard-8p", to: directory
        )
        try write(
            ShareCardView(mode: .quickTrivia, isVoteBattle: false, entries: entries(5), subtitle: nil)
                .rendered(colorScheme: .dark),
            named: "sharecard-dark", to: directory
        )
        try write(
            ShareCardView(
                mode: .voteBattle,
                isVoteBattle: true,
                entries: entries(5, votes: true),
                subtitle: "Votes are just for fun — no points awarded."
            ).rendered(colorScheme: .light),
            named: "sharecard-vote", to: directory
        )
    }
}
