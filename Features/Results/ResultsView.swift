//
//  ResultsView.swift
//  proximiPlay
//

import SwiftUI
import SwiftData
import MultipeerConnectivity
#if canImport(UIKit)
import UIKit
#endif

/// The final-standings screen shown after a game's last round ends, reached
/// via `router.navigate(to: .results)` from every mode view's final-round
/// "continue" action.
///
/// Renders identically for host and joiner, following the rest of the app's
/// role-agnostic view pattern — the only place role matters is which actions
/// are offered (`actions`) and which device writes to SwiftData
/// (`persistIfNeeded()`, host-only).
///
/// ## Where `mode` comes from
///
/// Straight from `GameEngine.mode`, on both roles: the host sets it in
/// `startGame(mode:roster:)` and a joiner mirrors it from the host's
/// `.gameStart` (`GameEngine.applyFollowerMessage`). It used to be derived
/// from `AppState.currentGameState` purely because `applyFollowerMessage`
/// never set `mode`, leaving it `nil` on every joiner — that gap is closed,
/// so the engine is now the single source for "which mode just finished."
///
/// ## "Play Again" / "Back to Lobby" sync design
///
/// Both host actions are broadcast, so joiners follow immediately instead of
/// sitting on stale final scores:
///
/// - **Play Again** reuses `.gameStart` (the same message
///   `LobbyView.startGame()` sends), so joiners' existing navigation
///   plumbing already knows how to follow it. The one wrinkle:
///   `GameSessionManager.lastGameStart` only changes value the *first* time
///   a mode starts — replaying the *same* mode wouldn't re-fire a SwiftUI
///   `.onChange`. `lastGameStartToken` (a monotonic counter bumped on every
///   `.gameStart`) exists purely to make that re-trigger reliable.
/// - **Back to Lobby** broadcasts `.lobbyReturn`. Joiners follow it from
///   `ContentView`, not from here: a joiner can still be sitting on a mode
///   view's final-round reveal when the host taps it, and only a
///   root-level observer of `GameSessionManager.lobbyReturnToken` brings
///   *every* screen back. The Multipeer session stays connected — only the
///   finished game is torn down — so everyone lands back in `LobbyView`
///   together and waits for the host's next pick.
///
/// Both are host-authoritative and origin-gated in
/// `GameSessionManager.receive(_:from:)`: a joiner can neither forge them
/// nor have the host follow one.
struct ResultsView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.motionReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Guards `persistIfNeeded()` against re-entry (e.g. a second
    /// `onAppear` from a SwiftUI re-render) so at most one `GameHistory`
    /// row is ever written per finished game.
    @State private var didPersist = false
    /// Drives the winner crown / header-icon spring entrance across the
    /// whole screen, flipped once in `onAppear`.
    @State private var animateReveal = false
    /// The rasterized `ShareCardView`, produced once scores land (see
    /// `renderShareCard()`) and handed to the toolbar `ShareLink`. `nil`
    /// while rendering hasn't happened yet — the toolbar shows a spinner
    /// rather than a button that would do nothing if tapped.
    @State private var shareImage: UIImage?

    private var engine: GameEngine { appState.gameEngine }
    private var sessionManager: GameSessionManager { appState.gameSessionManager }
    private var isHost: Bool { sessionManager.isHost }

    private var finalScores: [PlayerScore] { engine.finalScores ?? [] }

    /// See "Where `mode` comes from" above.
    private var mode: GameMode? { engine.mode }

    private var isVoteBattle: Bool { mode == .voteBattle }

    private var rankedScores: [RankedPlayerScore] {
        finalScores
            .map { RankedPlayerScore(playerId: $0.playerId, displayName: $0.displayName, score: $0.score) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.displayName < $1.displayName }
    }

    private var topScore: Int { rankedScores.first?.score ?? 0 }

    /// Same trigger as `LobbyView`/`GameHostView`'s banner: `ConnectionMonitor`
    /// keeps running through Results (nothing stops it until the session
    /// itself tears down), so a peer's heartbeat going quiet while everyone's
    /// looking at final scores — right before a host might tap "Play Again"
    /// — is just as worth surfacing here.
    private var reconnectingBanner: StatusBanner? {
        guard appState.connectionMonitor.isMonitoring,
              appState.connectionMonitor.peerHealth.values.contains(.lost) else { return nil }
        return StatusBanner(
            tone: .warning,
            systemImage: "wifi.exclamationmark",
            message: "Connection lost — reconnecting…"
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if isVoteBattle {
                    voteBattleSummary
                } else {
                    standings
                }
                actions
                leaveGameButton
            }
            .padding(20)
        }
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                shareButton
            }
        }
        .statusBannerOverlay(reconnectingBanner)
        .hostLeftAlert()
        .onAppear {
            persistIfNeeded()
            triggerCelebration()
            renderShareCard()
        }
        .onChange(of: sessionManager.lastGameStartToken) { _, _ in
            handleGameStartRebroadcast()
        }
        .onChange(of: colorScheme) { _, _ in
            renderShareCard()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                // Purely decorative flourish behind the trophy — skipped
                // entirely under Reduce Motion rather than shown as a
                // static, frozen scatter of sparkles (which would just read
                // as clutter with no motion to justify it). The trophy +
                // "Final Results" text alone already fully communicate the
                // win either way, so nothing here ever gates visible
                // information.
                if !reduceMotion && !isVoteBattle {
                    ConfettiBurst()
                }

                Image(systemName: isVoteBattle ? "party.popper.fill" : "trophy.fill")
                    .font(.system(size: 56))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.yellow)
                    .scaleEffect(animateReveal ? 1.0 : 0.6)
                    .opacity(animateReveal ? 1.0 : 0.0)
                    .motionEffect(reduceMotion: reduceMotion) { $0.symbolEffect(.bounce, value: animateReveal) }
                    .accessibilityHidden(true)
            }

            Text(mode?.displayName ?? "Game")
                .font(.headline)
                .foregroundStyle(Color.secondary)

            Text(isVoteBattle ? "Great game, everyone!" : "Final Results")
                .font(.largeTitle.bold())
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Competitive Standings

    private var standings: some View {
        VStack(spacing: 12) {
            ForEach(Array(rankedScores.enumerated()), id: \.element.id) { index, score in
                standingRow(rank: index + 1, score: score)
            }
        }
    }

    private func standingRow(rank: Int, score: RankedPlayerScore) -> some View {
        let isWinner = score.score == topScore
        let isMe = score.playerId == sessionManager.myPlayer.id
        let player = sessionManager.roster.players.first { $0.id == score.playerId }

        return HStack(spacing: 14) {
            Text("\(rank)")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(isWinner ? Color.yellow : Color.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            if let player {
                PlayerBadge(player: player)
            } else {
                fallbackAvatar(initial: score.displayName)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(score.displayName)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    if isWinner {
                        Image(systemName: "crown.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.yellow)
                            .scaleEffect(animateReveal ? 1.0 : 0.4)
                            .opacity(animateReveal ? 1.0 : 0.0)
                            .accessibilityHidden(true)
                    }
                }
                if isMe {
                    Text("You")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer(minLength: 0)

            // The emotional peak of the app — every score counts up rather
            // than snapping into place. See `AnimatedScoreText`.
            AnimatedScoreText(
                value: score.score,
                from: 0,
                font: .title3.weight(.bold),
                color: isWinner ? Color.yellow : Color.primary
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            isWinner ? Color.yellow.opacity(0.15) : Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(isWinner ? Color.yellow : .clear, lineWidth: 2)
        }
        // The winner's row gets the bouncier `Motion.celebration` spring —
        // everyone else gets the standard `Motion.arrival` — both staggered
        // by rank so standings cascade in rather than arriving as one
        // block. `.motion(_:value:)` collapses either preset to an instant,
        // fully-visible cut under Reduce Motion.
        .motion(
            (isWinner ? Motion.celebration : Motion.arrival)
                .delay(Motion.staggerDelay(index: rank - 1, reduceMotion: reduceMotion)),
            value: animateReveal
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(score.displayName)\(isMe ? ", you" : ""), rank \(rank)"
                + "\(isWinner ? ", winner" : ""), \(score.score) points"
        )
    }

    // MARK: - Vote Battle Summary

    /// Vote Battle never awards points (`GameEngine.computeScoreDeltas`
    /// returns an empty diff for it), so a competitive rank-by-score list
    /// would just show everyone tied at zero. Instead this mirrors
    /// `VoteRevealView`'s social framing: no ranking, just the roster, the
    /// *last round's* per-player counts (`RoundResult.voteCounts`, the only
    /// tally the wire carries — `GameEngine` accumulates no game-long one)
    /// and a callout for who won it, both honestly labeled as last-round
    /// figures rather than inventing a game-long total.
    private var voteBattleSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Votes are just for fun — no points awarded.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)

            VStack(spacing: 8) {
                ForEach(Array(finalScores.enumerated()), id: \.element.id) { index, score in
                    voteBattleRow(for: score, index: index)
                }
            }
        }
    }

    private func voteBattleRow(for score: PlayerScore, index: Int) -> some View {
        let lastRound = engine.lastRoundResult
        let isFanFavorite = lastRound?.highlightPlayerId == score.playerId
        let isMe = score.playerId == sessionManager.myPlayer.id
        let player = sessionManager.roster.players.first { $0.id == score.playerId }
        let votes = lastRound?.voteCounts != nil ? lastRound?.voteCount(for: score.playerId) : nil

        return HStack(spacing: 14) {
            if let player {
                PlayerBadge(player: player)
            } else {
                fallbackAvatar(initial: score.displayName)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(score.displayName)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                if isMe {
                    Text("You")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer(minLength: 0)

            if isFanFavorite {
                Label("Last Round Favorite", systemImage: "crown.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.yellow)
                    .labelStyle(.titleAndIcon)
                    .scaleEffect(animateReveal ? 1.0 : 0.4)
                    .opacity(animateReveal ? 1.0 : 0.0)
            }

            if let votes {
                Text(votes == 1 ? "1 vote" : "\(votes) votes")
                    .font(.caption.weight(isFanFavorite ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isFanFavorite ? Color.yellow : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        isFanFavorite ? Color.yellow.opacity(0.2) : Color.secondary.opacity(0.12),
                        in: Capsule()
                    )
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            isFanFavorite ? Color.yellow.opacity(0.15) : Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .motion(
            (isFanFavorite ? Motion.celebration : Motion.arrival)
                .delay(Motion.staggerDelay(index: index, reduceMotion: reduceMotion)),
            value: animateReveal
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(score.displayName)\(isMe ? ", you" : "")\(isFanFavorite ? ", last round favorite" : "")"
                + (votes.map { ", \($0 == 1 ? "1 vote" : "\($0) votes") last round" } ?? "")
        )
    }

    private func fallbackAvatar(initial name: String) -> some View {
        Circle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 50, height: 50)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.title2.bold())
                    // The fill is a 30%-opacity neutral, so white sits at
                    // roughly 1.2:1 against it. `.primary` adapts with the
                    // colour scheme and clears AA in both.
                    .foregroundStyle(Color.primary)
            }
            .accessibilityHidden(true)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        if isHost {
            VStack(spacing: 12) {
                PrimaryButton("Play Again", systemImage: "arrow.clockwise") {
                    playAgain()
                }
                Button {
                    backToLobby()
                } label: {
                    Text("Back to Lobby")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Back to Lobby")
                .accessibilityHint("Returns everyone to the lobby to choose the next game")
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .accessibilityHidden(true)
                // Names both what's being waited on and who can end the
                // wait, in the on-screen text itself — not just the
                // accessibility label below — so a sighted joiner gets the
                // same "am I stuck, or is this on the host" answer a
                // VoiceOver user gets.
                Text("Waiting for the host to start the next game…")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Waiting for the host to start the next game")
        }
    }

    // MARK: - Share

    /// Lives in the navigation bar rather than alongside `actions` on
    /// purpose: `actions` is role-dependent (host gets Play Again/Back to
    /// Lobby, a joiner gets a waiting hint), but sharing the final
    /// scoreboard is something *everyone* on the call should be able to do,
    /// and a toolbar item can't be mistaken for "the host's button" the way
    /// a third stacked action under Play Again could be. It also can't
    /// compete for attention with Play Again the way a same-list action
    /// would — it's off to the side, always in the same place.
    ///
    /// Shows a small spinner instead of a dead button while
    /// `renderShareCard()` hasn't produced an image yet (rendering is
    /// synchronous and near-instant, but scores could in principle arrive a
    /// beat after the screen appears).
    @ViewBuilder
    private var shareButton: some View {
        if let shareImage {
            ShareLink(
                item: Image(uiImage: shareImage),
                preview: SharePreview(shareTitle, image: Image(uiImage: shareImage))
            ) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share results")
            .accessibilityHint("Shares an image of the final scoreboard")
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        }
    }

    private var shareTitle: String {
        "\(mode?.displayName ?? "Game") Results"
    }

    /// Every row `ShareCardView` draws, resolved from `finalScores` (for
    /// display names/order) joined against the roster (for colour) exactly
    /// like `standingRow`/`voteBattleRow` above already do — just packaged
    /// into the card's simpler, engine-independent `ShareCardEntry`.
    private var shareCardEntries: [ShareCardEntry] {
        if isVoteBattle {
            let lastRound = engine.lastRoundResult
            return finalScores.map { score in
                let player = sessionManager.roster.players.first { $0.id == score.playerId }
                let votes = lastRound?.voteCounts != nil ? lastRound?.voteCount(for: score.playerId) ?? 0 : 0
                return ShareCardEntry(
                    id: score.playerId,
                    displayName: score.displayName,
                    color: player?.color ?? .blue,
                    value: votes,
                    isHighlighted: lastRound?.highlightPlayerId == score.playerId
                )
            }
        } else {
            return rankedScores.map { ranked in
                let player = sessionManager.roster.players.first { $0.id == ranked.playerId }
                return ShareCardEntry(
                    id: ranked.playerId,
                    displayName: ranked.displayName,
                    color: player?.color ?? .blue,
                    value: ranked.score,
                    isHighlighted: ranked.score == topScore
                )
            }
        }
    }

    /// See `RoundResult.voteCounts`'s doc comment: Vote Battle awards no
    /// points, so the card states that plainly rather than rendering an
    /// all-zero scoreboard that would read as a scoring bug.
    private var shareCardSubtitle: String? {
        isVoteBattle ? "Votes are just for fun — no points awarded." : nil
    }

    private var shareCard: ShareCardView? {
        guard let mode else { return nil }
        return ShareCardView(
            mode: mode,
            isVoteBattle: isVoteBattle,
            entries: shareCardEntries,
            subtitle: shareCardSubtitle
        )
    }

    /// Rasterizes the card once final scores (and `mode`) are available.
    /// Re-run on colour scheme changes so a card rendered right as the
    /// system switches appearance still matches what's currently on
    /// screen. Deliberately *not* re-run by "Play Again"/"Back to Lobby" —
    /// see those actions' doc comments: this screen navigates away before
    /// either takes effect, so there's no stale image to worry about, and
    /// nothing here touches the session or engine either way. Cancelling
    /// the resulting share sheet is a pure UIKit sheet dismissal with no
    /// completion handler wired to any of this app's state, so scores and
    /// the session are untouched by a cancel.
    private func renderShareCard() {
        guard !finalScores.isEmpty, let shareCard else {
            shareImage = nil
            return
        }
        shareImage = shareCard.rendered(colorScheme: colorScheme)
    }

    private var leaveGameButton: some View {
        Button {
            appState.leaveSession()
            router.popToRoot()
        } label: {
            Text("Leave Game")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .frame(minHeight: 44)
        }
        .accessibilityLabel("Leave Game")
        .accessibilityHint("Disconnects you from this game session and returns to the home screen")
    }

    // MARK: - Host Actions

    /// Re-broadcasts `.gameStart` for the mode that just finished — the
    /// same message `LobbyView.startGame()` sends, so joiners' existing
    /// `.gameStart`-observing navigation (now also live on this screen,
    /// see `handleGameStartRebroadcast()`) follows automatically. The
    /// engine is reset *before* broadcasting so no stale `finalScores`/
    /// `currentRound` linger in the moment between the message going out
    /// and `GameHostView.task`'s own `startGame` call actually restarting
    /// the round loop once this device navigates to the fresh game screen.
    private func playAgain() {
        guard isHost, let mode else { return }
        let roster = sessionManager.roster.players
        let config = GameConfig.defaultConfig(for: mode, playerCount: roster.count)

        engine.reset()
        sessionManager.broadcast(.gameStart(mode: mode, config: config))
        appState.currentGameState = .playing(mode)
        router.replaceTop(with: .game(mode))
    }

    /// Host-only: tells everyone the game is over, then clears the finished
    /// game and pops back to a fresh `LobbyView` push (mirroring
    /// `HomeView`'s own "Start Game" -> `.lobby` navigation) so the host can
    /// pick any mode next, including a different one.
    ///
    /// The `.lobbyReturn` broadcast goes out *before* the local teardown so
    /// joiners start moving at the same moment; the Multipeer session itself
    /// is untouched, so nobody has to rediscover or re-invite anyone.
    /// Joiners run the mirror image of the two lines below from
    /// `ContentView`'s `lobbyReturnToken` observer.
    private func backToLobby() {
        guard isHost else { return }
        sessionManager.broadcast(.lobbyReturn)
        appState.returnToLobbyAfterHostReturn()
        router.popToRoot()
        router.navigate(to: .lobby)
    }

    /// Joiner-only: follows the host's "Play Again" the moment its
    /// `.gameStart` rebroadcast arrives — see this file's doc comment for
    /// why `lastGameStartToken`, not `lastGameStart` itself, is observed.
    private func handleGameStartRebroadcast() {
        guard !isHost, let newMode = sessionManager.lastGameStart?.mode else { return }
        appState.currentGameState = .playing(newMode)
        router.replaceTop(with: .game(newMode))
    }

    // MARK: - Celebration

    /// Flips `animateReveal`, which every crown/trophy/row reveal above
    /// keys off. Routed through `Motion.withAnimation` rather than the raw
    /// `withAnimation(_:)` this used to call directly — under Reduce Motion
    /// `animateReveal` still flips to `true` (every row still becomes fully
    /// visible), the transaction just isn't animated.
    private func triggerCelebration() {
        Motion.withAnimation(Motion.celebration, reduceMotion: reduceMotion) {
            animateReveal = true
        }
        HapticEngine.shared.play(.winnerReveal)
        SoundPlayer.shared.play(.winnerReveal)
    }

    // MARK: - Persistence

    /// Writes exactly one `GameHistory` row and upserts each player's
    /// `PlayerStats`, host-only (the host is this app's single source of
    /// truth — see `GameEngine`'s doc comment) and guarded by `didPersist`
    /// against a repeat `onAppear`.
    private func persistIfNeeded() {
        guard isHost, !didPersist, let mode, !finalScores.isEmpty else { return }
        didPersist = true

        let winnerNames = isVoteBattle
            ? []
            : rankedScores.filter { $0.score == topScore }.map(\.displayName)
        let myScore = finalScores.first { $0.playerId == sessionManager.myPlayer.id }?.score ?? 0

        let history = GameHistory(
            gameMode: mode,
            playerCount: finalScores.count,
            winnerName: winnerNames.isEmpty ? nil : winnerNames.joined(separator: " & "),
            myScore: myScore,
            rounds: max(engine.roundNumber, 1),
            duration: gameDuration(for: mode)
        )
        modelContext.insert(history)

        // One fetch for every finishing player, not one per player: the old
        // loop issued up to 8 synchronous `FetchDescriptor`s on the main
        // thread at the exact moment the celebration animation starts.
        let existing = (try? PlayerStatsBatchLoader.existingStats(
            for: finalScores.map(\.displayName),
            in: modelContext
        )) ?? [:]

        for score in finalScores {
            upsertPlayerStats(
                for: score,
                isWinner: !isVoteBattle && score.score == topScore,
                mode: mode,
                existing: existing[score.displayName]
            )
        }

        try? modelContext.save()
    }

    /// The real elapsed time from `GameEngine`, which stamps a start on
    /// `startGame`/`.gameStart` and captures the duration once when the game
    /// actually ends (so it doesn't keep growing while someone lingers here).
    ///
    /// Falls back to the old rounds x per-round-budget estimate only if the
    /// engine has no timestamp — e.g. a joiner that missed `.gameStart`.
    private func gameDuration(for mode: GameMode) -> TimeInterval {
        if let measured = engine.lastGameDuration { return measured }
        let config = GameConfig.defaultConfig(for: mode, playerCount: max(finalScores.count, 1))
        return config.timePerRound * Double(max(engine.roundNumber, 1))
    }

    private func upsertPlayerStats(
        for score: PlayerScore,
        isWinner: Bool,
        mode: GameMode,
        existing: PlayerStats?
    ) {
        if let stats = existing {
            stats.gamesPlayed += 1
            if isWinner { stats.gamesWon += 1 }
            stats.totalScore += score.score
            if stats.favoriteMode == nil { stats.favoriteMode = mode.rawValue }
            stats.lastPlayedDate = Date()
        } else {
            let stats = PlayerStats(
                displayName: score.displayName,
                gamesPlayed: 1,
                gamesWon: isWinner ? 1 : 0,
                totalScore: score.score,
                favoriteMode: mode,
                lastPlayedDate: Date()
            )
            modelContext.insert(stats)
        }
    }

    // MARK: - Types

    private struct RankedPlayerScore: Identifiable {
        let playerId: UUID
        let displayName: String
        let score: Int
        var id: UUID { playerId }
    }
}

// MARK: - Animated Score Text

/// Rolls a running total from `from` up to `value` using
/// `.contentTransition(.numericText())` — the modern, declarative way to
/// "count up" a number — rather than a hand-rolled `Timer`/`Task.sleep`
/// loop stepping through intermediate integers.
///
/// Under Reduce Motion the count still lands on `value`, it just does so as
/// a single non-animated update — see `Motion.withAnimation`.
private struct AnimatedScoreText: View {
    let value: Int
    let from: Int
    var suffix: String = ""
    var font: Font = .title3.weight(.bold)
    var color: Color = .primary

    @State private var displayedValue: Int
    @Environment(\.motionReduceMotion) private var reduceMotion

    init(value: Int, from: Int, suffix: String = "", font: Font = .title3.weight(.bold), color: Color = .primary) {
        self.value = value
        self.from = from
        self.suffix = suffix
        self.font = font
        self.color = color
        _displayedValue = State(initialValue: from)
    }

    var body: some View {
        Text("\(displayedValue)\(suffix)")
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .onAppear {
                Motion.withAnimation(Motion.emphasis, reduceMotion: reduceMotion) {
                    displayedValue = value
                }
            }
    }
}

// MARK: - Confetti Burst

/// A brief, decorative scatter of sparkles behind the header trophy —
/// purely celebratory flourish, never how the win itself is communicated
/// (that's the trophy image and "Final Results" text, both always present).
/// Callers gate this out entirely under Reduce Motion rather than render it
/// as a frozen, non-animating scatter — see `header`.
private struct ConfettiBurst: View {
    @State private var animate = false

    private static let symbols = ["star.fill", "sparkle", "star.fill", "sparkle", "star.fill", "sparkle"]
    private static let colors: [Color] = [.yellow, .orange, .pink, .indigo, .green, .blue]

    var body: some View {
        ZStack {
            ForEach(0..<Self.symbols.count, id: \.self) { index in
                Image(systemName: Self.symbols[index])
                    .font(.system(size: 14))
                    .foregroundStyle(Self.colors[index % Self.colors.count])
                    .offset(offset(for: index))
                    .opacity(animate ? 0 : 1)
                    .scaleEffect(animate ? 1.2 : 0.4)
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) {
                animate = true
            }
        }
    }

    private func offset(for index: Int) -> CGSize {
        let angle = Double(index) / Double(Self.symbols.count) * 2 * .pi
        let radius: CGFloat = animate ? 70 : 0
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }
}

// MARK: - Previews

#if DEBUG
/// Builds preview `AppState` purely via `GameEngine.applyFollowerMessage(_:)`
/// — the same mirroring path a joiner's `AppState` message routing uses —
/// rather than driving a real `startGame()` round loop, since `ResultsView`
/// only ever reads `mode`/`finalScores`/`lastRoundResult`, none of which
/// need a live round in progress to populate for the canvas.
///
/// The opening `.gameStart` matters: it is what sets `GameEngine.mode` on a
/// follower, which is exactly what this screen's header and Vote Battle
/// branch key off.
@MainActor
private func resultsPreviewAppState(
    mode: GameMode,
    isHost: Bool,
    scores: [PlayerScore],
    players: [Player],
    highlightPlayerId: UUID? = nil,
    voteCounts: [UUID: Int]? = nil
) -> AppState {
    let appState = AppState()
    appState.gameSessionManager.isHost = isHost
    appState.gameSessionManager.myPlayer = players[0]
    appState.gameSessionManager.roster.setHost(players[0])
    appState.gameSessionManager.roster.applyLobbyUpdate(players)
    appState.currentGameState = .playing(mode)

    appState.gameEngine.applyFollowerMessage(
        .gameStart(mode: mode, config: GameConfig.defaultConfig(for: mode, playerCount: players.count))
    )
    if let highlightPlayerId {
        appState.gameEngine.applyFollowerMessage(
            .roundResult(
                result: RoundResult(
                    roundNumber: 5,
                    scores: scores,
                    highlightPlayerId: highlightPlayerId,
                    voteCounts: voteCounts
                )
            )
        )
    }
    appState.gameEngine.applyFollowerMessage(.gameEnd(scores: scores))
    return appState
}

private let previewHost = Player(displayName: "Ari", color: .blue, isHost: true)
private let previewJoiner1 = Player(displayName: "Bo", color: .green)
private let previewJoiner2 = Player(displayName: "Priyanka Chandrasekaran", color: .purple)
private let previewPlayers = [previewHost, previewJoiner1, previewJoiner2]

private let previewTriviaScores = [
    PlayerScore(playerId: previewHost.id, displayName: previewHost.displayName, score: 320),
    PlayerScore(playerId: previewJoiner1.id, displayName: previewJoiner1.displayName, score: 450),
    PlayerScore(playerId: previewJoiner2.id, displayName: previewJoiner2.displayName, score: 450)
]

private let previewVoteScores = previewPlayers.map {
    PlayerScore(playerId: $0.id, displayName: $0.displayName, score: 0)
}

#Preview("Winner — Host") {
    NavigationStack {
        ResultsView()
    }
    .environment(
        resultsPreviewAppState(
            mode: .quickTrivia,
            isHost: true,
            scores: previewTriviaScores,
            players: previewPlayers
        )
    )
    .environment(Router())
    .modelContainer(for: [GameHistory.self, PlayerStats.self], inMemory: true)
}

#Preview("Vote Battle") {
    NavigationStack {
        ResultsView()
    }
    .environment(
        resultsPreviewAppState(
            mode: .voteBattle,
            isHost: true,
            scores: previewVoteScores,
            players: previewPlayers,
            highlightPlayerId: previewJoiner1.id,
            voteCounts: [previewJoiner1.id: 2, previewJoiner2.id: 1]
        )
    )
    .environment(Router())
    .modelContainer(for: [GameHistory.self, PlayerStats.self], inMemory: true)
}

#Preview("Joiner — Waiting") {
    NavigationStack {
        ResultsView()
    }
    .environment(
        resultsPreviewAppState(
            mode: .quickTrivia,
            isHost: false,
            scores: previewTriviaScores,
            players: previewPlayers
        )
    )
    .environment(Router())
    .modelContainer(for: [GameHistory.self, PlayerStats.self], inMemory: true)
}

#Preview("Reconnecting Banner") {
    NavigationStack {
        ResultsView()
    }
    .environment({
        let appState = resultsPreviewAppState(
            mode: .quickTrivia,
            isHost: true,
            scores: previewTriviaScores,
            players: previewPlayers
        )
        appState.connectionMonitor.peerHealth[MCPeerID(displayName: previewJoiner1.displayName)] = .lost
        return appState
    }())
    .environment(Router())
    .modelContainer(for: [GameHistory.self, PlayerStats.self], inMemory: true)
}

#Preview("Dark") {
    NavigationStack {
        ResultsView()
    }
    .environment(
        resultsPreviewAppState(
            mode: .quickTrivia,
            isHost: true,
            scores: previewTriviaScores,
            players: previewPlayers
        )
    )
    .environment(Router())
    .modelContainer(for: [GameHistory.self, PlayerStats.self], inMemory: true)
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        ResultsView()
    }
    .environment(
        resultsPreviewAppState(
            mode: .quickTrivia,
            isHost: true,
            scores: previewTriviaScores,
            players: previewPlayers
        )
    )
    .environment(Router())
    .modelContainer(for: [GameHistory.self, PlayerStats.self], inMemory: true)
    .dynamicTypeSize(.accessibility3)
}

/// Confirms the winner's trophy, crown, and every standing (with its final
/// score already in place) are fully visible immediately — no confetti, no
/// symbol bounce, no staggered spring, and critically no score left sitting
/// at its `AnimatedScoreText` starting value waiting on a count-up that
/// never runs.
#Preview("Reduce Motion") {
    NavigationStack {
        ResultsView()
    }
    .environment(
        resultsPreviewAppState(
            mode: .quickTrivia,
            isHost: true,
            scores: previewTriviaScores,
            players: previewPlayers
        )
    )
    .environment(Router())
    .modelContainer(for: [GameHistory.self, PlayerStats.self], inMemory: true)
    .environment(\.motionReduceMotion, true)
}
#endif
