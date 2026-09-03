//
//  PlayerStats.swift
//  proximiPlay
//

import Foundation
import SwiftData

/// Persists cumulative statistics for the local player.
@Model
final class PlayerStats {
    var id: UUID
    var displayName: String
    var gamesPlayed: Int
    var gamesWon: Int
    var totalScore: Int
    var favoriteMode: String?    // GameMode.rawValue
    var lastPlayedDate: Date?

    init(
        id: UUID = UUID(),
        displayName: String,
        gamesPlayed: Int = 0,
        gamesWon: Int = 0,
        totalScore: Int = 0,
        favoriteMode: GameMode? = nil,
        lastPlayedDate: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.gamesPlayed = gamesPlayed
        self.gamesWon = gamesWon
        self.totalScore = totalScore
        self.favoriteMode = favoriteMode?.rawValue
        self.lastPlayedDate = lastPlayedDate
    }

    /// Win rate as a value in [0, 1]. Returns 0 when no games have been played.
    var winRate: Double {
        guard gamesPlayed > 0 else { return 0 }
        return Double(gamesWon) / Double(gamesPlayed)
    }

    /// Converts the stored raw value back to the typed `GameMode` enum.
    var preferredMode: GameMode? {
        guard let favoriteMode else { return nil }
        return GameMode(rawValue: favoriteMode)
    }
}
