//
//  DrawGameView.swift
//  proximiPlay
//

import MultipeerConnectivity
import SwiftUI

/// Renders one Speed Draw game end-to-end: word → draw/guess → reveal →
/// next round, purely from `GameEngine`'s observable state.
///
/// Follows `TriviaGameView`/`VoteGameView`'s established pattern exactly: a
/// local FIFO `roundQueue`/`revealSnapshot` pair avoids the same-tick
/// `currentRound` → `lastRoundResult` race described in `TriviaGameView`'s
/// doc comment, and every branch below reads `appState.gameEngine` only, so
/// host and joiner devices render identically. Role only ever changes what's
/// *displayed and interactive* — the drawer sees the word and a live canvas,
/// everyone else sees a read-only canvas and `GuessInputView`.
///
/// ## Why the word is never hidden from `RoundData`
///
/// `GameEngine.makeRoundData(for:)` broadcasts `.draw(word:drawerId:)` to
/// **every** device, drawer and guessers alike — there is no separate
/// per-role payload on the wire. This view enforces the "don't show
/// anyone" rule purely at render time (only the drawer's branch ever puts
/// `round.word` on screen); it does not — and structurally cannot, without
/// touching `GameEngine`, which is out of scope here — stop a modified
/// client from reading its own local `currentRound`. That's an accepted
/// trust boundary for a same-room party game, identical in spirit to how
/// Quick Trivia trusts the client to submit only one answer.
///
/// ## Stroke sync bypasses the engine entirely
///
/// `GameEngine.submitInput` treats `.drawStroke` as a no-op (see its doc
/// comment) — strokes are peer-to-peer rendering data, not scored input.
/// This view never routes strokes through `AppState.submitPlayerInput`;
/// instead `sendStrokeBatch(_:)` sends them directly over
/// `GameSessionManager`, unreliable, host-relayed so every device converges
/// on the same drawing regardless of who's actually drawing. See
/// `StrokeSync`'s doc comment for the full wire convention.
struct DrawGameView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    /// Rounds this device has seen start, oldest-first, awaiting their
    /// reveal. In practice at most one or two entries deep.
    @State private var roundQueue: [RoundSnapshot] = []
    @State private var revealSnapshot: RevealSnapshot?
    @State private var revealAutoAdvanceTask: Task<Void, Never>?
    /// Cumulative scores as of the most recently shown reveal — the
    /// baseline the *next* reveal diffs against to show per-round point
    /// gains. Empty before round 1 (everyone starts at 0).
    @State private var scoresBeforeReveal: [UUID: Int] = [:]

    private var engine: GameEngine { appState.gameEngine }
    private var myPlayerId: UUID { appState.gameSessionManager.myPlayer.id }

    /// `GameEngine.totalRounds` is never populated on joiner devices (see
    /// `TriviaGameView`'s identical fallback). Speed Draw's round count
    /// depends on the roster size (one round per player), so this falls
    /// back to the *current* roster size rather than a fixed constant.
    private var totalRounds: Int {
        if engine.totalRounds > 0 { return engine.totalRounds }
        let playerCount = appState.gameSessionManager.roster.players.count
        return GameConfig.defaultConfig(for: .speedDraw, playerCount: playerCount).roundCount
    }

    private var currentDrawPayload: DrawPayload? {
        guard case .draw(let word, let drawerId)? = engine.currentRound else { return nil }
        return DrawPayload(word: word, drawerId: drawerId)
    }

    var body: some View {
        Group {
            if let revealSnapshot {
                DrawRoundResultView(
                    roundNumber: revealSnapshot.round.roundIndex,
                    totalRounds: totalRounds,
                    word: revealSnapshot.round.word,
                    drawerId: revealSnapshot.round.drawerId,
                    myPlayerId: myPlayerId,
                    result: revealSnapshot.result,
                    previousScores: revealSnapshot.baselineScores,
                    isFinalRound: revealSnapshot.isFinal
                ) {
                    router.navigate(to: .results)
                }
            } else if let current = roundQueue.last {
                playingView(current)
            } else {
                waitingView
            }
        }
        .animation(.default, value: revealSnapshot != nil)
        .navigationTitle(GameMode.speedDraw.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionIndicator(state: appState.gameSessionManager.connectionState)
            }
        }
        .hostLeftAlert()
        .leaveGameGuard()
        .onChange(of: currentDrawPayload, initial: true) { _, newPayload in
            handleNewRound(newPayload)
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
            Image(systemName: "pencil.tip")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.indigo)
                .accessibilityHidden(true)
            Text("Waiting for the first word…")
                .font(.headline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .accessibilityHidden(true)
            Spacer()
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for the first word")
    }

    // MARK: - Playing

    /// The drawer's branch has no text input, so keyboard avoidance never
    /// comes into play there — it stays a single `VStack`. The guesser's
    /// branch does, though: `GuessInputView`'s `TextField` pulls the
    /// keyboard up, and if the guess bar sits inside the same `VStack` as
    /// the canvas, SwiftUI's keyboard avoidance shoves the *whole* stack
    /// upward, pushing the drawing off the top of the screen right when a
    /// guesser most needs to see it while typing. Floating the guess bar in
    /// `.safeAreaInset(edge: .bottom)` on the outer container instead keeps
    /// it out of that keyboard-shifted content: the canvas area above it
    /// resizes to make room for both the inset and the keyboard, so both
    /// stay visible and readable at once.
    @ViewBuilder
    private func playingView(_ round: RoundSnapshot) -> some View {
        let isDrawer = round.drawerId == myPlayerId

        if isDrawer {
            VStack(spacing: 16) {
                RoundHeaderView(roundNumber: round.roundIndex, totalRounds: totalRounds)
                drawerBanner(word: round.word)
                DrawingCanvasView(isEditable: true, onStrokeBatch: sendStrokeBatch)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        } else {
            VStack(spacing: 16) {
                RoundHeaderView(roundNumber: round.roundIndex, totalRounds: totalRounds)
                DrawingCanvasView(
                    isEditable: false,
                    segments: appState.strokeSync.segments
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .safeAreaInset(edge: .bottom) {
                GuessInputView(onSubmit: submitGuess)
                    .id(round.roundIndex)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .background(.bar)
            }
        }
    }

    private func drawerBanner(word: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Draw: \(word)")
                .font(.title3.bold())
                .foregroundStyle(Color.primary)
            Text("Don't show anyone!")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Draw \(word). Don't show anyone your screen.")
    }

    // MARK: - Input Routing

    private func submitGuess(_ text: String) {
        appState.submitPlayerInput(.guess(text: text))
    }

    /// Streams one outbound stroke batch, entirely outside `GameEngine` and
    /// `AppState.submitPlayerInput`: the host broadcasts straight to every
    /// connected peer (it's directly connected to all of them); a joiner —
    /// only ever directly connected to the host in this app's star-shaped
    /// Multipeer session — sends to the host alone and relies on
    /// `AppState`'s `.drawStroke` relay to reach every other joiner. See
    /// `StrokeSync`'s doc comment for the receiving side of this contract.
    private func sendStrokeBatch(_ points: [CodablePoint]) {
        let session = appState.gameSessionManager
        let message = GameMessage.playerInput(playerId: session.myPlayer.id, input: .drawStroke(points: points))

        if session.isHost {
            let peers = session.connectedPeers
            guard !peers.isEmpty else { return }
            session.send(message, to: peers, mode: .unreliable)
        } else {
            guard let hostPlayer = session.roster.players.first,
                  let hostPeer = session.roster.peerID(for: hostPlayer.id) else { return }
            session.send(message, to: [hostPeer], mode: .unreliable)
        }
    }

    // MARK: - Round Transitions

    private func handleNewRound(_ payload: DrawPayload?) {
        guard let payload else { return }
        appState.strokeSync.clear()
        let nextIndex = (roundQueue.last?.roundIndex ?? 0) + 1
        roundQueue.append(RoundSnapshot(roundIndex: nextIndex, word: payload.word, drawerId: payload.drawerId))
    }

    private func presentReveal() {
        guard let result = engine.lastRoundResult, !roundQueue.isEmpty else { return }
        let completedRound = roundQueue.removeFirst()

        revealAutoAdvanceTask?.cancel()
        let isFinal = engine.finalScores != nil
        revealSnapshot = RevealSnapshot(
            round: completedRound,
            result: result,
            baselineScores: scoresBeforeReveal,
            isFinal: isFinal
        )
        scoresBeforeReveal = Dictionary(uniqueKeysWithValues: result.scores.map { ($0.playerId, $0.score) })

        guard !isFinal else { return }
        revealAutoAdvanceTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            revealSnapshot = nil
        }
    }

    // MARK: - Types

    private struct DrawPayload: Equatable {
        let word: String
        let drawerId: UUID
    }

    private struct RoundSnapshot: Equatable {
        let roundIndex: Int
        let word: String
        let drawerId: UUID
    }

    private struct RevealSnapshot {
        let round: RoundSnapshot
        let result: RoundResult
        let baselineScores: [UUID: Int]
        let isFinal: Bool
    }
}

// MARK: - Round Result Reveal

/// The interstitial shown between Speed Draw rounds: reveals the word, who
/// guessed it (if anyone), and the running standings — mirroring
/// `TriviaRoundResultView`'s layout and reveal pattern. Kept private to this
/// file rather than split out, since Speed Draw's task scope only calls for
/// three new files.
private struct DrawRoundResultView: View {
    let roundNumber: Int
    let totalRounds: Int
    let word: String
    let drawerId: UUID
    let myPlayerId: UUID
    let result: RoundResult
    let previousScores: [UUID: Int]
    let isFinalRound: Bool
    var onContinue: (() -> Void)?

    private var winnerName: String? {
        guard let highlightId = result.highlightPlayerId, highlightId != drawerId else { return nil }
        return result.scores.first { $0.playerId == highlightId }?.displayName
    }

    private var rankedScores: [RankedScore] {
        result.scores
            .map { score in
                RankedScore(
                    playerId: score.playerId,
                    displayName: score.displayName,
                    total: score.score,
                    delta: score.score - (previousScores[score.playerId] ?? 0)
                )
            }
            .sorted {
                $0.total != $1.total ? $0.total > $1.total : $0.displayName < $1.displayName
            }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(isFinalRound ? "Final Round" : "Round \(roundNumber) of \(totalRounds)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                wordReveal

                standings

                footer
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
    }

    private var wordReveal: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The word was")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            Text(word.capitalized)
                .font(.title2.bold())
                .foregroundStyle(Color.primary)

            if let winnerName {
                Label("\(winnerName) guessed it!", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.green)
            } else {
                Label("Nobody guessed it", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var standings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Standings")
                .font(.headline)
                .foregroundStyle(Color.primary)

            VStack(spacing: 8) {
                ForEach(Array(rankedScores.enumerated()), id: \.element.playerId) { position, score in
                    standingRow(rank: position + 1, score: score)
                }
            }
        }
    }

    private func standingRow(rank: Int, score: RankedScore) -> some View {
        let isDrawer = score.playerId == drawerId
        let isMe = score.playerId == myPlayerId

        return HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(score.displayName)
                        .font(.subheadline.weight(isMe ? .bold : .regular))
                        .foregroundStyle(Color.primary)
                    if isDrawer {
                        Image(systemName: "pencil.tip")
                            .font(.caption)
                            .foregroundStyle(Color.indigo)
                            .accessibilityHidden(true)
                    }
                }
                Text("\(score.total) total")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 0)

            Text(score.delta > 0 ? "+\(score.delta)" : "\(score.delta)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(score.delta > 0 ? Color.green : Color.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isMe ? Color.indigo.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(score.displayName)\(isMe ? ", you" : "")\(isDrawer ? ", drawer" : ""), rank \(rank), "
                + "\(score.delta > 0 ? "gained \(score.delta) points" : "no points gained") this round, "
                + "\(score.total) points total"
        )
    }

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

    private struct RankedScore {
        let playerId: UUID
        let displayName: String
        let total: Int
        let delta: Int
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func drawPreviewAppState(roundCount: Int = 3, asDrawer: Bool = true) -> AppState {
    let appState = AppState()
    let host = Player(displayName: "Ari", color: .blue, isHost: true)
    let joiner1 = Player(displayName: "Bo", color: .green)
    let joiner2 = Player(displayName: "Priyanka Chandrasekaran", color: .purple)

    appState.gameSessionManager.isHost = true
    appState.gameSessionManager.myPlayer = asDrawer ? host : joiner1
    appState.gameSessionManager.roster.setHost(host)

    appState.gameEngine.startGame(
        mode: .speedDraw,
        roster: [host, joiner1, joiner2],
        config: GameConfig(roundCount: roundCount, timePerRound: 60)
    )

    return appState
}

#Preview("Waiting") {
    NavigationStack {
        DrawGameView()
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Drawer") {
    NavigationStack {
        DrawGameView()
    }
    .environment(drawPreviewAppState(asDrawer: true))
    .environment(Router())
}

#Preview("Guesser") {
    NavigationStack {
        DrawGameView()
    }
    .environment(drawPreviewAppState(asDrawer: false))
    .environment(Router())
}

#Preview("Dark") {
    NavigationStack {
        DrawGameView()
    }
    .environment(drawPreviewAppState(asDrawer: true))
    .environment(Router())
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        DrawGameView()
    }
    .environment(drawPreviewAppState(asDrawer: false))
    .environment(Router())
    .dynamicTypeSize(.accessibility3)
}
#endif
