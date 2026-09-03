//
//  AppState.swift
//  proximiPlay
//

import Foundation
import MultipeerConnectivity
import os

/// Per-player minimum-interval throttle for inbound `.drawStroke` batches,
/// guarding the host's relay fan-out against a modified client flooding the
/// shared canvas — `StrokeSync.maxSegments` only bounds *stored* segments,
/// not the rate messages arrive/relay at, and client-side batching in
/// `DrawingCanvasView` is trivially bypassed by a modified client.
///
/// Keyed by the asserted drawer's `playerId` rather than the delivering
/// `MCPeerID`, since a relayed batch's immediate sender is always the host
/// (see `AppState`'s message-receive path) — throttling by peer would
/// bucket every guesser's relayed traffic under the host's single peer
/// identity instead of the actual drawer being rate-limited.
///
/// `minInterval` of 40ms (~25/sec) sits comfortably above
/// `DrawingCanvasView`'s legitimate ~20 batches/sec, so normal drawing is
/// never perceptibly throttled while a flood is still capped.
///
/// A plain class (not an actor): only ever touched from `onMessageReceived`,
/// which already runs on `@MainActor`.
@MainActor
private final class StrokeRateLimiter {
    private let minInterval: TimeInterval
    private var lastAcceptedAt: [UUID: Date] = [:]

    init(minInterval: TimeInterval = 1.0 / 25.0) {
        self.minInterval = minInterval
    }

    /// Returns `true` (and records `playerId`'s acceptance time) if enough
    /// time has elapsed since its last accepted batch; otherwise returns
    /// `false` and the batch should be dropped without being displayed or
    /// relayed.
    func allow(_ playerId: UUID, now: Date = Date()) -> Bool {
        if let last = lastAcceptedAt[playerId], now.timeIntervalSince(last) < minInterval {
            return false
        }
        lastAcceptedAt[playerId] = now
        return true
    }

    /// Drops stale per-player state for a player that disconnected, so a
    /// reconnecting player (a fresh `Player.id`, in practice) never
    /// inherits stale throttle state.
    func reset(_ playerId: UUID) {
        lastAcceptedAt.removeValue(forKey: playerId)
    }
}

/// The top-level application state, injected into the environment at app startup.
///
/// Owns the networking and connection-monitoring singletons so that any view
/// in the hierarchy can access them without prop-drilling.
@Observable @MainActor
final class AppState {
    private nonisolated static let logger = Logger(
        subsystem: "com.proximiplay",
        category: "app-state"
    )

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
        // otherwise). `.roundStart`/`.roundResult`/`.gameEnd` are only ever
        // legitimately *received* by a joiner from the host — routing them
        // into `applyFollowerMessage` is gated on `isFromHost(peerID)` so a
        // forging fellow joiner (or a stray message arriving at the host
        // itself) can never overwrite the authoritative engine's
        // `finalScores`/`currentRound`/`isRunning`.
        let monitor = connectionMonitor
        let sessionManager = gameSessionManager
        let strokeSync = strokeSync
        let strokeThrottle = StrokeRateLimiter()
        gameSessionManager.onMessageReceived = { [weak sessionManager] message, peerID in
            guard let sessionManager else { return }
            switch message {
            case .heartbeat:
                monitor.recordHeartbeat(from: peerID)

            case .playerInput(let playerId, let input, let round):
                if case .drawStroke(let points) = input {
                    // Peer-to-peer rendering data, not scored input — never
                    // routed through the engine (see `GameEngine.submitInput`
                    // and `StrokeSync`'s doc comment). Only the round's
                    // assigned drawer may draw; every other asserted
                    // `playerId` is dropped before it ever reaches
                    // `strokeSync` or a relay, so a non-drawer can't scribble
                    // on everyone's shared canvas. A per-drawer throttle then
                    // caps the accepted rate, since `StrokeSync.maxSegments`
                    // only bounds stored segments, not the arrival/relay
                    // rate a modified client could flood at.
                    guard playerId == engine.currentDrawerId else {
                        Self.logger.warning("Dropped .drawStroke asserted by a non-drawer player")
                        return
                    }
                    guard strokeThrottle.allow(playerId) else {
                        return
                    }
                    strokeSync.receive(points: points)
                    // The host also relays to every other connected peer,
                    // since this app's Multipeer session is star-shaped: a
                    // joiner-drawer can only reach the host directly, not
                    // its fellow joiners.
                    if sessionManager.isHost {
                        let relayTargets = sessionManager.connectedPeers.filter { $0 != peerID }
                        if !relayTargets.isEmpty {
                            sessionManager.send(message, to: relayTargets, mode: .unreliable)
                        }
                    }
                } else if sessionManager.isHost {
                    engine.submitInput(playerId: playerId, input: input, round: round)
                }

            case .disconnect(let playerId):
                strokeThrottle.reset(playerId)
                if sessionManager.isHost {
                    engine.playerDisconnected(playerId)
                }

            case .roundStart, .roundResult, .gameEnd:
                guard sessionManager.isFromHost(peerID) else {
                    Self.logger.warning("Dropped \(String(describing: message)) not from the host peer")
                    return
                }
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
        // Stamp this device's own view of the round in progress — kept
        // accurate via `GameEngine.applyFollowerMessage`'s `.roundStart`
        // handling — so the host can reject the input if it arrives after
        // the host has already moved past that round (see
        // `GameEngine.submitInput`'s `round` parameter).
        let round = gameEngine.roundNumber
        sessionManager.send(.playerInput(playerId: sessionManager.myPlayer.id, input: input, round: round), to: [hostPeer])
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
