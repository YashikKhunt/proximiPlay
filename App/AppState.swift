//
//  AppState.swift
//  proximiPlay
//

import Foundation
import MultipeerConnectivity

/// The top-level application state, injected into the environment at app startup.
///
/// Owns the networking and connection-monitoring singletons so that any view
/// in the hierarchy can access them without prop-drilling.
@Observable @MainActor
final class AppState {
    let gameSessionManager = GameSessionManager()
    let connectionMonitor = ConnectionMonitor()
    let gameEngine: GameEngine
    /// The Speed Draw stroke-rendering buffer, fed directly by
    /// `.drawStroke` messages below — deliberately bypassing `GameEngine`,
    /// which treats strokes as a no-op (see `GameEngine.submitInput`). See
    /// `StrokeSync`'s doc comment for the full wire convention.
    let strokeSync = StrokeSync()
    var currentGameState: GameState = .idle
    var isPremiumUnlocked: Bool = false

    init() {
        let engine = GameEngine(sender: gameSessionManager)
        gameEngine = engine

        // Route incoming messages to their owning subsystem: heartbeats to
        // the connection monitor, gameplay messages to the engine (as
        // host-side input when this device is hosting, as follower state
        // otherwise — the host never receives its own `.roundStart`/
        // `.roundResult`/`.gameEnd` broadcasts back, so routing those
        // unconditionally into `applyFollowerMessage` is safe on every
        // device).
        let monitor = connectionMonitor
        let sessionManager = gameSessionManager
        let strokeSync = strokeSync
        gameSessionManager.onMessageReceived = { [weak sessionManager] message, peerID in
            guard let sessionManager else { return }
            switch message {
            case .heartbeat:
                monitor.recordHeartbeat(from: peerID)

            case .playerInput(let playerId, let input):
                if case .drawStroke(let points) = input {
                    // Peer-to-peer rendering data, not scored input — never
                    // routed through the engine (see `GameEngine.submitInput`
                    // and `StrokeSync`'s doc comment). The host also relays
                    // to every other connected peer, since this app's
                    // Multipeer session is star-shaped: a joiner-drawer can
                    // only reach the host directly, not its fellow joiners.
                    strokeSync.receive(points: points)
                    if sessionManager.isHost {
                        let relayTargets = sessionManager.connectedPeers.filter { $0 != peerID }
                        if !relayTargets.isEmpty {
                            sessionManager.send(message, to: relayTargets, mode: .unreliable)
                        }
                    }
                } else if sessionManager.isHost {
                    engine.submitInput(playerId: playerId, input: input)
                }

            case .disconnect(let playerId):
                if sessionManager.isHost {
                    engine.playerDisconnected(playerId)
                }

            case .roundStart, .roundResult, .gameEnd:
                engine.applyFollowerMessage(message)

            case .lobbyUpdate, .gameStart:
                break
            }
        }
    }

    /// Explicitly tears down the active session and stops connection
    /// monitoring.
    ///
    /// Call this from a deliberate user action — a "Leave" button or real
    /// back-navigation out of the lobby — never from `.onDisappear`
    /// unconditionally, since Phase 2 pushes a game screen on top of the
    /// lobby without the player actually leaving the session.
    func leaveSession() {
        connectionMonitor.stopMonitoring()
        gameSessionManager.stopSession()
        gameEngine.reset()
    }

    /// `true` once the Multipeer session disconnects while a game is in
    /// progress — i.e. the host (or, on the host, every joiner) left
    /// mid-game. Mode views observe this to surface a "host left" alert;
    /// the alert UI itself is a later task.
    var hostLeft: Bool {
        if case .disconnected = gameSessionManager.connectionState, case .playing = currentGameState {
            return true
        }
        return false
    }

    /// Clears game and session state after `hostLeft` fires, returning the
    /// app to a clean idle state so navigation can reset to the root.
    func resetAfterHostLeft() {
        gameEngine.reset()
        currentGameState = .idle
        gameSessionManager.stopSession()
    }

    /// Submits `input` on behalf of the local player, routing it correctly
    /// regardless of role: the **host** feeds it straight into its local
    /// `GameEngine` (the source of truth, no round trip needed); a
    /// **joiner** has no engine driving the game, so it sends a
    /// `.playerInput` message to the host over the wire instead.
    ///
    /// Shared across every mode view so each one only ever writes a single
    /// `appState.submitPlayerInput(...)` call rather than re-deriving this
    /// host/joiner branch itself.
    ///
    /// No-op if this device is a joiner with no resolvable host peer (e.g.
    /// the host has already disconnected — `hostLeft` will be surfacing an
    /// alert in that case anyway).
    func submitPlayerInput(_ input: PlayerInput) {
        let sessionManager = gameSessionManager
        if sessionManager.isHost {
            gameEngine.submitInput(playerId: sessionManager.myPlayer.id, input: input)
            return
        }

        guard let hostPlayer = sessionManager.roster.players.first,
              let hostPeer = sessionManager.roster.peerID(for: hostPlayer.id) else { return }
        sessionManager.send(.playerInput(playerId: sessionManager.myPlayer.id, input: input), to: [hostPeer])
    }

    /// Bridges a synced roster `Player` to its live connection health by
    /// looking up the peer the host originally mapped them to.
    ///
    /// Returns `nil` for the local player (never tracked in
    /// `ConnectionMonitor`) and for players with no recorded heartbeat yet.
    func peerHealth(for player: Player) -> ConnectionMonitor.PeerHealth? {
        guard let peerID = gameSessionManager.roster.peerID(for: player.id) else { return nil }
        return connectionMonitor.peerHealth[peerID]
    }
}
