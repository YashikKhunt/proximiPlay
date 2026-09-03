//
//  GameConfig.swift
//  proximiPlay
//

import Foundation

/// Round and timing configuration for a game session.
struct GameConfig: Codable, Sendable {
    var roundCount: Int
    var timePerRound: TimeInterval

    /// Returns the default configuration for the given game mode, assuming
    /// a typical 4-player lobby. Prefer `defaultConfig(for:playerCount:)`
    /// wherever the actual roster size is known (e.g. `GameEngine`), since
    /// Speed Draw's round count must match the number of players.
    static func defaultConfig(for mode: GameMode) -> GameConfig {
        defaultConfig(for: mode, playerCount: 4)
    }

    /// Returns the default configuration for `mode`, tailored to
    /// `playerCount`. Only Speed Draw's round count depends on the roster
    /// size — one round per player, so everyone draws exactly once.
    static func defaultConfig(for mode: GameMode, playerCount: Int) -> GameConfig {
        switch mode {
        case .quickTrivia:
            GameConfig(roundCount: 5, timePerRound: 20)
        case .voteBattle:
            GameConfig(roundCount: 5, timePerRound: 30)
        case .speedDraw:
            GameConfig(roundCount: max(playerCount, 1), timePerRound: 60)
        case .reflexTap:
            // Best-of-5.
            GameConfig(roundCount: 5, timePerRound: 5)
        }
    }
}
