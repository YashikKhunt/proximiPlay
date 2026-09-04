//
//  TriviaRoundResultView.swift
//  proximiPlay
//

import SwiftUI

/// The interstitial shown between Quick Trivia rounds: reveals the correct
/// answer, who scored (and how much, including the speed bonus), and the
/// running standings.
///
/// A pure, parameter-driven view — every input is a plain value, so it
/// renders identically for host and joiner and needs no environment access.
/// `TriviaGameView` is responsible for capturing this data at the right
/// moment (see its doc comment) and for the actual advance-to-next-round
/// timing; this view only renders a snapshot and reports the user's
/// "continue" tap on the final round.
struct TriviaRoundResultView: View {
    let roundNumber: Int
    let totalRounds: Int
    let question: String
    let options: [String]
    let correctIndex: Int
    /// `nil` when the local player didn't answer in time.
    let mySelectedIndex: Int?
    let myPlayerId: UUID
    let result: RoundResult
    /// Cumulative scores immediately before this round, used to derive each
    /// player's point gain this round (`result.scores` only carries running
    /// totals).
    let previousScores: [UUID: Int]
    let isFinalRound: Bool
    /// Invoked when the player taps through from the final round's reveal.
    /// Unused (and not shown) on non-final rounds, which auto-advance.
    var onContinue: (() -> Void)?

    /// Player ids that have finished their staggered spring-in — the same
    /// card-reveal vocabulary `VoteRevealView`'s results use, so the two
    /// interstitials that share this "answer revealed, then standings roll
    /// in" shape actually feel like the same app.
    @State private var revealedIds: Set<UUID> = []

    @Environment(\.motionReduceMotion) private var reduceMotion

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

                answerReveal

                standings

                footer
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .onAppear { animateReveal() }
    }

    // MARK: - Answer Reveal

    private var answerReveal: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question)
                .font(.title3.bold())
                .foregroundStyle(Color.primary)

            VStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    optionRow(index: index, text: option)
                }
            }

            if mySelectedIndex == nil {
                Label("You didn't answer in time", systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func optionRow(index: Int, text: String) -> some View {
        let isCorrect = index == correctIndex
        let isMyWrongPick = mySelectedIndex == index && !isCorrect

        return HStack(spacing: 10) {
            Image(systemName: isCorrect ? "checkmark.circle.fill" : (isMyWrongPick ? "xmark.circle.fill" : "circle"))
                .foregroundStyle(isCorrect ? Color.green : (isMyWrongPick ? Color.red : Color.secondary))
                .accessibilityHidden(true)

            Text(text)
                .font(.body)
                .foregroundStyle(Color.primary)
                .strikethrough(isMyWrongPick)

            Spacer(minLength: 0)

            if mySelectedIndex == index {
                Text("Your pick")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            isCorrect ? Color.green.opacity(0.12) : (isMyWrongPick ? Color.red.opacity(0.12) : Color.clear),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(index: index, isCorrect: isCorrect, text: text))
    }

    private func rowAccessibilityLabel(index: Int, isCorrect: Bool, text: String) -> String {
        var parts = [text]
        if isCorrect { parts.append("correct answer") }
        if mySelectedIndex == index { parts.append("your pick") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Standings

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
        let isTopScorer = result.highlightPlayerId == score.playerId && score.delta > 0
        let isMe = score.playerId == myPlayerId
        let revealed = revealedIds.contains(score.playerId)

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
                    if isTopScorer {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(Color.yellow)
                            .accessibilityHidden(true)
                    }
                }
                // Counts up from this round's starting total to
                // `score.total` via `.contentTransition(.numericText())`
                // rather than snapping straight to the new number — see
                // `AnimatedScoreText`.
                AnimatedScoreText(
                    value: score.total,
                    from: score.total - score.delta,
                    suffix: " total",
                    font: .caption,
                    color: Color.secondary
                )
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
        .scaleEffect(revealed ? 1.0 : 0.85)
        .opacity(revealed ? 1.0 : 0.0)
        // Shared card-reveal vocabulary with `VoteRevealView`'s results —
        // see that view's matching modifier for why the delay is still
        // threaded through even though `.motion(_:value:)` alone already
        // collapses to an instant cut under Reduce Motion.
        .motion(Motion.arrival.delay(Motion.staggerDelay(index: rank - 1, reduceMotion: reduceMotion)), value: revealed)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(score.displayName)\(isMe ? ", you" : ""), rank \(rank), "
                + "\(score.delta > 0 ? "gained \(score.delta) points" : "no points gained") this round, "
                + "\(score.total) points total"
                + (isTopScorer ? ", fastest correct answer this round" : "")
        )
    }

    // MARK: - Reveal Animation

    /// Staggers each standings row's spring-in by rank. Mirrors
    /// `VoteRevealView.animateReveal()` exactly, including the Reduce
    /// Motion branch: every row is made visible synchronously (not via a
    /// zero-delay `Task`) so nothing is left waiting on a runloop turn that
    /// would otherwise make it briefly — or, if this view were ever torn
    /// down first, permanently — invisible.
    private func animateReveal() {
        guard !reduceMotion else {
            revealedIds = Set(rankedScores.map(\.playerId))
            return
        }

        for (index, score) in rankedScores.enumerated() {
            let delay = Motion.staggerDelay(index: index, reduceMotion: reduceMotion)
            Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                revealedIds.insert(score.playerId)
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

    // MARK: - Types

    private struct RankedScore {
        let playerId: UUID
        let displayName: String
        let total: Int
        let delta: Int
    }
}

// MARK: - Animated Score Text

/// Rolls a running total from `from` up to `value` using
/// `.contentTransition(.numericText())` — the modern, declarative way to
/// "count up" a number — rather than a hand-rolled `Timer`/`Task.sleep`
/// loop stepping through intermediate integers. `suffix` rides along inside
/// the same `Text` (e.g. `" total"`) so only the digits animate.
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

// MARK: - Previews

#if DEBUG
private extension TriviaRoundResultView {
    static let sampleQuestion = "What is the capital of France?"
    static let sampleOptions = ["Berlin", "Paris", "Madrid", "Rome"]
    static let sampleCorrectIndex = 1

    static let playerA = UUID()
    static let playerB = UUID()
    static let playerC = UUID()

    static let sampleResult = RoundResult(
        roundNumber: 2,
        scores: [
            PlayerScore(playerId: playerA, displayName: "Ari", score: 340),
            PlayerScore(playerId: playerB, displayName: "Bo", score: 180),
            PlayerScore(playerId: playerC, displayName: "Priyanka Chandrasekaran", score: 100)
        ],
        highlightPlayerId: playerA
    )

    static let samplePreviousScores: [UUID: Int] = [
        playerA: 150,
        playerB: 180,
        playerC: 100
    ]
}

#Preview("Correct Pick") {
    TriviaRoundResultView(
        roundNumber: 2,
        totalRounds: 5,
        question: TriviaRoundResultView.sampleQuestion,
        options: TriviaRoundResultView.sampleOptions,
        correctIndex: TriviaRoundResultView.sampleCorrectIndex,
        mySelectedIndex: 1,
        myPlayerId: TriviaRoundResultView.playerA,
        result: TriviaRoundResultView.sampleResult,
        previousScores: TriviaRoundResultView.samplePreviousScores,
        isFinalRound: false
    )
}

#Preview("Wrong Pick") {
    TriviaRoundResultView(
        roundNumber: 2,
        totalRounds: 5,
        question: TriviaRoundResultView.sampleQuestion,
        options: TriviaRoundResultView.sampleOptions,
        correctIndex: TriviaRoundResultView.sampleCorrectIndex,
        mySelectedIndex: 0,
        myPlayerId: TriviaRoundResultView.playerB,
        result: TriviaRoundResultView.sampleResult,
        previousScores: TriviaRoundResultView.samplePreviousScores,
        isFinalRound: false
    )
}

#Preview("Didn't Answer") {
    TriviaRoundResultView(
        roundNumber: 2,
        totalRounds: 5,
        question: TriviaRoundResultView.sampleQuestion,
        options: TriviaRoundResultView.sampleOptions,
        correctIndex: TriviaRoundResultView.sampleCorrectIndex,
        mySelectedIndex: nil,
        myPlayerId: TriviaRoundResultView.playerC,
        result: TriviaRoundResultView.sampleResult,
        previousScores: TriviaRoundResultView.samplePreviousScores,
        isFinalRound: false
    )
}

#Preview("Final Round") {
    TriviaRoundResultView(
        roundNumber: 5,
        totalRounds: 5,
        question: TriviaRoundResultView.sampleQuestion,
        options: TriviaRoundResultView.sampleOptions,
        correctIndex: TriviaRoundResultView.sampleCorrectIndex,
        mySelectedIndex: 1,
        myPlayerId: TriviaRoundResultView.playerA,
        result: TriviaRoundResultView.sampleResult,
        previousScores: TriviaRoundResultView.samplePreviousScores,
        isFinalRound: true
    ) { }
}

#Preview("Dark") {
    TriviaRoundResultView(
        roundNumber: 2,
        totalRounds: 5,
        question: TriviaRoundResultView.sampleQuestion,
        options: TriviaRoundResultView.sampleOptions,
        correctIndex: TriviaRoundResultView.sampleCorrectIndex,
        mySelectedIndex: 1,
        myPlayerId: TriviaRoundResultView.playerA,
        result: TriviaRoundResultView.sampleResult,
        previousScores: TriviaRoundResultView.samplePreviousScores,
        isFinalRound: false
    )
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    TriviaRoundResultView(
        roundNumber: 2,
        totalRounds: 5,
        question: TriviaRoundResultView.sampleQuestion,
        options: TriviaRoundResultView.sampleOptions,
        correctIndex: TriviaRoundResultView.sampleCorrectIndex,
        mySelectedIndex: 0,
        myPlayerId: TriviaRoundResultView.playerB,
        result: TriviaRoundResultView.sampleResult,
        previousScores: TriviaRoundResultView.samplePreviousScores,
        isFinalRound: false
    )
    .dynamicTypeSize(.accessibility3)
}

/// Confirms every standings row and its final total are fully visible
/// immediately — no waiting on the staggered spring `animateReveal()`
/// skips, and no reliance on the numeric count-up ever playing.
#Preview("Reduce Motion") {
    TriviaRoundResultView(
        roundNumber: 2,
        totalRounds: 5,
        question: TriviaRoundResultView.sampleQuestion,
        options: TriviaRoundResultView.sampleOptions,
        correctIndex: TriviaRoundResultView.sampleCorrectIndex,
        mySelectedIndex: 1,
        myPlayerId: TriviaRoundResultView.playerA,
        result: TriviaRoundResultView.sampleResult,
        previousScores: TriviaRoundResultView.samplePreviousScores,
        isFinalRound: false
    )
    .environment(\.motionReduceMotion, true)
}
#endif
