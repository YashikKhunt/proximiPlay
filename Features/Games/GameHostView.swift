//
//  GameHostView.swift
//  proximiPlay
//

import SwiftUI
#if DEBUG
import MultipeerConnectivity
#endif

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

    /// The name most recently reported missing from the roster, if the
    /// notice hasn't auto-dismissed yet. See `announceDeparture(from:to:)`.
    @State private var departedPlayerName: String?
    /// Cancelled and replaced on every new departure so a second player
    /// leaving in quick succession restarts the notice's on-screen time
    /// instead of racing an earlier dismiss against the newer name.
    @State private var departureDismissTask: Task<Void, Never>?

    private var sessionManager: GameSessionManager { appState.gameSessionManager }

    /// Same trigger as `LobbyView.reconnectingBanner` — surfaced here too
    /// since a mid-game connectivity blip is exactly when a player most
    /// wants to know "is this stuck, or is it the network" without leaving
    /// the game screen to check.
    private var reconnectingBanner: StatusBanner? {
        guard appState.connectionMonitor.isMonitoring,
              appState.connectionMonitor.peerHealth.values.contains(.lost) else { return nil }
        return StatusBanner(
            tone: .warning,
            systemImage: "wifi.exclamationmark",
            message: "Connection lost — reconnecting…"
        )
    }

    /// A transient, auto-dismissing notice for a peer that dropped mid-game
    /// (as opposed to the host itself leaving, which is a decision-blocking
    /// `.alert` via `hostLeftAlert()` on every mode view). The game keeps
    /// running underneath — this is purely informational.
    private var departureBanner: StatusBanner? {
        guard let departedPlayerName else { return nil }
        return StatusBanner(
            tone: .info,
            systemImage: "person.fill.xmark",
            message: "\(departedPlayerName) disconnected"
        )
    }

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
        .statusBannerOverlay([reconnectingBanner, departureBanner].compactMap { $0 })
        // The roster shrinking is the only on-screen trace of
        // `GameSessionManager.onPlayerLeft` firing (it hands `AppState` a
        // bare `UUID` — by the time that callback runs, `hostPlayerLeft` has
        // already removed the departed `Player` from the roster, so there's
        // no name left to read off it there). Diffing the roster here, one
        // step downstream, is what actually recovers the departed player's
        // name while it's still available in `oldPlayers`.
        .onChange(of: sessionManager.roster.players) { oldPlayers, newPlayers in
            announceDeparture(from: oldPlayers, to: newPlayers)
        }
        .onDisappear {
            departureDismissTask?.cancel()
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

    /// Surfaces `departureBanner` for ~4 seconds for the first player found
    /// in `oldPlayers` but missing from `newPlayers`. Only ever fires for a
    /// fellow player leaving while the session stays up — the host itself
    /// disconnecting is reported by `hostLeftAlert()` instead, since a
    /// departed host has nothing left to broadcast a `.lobbyUpdate` from.
    private func announceDeparture(from oldPlayers: [Player], to newPlayers: [Player]) {
        let newIds = Set(newPlayers.map(\.id))
        guard let departed = oldPlayers.first(where: { !newIds.contains($0.id) }) else { return }

        departureDismissTask?.cancel()
        departedPlayerName = departed.displayName
        departureDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            departedPlayerName = nil
        }
    }
}

// MARK: - Previews

#if DEBUG
/// Reruns `announceDeparture(from:to:)`'s trigger path for real — seeds a
/// two-player roster, then removes one peer a second after appearing, the
/// same `PlayerRoster.hostPlayerLeft(peer:)` call a live session's
/// `MCSessionDelegate` callback makes — so the canvas actually exercises the
/// banner's auto-show/auto-dismiss timing rather than a hand-set flag.
private struct DeparturePreviewHarness: View {
    let appState: AppState
    let peer: MCPeerID

    var body: some View {
        GameHostView(mode: .quickTrivia)
            .task {
                try? await Task.sleep(for: .seconds(1))
                appState.gameSessionManager.roster.hostPlayerLeft(peer: peer)
            }
    }
}

@MainActor
private func departurePreview() -> some View {
    let appState = AppState()
    let host = Player(displayName: "Ari", color: .blue, isHost: true)
    appState.gameSessionManager.isHost = true
    appState.gameSessionManager.myPlayer = host
    appState.gameSessionManager.roster.setHost(host)

    let peer = MCPeerID(displayName: "Bo")
    appState.gameSessionManager.roster.hostPlayerJoined(peer: peer, displayName: "Bo")

    return NavigationStack {
        DeparturePreviewHarness(appState: appState, peer: peer)
    }
    .environment(appState)
    .environment(Router())
}

#Preview("Departure Banner") {
    departurePreview()
}

#Preview("Reconnecting Banner") {
    NavigationStack {
        GameHostView(mode: .quickTrivia)
    }
    .environment({
        let appState = AppState()
        appState.connectionMonitor.peerHealth[MCPeerID(displayName: "Bo")] = .lost
        return appState
    }())
    .environment(Router())
}
#endif

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
