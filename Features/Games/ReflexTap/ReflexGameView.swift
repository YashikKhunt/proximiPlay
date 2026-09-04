//
//  ReflexGameView.swift
//  proximiPlay
//

import SwiftUI

/// Renders one Reflex Tap game end-to-end: tension build-up -> flash -> tap
/// -> reveal -> next round, purely from `GameEngine`'s observable state.
///
/// Follows `TriviaGameView`/`VoteGameView`/`DrawGameView`'s established
/// pattern: round sequencing lives in the shared ``RoundFlow`` coordinator,
/// whose FIFO queue avoids the same-tick `currentRound` -> `lastRoundResult`
/// race described in its doc comment, and every branch reads
/// `appState.gameEngine` only, so host and joiner devices render
/// identically. Role only ever changes *when* the flash timer starts (both
/// still start it the moment they locally observe the round begin). The
/// flash timing and the tap phase stay here — they are Reflex Tap's alone.
///
/// ## Detecting a new round with no per-round payload
///
/// Unlike trivia's question or vote's prompt, `RoundData.reflex` carries no
/// associated data at all -- there's nothing to diff between round 1 and
/// round 3 to notice they're different rounds. This view instead watches the
/// **edge** of `currentRound` going from `nil` to non-`nil`
/// (``isRoundActive``), which still fires correctly on every round because
/// `GameEngine` always resets `currentRound` back to `nil` when a round's
/// result is broadcast (`finishRound()` on the host,
/// `applyFollowerMessage(.roundResult)` on joiners) before the next
/// `.roundStart` sets it again -- so every round genuinely passes through a
/// `nil` in between, making the `Bool` transition a reliable signal.
///
/// ## Deriving the flash moment with no delay on the wire
///
/// `RoundData.reflex` also carries no flash-delay payload, so the flash
/// can't be scheduled by a host-broadcast timestamp the way, say, trivia's
/// speed bonus uses `roundStartedAt`. Every device instead derives an
/// identical delay purely from the round index it already tracks locally
/// (`SeededGenerator`, seeded on `roundIndex`) -- both host and joiners
/// build that index in lockstep from the same ordered stream of
/// `.roundStart` broadcasts, so no new message or engine change is needed
/// for every screen to flash at approximately the same moment. See
/// `flashDelay(forRound:)` for why the delay window itself had to be
/// narrowed from the roughly 2-6 second range a reflex game would normally
/// use.
///
/// ## Why the engine's -50 early-tap penalty rarely actually fires
///
/// `GameEngine.reflexScores(taps:flashAt:)` penalizes any tap timestamped
/// before `flashAt`, and `finishRound()` passes `roundStartedAt` for that
/// parameter -- the instant `.roundStart` was broadcast, **not** the later
/// client-rendered flash `runFlashTimer(roundIndex:delay:)` waits for. Since
/// `RoundData.reflex` has no delay payload, the engine has no way to know
/// when devices will actually show their flash, so its penalty reference is
/// effectively "round start," not "flash." Any real tap a player makes
/// necessarily happens after their device received `.roundStart` (i.e.
/// after `flashAt`), so the dedicated `-50` penalty will rarely trigger in
/// practice. `handleTap(roundIndex:)` still forwards early taps to the
/// engine regardless -- both because a modified/laggy client could
/// genuinely predate `flashAt`, and because `GameEngine.submitInput`'s
/// first-wins rule for `.reflexTap` means an early tap consumes the
/// player's one submission for the round either way, ruling out a
/// legitimate post-flash attempt. That's a real, if softer, consequence for
/// jumping the gun even when the `-50` itself doesn't land.
struct ReflexGameView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    @State private var flow = RoundFlow<RoundSnapshot>()

    private var engine: GameEngine { appState.gameEngine }
    private var myPlayerId: UUID { appState.gameSessionManager.myPlayer.id }

    /// Host-authoritative on every device: the host sets this in
    /// `startGame`, joiners mirror it from the host's `.gameStart`
    /// (`GameEngine.applyFollowerMessage`). No local `GameConfig` guess.
    private var totalRounds: Int { engine.totalRounds }

    /// See "Detecting a new round with no per-round payload" above.
    private var isRoundActive: Bool {
        if case .reflex? = engine.currentRound { return true }
        return false
    }

    var body: some View {
        Group {
            if let reveal = flow.reveal {
                ReflexRoundResultView(
                    roundNumber: reveal.round.index,
                    totalRounds: totalRounds,
                    myPlayerId: myPlayerId,
                    result: reveal.result,
                    previousScores: reveal.baselineScores,
                    isFinalRound: reveal.isFinal
                ) {
                    router.navigate(to: .results)
                }
            } else if let current = flow.current {
                ReflexPromptView(
                    roundNumber: current.index,
                    totalRounds: totalRounds,
                    phase: current.payload.phase
                ) {
                    handleTap(roundIndex: current.index)
                }
                .task(id: current.index) {
                    await runFlashTimer(roundIndex: current.index, delay: current.payload.flashDelay)
                }
            } else {
                waitingView
            }
        }
        .animation(.default, value: flow.reveal != nil)
        .navigationTitle(GameMode.reflexTap.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionIndicator(state: appState.gameSessionManager.connectionState)
            }
        }
        .hostLeftAlert()
        .leaveGameGuard()
        .roundFlow(
            flow,
            engine: engine,
            roundTrigger: isRoundActive,
            beginRound: { isActive, nextRoundIndex in
                guard isActive else { return nil }
                return RoundSnapshot(flashDelay: Self.flashDelay(forRound: nextRoundIndex))
            },
            onReveal: { reveal in
                celebrateIfLocalPlayerWon(reveal)
            }
        )
    }

    // MARK: - Waiting (before the first round)

    private var waitingView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bolt.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.indigo)
                .accessibilityHidden(true)
            Text("Waiting for the round to start…")
                .font(.headline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .accessibilityHidden(true)
            Spacer()
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for the round to start")
    }

    // MARK: - Tap Handling

    /// Records a tap for `roundIndex`, moving that round's local phase to
    /// `.tooSoon` (tapped during the tension build-up) or `.lockedIn`
    /// (tapped during/after the flash), and forwards it to the engine
    /// regardless -- see "Why the engine's -50 early-tap penalty rarely
    /// actually fires" above. Ignored once the round already has a tap
    /// recorded (`.tooSoon`/`.lockedIn`), matching the engine's own
    /// first-wins rule for `.reflexTap`.
    private func handleTap(roundIndex: Int) {
        guard let phase = flow.payload(forRound: roundIndex)?.phase else { return }
        guard phase == .waiting || phase == .flash else { return }

        let wasEarly = phase == .waiting
        flow.update(round: roundIndex) { $0.phase = wasEarly ? .tooSoon : .lockedIn }

        if wasEarly {
            HapticEngine.shared.play(.answerWrong)
            SoundPlayer.shared.play(.answerWrong)
        } else {
            HapticEngine.shared.play(.tapRegistered)
            SoundPlayer.shared.play(.tapRegistered)
        }

        appState.submitPlayerInput(.reflexTap(timestamp: Date()))
    }

    // MARK: - Flash Scheduling

    /// Sleeps until this round's locally scheduled flash moment, then
    /// reveals it with a heavy haptic -- unless the player already tapped
    /// early (`.tooSoon`) or the round has already moved on (popped from
    /// `roundQueue` by `presentReveal()`), in which case this is a no-op.
    /// Cancelled automatically by SwiftUI's `.task(id:)` once this round's
    /// `ReflexPromptView` leaves the hierarchy.
    ///
    /// Primes both generators it might need — `.roundStart` (the flash
    /// itself) and `.tapRegistered` (a valid tap immediately after) — the
    /// instant the tension phase begins, well ahead of either one actually
    /// firing. Reflex Tap is the one mode where `UIFeedbackGenerator`'s
    /// priming latency reduction is worth the trade-off (see `HapticEngine`'s
    /// doc comment): the entire game is testing reaction speed, so shaving
    /// the generator's cold-start latency off the flash cue and the tap
    /// acknowledgement actually matters here in a way it doesn't for, say, a
    /// trivia answer selection.
    private func runFlashTimer(roundIndex: Int, delay: TimeInterval) async {
        HapticEngine.shared.prepare(.roundStart)
        HapticEngine.shared.prepare(.tapRegistered)

        do {
            try await Task.sleep(for: .seconds(delay))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        guard flow.payload(forRound: roundIndex)?.phase == .waiting else { return }

        flow.update(round: roundIndex) { $0.phase = .flash }
        HapticEngine.shared.play(.roundStart)
        SoundPlayer.shared.play(.roundStart)
    }

    // MARK: - Reveal Feedback

    /// Fires a success haptic when the just-revealed round moved the local
    /// player's score up -- Reflex Tap's own reaction to a reveal, using the
    /// pre-result baseline `RoundFlow` hands back. (The reveal itself shows
    /// per-round deltas for everyone; this is only the local celebration.)
    private func celebrateIfLocalPlayerWon(_ reveal: RoundFlow<RoundSnapshot>.Reveal) {
        let myPreviousScore = reveal.baselineScores[myPlayerId] ?? 0
        let myNewScore = reveal.result.scores.first { $0.playerId == myPlayerId }?.score ?? myPreviousScore
        guard myNewScore > myPreviousScore else { return }

        HapticEngine.shared.play(.winnerReveal)
        SoundPlayer.shared.play(.winnerReveal)
    }

    // MARK: - Types

    /// Reflex Tap's per-round client state: this device's locally derived
    /// flash moment and how far through the tap sequence it has got. Neither
    /// is ever mirrored to the engine or the wire.
    private struct RoundSnapshot: Equatable {
        let flashDelay: TimeInterval
        var phase: TapPhase = .waiting
    }
}

// MARK: - Deterministic Flash Delay

extension ReflexGameView {
    /// The delay, in seconds, between a round starting and its flash --
    /// derived deterministically from `roundIndex` so every device computes
    /// the identical value with nothing new on the wire.
    ///
    /// A reflex game would normally want something like a 2-6 second
    /// randomized delay to build tension. But `GameConfig.defaultConfig(for:
    /// .reflexTap)` fixes `timePerRound` at exactly 5 seconds -- the hard
    /// round timeout `GameEngine.runRound()` uses to force-finish a round
    /// nobody responds to. A 6-second flash delay would then routinely let
    /// that timeout fire *before* any device ever shows its flash, ending
    /// the round with zero taps possible and nothing for the player to
    /// react to. To keep every round actually playable within that fixed
    /// budget, the delay is instead scaled to a fraction of the shared
    /// round timeout (20-60%, i.e. 1-3 seconds at the default 5-second
    /// timeout) that reliably leaves reaction- and network-latency headroom
    /// before the host's timeout can fire.
    static func flashDelay(forRound roundIndex: Int) -> TimeInterval {
        var rng = SeededGenerator(seed: UInt64(max(roundIndex, 0)))
        let fraction = Double.random(in: minFlashDelayFraction...maxFlashDelayFraction, using: &rng)
        return roundTimeout * fraction
    }

    private static let minFlashDelayFraction: Double = 0.2
    private static let maxFlashDelayFraction: Double = 0.6

    private static var roundTimeout: TimeInterval {
        GameConfig.defaultConfig(for: .reflexTap).timePerRound
    }
}

/// A small, deterministic pseudo-random source (SplitMix64) so every device
/// -- host and joiners alike -- computes the exact same reflex flash delay
/// for a given round from nothing but that round's index. See
/// `ReflexGameView.flashDelay(forRound:)`'s doc comment for why no new wire
/// payload is needed instead.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid an all-zero state, which would otherwise produce an
        // all-zero stream.
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Tap Phase

/// The local, client-only phase of a single reflex round -- never mirrored
/// to the engine or the wire, purely UI state driving what
/// `ReflexPromptView` shows and whether a tap counts as early or valid.
private enum TapPhase: Equatable {
    /// Tension build-up before the flash. A tap here is "too soon."
    case waiting
    /// The flash is showing. A tap here is a valid, timed attempt.
    case flash
    /// The player tapped during `.waiting`.
    case tooSoon
    /// The player tapped during `.flash` and their input has been sent.
    case lockedIn
}

// MARK: - Full-Screen Prompt

/// The full-screen, whole-area-tappable state for one round -- tension
/// build-up, flash, and the two possible outcomes of tapping. Kept separate
/// from `ReflexGameView` so every phase can be previewed directly without
/// needing to drive `GameEngine`'s round timing to reach it.
private struct ReflexPromptView: View {
    let roundNumber: Int
    let totalRounds: Int
    let phase: TapPhase
    var onTap: () -> Void = {}

    // The app-wide mirror rather than SwiftUI's own key, so there is a
    // single source of truth for Reduce Motion and this view is previewable
    // in both states. ContentView feeds the mirror from the real key.
    @Environment(\.motionReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 24) {
                HStack {
                    Text("Round \(roundNumber) of \(totalRounds)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(foregroundColor.opacity(secondaryTextOpacity))
                    Spacer()
                }

                Spacer()

                Image(systemName: symbolName)
                    .font(.system(size: 72))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(foregroundColor)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(foregroundColor)
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.headline)
                        .foregroundStyle(foregroundColor.opacity(secondaryTextOpacity))
                        .multilineTextAlignment(.center)
                }

                if phase == .tooSoon || phase == .lockedIn {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(foregroundColor)
                        Text("Waiting for others…")
                            .font(.subheadline)
                            .foregroundStyle(foregroundColor.opacity(secondaryTextOpacity))
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard phase == .waiting || phase == .flash else { return }
            onTap()
        }
        // Reduce Motion: an instant cut between phases rather than a
        // cross-fade, so nothing strobes -- the color/label change is still
        // obvious, just not animated.
        .animation(reduceMotion ? nil : .easeIn(duration: 0.12), value: phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isTappable ? .isButton : [])
        .accessibilityHint(isTappable ? "Double-tap the instant the screen flashes" : "")
    }

    private var isTappable: Bool { phase == .waiting || phase == .flash }

    /// Custom, deliberately darker/deeper fills rather than plain
    /// `Color.green`/`Color.red` — the system colors don't leave enough
    /// contrast headroom for legible text on top of them (see
    /// `foregroundColor` and this type's contrast targets below).
    private var backgroundColor: Color {
        switch phase {
        case .waiting:  .black
        case .flash:    .flashGreen
        case .tooSoon:  .tooSoonRed
        case .lockedIn: .flashGreen
        }
    }

    /// Paired with `backgroundColor` to clear WCAG's 4.5:1 body-text /
    /// 3:1 large-text contrast floors on every phase, not just `.waiting`'s
    /// white-on-black:
    /// - `.flashGreen` (a vivid but *dark-enough* green,
    ///   `Color(red: 0.20, green: 0.78, blue: 0.35)`) paired with **black**
    ///   text measures ~9.45:1.
    /// - `.tooSoonRed` (a deep red, `Color(red: 0.55, green: 0, blue: 0)`)
    ///   paired with **white** text measures ~9.91:1.
    /// - `.waiting`'s plain black paired with white text is ~21:1.
    /// All three comfortably clear both the 4.5:1 body-text and 3:1
    /// large-text targets — previously, white text at ~2.2:1 over
    /// `Color.green`/`Color.red` fell well under even the lower bar.
    private var foregroundColor: Color {
        switch phase {
        case .waiting:          .white
        case .flash, .lockedIn: .black
        case .tooSoon:          .white
        }
    }

    /// Subtitle/secondary text keeps its `0.85` opacity reduction only on
    /// `.waiting`'s white-on-black (still ~17.9:1 even reduced, nowhere
    /// near the contrast floor). The flash/lockedIn/tooSoon states drop the
    /// reduction entirely so the already-tighter (if still compliant)
    /// contrast on those fills isn't eaten further by translucency.
    private var secondaryTextOpacity: Double {
        phase == .waiting ? 0.85 : 1.0
    }

    private var symbolName: String {
        switch phase {
        case .waiting:  "eye.fill"
        case .flash:    "bolt.fill"
        case .tooSoon:  "hand.raised.fill"
        case .lockedIn: "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch phase {
        case .waiting:  "Wait for it…"
        case .flash:    "TAP NOW!"
        case .tooSoon:  "Too soon!"
        case .lockedIn: "Nice reflexes!"
        }
    }

    private var subtitle: String {
        switch phase {
        case .waiting:  "Tap the instant the screen flashes"
        case .flash:    "Tap anywhere"
        case .tooSoon:  "You tapped before the flash"
        case .lockedIn: "Your tap was recorded"
        }
    }

    private var accessibilityLabel: String { "\(title). \(subtitle)." }
}

// MARK: - Contrast-Safe Fill Colors

/// See `ReflexPromptView.foregroundColor`'s doc comment for the contrast
/// math behind these two custom fills.
private extension Color {
    static let flashGreen = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let tooSoonRed = Color(red: 0.55, green: 0.0, blue: 0.0)
}

// MARK: - Round Result Reveal

/// The interstitial shown between Reflex Tap rounds: who tapped fastest (if
/// anyone), the running standings, then advance -- mirroring
/// `DrawRoundResultView`'s layout and reveal pattern.
private struct ReflexRoundResultView: View {
    let roundNumber: Int
    let totalRounds: Int
    let myPlayerId: UUID
    let result: RoundResult
    let previousScores: [UUID: Int]
    let isFinalRound: Bool
    var onContinue: (() -> Void)?

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

    /// `GameEngine.computeHighlight(mode:deltas:)` falls back to
    /// `deltas.max(by:)` for Reflex Tap, which still returns *someone* even
    /// when every tap this round was an early `-50` (i.e. nobody actually
    /// won). Rather than fabricate a winner the round didn't have, this
    /// only credits `highlightPlayerId` as the winner when their score
    /// actually went up -- entirely derived from `RoundResult.scores`, not
    /// invented.
    private var roundWinner: RankedScore? {
        guard let highlightId = result.highlightPlayerId else { return nil }
        return rankedScores.first { $0.playerId == highlightId && $0.delta > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(isFinalRound ? "Final Round" : "Round \(roundNumber) of \(totalRounds)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                winnerReveal
                standings
                footer
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
    }

    private var winnerReveal: some View {
        Group {
            if let roundWinner {
                Label("\(roundWinner.displayName) tapped fastest!", systemImage: "bolt.fill")
                    .font(.title3.bold())
                    .foregroundStyle(Color.primary)
            } else {
                Label("No valid taps this round", systemImage: "hand.raised.fill")
                    .font(.title3.bold())
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
        let isMe = score.playerId == myPlayerId

        return HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(score.displayName)
                    .font(.subheadline.weight(isMe ? .bold : .regular))
                    .foregroundStyle(Color.primary)
                Text("\(score.total) total")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 0)

            Text(score.delta > 0 ? "+\(score.delta)" : "\(score.delta)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(score.delta > 0 ? Color.green : (score.delta < 0 ? Color.red : Color.secondary))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isMe ? Color.indigo.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(score.displayName)\(isMe ? ", you" : ""), rank \(rank), "
                + "\(score.delta > 0 ? "gained \(score.delta) points" : score.delta < 0 ? "lost \(-score.delta) points" : "no points gained") this round, "
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
private func reflexPreviewAppState(roundCount: Int = 5) -> AppState {
    let appState = AppState()
    let host = Player(displayName: "Ari", color: .blue, isHost: true)
    let joiner = Player(displayName: "Priyanka Chandrasekaran", color: .green)

    appState.gameSessionManager.isHost = true
    appState.gameSessionManager.myPlayer = host

    appState.gameEngine.startGame(
        mode: .reflexTap,
        roster: [host, joiner],
        config: GameConfig(roundCount: roundCount, timePerRound: 5)
    )

    return appState
}

private let previewPlayerId = UUID()

private func previewResult(myDelta: Int, highlightIsMe: Bool) -> RoundResult {
    let otherId = UUID()
    let scores = [
        PlayerScore(playerId: previewPlayerId, displayName: "Ari", score: 150 + myDelta),
        PlayerScore(playerId: otherId, displayName: "Priyanka Chandrasekaran", score: 200)
    ]
    return RoundResult(
        roundNumber: 3,
        scores: scores,
        highlightPlayerId: highlightIsMe ? previewPlayerId : otherId
    )
}

#Preview("Waiting for Round") {
    NavigationStack {
        ReflexGameView()
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Playing") {
    NavigationStack {
        ReflexGameView()
    }
    .environment(reflexPreviewAppState())
    .environment(Router())
}

#Preview("Tension (Wait for it)") {
    ReflexPromptView(roundNumber: 2, totalRounds: 5, phase: .waiting)
}

#Preview("Flash") {
    ReflexPromptView(roundNumber: 2, totalRounds: 5, phase: .flash)
}

#Preview("Too Soon") {
    ReflexPromptView(roundNumber: 2, totalRounds: 5, phase: .tooSoon)
}

#Preview("Locked In") {
    ReflexPromptView(roundNumber: 2, totalRounds: 5, phase: .lockedIn)
}

#Preview("Round Result") {
    ReflexRoundResultView(
        roundNumber: 3,
        totalRounds: 5,
        myPlayerId: previewPlayerId,
        result: previewResult(myDelta: -50, highlightIsMe: false),
        previousScores: [previewPlayerId: 200, UUID(): 100],
        isFinalRound: false
    )
}

#Preview("Final Round Result") {
    ReflexRoundResultView(
        roundNumber: 5,
        totalRounds: 5,
        myPlayerId: previewPlayerId,
        result: previewResult(myDelta: 100, highlightIsMe: true),
        previousScores: [previewPlayerId: 50],
        isFinalRound: true
    )
}

#Preview("Dark") {
    ReflexPromptView(roundNumber: 2, totalRounds: 5, phase: .flash)
        .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    ReflexPromptView(roundNumber: 2, totalRounds: 5, phase: .waiting)
        .dynamicTypeSize(.accessibility3)
}
#endif
