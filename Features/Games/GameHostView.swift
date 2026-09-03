//
//  GameHostView.swift
//  proximiPlay
//

import SwiftUI

/// Container view hosting the active mini-game for a given `GameMode`.
///
/// Reached via `Router.Destination.game(mode)` after the host broadcasts
/// `.gameStart` and every device navigates in. Still a thin shell — it
/// switches over `mode` to hand off to that mode's dedicated view (Quick
/// Trivia, Vote Battle, and Speed Draw are built; Reflex Tap keeps
/// rendering a placeholder until its own work lands) and, on the
/// **host** device, kicks off the
/// host-authoritative `GameEngine` for modes whose view is ready to render
/// its output. Joiners never call `startGame` — their engine state is fed
/// entirely by `AppState`'s message routing (see `AppState.swift`).
struct GameHostView: View {
    let mode: GameMode

    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    private var sessionManager: GameSessionManager { appState.gameSessionManager }

    var body: some View {
        Group {
            switch mode {
            case .quickTrivia:
                TriviaGameView()
            case .voteBattle:
                VoteGameView()
            case .speedDraw:
                DrawGameView()
            case .reflexTap:
                placeholderView
            }
        }
        .task {
            startEngineIfNeeded()
        }
    }

    /// Starts the host-authoritative engine for modes whose dedicated view
    /// is wired up to render it. No-op on joiner devices (`AppState`
    /// mirrors the host's broadcasts into the engine instead) and a no-op
    /// if a game is already running, so this is safe to call every time the
    /// view appears.
    private func startEngineIfNeeded() {
        guard sessionManager.isHost, mode == .quickTrivia || mode == .voteBattle || mode == .speedDraw else { return }
        let roster = sessionManager.roster.players
        appState.gameEngine.startGame(
            mode: mode,
            roster: roster,
            config: GameConfig.defaultConfig(for: mode, playerCount: roster.count)
        )
    }

    // MARK: - Placeholder (modes without a dedicated view yet)

    private var placeholderView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: mode.sfSymbol)
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.indigo)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(mode.displayName)
                    .font(.title.bold())
                    .foregroundStyle(Color.primary)

                statusText
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }

            ProgressView()
                .padding(.top, 8)
                .accessibilityHidden(true)

            Spacer()
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.displayName). \(statusAccessibilityDescription)")
        .navigationTitle(mode.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionIndicator(state: sessionManager.connectionState)
            }
        }
    }

    // MARK: - Placeholder per-mode status

    /// Placeholder status copy per mode — each mode's dedicated round view
    /// replaces this once its gameplay logic lands.
    private var statusText: Text {
        switch mode {
        case .quickTrivia:
            Text("Waiting for the first question…")
        case .voteBattle:
            Text("Waiting for the first prompt…")
        case .speedDraw:
            Text("Waiting for the first word…")
        case .reflexTap:
            Text("Waiting for the round to start…")
        }
    }

    private var statusAccessibilityDescription: String {
        switch mode {
        case .quickTrivia: "Waiting for the first question"
        case .voteBattle:  "Waiting for the first prompt"
        case .speedDraw:   "Waiting for the first word"
        case .reflexTap:   "Waiting for the round to start"
        }
    }
}

// MARK: - Previews

#Preview("Quick Trivia") {
    NavigationStack {
        GameHostView(mode: .quickTrivia)
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Vote Battle") {
    NavigationStack {
        GameHostView(mode: .voteBattle)
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Speed Draw") {
    NavigationStack {
        GameHostView(mode: .speedDraw)
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Reflex Tap") {
    NavigationStack {
        GameHostView(mode: .reflexTap)
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Dark") {
    NavigationStack {
        GameHostView(mode: .quickTrivia)
    }
    .environment(AppState())
    .environment(Router())
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        GameHostView(mode: .quickTrivia)
    }
    .environment(AppState())
    .environment(Router())
    .dynamicTypeSize(.accessibility3)
}
