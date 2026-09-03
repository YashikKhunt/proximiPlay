//
//  RoundResult.swift
//  proximiPlay
//

import Foundation

/// Summary of a single round, broadcast to all players after the round ends.
struct RoundResult: Codable, Sendable {
    let roundNumber: Int
    var scores: [PlayerScore]
    /// The player who scored highest this round, if any.
    var highlightPlayerId: UUID?
}
