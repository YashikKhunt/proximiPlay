//
//  TriviaGameView.swift
//  proximiPlay
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders one Quick Trivia game end-to-end: question → answer → reveal →
/// next round, purely from `GameEngine`'s observable state.
///
/// Deliberately role-agnostic: every branch below reads `appState.gameEngine`
/// only, so host and joiner devices render identically. The **only** place
/// role matters is input routing, which is delegated to
/// `AppState.submitPlayerInput(_:)` (host submits locally, joiner sends to
/// the host peer).
///
/// ## Why a local round queue instead of reading `engine` state directly
///
/// The host's round loop can advance `currentRound` → next round in the very
/// same synchronous call that set `lastRoundResult` (no artificial delay
/// between rounds in `GameEngine`), so a naïve "watch `currentRound`, watch
/// `lastRoundResult`" pair of `onChange`s can race: by the time SwiftUI gets
/// around to re-rendering, the engine may already be two states ahead. To
/// stay correct regardless of that timing, this view treats round starts and
/// round results as two independent, strictly-ordered FIFO streams —
/// `roundQueue` (append on every new question) and the reveal it pops one
/// entry from on every new result — rather than a single overwritable slot
/// that could be clobbered mid-transition.
struct TriviaGameView: View {
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
    @State private var currentRoundStartedAt: Date = .distantPast

    private var engine: GameEngine { appState.gameEngine }

    /// `GameEngine.totalRounds` is never populated on joiner devices
    /// (`applyFollowerMessage` only mirrors `currentRound`/`lastRoundResult`/
    /// `finalScores`), so fall back to Quick Trivia's fixed round count —
    /// identical to what the host actually used, since `GameConfig`'s
    /// trivia default doesn't vary by player count.
    private var totalRounds: Int {
        engine.totalRounds > 0 ? engine.totalRounds : GameConfig.defaultConfig(for: .quickTrivia).roundCount
    }

    private var roundDuration: TimeInterval {
        GameConfig.defaultConfig(for: .quickTrivia).timePerRound
    }

    private var currentTriviaPayload: TriviaPayload? {
        guard case .trivia(let question, let options, let correctIndex)? = engine.currentRound else { return nil }
        return TriviaPayload(question: question, options: options, correctIndex: correctIndex)
    }

    var body: some View {
        Group {
            if let revealSnapshot {
                TriviaRoundResultView(
                    roundNumber: revealSnapshot.round.roundIndex,
                    totalRounds: totalRounds,
                    question: revealSnapshot.round.question,
                    options: revealSnapshot.round.options,
                    correctIndex: revealSnapshot.round.correctIndex,
                    mySelectedIndex: revealSnapshot.round.mySelectedIndex,
                    myPlayerId: appState.gameSessionManager.myPlayer.id,
                    result: revealSnapshot.result,
                    previousScores: revealSnapshot.baselineScores,
                    isFinalRound: revealSnapshot.isFinal
                ) {
                    router.navigate(to: .results)
                }
            } else if let current = roundQueue.last {
                answeringView(current)
            } else {
                waitingView
            }
        }
        .animation(.default, value: revealSnapshot != nil)
        .navigationTitle(GameMode.quickTrivia.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionIndicator(state: appState.gameSessionManager.connectionState)
            }
        }
        .hostLeftAlert()
        .leaveGameGuard()
        .onChange(of: currentTriviaPayload, initial: true) { _, newPayload in
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
            Image(systemName: "questionmark.circle")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.indigo)
                .accessibilityHidden(true)
            Text("Waiting for the first question…")
                .font(.headline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .accessibilityHidden(true)
            Spacer()
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for the first question")
    }

    // MARK: - Answering

    private func answeringView(_ round: RoundSnapshot) -> some View {
        VStack(spacing: 20) {
            RoundHeaderView(roundNumber: round.roundIndex, totalRounds: totalRounds)

            TimelineView(.periodic(from: currentRoundStartedAt, by: 1.0 / 20.0)) { context in
                let elapsed = context.date.timeIntervalSince(currentRoundStartedAt)
                let fraction = roundDuration > 0 ? max(0, min(1, 1 - (elapsed / roundDuration))) : 0
                ProgressView(value: fraction)
                    .tint(fraction < 0.25 ? Color.red : Color.indigo)
                    .accessibilityHidden(true)
            }

            Text(round.question)
                .font(.title3.bold())
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(round.options.enumerated()), id: \.offset) { index, option in
                    TriviaAnswerButton(
                        letter: Self.letter(for: index),
                        text: option,
                        state: buttonState(for: index, in: round)
                    ) {
                        selectAnswer(index)
                    }
                }
            }

            if round.mySelectedIndex != nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for others…")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Answer locked in. Waiting for other players.")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func buttonState(for index: Int, in round: RoundSnapshot) -> TriviaAnswerButton.AnswerState {
        guard let selected = round.mySelectedIndex else { return .normal }
        return index == selected ? .selected : .locked
    }

    private func selectAnswer(_ index: Int) {
        guard !roundQueue.isEmpty, roundQueue[roundQueue.count - 1].mySelectedIndex == nil else { return }

        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif

        roundQueue[roundQueue.count - 1].mySelectedIndex = index
        appState.submitPlayerInput(.triviaAnswer(index: index, timestamp: Date()))
    }

    // MARK: - Round Transitions

    private func handleNewRound(_ payload: TriviaPayload?) {
        guard let payload else { return }
        currentRoundStartedAt = Date()
        let nextIndex = (roundQueue.last?.roundIndex ?? 0) + 1
        roundQueue.append(
            RoundSnapshot(
                roundIndex: nextIndex,
                question: payload.question,
                options: payload.options,
                correctIndex: payload.correctIndex,
                mySelectedIndex: nil
            )
        )
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

    private struct TriviaPayload: Equatable {
        let question: String
        let options: [String]
        let correctIndex: Int
    }

    private struct RoundSnapshot: Equatable {
        let roundIndex: Int
        let question: String
        let options: [String]
        let correctIndex: Int
        var mySelectedIndex: Int?
    }

    private struct RevealSnapshot {
        let round: RoundSnapshot
        let result: RoundResult
        let baselineScores: [UUID: Int]
        let isFinal: Bool
    }

    private static let letters = ["A", "B", "C", "D"]

    /// Bounds-safe: `RoundData.trivia`'s option count is never validated
    /// against `letters.count` before reaching this view (a malformed or
    /// future round payload could carry 5+ options), so this falls back to
    /// a neutral glyph rather than crashing on an out-of-range subscript.
    private static func letter(for index: Int) -> String {
        guard letters.indices.contains(index) else { return "•" }
        return letters[index]
    }
}

// MARK: - Answer Button

private struct TriviaAnswerButton: View {
    enum AnswerState {
        case normal
        case selected
        case locked
    }

    let letter: String
    let text: String
    let state: AnswerState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(letter)
                    .font(.headline)
                    .foregroundStyle(state == .selected ? Color.white : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(
                        state == .selected ? Color.indigo : Color(uiColor: .tertiarySystemBackground),
                        in: Circle()
                    )

                Text(text)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)

                Spacer(minLength: 0)

                if state == .selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.indigo)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(
                state == .selected ? Color.indigo.opacity(0.15) : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(state == .selected ? Color.indigo : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(state == .locked)
        .opacity(state == .locked ? 0.5 : 1.0)
        .accessibilityLabel("Option \(letter): \(text)")
        .accessibilityAddTraits(state == .selected ? [.isSelected] : [])
        .accessibilityHint(state == .normal ? "Double-tap to choose this answer" : "")
    }
}

// MARK: - Host Left Alert (shared across mode views)

/// Surfaces a "Host left the game" alert whenever `AppState.hostLeft`
/// becomes `true`, resetting engine/session state and returning to the root
/// of navigation on acknowledgement.
///
/// Lives alongside `TriviaGameView` (the first mode view built) so every
/// other mode view can apply the same `.hostLeftAlert()` modifier rather
/// than re-implementing this alert per mode.
private struct HostLeftAlertModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        content.alert(
            "Host Left",
            isPresented: Binding(get: { appState.hostLeft }, set: { _ in })
        ) {
            Button("OK") {
                appState.resetAfterHostLeft()
                router.popToRoot()
            }
        } message: {
            Text("The host left the game.")
        }
    }
}

extension View {
    /// See `HostLeftAlertModifier`.
    func hostLeftAlert() -> some View {
        modifier(HostLeftAlertModifier())
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func triviaPreviewAppState(roundCount: Int = 3) -> AppState {
    let appState = AppState()
    let host = Player(displayName: "Ari", color: .blue, isHost: true)
    let joiner = Player(displayName: "Bo", color: .green)

    appState.gameSessionManager.isHost = true
    appState.gameSessionManager.myPlayer = host

    appState.gameEngine.startGame(
        mode: .quickTrivia,
        roster: [host, joiner],
        config: GameConfig(roundCount: roundCount, timePerRound: 20)
    )

    return appState
}

#Preview("Waiting") {
    NavigationStack {
        TriviaGameView()
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Answering") {
    NavigationStack {
        TriviaGameView()
    }
    .environment(triviaPreviewAppState())
    .environment(Router())
}

#Preview("Dark") {
    NavigationStack {
        TriviaGameView()
    }
    .environment(triviaPreviewAppState())
    .environment(Router())
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        TriviaGameView()
    }
    .environment(triviaPreviewAppState())
    .environment(Router())
    .dynamicTypeSize(.accessibility3)
}
#endif
