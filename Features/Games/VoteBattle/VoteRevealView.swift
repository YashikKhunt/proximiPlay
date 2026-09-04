//
//  VoteRevealView.swift
//  proximiPlay
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The interstitial shown between Vote Battle rounds: reveals who was voted
/// "most likely," celebrated with a staggered spring reveal and a success
/// haptic — the votes themselves are the fun, so no cumulative scores are
/// shown here (Vote Battle never awards points; see `GameEngine.computeScoreDeltas`).
///
/// A pure, parameter-driven view — every input is a plain value, so it
/// renders identically for host and joiner and needs no environment access.
/// `VoteGameView` is responsible for capturing this data at the right moment
/// and for the actual advance-to-next-round timing; this view only renders a
/// snapshot and reports the user's "continue" tap on the final round.
///
/// ## Vote counts
///
/// `RoundResult.voteCounts` carries the host's per-player tally
/// (`GameEngine.voteTally`) on the wire, so every device shows the real
/// numbers — not just who won, but by how much. Players with no votes are
/// absent from the tally and read back as `0` via `voteCount(for:)`. The
/// tally is `nil` for a round nobody voted in, in which case the counts are
/// suppressed entirely rather than rendering a wall of zeroes.
struct VoteRevealView: View {
    let roundNumber: Int
    let totalRounds: Int
    let prompt: String
    let players: [Player]
    /// `nil` when the local player didn't vote before the round ended.
    let myVoteTargetId: UUID?
    let myPlayerId: UUID
    let result: RoundResult
    let isFinalRound: Bool
    /// Invoked when the player taps through from the final round's reveal.
    /// Unused (and not shown) on non-final rounds, which auto-advance.
    var onContinue: (() -> Void)?

    /// Player ids that have finished their staggered spring-in, driving each
    /// row's scale/opacity transition.
    @State private var revealedIds: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(isFinalRound ? "Final Round" : "Round \(roundNumber) of \(totalRounds)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                promptCard

                results

                footer
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .onAppear { animateReveal() }
    }

    // MARK: - Prompt

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt)
                .font(.title3.bold())
                .foregroundStyle(Color.primary)

            if myVoteTargetId == nil {
                Label("You didn't vote in time", systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Results

    /// `true` once the host has sent a real tally for this round — the only
    /// case where per-player counts are meaningful.
    private var hasTally: Bool { result.voteCounts != nil }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
                if hasTally {
                    Text(result.totalVotes == 1 ? "1 vote cast" : "\(result.totalVotes) votes cast")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
            }

            VStack(spacing: 8) {
                ForEach(Array(players.enumerated()), id: \.element.id) { index, player in
                    resultRow(for: player, index: index)
                }
            }
        }
    }

    private func resultRow(for player: Player, index: Int) -> some View {
        let isWinner = result.highlightPlayerId == player.id
        let isMyVote = myVoteTargetId == player.id
        let isMe = player.id == myPlayerId
        let revealed = revealedIds.contains(player.id)
        let votes = result.voteCount(for: player.id)

        return HStack(spacing: 12) {
            PlayerBadge(player: player)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.displayName)
                    .font(.subheadline.weight(isMe || isWinner ? .bold : .regular))
                    .foregroundStyle(Color.primary)
                if isMyVote {
                    Text("Your vote")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer(minLength: 0)

            if isWinner {
                Image(systemName: "crown.fill")
                    .font(.caption)
                    .foregroundStyle(Color.yellow)
                    .accessibilityHidden(true)
            }

            if hasTally {
                // The count itself carries the ranking — never colour
                // alone, so it still reads at a glance without relying on
                // the yellow highlight.
                Text(votes == 1 ? "1 vote" : "\(votes) votes")
                    .font(.caption.weight(isWinner ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isWinner ? Color.yellow : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        isWinner ? Color.yellow.opacity(0.2) : Color.secondary.opacity(0.12),
                        in: Capsule()
                    )
            } else if isWinner {
                Text("Most Votes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.yellow)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            isWinner ? Color.yellow.opacity(0.15) : Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isWinner ? Color.yellow : .clear, lineWidth: 2)
        }
        .scaleEffect(revealed ? 1.0 : 0.85)
        .opacity(revealed ? 1.0 : 0.0)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.65).delay(Double(index) * 0.08),
            value: revealed
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            rowAccessibilityLabel(player: player, isWinner: isWinner, isMyVote: isMyVote, isMe: isMe, votes: votes)
        )
    }

    private func rowAccessibilityLabel(
        player: Player,
        isWinner: Bool,
        isMyVote: Bool,
        isMe: Bool,
        votes: Int
    ) -> String {
        var parts = [player.displayName]
        if isMe { parts.append("you") }
        if isMyVote { parts.append("your vote") }
        if hasTally { parts.append(votes == 1 ? "1 vote" : "\(votes) votes") }
        if isWinner { parts.append("most votes this round") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Reveal Animation

    private func animateReveal() {
        for (index, player) in players.enumerated() {
            let delay = Double(index) * 0.08
            Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                revealedIds.insert(player.id)
                if player.id == result.highlightPlayerId {
                    #if canImport(UIKit)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    #endif
                }
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if isFinalRound {
            VStack(spacing: 12) {
                Text("Game complete!")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                PrimaryButton("See Final Results", systemImage: "trophy.fill") {
                    onContinue?()
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Next round starting…")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Next round starting soon")
        }
    }
}

// MARK: - Previews

#if DEBUG
private extension VoteRevealView {
    static let samplePrompt = "Most likely to fall asleep during the movie"

    static let playerA = Player(displayName: "Ari", color: .blue, isHost: true)
    static let playerB = Player(displayName: "Bo", color: .green)
    static let playerC = Player(displayName: "Priyanka Chandrasekaran", color: .purple)

    static let samplePlayers = [playerA, playerB, playerC]

    static let sampleResult = RoundResult(
        roundNumber: 2,
        scores: samplePlayers.map { PlayerScore(playerId: $0.id, displayName: $0.displayName, score: 0) },
        highlightPlayerId: playerB.id,
        // Exactly the shape `GameEngine.voteTally` produces: only players
        // who actually received votes appear.
        voteCounts: [playerB.id: 2, playerC.id: 1]
    )

    /// A round nobody voted in — the host sends no tally, so the counts
    /// (and the winner crown) are suppressed rather than shown as zeroes.
    static let noVotesResult = RoundResult(
        roundNumber: 2,
        scores: samplePlayers.map { PlayerScore(playerId: $0.id, displayName: $0.displayName, score: 0) }
    )
}

#Preview("Voted") {
    VoteRevealView(
        roundNumber: 2,
        totalRounds: 5,
        prompt: VoteRevealView.samplePrompt,
        players: VoteRevealView.samplePlayers,
        myVoteTargetId: VoteRevealView.playerB.id,
        myPlayerId: VoteRevealView.playerA.id,
        result: VoteRevealView.sampleResult,
        isFinalRound: false
    )
}

#Preview("No Votes Cast") {
    VoteRevealView(
        roundNumber: 2,
        totalRounds: 5,
        prompt: VoteRevealView.samplePrompt,
        players: VoteRevealView.samplePlayers,
        myVoteTargetId: nil,
        myPlayerId: VoteRevealView.playerA.id,
        result: VoteRevealView.noVotesResult,
        isFinalRound: false
    )
}

#Preview("Didn't Vote") {
    VoteRevealView(
        roundNumber: 2,
        totalRounds: 5,
        prompt: VoteRevealView.samplePrompt,
        players: VoteRevealView.samplePlayers,
        myVoteTargetId: nil,
        myPlayerId: VoteRevealView.playerC.id,
        result: VoteRevealView.sampleResult,
        isFinalRound: false
    )
}

#Preview("Final Round") {
    VoteRevealView(
        roundNumber: 5,
        totalRounds: 5,
        prompt: VoteRevealView.samplePrompt,
        players: VoteRevealView.samplePlayers,
        myVoteTargetId: VoteRevealView.playerB.id,
        myPlayerId: VoteRevealView.playerA.id,
        result: VoteRevealView.sampleResult,
        isFinalRound: true
    ) { }
}

#Preview("Dark") {
    VoteRevealView(
        roundNumber: 2,
        totalRounds: 5,
        prompt: VoteRevealView.samplePrompt,
        players: VoteRevealView.samplePlayers,
        myVoteTargetId: VoteRevealView.playerB.id,
        myPlayerId: VoteRevealView.playerA.id,
        result: VoteRevealView.sampleResult,
        isFinalRound: false
    )
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    VoteRevealView(
        roundNumber: 2,
        totalRounds: 5,
        prompt: VoteRevealView.samplePrompt,
        players: VoteRevealView.samplePlayers,
        myVoteTargetId: VoteRevealView.playerB.id,
        myPlayerId: VoteRevealView.playerA.id,
        result: VoteRevealView.sampleResult,
        isFinalRound: false
    )
    .dynamicTypeSize(.accessibility3)
}
#endif
