//
//  AppState.swift
//  proximiPlay
//

import Foundation
// @preconcurrency: `MCPeerID` predates Sendable and is not annotated, but it
// is an immutable identity object that Apple's own Multipeer APIs hand across
// threads. `StrokeRelay.Job` carries peers to a detached consumer, so without
// this the conformance is only satisfied by main-actor isolation — which is
// exactly the isolation the relay exists to escape.
@preconcurrency import MultipeerConnectivity
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

/// Relays outbound Speed Draw stroke batches to the host's fellow peers off
/// the main actor, while still sending them to the network in the exact
/// order they were enqueued.
///
/// ## Why off the main actor
///
/// `GameSessionManager.send(_:to:mode:)` is `nonisolated`, but calling a
/// `nonisolated` function from `@MainActor` code does not itself hop off the
/// main thread — it runs inline, on whatever actor/thread the caller is on.
/// Before this type existed, the relay call in `AppState`'s
/// `onMessageReceived` closure (itself invoked on `@MainActor` from
/// `GameSessionManager.receive(_:from:)`) ran the JSON encode and
/// `MCSession.send` synchronously on the main thread, up to ~20-25
/// batches/sec during Speed Draw (`StrokeRateLimiter` caps it there),
/// competing with SwiftUI's own main-thread work.
///
/// ## Why ordering still holds
///
/// Stroke batches render as independent polyline segments
/// (`StrokeSync.receive(points:)`), appended in **receive order** — there is
/// no sequence number on the wire to re-sort by, so out-of-order delivery
/// renders as a visibly scrambled drawing. Simply spawning a bare
/// `Task { sessionManager.send(...) }` per batch would not preserve that:
/// distinct `Task`s of equal priority are not guaranteed by the Swift
/// concurrency runtime to run in the order they were created, since ready
/// tasks are picked up by whichever thread in the cooperative pool is free
/// next.
///
/// This type sidesteps that by never spawning a task per batch. `enqueue`
/// is a synchronous, non-suspending call — `AsyncStream.Continuation
/// .yield(_:)` is documented to buffer values in call order — made directly
/// from the main actor, so the enqueue order is exactly the order
/// `onMessageReceived` validated (drawer check + throttle) the batches in.
/// A single long-lived consumer `Task`, started once in `init`, then drains
/// that buffer with `for await` — one item fully sent before the next is
/// even pulled off the stream — so batches reach `MCSession.send` in the
/// same order they were enqueued. That serial, one-at-a-time drain is what
/// actually guarantees order here, not any property of task scheduling.
private final class StrokeRelay: Sendable {
    /// `nonisolated` because the consumer reads these fields from a
    /// detached task: under the project's `SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor`, a plain struct's properties are main-actor isolated, which
    /// is a warning today and an error in the Swift 6 language mode.
    private nonisolated struct Job: Sendable {
        let message: GameMessage
        let peers: [MCPeerID]
    }

    private let continuation: AsyncStream<Job>.Continuation
    private let consumerTask: Task<Void, Never>

    /// Deepest relay backlog held before the *stalest* jobs are dropped.
    ///
    /// `AsyncStream`'s default policy is `.unbounded`, which would let the
    /// queue grow without limit if `MCSession.send` ever ran slower than
    /// batches arrive (a congested link, or many peers). The per-drawer
    /// throttle already caps arrivals at ~25/sec, so this depth is about
    /// 20 seconds of backlog — far past the point where unreliable stroke
    /// data is still worth delivering. Dropping beats growing here: the
    /// transport is `.unreliable` by design and the receiver's own segment
    /// buffer is capped too, so a gap is already an expected outcome.
    ///
    /// `.bufferingNewest`, deliberately: `.bufferingOldest(n)` keeps the
    /// oldest n and discards *arriving* ones once full, which is backwards
    /// here — under congestion the relay would drain an ever-staler queue
    /// while throwing away the strokes being drawn right now, so guessers
    /// would fall further behind instead of catching up to live.
    private static let maxBacklog = 512

    init(sender: GameSessionManager) {
        let (stream, continuation) = AsyncStream<Job>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.maxBacklog)
        )
        self.continuation = continuation
        // .utility, matching ConnectionMonitor's heartbeat loop: real-time
        // enough for drawing to feel live, but never competing with the main
        // actor's UI work for priority.
        self.consumerTask = Task.detached(priority: .utility) { [sender] in
            for await job in stream {
                sender.send(job.message, to: job.peers, mode: .unreliable)
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask.cancel()
    }

    /// Enqueues one relay job. Synchronous and non-suspending, so it is safe
    /// to call directly from the main-actor message-receive path without
    /// ever blocking on the network send.
    func enqueue(_ message: GameMessage, to peers: [MCPeerID]) {
        continuation.yield(Job(message: message, peers: peers))
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
        let strokeRelay = StrokeRelay(sender: sessionManager)
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
                    // its fellow joiners. The throttle/drawer checks above
                    // already ran on the main actor; only the encode +
                    // `MCSession.send` itself moves off it, via `strokeRelay`
                    // (see its doc comment for why this still preserves
                    // relay order).
                    if sessionManager.isHost {
                        let relayTargets = sessionManager.connectedPeers.filter { $0 != peerID }
                        if !relayTargets.isEmpty {
                            strokeRelay.enqueue(message, to: relayTargets)
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

            case .gameStart, .roundStart, .roundResult, .gameEnd:
                // `.gameStart` joins the follower branch so a joiner's
                // engine learns the mode and round count (see
                // `GameEngine.applyFollowerMessage`) — it is exactly as
                // host-authoritative as the round messages, so it gets the
                // exact same origin gate: dropped from any peer that isn't
                // the joined host, and dropped unconditionally on the host.
                guard sessionManager.isFromHost(peerID) else {
                    Self.logger.warning("Dropped \(String(describing: message)) not from the host peer")
                    return
                }
                engine.applyFollowerMessage(message)

            case .lobbyUpdate, .identityAssignment, .lobbyReturn, .removedByHost:
                // Session-level, not game-level: mirrored into
                // `GameSessionManager` state (roster, `myPlayer`,
                // `lobbyReturnToken`, `removedByHostToken`) inside its own
                // `receive(_:from:)`, behind the same `isFromHost` gate.
                // `.lobbyReturn`'s navigation + engine teardown happen
                // together in `ResultsView` so joiners never render a
                // half-cleared game; `.removedByHost`'s happen together in
                // `ContentView`'s root-level observer, for the same reason.
                break
            }
        }

        // Peer loss arrives as an MCSession state change, never as a
        // `.disconnect` message — nothing in the app sends one — so this is
        // the only path that tells game state somebody left mid-round.
        // Warm the sound cache off the critical path: the first play of
        // each effect otherwise does synchronous disk I/O, and `.roundStart`'s
        // first play lands exactly on Reflex Tap's flash.
        Task { @MainActor in
            SoundPlayer.shared.preloadAll()
        }

        gameSessionManager.onPlayerLeft = { playerId in
            strokeThrottle.reset(playerId)
            engine.playerDisconnected(playerId)
        }
    }

    // MARK: - Debug Roster Seeding

#if DEBUG
    /// Populates the roster with fake connected peers so lobby and roster UI
    /// can be inspected on a single device.
    ///
    /// Multipeer Connectivity needs at least two real devices to put anybody
    /// but yourself in the roster, so every multi-player lobby state has
    /// historically been unreviewable in the Simulator — which is how a
    /// roster row shipped rendering its avatar hard-right with the name
    /// centred underneath. Opt in with the `-demo-roster` launch argument;
    /// it is compiled out of release builds entirely and never runs during a
    /// real session.
    ///
    /// Purely presentational: it seeds `PlayerRoster` and peer health, and
    /// starts no session, so nothing here can reach the network.
    ///
    /// The seeded peer health is deliberately short-lived — `ConnectionMonitor`
    /// prunes health for any peer absent from the real `connectedPeers`, which
    /// a fake roster never joins — so the health dots fade after a heartbeat
    /// tick. Expected, not a bug in the row; `PlayerRow`'s previews cover the
    /// dot's rendering.
    func seedDemoRosterIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-demo-roster") else { return }

        gameSessionManager.isHost = true
        gameSessionManager.roster.setHost(gameSessionManager.myPlayer)

        let demoPeers: [(name: String, health: ConnectionMonitor.PeerHealth)] = [
            ("Bo", .healthy),
            ("Cass", .degraded),
            ("Devinder", .lost)
        ]
        for peer in demoPeers {
            let peerID = MCPeerID(displayName: peer.name)
            _ = gameSessionManager.roster.hostPlayerJoined(peer: peerID, displayName: peer.name)
            connectionMonitor.peerHealth[peerID] = peer.health
        }

        Self.logger.info("Seeded a demo roster (-demo-roster) — no session started")
    }
#endif

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

    /// Drops the finished game while **keeping the Multipeer session
    /// connected**, so everyone can regroup in the lobby for the next one.
    ///
    /// Both sides of "Back to Lobby" run this: the host from `ResultsView`'s
    /// button (which also broadcasts `.lobbyReturn`) and every joiner from
    /// `ContentView`'s `lobbyReturnToken` observer. Contrast
    /// `resetAfterHostLeft()`, which also tears the session down because
    /// there is nothing left to stay connected to.
    func returnToLobbyAfterHostReturn() {
        gameEngine.reset()
        currentGameState = .idle
    }

    /// Clears game and session state after `hostLeft` fires, returning the
    /// app to a clean idle state so navigation can reset to the root.
    func resetAfterHostLeft() {
        gameEngine.reset()
        currentGameState = .idle
        gameSessionManager.stopSession()
    }

    /// Clears game and session state after the host removed this device,
    /// returning the app to a clean idle state so navigation can reset to
    /// the root.
    ///
    /// Identical in effect to `resetAfterHostLeft()` — the session is gone
    /// either way — but kept separate because the two are reached from
    /// different signals and read very differently to the player. Tearing
    /// the session down here is also what makes the removal stick from this
    /// side: the device stops browsing and cannot silently reconnect.
    func resetAfterRemoval() {
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
