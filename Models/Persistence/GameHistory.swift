//
//  GameHistory.swift
//  proximiPlay
//

import Foundation
import SwiftData

/// Persists the result of a single completed game session.
@Model
final class GameHistory {
    var id: UUID
    var date: Date
    var gameMode: String        // GameMode.rawValue
    var playerCount: Int
    var winnerName: String?
    var myScore: Int
    var rounds: Int
    var duration: TimeInterval   // seconds

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        gameMode: GameMode,
        playerCount: Int,
        winnerName: String? = nil,
        myScore: Int,
        rounds: Int,
        duration: TimeInterval
    ) {
        self.id = id
        self.date = date
        self.gameMode = gameMode.rawValue
        self.playerCount = playerCount
        self.winnerName = winnerName
        self.myScore = myScore
        self.rounds = rounds
        self.duration = duration
    }

    /// Converts the stored raw value back to the typed `GameMode` enum.
    var mode: GameMode? {
        GameMode(rawValue: gameMode)
    }
}
