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
/// Trivia, Vote Battle, Speed Draw, and Reflex Tap are all built) and, on
/// the **host** device, kicks off the host-authoritative `GameEngine`.
/// Joiners never call `startGame` — their engine state is fed entirely by
/// `AppState`'s message routing (see `AppState.swift`).
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
                ReflexGameView()
            }
        }
        .task {
            startEngineIfNeeded()
        }
    }

    /// Starts the host-authoritative engine. No-op on joiner devices
    /// (`AppState` mirrors the host's broadcasts into the engine instead)
    /// and a no-op if a game is already running, so this is safe to call
    /// every time the view appears.
    private func startEngineIfNeeded() {
        guard sessionManager.isHost else { return }
        let roster = sessionManager.roster.players
        appState.gameEngine.startGame(
            mode: mode,
            roster: roster,
            config: GameConfig.defaultConfig(for: mode, playerCount: roster.count)
        )
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
