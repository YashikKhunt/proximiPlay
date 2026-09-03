//
//  PlayerScore.swift
//  proximiPlay
//

import Foundation

/// A player's cumulative score, used in round results and final standings.
struct PlayerScore: Codable, Identifiable, Sendable {
    let playerId: UUID
    var displayName: String
    var score: Int

    var id: UUID { playerId }
}
