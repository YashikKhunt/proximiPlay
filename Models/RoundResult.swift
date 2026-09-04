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

    /// Vote Battle only: how many votes each player received this round,
    /// computed host-side by `GameEngine.voteTally(votes:)`.
    ///
    /// `nil` for every other mode (and for a Vote Battle round nobody voted
    /// in) — Vote Battle awards no points, so these counts are the mode's
    /// entire payoff and the only thing `VoteRevealView` can show beyond
    /// "who won". Optional rather than defaulted so the synthesized
    /// `Codable` decodes with `decodeIfPresent`: a payload without the key
    /// still decodes cleanly instead of failing the whole message.
    ///
    /// Keys are `Player.id`s; a player with no votes may be absent, so read
    /// through `voteCount(for:)` rather than subscripting directly.
    var voteCounts: [UUID: Int]?

    init(
        roundNumber: Int,
        scores: [PlayerScore],
        highlightPlayerId: UUID? = nil,
        voteCounts: [UUID: Int]? = nil
    ) {
        self.roundNumber = roundNumber
        self.scores = scores
        self.highlightPlayerId = highlightPlayerId
        self.voteCounts = voteCounts
    }

    /// Votes received by `playerId` this round — `0` when the tally is
    /// absent (non-vote modes) or simply doesn't list them.
    func voteCount(for playerId: UUID) -> Int {
        voteCounts?[playerId] ?? 0
    }

    /// Total votes cast this round, for "N of M voted"-style context.
    var totalVotes: Int {
        voteCounts?.values.reduce(0, +) ?? 0
    }
}
