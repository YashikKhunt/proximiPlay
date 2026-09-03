//
//  VoteGameView.swift
//  proximiPlay
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders one Vote Battle game end-to-end: prompt → vote → reveal → next
/// round, purely from `GameEngine`'s observable state.
///
/// Deliberately role-agnostic, following `TriviaGameView`'s pattern exactly:
/// every branch below reads `appState.gameEngine` only, so host and joiner
/// devices render identically, and role only matters for input routing via
/// `AppState.submitPlayerInput(_:)`. Also mirrors Trivia's local
/// `roundQueue`/`revealSnapshot` FIFO handling to stay correct even when the
/// host's round loop advances `currentRound` in the same synchronous call
/// that set `lastRoundResult` — see `TriviaGameView`'s doc comment for the
/// full race-avoidance rationale.
///
/// ## Why there's no "N of M voted" progress
///
/// `GameEngine` keeps its per-round `inputs` dictionary private — neither
/// `RoundData` nor `RoundResult` exposes how many players have voted so far,
/// only the eventual `highlightPlayerId` (the most-voted player) once the
/// round ends. Rather than fabricate a count the engine doesn't provide,
/// this view shows a simple "vote is in" waiting state once the local player
/// has voted, matching what's actually observable.
struct VoteGameView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    /// Rounds this device has seen start, oldest-first, awaiting their
    /// reveal. In practice at most one or two entries deep.
    @State private var roundQueue: [RoundSnapshot] = []
    @State private var revealSnapshot: RevealSnapshot?
    @State private var revealAutoAdvanceTask: Task<Void, Never>?

    private var engine: GameEngine { appState.gameEngine }

    /// `GameEngine.totalRounds` is never populated on joiner devices
    /// (`applyFollowerMessage` only mirrors `currentRound`/`lastRoundResult`/
    /// `finalScores`), so fall back to Vote Battle's fixed round count —
    /// identical to what the host actually used, since `GameConfig`'s vote
    /// default doesn't vary by player count.
    private var totalRounds: Int {
        engine.totalRounds > 0 ? engine.totalRounds : GameConfig.defaultConfig(for: .voteBattle).roundCount
    }

    private var currentPrompt: String? {
        guard case .vote(let prompt)? = engine.currentRound else { return nil }
        return prompt
    }

    var body: some View {
        Group {
            if let revealSnapshot {
                VoteRevealView(
                    roundNumber: revealSnapshot.round.roundIndex,
                    totalRounds: totalRounds,
                    prompt: revealSnapshot.round.prompt,
                    players: revealSnapshot.round.players,
                    myVoteTargetId: revealSnapshot.round.myVoteTargetId,
                    myPlayerId: appState.gameSessionManager.myPlayer.id,
                    result: revealSnapshot.result,
                    isFinalRound: revealSnapshot.isFinal
                ) {
                    router.navigate(to: .results)
                }
                .id(revealSnapshot.round.roundIndex)
            } else if let current = roundQueue.last {
                votingView(current)
            } else {
                waitingView
            }
        }
        .animation(.default, value: revealSnapshot != nil)
        .navigationTitle(GameMode.voteBattle.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionIndicator(state: appState.gameSessionManager.connectionState)
            }
        }
        .hostLeftAlert()
        .leaveGameGuard()
        .onChange(of: currentPrompt, initial: true) { _, newPrompt in
            handleNewRound(newPrompt)
        }
        .onChange(of: engine.lastRoundResult?.roundNumber, initial: true) { _, newRoundNumber in
            guard newRoundNumber != nil else { return }
            presentReveal()
        }
        .onDisappear {
            revealAutoAdvanceTask?.cancel()
        }
    }

    // MARK: - Waiting

    private var waitingView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "hand.thumbsup")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.indigo)
                .accessibilityHidden(true)
            Text("Waiting for the first prompt…")
                .font(.headline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .accessibilityHidden(true)
            Spacer()
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for the first prompt")
    }

    // MARK: - Voting

    private func votingView(_ round: RoundSnapshot) -> some View {
        VStack(spacing: 20) {
            RoundHeaderView(roundNumber: round.roundIndex, totalRounds: totalRounds)

            Text(round.prompt)
                .font(.title3.bold())
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                    ForEach(round.players) { player in
                        VotePlayerCard(
                            player: player,
                            isMe: player.id == appState.gameSessionManager.myPlayer.id,
                            state: cardState(for: player, in: round)
                        ) {
                            selectTarget(player.id)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if round.myVoteTargetId != nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Vote in — waiting for others…")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Vote locked in. Waiting for other players.")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func cardState(for player: Player, in round: RoundSnapshot) -> VotePlayerCard.VoteState {
        guard let selected = round.myVoteTargetId else { return .normal }
        return player.id == selected ? .selected : .locked
    }

    private func selectTarget(_ playerId: UUID) {
        guard !roundQueue.isEmpty, roundQueue[roundQueue.count - 1].myVoteTargetId == nil else { return }

        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif

        roundQueue[roundQueue.count - 1].myVoteTargetId = playerId
        appState.submitPlayerInput(.vote(targetPlayerId: playerId))
    }

    // MARK: - Round Transitions

    private func handleNewRound(_ prompt: String?) {
        guard let prompt else { return }
        let nextIndex = (roundQueue.last?.roundIndex ?? 0) + 1
        roundQueue.append(
            RoundSnapshot(
                roundIndex: nextIndex,
                prompt: prompt,
                players: appState.gameSessionManager.roster.players,
                myVoteTargetId: nil
            )
        )
    }

    private func presentReveal() {
        guard let result = engine.lastRoundResult, !roundQueue.isEmpty else { return }
        let completedRound = roundQueue.removeFirst()

        revealAutoAdvanceTask?.cancel()
        let isFinal = engine.finalScores != nil
        revealSnapshot = RevealSnapshot(round: completedRound, result: result, isFinal: isFinal)

        guard !isFinal else { return }
        revealAutoAdvanceTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            revealSnapshot = nil
        }
    }

    // MARK: - Types

    private struct RoundSnapshot: Equatable {
        let roundIndex: Int
        let prompt: String
        let players: [Player]
        var myVoteTargetId: UUID?
    }

    private struct RevealSnapshot {
        let round: RoundSnapshot
        let result: RoundResult
        let isFinal: Bool
    }
}

// MARK: - Player Vote Card

/// A tappable player card in the voting grid — the sole voting affordance
/// (no separate submit button). Tapping depresses and selects the card;
/// once any card is selected, every card locks to prevent changing a vote.
private struct VotePlayerCard: View {
    enum VoteState {
        case normal
        case selected
        case locked
    }

    let player: Player
    let isMe: Bool
    let state: VoteState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                PlayerBadge(player: player)

                if state == .selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.indigo)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                state == .selected ? Color.indigo.opacity(0.15) : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(state == .selected ? Color.indigo : .clear, lineWidth: 2)
            }
            .scaleEffect(state == .selected ? 0.97 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state)
        .disabled(state == .locked)
        .opacity(state == .locked ? 0.5 : 1.0)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(state == .selected ? [.isSelected] : [])
        .accessibilityHint(state == .normal ? "Double-tap to vote for this player" : "")
    }

    private var accessibilityLabel: String {
        var parts = [player.displayName]
        if isMe { parts.append("you") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func votePreviewAppState(roundCount: Int = 3) -> AppState {
    let appState = AppState()
    let host = Player(displayName: "Ari", color: .blue, isHost: true)
    let joiner1 = Player(displayName: "Bo", color: .green)
    let joiner2 = Player(displayName: "Priyanka Chandrasekaran", color: .purple)

    appState.gameSessionManager.isHost = true
    appState.gameSessionManager.myPlayer = host
    appState.gameSessionManager.roster.setHost(host)

    appState.gameEngine.startGame(
        mode: .voteBattle,
        roster: [host, joiner1, joiner2],
        config: GameConfig(roundCount: roundCount, timePerRound: 30)
    )

    return appState
}

#Preview("Waiting") {
    NavigationStack {
        VoteGameView()
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Voting") {
    NavigationStack {
        VoteGameView()
    }
    .environment(votePreviewAppState())
    .environment(Router())
}

#Preview("Dark") {
    NavigationStack {
        VoteGameView()
    }
    .environment(votePreviewAppState())
    .environment(Router())
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        VoteGameView()
    }
    .environment(votePreviewAppState())
    .environment(Router())
    .dynamicTypeSize(.accessibility3)
}
#endif
