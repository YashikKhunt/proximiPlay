//
//  AppState.swift
//  proximiPlay
//

import Foundation

/// The top-level application state, injected into the environment at app startup.
///
/// Owns the networking and connection-monitoring singletons so that any view
/// in the hierarchy can access them without prop-drilling.
@Observable @MainActor
final class AppState {
    let gameSessionManager = GameSessionManager()
    let connectionMonitor = ConnectionMonitor()
    var currentGameState: GameState = .idle
    var isPremiumUnlocked: Bool = false

    init() {
        // Route incoming heartbeats to the monitor; Phase 2 game logic will
        // extend this dispatch with gameplay messages.
        let monitor = connectionMonitor
        gameSessionManager.onMessageReceived = { message, peerID in
            if case .heartbeat = message {
                monitor.recordHeartbeat(from: peerID)
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
