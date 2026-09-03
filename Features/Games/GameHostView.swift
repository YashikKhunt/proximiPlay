//
//  GameHostView.swift
//  proximiPlay
//

import SwiftUI

/// Container view hosting the active mini-game for a given `GameMode`.
///
/// Reached via `Router.Destination.game(mode)` after the host broadcasts
/// `.gameStart` and every device navigates in. This is a thin shell for now
/// — it switches over `mode` to render placeholder per-mode content and
/// reads `appState.currentGameState` for the high-level phase. It
/// deliberately does not call any game-engine API, since the engine
/// (`Features/Games/GameEngine.swift`) is being built concurrently; each
/// mode's dedicated view will replace its placeholder section as that work
/// lands.
struct GameHostView: View {
    let mode: GameMode

    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    private var sessionManager: GameSessionManager { appState.gameSessionManager }

    var body: some View {
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
