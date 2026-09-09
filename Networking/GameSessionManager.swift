//
//  GameSessionManager.swift
//  proximiPlay
//

import Foundation
import MultipeerConnectivity
#if canImport(UIKit)
import UIKit
#endif
import os

// MARK: - GameSessionManager

/// Manages Multipeer Connectivity sessions for ProximiPlay, handling host
/// advertising, peer browsing, and bidirectional message exchange.
///
/// Designed for iOS 17+ with `@Observable` for SwiftUI integration. All
/// observable property mutations are dispatched to `@MainActor` from delegate
/// callbacks to guarantee UI-safe updates.
///
/// **Key implementation detail:** `MCPeerID` is cached via `NSKeyedArchiver`
/// in `UserDefaults`. The Multipeer Connectivity framework refuses to
/// reconnect when a *new* `MCPeerID` reuses the same `displayName` as a
/// previously-seen peer, so the archived identity must be reused across
/// app launches.
@Observable
final class GameSessionManager: NSObject, Sendable {

    // MARK: - Constants

    /// Bonjour service type. Must be 1-15 lowercase ASCII letters/hyphens.
    let serviceType = "proximiplay"

    /// Maximum players in a session, host included.
    static let maxPlayers = 8

    /// Maximum accepted size (in bytes) for an inbound message payload.
    /// Anything larger is dropped before decoding — a defensive cap against
    /// malformed or hostile peers, since `didReceive` fires for any bytes a
    /// connected peer chooses to send.
    ///
    /// nonisolated: read directly from the nonisolated `didReceive` delegate
    /// callback, before any `@MainActor` hop, so oversize payloads never
    /// even reach decoding.
    nonisolated static let maxPayloadBytes = 65536

    /// UserDefaults key for the archived MCPeerID.
    private static let peerIDKey = "proximiplay.myPeerID"

    /// Maximum accepted size (in bytes) for the invitation context a joiner
    /// attaches to `joinHost(_:)`. The payload is just a UTF-8 nickname
    /// bounded by `PlayerNickname.maxLength`, so anything larger is a
    /// malformed or hostile peer and is ignored in favour of the peer's own
    /// display name.
    nonisolated static let maxInvitationContextBytes = 256

    // MARK: - Logger

    // nonisolated: Logger is Sendable and this is an immutable let, so it is
    // safely callable from the nonisolated MPC delegate callbacks.
    private nonisolated static let logger = Logger(
        subsystem: "com.proximiplay",
        category: "networking"
    )

    // MARK: - Multipeer Objects

    /// The local peer identity, cached across launches.
    @ObservationIgnored nonisolated private let myPeerID: MCPeerID

    /// The active connectivity session.
    @ObservationIgnored nonisolated(unsafe) private var session: MCSession!

    /// Advertises this device as a host that peers can join.
    @ObservationIgnored nonisolated(unsafe) private var advertiser: MCNearbyServiceAdvertiser!

    /// Browses for nearby hosts that this device can join.
    @ObservationIgnored nonisolated(unsafe) private var browser: MCNearbyServiceBrowser!

    // MARK: - Observable State

    /// Peers currently connected to the session.
    @MainActor var connectedPeers: [MCPeerID] = []

    /// Host peers discovered by the browser.
    @MainActor var discoveredHosts: [MCPeerID] = []

    /// The high-level connection lifecycle state.
    @MainActor var connectionState: ConnectionState = .idle

    /// Whether this device is the game host (advertiser).
    @MainActor var isHost: Bool = false

    /// The local player representation.
    ///
    /// Seeded from the persisted nickname (`PlayerNickname.load()`), then —
    /// on a joiner — **replaced wholesale** by whatever the host assigns via
    /// `.identityAssignment(player:)`. The id, color and host flag are
    /// always the host's to decide; this device only ever *requests* a
    /// display name.
    @MainActor var myPlayer: Player

    /// A join request awaiting the host's explicit accept/decline decision.
    @MainActor var pendingInvitation: PendingInvitation?

    /// Set on joiner devices when a `.gameStart` message arrives from the
    /// host. The host never observes this — it never receives its own
    /// broadcast — so it drives navigation directly from its "Start Game"
    /// action instead. Joiner-side views (`LobbyView`) observe this via
    /// `.onChange` to navigate into the game once the host starts it.
    @MainActor var lastGameStart: (mode: GameMode, config: GameConfig)?

    /// Monotonically increments every time a `.gameStart` message arrives,
    /// even when it repeats the exact same mode/config (e.g. the host's
    /// "Play Again" on `ResultsView`) — `lastGameStart` alone wouldn't
    /// re-fire a SwiftUI `.onChange` in that case since its value wouldn't
    /// actually change. Observe this token instead of `lastGameStart`
    /// itself wherever a message needs to reliably re-trigger on every
    /// rebroadcast, not just the first.
    @MainActor var lastGameStartToken: Int = 0

    /// Monotonically increments on every `.lobbyReturn` accepted from the
    /// host — the joiner-side signal that the host tapped "Back to Lobby"
    /// on `ResultsView`. A token rather than a `Bool` for the same reason
    /// as `lastGameStartToken`: a second return after a second game must
    /// re-fire SwiftUI's `.onChange`, and a `Bool` that is already `true`
    /// wouldn't. Never incremented on the host (`isFromHost` is always
    /// `false` there), so the host can't follow its own broadcast.
    @MainActor var lobbyReturnToken: Int = 0

    /// Monotonically increments on every `.removedByHost` accepted from the
    /// host — the joiner-side signal that the host removed this device from
    /// the game. A token rather than a `Bool` for the same reason as
    /// `lobbyReturnToken`. Never incremented on the host (`isFromHost` is
    /// always `false` there), so a host can never remove itself, and a
    /// fellow joiner's forged message is dropped before it gets here.
    @MainActor var removedByHostToken: Int = 0

    /// Peers the host removed, blocked for the remainder of this session.
    ///
    /// Load-bearing, not bookkeeping. `.removedByHost` only *asks* a peer to
    /// leave — Multipeer has no force-disconnect — and the host keeps
    /// advertising after a removal, so without this the removed device (or a
    /// modified client that ignored the message outright) re-invites itself
    /// straight back. Checked in the advertiser's invitation callback, which
    /// declines blocked peers without ever surfacing a prompt to the host.
    ///
    /// Session-scoped by design: cleared by `stopSession()`, so a removal is
    /// never a permanent ban that outlives the game it happened in. Keyed by
    /// `MCPeerID`, which is cached per install (see `PlayerNickname`), so it
    /// survives the removed player force-quitting and reopening the app.
    @ObservationIgnored @MainActor private var blockedPeers: Set<MCPeerID> = []

    /// Nicknames peers asked for in their invitation context, held from the
    /// advertiser callback until the matching `.connected` state change
    /// creates their roster entry. Sanitized on the way *in* to the roster
    /// (`PlayerRoster.hostPlayerJoined`), never trusted raw.
    @ObservationIgnored @MainActor private var requestedNicknames: [MCPeerID: String] = [:]

    /// The host-authoritative player roster, kept in sync across every
    /// device via `.lobbyUpdate` broadcasts. Also consulted from the
    /// message-receive path to validate that inbound `.playerInput` /
    /// `.disconnect` messages carry the `playerId` the delivering peer
    /// actually owns.
    @MainActor let roster = PlayerRoster()

    /// The peer this device invited via `joinHost(_:)` — `nil` on the host
    /// itself (which never joins anyone) and before a joiner has invited a
    /// host. This app's Multipeer session is star-shaped: a joiner only
    /// ever connects to this one peer, so it doubles as "the host peer" for
    /// validating that host-authoritative broadcasts genuinely originate
    /// from the host rather than a forging fellow joiner. See `isFromHost`.
    ///
    /// Externally settable (like `isHost`/`myPlayer` above) so tests and
    /// previews can exercise `isFromHost`/message-routing without a live
    /// Multipeer session; production code only ever sets it from
    /// `joinHost(_:)`/`startHosting()`/`stopSession()`.
    @MainActor var hostPeerID: MCPeerID?

    // MARK: - Callbacks

    /// Invoked on `@MainActor` when a `GameMessage` arrives from a peer.
    @MainActor var onMessageReceived: (@MainActor @Sendable (GameMessage, MCPeerID) -> Void)?

    /// Invoked on the host when a peer actually drops, carrying the
    /// departed `Player.id`.
    ///
    /// Peer loss surfaces as an `MCSession` state change, not as a
    /// `GameMessage`, so this is the only signal game state gets that
    /// somebody left mid-round.
    @MainActor var onPlayerLeft: (@MainActor @Sendable (UUID) -> Void)?

    // MARK: - Pending Invitation

    /// A peer's request to join, held until the host accepts or declines.
    struct PendingInvitation: Identifiable {
        let id = UUID()
        let peerName: String
        let respond: (Bool, MCSession?) -> Void
    }

    // MARK: - Connection State

    /// Represents the progression of a Multipeer Connectivity session.
    enum ConnectionState: Equatable, Sendable {
        case idle
        case advertising
        case browsing
        case connecting
        case connected
        case disconnected(reason: String)
    }

    // MARK: - Initialization

    @MainActor
    override init() {
        let peerID = Self.loadOrCreatePeerID()
        self.myPeerID = peerID

        // The nickname is app-level identity and is deliberately *not* used
        // to build `myPeerID` — see `PlayerNickname`'s doc comment.
        self.myPlayer = Player(
            displayName: PlayerNickname.load(),
            color: .blue,
            isHost: false
        )

        super.init()

        self.session = MCSession(
            peer: myPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        self.session.delegate = self

        Self.logger.info("Session manager initialized with peer: \(peerID.displayName)")
    }

    // MARK: - MCPeerID Caching

    /// Loads a previously archived `MCPeerID` from `UserDefaults`, or creates
    /// and archives a new one if none exists.
    ///
    /// This is critical for Multipeer Connectivity reliability: the framework
    /// tracks peers by identity, and a new `MCPeerID` with an existing
    /// `displayName` will be treated as a conflicting peer, preventing
    /// reconnection.
    private static func loadOrCreatePeerID() -> MCPeerID {
        if let data = UserDefaults.standard.data(forKey: peerIDKey),
           let peerID = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: MCPeerID.self,
               from: data
           ) {
            logger.debug("Loaded cached MCPeerID: \(peerID.displayName)")
            return peerID
        }

        let peerID = MCPeerID(displayName: UIDevice.current.name)

        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: peerID,
            requiringSecureCoding: true
        ) {
            UserDefaults.standard.set(data, forKey: peerIDKey)
            logger.info("Created and cached new MCPeerID: \(peerID.displayName)")
        } else {
            logger.error("Failed to archive MCPeerID — reconnection may break across launches")
        }

        return peerID
    }

    // MARK: - Hosting

    /// Begins advertising this device as a game host that nearby peers can
    /// discover and join.
    @MainActor
    func startHosting() {
        stopSession()

        isHost = true
        // Pick up any nickname edit made since this manager was created —
        // the host seeds its own roster entry from `myPlayer`, so this is
        // the name every other device will render for it.
        myPlayer.displayName = PlayerNickname.load()
        myPlayer.isHost = true
        connectionState = .advertising
        hostPeerID = nil
        roster.setHost(myPlayer)

        advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: nil,
            serviceType: serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()

        Self.logger.info("Started hosting (advertising)")
    }

    // MARK: - Browsing

    /// Begins browsing for nearby hosts to join.
    @MainActor
    func startBrowsing() {
        stopSession()

        isHost = false
        myPlayer.displayName = PlayerNickname.load()
        myPlayer.isHost = false
        connectionState = .browsing

        browser = MCNearbyServiceBrowser(
            peer: myPeerID,
            serviceType: serviceType
        )
        browser.delegate = self
        browser.startBrowsingForPeers()

        Self.logger.info("Started browsing for hosts")
    }

    // MARK: - Joining

    /// Sends an invitation to the specified host peer to join their session.
    ///
    /// - Parameter peerID: The host's `MCPeerID` from `discoveredHosts`.
    @MainActor
    func joinHost(_ peerID: MCPeerID) {
        guard let browser else {
            Self.logger.warning("Cannot join host — browser is nil")
            return
        }

        connectionState = .connecting
        hostPeerID = peerID
        // The invitation context is how this device's chosen nickname
        // reaches the host *before* the host builds its roster entry — the
        // `MCPeerID` carries only the (privacy-leaking) device name, and
        // must not be rebuilt from the nickname (see `PlayerNickname`).
        // The host still sanitizes it and still owns the final identity.
        let nickname = PlayerNickname.load()
        myPlayer.displayName = nickname
        browser.invitePeer(
            peerID,
            to: session,
            withContext: Data(nickname.utf8),
            timeout: 30
        )

        Self.logger.info("Invited host: \(peerID.displayName)")
    }

    // MARK: - Nickname

    /// Persists a new nickname and applies it to the local player.
    ///
    /// Returns the value actually stored (sanitized — trimmed, length
    /// capped, and falling back to the device name when cleared) so callers
    /// can reflect exactly what other devices will see. When hosting, the
    /// host's own roster entry is refreshed and rebroadcast so the lobby
    /// updates everywhere; joiners carry the nickname to the host in their
    /// invitation context instead (`joinHost(_:)`).
    @discardableResult
    @MainActor
    func updateNickname(_ raw: String) -> String {
        let stored = PlayerNickname.save(raw)
        myPlayer.displayName = stored
        if isHost {
            roster.setHost(myPlayer)
            broadcastLobbyUpdate()
        }
        Self.logger.info("Nickname updated")
        return stored
    }

    // MARK: - Stopping

    /// Tears down the current session, stopping advertising/browsing and
    /// disconnecting all peers.
    @MainActor
    func stopSession() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil

        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil

        session.disconnect()

        connectedPeers = []
        discoveredHosts = []
        connectionState = .idle
        isHost = false
        myPlayer.isHost = false
        hostPeerID = nil
        roster.reset()
        requestedNicknames = [:]
        lastGameStart = nil
        lastGameStartToken = 0
        lobbyReturnToken = 0
        removedByHostToken = 0
        blockedPeers = []

        Self.logger.info("Session stopped and state reset")
    }

    // MARK: - Sending

    /// Encodes and sends a `GameMessage` to specific peers.
    ///
    /// - Parameters:
    ///   - message: The game message to send.
    ///   - peers: The target peers. Must not be empty.
    ///   - mode: `.reliable` for ordered delivery, `.unreliable` for speed.
    // nonisolated so encoding + MCSession.send can run off the main actor
    // (e.g. from the heartbeat loop); touches only nonisolated state.
    nonisolated func send(
        _ message: GameMessage,
        to peers: [MCPeerID],
        mode: MCSessionSendDataMode = .reliable
    ) {
        guard !peers.isEmpty else {
            Self.logger.warning("send(_:to:mode:) called with empty peers array")
            return
        }

        do {
            let data = try message.encoded()
            try session.send(data, toPeers: peers, with: mode)
            Self.logger.debug("Sent message to \(peers.count) peer(s)")
        } catch {
            Self.logger.error(
                "Failed to send message: \(error.localizedDescription)"
            )
        }
    }

    /// Encodes and broadcasts a `GameMessage` to every connected peer using
    /// `.reliable` delivery.
    ///
    /// - Parameter message: The game message to broadcast.
    nonisolated func broadcast(_ message: GameMessage) {
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            Self.logger.debug("broadcast(_:) skipped — no connected peers")
            return
        }
        send(message, to: peers, mode: .reliable)
    }

    /// Broadcasts the current roster to every connected peer. Host-only —
    /// call after any roster mutation so every device renders an identical
    /// player list.
    @MainActor
    private func broadcastLobbyUpdate() {
        broadcast(.lobbyUpdate(players: roster.players))
    }

    // MARK: - Message Validation

    /// `true` when `peer` is safe to trust as the game host for
    /// host-authoritative broadcasts (`.gameStart`, `.lobbyUpdate`,
    /// `.roundStart`/`.roundResult`/`.gameEnd`, and relayed `.playerInput`
    /// such as Speed Draw strokes) — i.e. this device is a joiner and
    /// `peer` is the one peer it invited via `joinHost(_:)`. Always `false`
    /// on the host itself, since the host is the origin of these messages,
    /// never a legitimate recipient of one (a message claiming to be one of
    /// these arriving at the host is necessarily forged).
    @MainActor
    func isFromHost(_ peer: MCPeerID) -> Bool {
        !isHost && peer == hostPeerID
    }

    /// Returns `true` when `message` is safe to route to `onMessageReceived`.
    ///
    /// `.playerInput` and `.disconnect` carry a self-asserted `playerId`
    /// that must match the `Player` the roster mapped to the delivering
    /// peer at join time — otherwise a peer could spoof another player's
    /// identity. The one exception is a `.playerInput` relayed by the host
    /// itself to a joiner (this app's star-shaped session only ever relays
    /// `.drawStroke` batches, never a peer's own scored input): joiners
    /// have no `peerToPlayerId` mapping of their own to check the asserted
    /// `playerId` against (only the host populates that map, from
    /// `hostPlayerJoined`), but the host has already validated the
    /// original sender against its own roster before relaying, so trust
    /// follows transitively. Every other message type passes through
    /// unchecked.
    ///
    /// Pure aside from the `roster`/`hostPeerID`/`isHost` reads, so it is
    /// directly unit-testable: populate `roster` via
    /// `hostPlayerJoined(peer:displayName:)` and call this with any
    /// `MCPeerID`/`GameMessage` pair.
    @MainActor
    func isMessageAuthentic(_ message: GameMessage, from peer: MCPeerID) -> Bool {
        switch message {
        case .playerInput(let playerId, let input, _):
            // The host relays exactly one input kind — `.drawStroke`, for the
            // star topology's benefit — having already validated the original
            // sender. Scope the bypass to that case rather than to "anything
            // from the host", so a future relay path can't silently inherit
            // unauthenticated-playerId trust.
            if isFromHost(peer), case .drawStroke = input { return true }
            return roster.isValid(playerId: playerId, from: peer)
        case .disconnect(let playerId):
            return roster.isValid(playerId: playerId, from: peer)
        default:
            return true
        }
    }

    /// Returns `true` when `data` exceeds `maxPayloadBytes` and should be
    /// dropped before attempting to decode it.
    ///
    /// A free function of `Data`, so it is directly unit-testable without
    /// any session/peer machinery.
    nonisolated static func isOversizedPayload(_ data: Data) -> Bool {
        data.count > maxPayloadBytes
    }

    /// Validates and routes a decoded inbound message: drops spoofed
    /// `.playerInput`/`.disconnect` messages, mirrors host-authoritative
    /// session messages (`.lobbyUpdate`, `.identityAssignment`,
    /// `.gameStart`, `.lobbyReturn`) into local state on joiner devices,
    /// then forwards every message that passes validation to
    /// `onMessageReceived`.
    ///
    /// Every one of those mirrors is guarded by `isFromHost(peerID)`, which
    /// fails closed: it is `false` for any peer other than the one this
    /// device invited via `joinHost(_:)`, and *always* `false` on the host
    /// (which originates these messages and must never follow one).
    ///
    /// Internal rather than private purely so tests can drive the real
    /// routing logic without a live `MCSession` — production code only ever
    /// calls it from `session(_:didReceive:fromPeer:)`.
    @MainActor
    func receive(_ message: GameMessage, from peerID: MCPeerID) {
        guard isMessageAuthentic(message, from: peerID) else {
            Self.logger.warning(
                "Dropped message from \(peerID.displayName) — playerId did not match roster mapping"
            )
            return
        }

        if case .lobbyUpdate(let players) = message, isFromHost(peerID) {
            roster.applyLobbyUpdate(players)
            // `peerID` is already verified as the host peer above; record
            // it against the host's own player id so this joiner can
            // resolve `roster.peerID(for:)` for outbound messages (see
            // `PlayerRoster.setHostPeerMapping`'s doc comment).
            if let hostPlayer = players.first {
                roster.setHostPeerMapping(peer: peerID, hostPlayerId: hostPlayer.id)
            }
            // Deliberately *no* name matching here: this device learns who
            // it is only from `.identityAssignment` below. Matching on
            // `displayName` gave two players with the same nickname the
            // same identity, and the loser of that tie silently self-DoS'd
            // (the host validates `playerId` against the sending peer).
            // A roster refresh may still update this device's own entry —
            // adopt it by id, never by name.
            if let mine = players.first(where: { $0.id == myPlayer.id }) {
                myPlayer = mine
            }
        }

        if case .identityAssignment(let assigned) = message, isFromHost(peerID) {
            myPlayer = assigned
            Self.logger.info("Adopted host-assigned identity")
        }

        if case .gameStart(let mode, let config) = message, isFromHost(peerID) {
            lastGameStart = (mode, config)
            lastGameStartToken += 1
        }

        if case .lobbyReturn = message, isFromHost(peerID) {
            lobbyReturnToken += 1
            Self.logger.info("Host returned the session to the lobby")
        }

        if case .removedByHost = message, isFromHost(peerID) {
            removedByHostToken += 1
            Self.logger.info("Host removed this device from the game")
        }

        onMessageReceived?(message, peerID)
    }
}

// MARK: - MCSessionDelegate

extension GameSessionManager: MCSessionDelegate {

    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        let displayName = peerID.displayName

        switch state {
        case .notConnected:
            Self.logger.info("Peer disconnected: \(displayName)")
            Task { @MainActor in
                self.connectedPeers.removeAll { $0 == peerID }
                if self.connectedPeers.isEmpty {
                    self.connectionState = .disconnected(
                        reason: "\(displayName) disconnected"
                    )
                }
                self.requestedNicknames.removeValue(forKey: peerID)
                if self.isHost {
                    let departedId = self.roster.hostPlayerLeft(peer: peerID)
                    self.broadcastLobbyUpdate()
                    // A real peer drop never produces a `.disconnect` wire
                    // message — nothing sends one — so the engine has to be
                    // told here, or a departed player keeps holding up the
                    // round and stays in the drawer rotation.
                    if let departedId {
                        self.onPlayerLeft?(departedId)
                    }
                }
            }

        case .connecting:
            Self.logger.info("Connecting to peer: \(displayName)")
            Task { @MainActor in
                self.connectionState = .connecting
            }

        case .connected:
            Self.logger.info("Connected to peer: \(displayName)")
            Task { @MainActor in
                if !self.connectedPeers.contains(peerID) {
                    self.connectedPeers.append(peerID)
                }
                self.connectionState = .connected

                if self.isHost {
                    // Use the nickname the peer asked for in its invitation
                    // context, falling back to its MCPeerID display name.
                    // `hostPlayerJoined` sanitizes either way.
                    let requested = self.requestedNicknames.removeValue(forKey: peerID) ?? displayName
                    let assigned = self.roster.hostPlayerJoined(peer: peerID, displayName: requested)
                    // Tell *this* peer exactly who it is before the roster
                    // broadcast, so it never has to recognise itself in a
                    // list (which broke the moment two players shared a
                    // nickname). Point-to-point, host → one joiner.
                    self.send(.identityAssignment(player: assigned), to: [peerID])
                    self.broadcastLobbyUpdate()
                }
            }

        @unknown default:
            Self.logger.warning(
                "Unknown session state for peer \(displayName): \(String(describing: state))"
            )
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        guard !Self.isOversizedPayload(data) else {
            Self.logger.warning(
                "Dropped oversize payload from \(peerID.displayName): \(data.count) bytes exceeds \(Self.maxPayloadBytes)-byte cap"
            )
            return
        }

        do {
            let message = try GameMessage.decoded(from: data)
            Self.logger.debug(
                "Received message from \(peerID.displayName)"
            )
            Task { @MainActor in
                self.receive(message, from: peerID)
            }
        } catch {
            Self.logger.error(
                "Failed to decode message from \(peerID.displayName): \(error.localizedDescription)"
            )
        }
    }

    // MARK: Stream / Resource Stubs

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        // Not used in ProximiPlay.
    }

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        // Not used in ProximiPlay.
    }

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {
        // Not used in ProximiPlay.
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension GameSessionManager: MCNearbyServiceAdvertiserDelegate {

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Self.logger.info("Received invitation from: \(peerID.displayName)")
        let requestedNickname = Self.nickname(fromInvitationContext: context)
        Task { @MainActor in
            // A peer the host already removed never gets a second prompt —
            // declined outright, so a removal cannot be undone by the removed
            // player simply tapping Join again (see `removePlayer(_:)`).
            guard !self.blockedPeers.contains(peerID) else {
                Self.logger.info("Declined invitation from a peer the host removed")
                invitationHandler(false, nil)
                return
            }
            // Enforce the player cap (host occupies one of maxPlayers slots)
            // and hold at most one pending request at a time. Everything else
            // waits for an explicit host decision — never auto-accept.
            guard self.connectedPeers.count < Self.maxPlayers - 1,
                  self.pendingInvitation == nil else {
                Self.logger.info("Declined invitation from \(peerID.displayName) (full or busy)")
                invitationHandler(false, nil)
                return
            }
            // Held until this peer actually connects, at which point it
            // seeds the roster entry the host assigns them.
            let name = PlayerNickname.sanitize(
                requestedNickname ?? peerID.displayName,
                fallback: peerID.displayName
            )
            self.requestedNicknames[peerID] = name
            self.pendingInvitation = PendingInvitation(
                peerName: name,
                respond: invitationHandler
            )
        }
    }

    /// Decodes the nickname a joiner attached to its invitation, or `nil`
    /// when the context is absent, oversized, or not valid UTF-8.
    ///
    /// A free function of `Data?`, so the size/encoding guards are directly
    /// unit-testable without a live advertiser.
    nonisolated static func nickname(fromInvitationContext context: Data?) -> String? {
        guard let context, !context.isEmpty else { return nil }
        guard context.count <= maxInvitationContextBytes else {
            logger.warning("Ignored oversize invitation context: \(context.count) bytes")
            return nil
        }
        return String(data: context, encoding: .utf8)
    }

    /// Resolves the pending join request with the host's decision.
    ///
    /// Safe to call when no request is pending (no-op), so alert dismissal
    /// and button actions can both route here without double-responding.
    @MainActor
    func respondToPendingInvitation(accept: Bool) {
        guard let invitation = pendingInvitation else { return }
        pendingInvitation = nil
        invitation.respond(accept, accept ? session : nil)
        Self.logger.info("Host \(accept ? "accepted" : "declined") join request from \(invitation.peerName)")
    }

    // MARK: - Host: Removing a Player

    /// Removes `player` from the session. Host-only; a no-op for anyone else
    /// or for the host's own entry.
    ///
    /// App Store Guideline 1.2 expects a way to remove an abusive user, and
    /// this app carries user-generated content on two surfaces that reach
    /// every device: nicknames (also baked into the shareable result card)
    /// and live Speed Draw strokes.
    ///
    /// Three things happen, and all three are needed:
    ///
    /// 1. `.removedByHost` is sent point-to-point so the target tears down
    ///    its own session and says why. Multipeer cannot force-disconnect a
    ///    peer, so this is a request the target device honours — a modified
    ///    client could ignore it, which is why it is not the only step.
    /// 2. The peer is dropped from the roster. Their `playerId` no longer
    ///    maps to their `MCPeerID`, so any further `.playerInput` they send
    ///    fails `PlayerRoster.isValid(playerId:for:)` and is discarded — the
    ///    removal holds even against a client that stayed connected.
    /// 3. Their `MCPeerID` is blocked for the rest of the session, so the
    ///    still-advertising host auto-declines their re-invitation instead
    ///    of prompting the host to re-admit the person they just removed.
    ///
    /// The updated roster is broadcast last, so every remaining device
    /// re-renders without the removed player.
    ///
    /// - Returns: `true` when the player was removed.
    @discardableResult
    @MainActor
    func removePlayer(_ player: Player) -> Bool {
        guard isHost else {
            Self.logger.warning("removePlayer(_:) ignored — not the host")
            return false
        }
        guard player.id != myPlayer.id else {
            Self.logger.warning("removePlayer(_:) ignored — the host cannot remove itself")
            return false
        }
        guard let peerID = roster.peerID(for: player.id) else {
            Self.logger.warning("removePlayer(_:) ignored — no peer mapped to that player")
            return false
        }

        // Tell them first, while the session still carries the message.
        send(.removedByHost, to: [peerID])

        blockedPeers.insert(peerID)
        requestedNicknames.removeValue(forKey: peerID)
        roster.hostPlayerLeft(peer: peerID)
        broadcastLobbyUpdate()

        // Tell game state now rather than waiting for the `.notConnected`
        // state change: a mid-game removal must not leave the engine holding
        // the round open for input from someone who is no longer playing, and
        // a client that ignores `.removedByHost` never produces that state
        // change at all. Same callback a real peer drop uses, so the engine
        // path is identical either way — and it is idempotent, so the
        // disconnect that (usually) follows is harmless.
        onPlayerLeft?(player.id)

        Self.logger.info("Host removed a player and blocked their peer for this session")
        return true
    }

    /// Whether `peer` was removed by the host earlier in this session.
    /// Exposed for tests and for the advertiser's invitation gate.
    @MainActor
    func isBlocked(_ peer: MCPeerID) -> Bool {
        blockedPeers.contains(peer)
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: any Error
    ) {
        Self.logger.error(
            "Advertiser failed to start: \(error.localizedDescription)"
        )
        Task { @MainActor in
            self.connectionState = .disconnected(
                reason: "Failed to start advertising: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension GameSessionManager: MCNearbyServiceBrowserDelegate {

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        Self.logger.info("Discovered host: \(peerID.displayName)")
        Task { @MainActor in
            if !self.discoveredHosts.contains(peerID) {
                self.discoveredHosts.append(peerID)
            }
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        Self.logger.info("Lost host: \(peerID.displayName)")
        Task { @MainActor in
            self.discoveredHosts.removeAll { $0 == peerID }
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: any Error
    ) {
        Self.logger.error(
            "Browser failed to start: \(error.localizedDescription)"
        )
        Task { @MainActor in
            self.connectionState = .disconnected(
                reason: "Failed to start browsing: \(error.localizedDescription)"
            )
        }
    }
}
