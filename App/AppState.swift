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
}
