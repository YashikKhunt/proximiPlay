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
            "\(score.displayName)\(isMe ? ", you" : ""), rank \(rank), "
                + "\(score.delta > 0 ? "gained \(score.delta) points" : "no points gained") this round, "
                + "\(score.total) points total"
                + (isTopScorer ? ", fastest correct answer this round" : "")
        )
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
#endif
