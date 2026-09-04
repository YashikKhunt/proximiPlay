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
/// Round sequencing — queueing each new question, pairing it with its own
/// result, and the timed reveal in between — lives in the shared
/// ``RoundFlow`` coordinator, which every mode view shares; see its doc
/// comment for why round starts are a FIFO queue rather than a single slot.
/// This view keeps only trivia's own rendering and answer handling.
struct TriviaGameView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    @State private var flow = RoundFlow<RoundSnapshot>()
    @State private var currentRoundStartedAt: Date = .distantPast

    private var engine: GameEngine { appState.gameEngine }

    /// Host-authoritative on every device: the host sets this in
    /// `startGame`, joiners mirror it from the host's `.gameStart`
    /// (`GameEngine.applyFollowerMessage`). No local `GameConfig` guess.
    private var totalRounds: Int { engine.totalRounds }

    private var roundDuration: TimeInterval {
        GameConfig.defaultConfig(for: .quickTrivia).timePerRound
    }

    private var currentTriviaPayload: TriviaPayload? {
        guard case .trivia(let question, let options, let correctIndex)? = engine.currentRound else { return nil }
        return TriviaPayload(question: question, options: options, correctIndex: correctIndex)
    }

    var body: some View {
        Group {
            if let reveal = flow.reveal {
                TriviaRoundResultView(
                    roundNumber: reveal.round.index,
                    totalRounds: totalRounds,
                    question: reveal.round.payload.question,
                    options: reveal.round.payload.options,
                    correctIndex: reveal.round.payload.correctIndex,
                    mySelectedIndex: reveal.round.payload.mySelectedIndex,
                    myPlayerId: appState.gameSessionManager.myPlayer.id,
                    result: reveal.result,
                    previousScores: reveal.baselineScores,
                    isFinalRound: reveal.isFinal
                ) {
                    router.navigate(to: .results)
                }
            } else if let current = flow.current {
                answeringView(current)
            } else {
                waitingView
            }
        }
        .animation(.default, value: flow.reveal != nil)
        .navigationTitle(GameMode.quickTrivia.displayName)
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
            roundTrigger: currentTriviaPayload,
            beginRound: { payload, _ in
                guard let payload else { return nil }
                return RoundSnapshot(
                    question: payload.question,
                    options: payload.options,
                    correctIndex: payload.correctIndex,
                    mySelectedIndex: nil
                )
            },
            onRoundStart: { _ in
                currentRoundStartedAt = Date()
            }
        )
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

    private func answeringView(_ round: RoundFlow<RoundSnapshot>.Round) -> some View {
        let snapshot = round.payload

        return VStack(spacing: 20) {
            RoundHeaderView(roundNumber: round.index, totalRounds: totalRounds)

            TimelineView(.periodic(from: currentRoundStartedAt, by: 1.0 / 20.0)) { context in
                let elapsed = context.date.timeIntervalSince(currentRoundStartedAt)
                let fraction = roundDuration > 0 ? max(0, min(1, 1 - (elapsed / roundDuration))) : 0
                ProgressView(value: fraction)
                    .tint(fraction < 0.25 ? Color.red : Color.indigo)
                    .accessibilityHidden(true)
            }

            Text(snapshot.question)
                .font(.title3.bold())
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(snapshot.options.enumerated()), id: \.offset) { index, option in
                    TriviaAnswerButton(
                        letter: Self.letter(for: index),
                        text: option,
                        state: buttonState(for: index, in: snapshot)
                    ) {
                        selectAnswer(index)
                    }
                }
            }

            if snapshot.mySelectedIndex != nil {
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
        guard let current = flow.current, current.payload.mySelectedIndex == nil else { return }

        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif

        flow.updateCurrent { $0.mySelectedIndex = index }
        appState.submitPlayerInput(.triviaAnswer(index: index, timestamp: Date()))
    }

    // MARK: - Types

    /// The engine-side question payload, extracted from `currentRound` so a
    /// *new* question is what `RoundFlow` treats as a new round.
    private struct TriviaPayload: Equatable {
        let question: String
        let options: [String]
        let correctIndex: Int
    }

    /// Trivia's per-round client state: the question as shown, plus this
    /// device's own answer once locked in.
    private struct RoundSnapshot: Equatable {
        let question: String
        let options: [String]
        let correctIndex: Int
        var mySelectedIndex: Int?
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
