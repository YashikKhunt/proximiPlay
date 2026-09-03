//
//  GameConfig.swift
//  proximiPlay
//

import Foundation

/// Round and timing configuration for a game session.
struct GameConfig: Codable, Sendable {
    var roundCount: Int
    var timePerRound: TimeInterval

    /// Returns the default configuration for the given game mode.
    static func defaultConfig(for mode: GameMode) -> GameConfig {
        switch mode {
        case .quickTrivia:
            GameConfig(roundCount: 10, timePerRound: 15)
        case .voteBattle:
            GameConfig(roundCount: 8, timePerRound: 20)
        case .speedDraw:
            GameConfig(roundCount: 6, timePerRound: 60)
        case .reflexTap:
            GameConfig(roundCount: 12, timePerRound: 5)
        }
    }
}
