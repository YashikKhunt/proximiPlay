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

    /// `true` when this is the last round of the game — i.e. the host called
    /// `endGame()` immediately after broadcasting this result.
    ///
    /// **Carried in-band deliberately.** The obvious alternative — deriving
    /// "was that the last round?" from `GameEngine.finalScores` being set —
    /// is correct only on the host, where `finishRound()` sets
    /// `lastRoundResult` and `endGame()` sets `finalScores` in one
    /// synchronous turn that Observation coalesces into a single update. A
    /// joiner receives `.roundResult` and `.gameEnd` as two *separate*
    /// messages, each dispatched in its own main-actor `Task`, so its
    /// round-result observer runs a whole turn before `finalScores` exists.
    /// Joiners consequently showed the final round's reveal as a
    /// non-final one ("Next round starting…"), auto-advanced it after
    /// 2.5s, and were stranded on the waiting view for the rest of the
    /// game while the host sat on the results screen.
    ///
    /// Defaulted (rather than non-optional) so a payload encoded without
    /// the key still decodes cleanly. See `GameEngine.finishRound()`, which
    /// computes this from the same condition it uses to decide whether to
    /// call `endGame()`, and `RoundFlowModifier`, which consumes it.
    var isFinal: Bool = false

    init(
        roundNumber: Int,
        scores: [PlayerScore],
        highlightPlayerId: UUID? = nil,
        voteCounts: [UUID: Int]? = nil,
        isFinal: Bool = false
    ) {
        self.roundNumber = roundNumber
        self.scores = scores
        self.highlightPlayerId = highlightPlayerId
        self.voteCounts = voteCounts
        self.isFinal = isFinal
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
