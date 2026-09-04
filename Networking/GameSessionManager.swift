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

    /// The local player representation, initialized from the device name.
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

        self.myPlayer = Player(
            displayName: peerID.displayName,
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
        browser.invitePeer(
            peerID,
            to: session,
            withContext: nil,
            timeout: 30
        )

        Self.logger.info("Invited host: \(peerID.displayName)")
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
        lastGameStart = nil
        lastGameStartToken = 0

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
        case .playerInput(let playerId, _, _):
            if isFromHost(peer) { return true }
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
    /// `.playerInput`/`.disconnect` messages, mirrors `.lobbyUpdate` into
    /// the local roster on joiner devices, then forwards every message that
    /// passes validation to `onMessageReceived`.
    @MainActor
    private func receive(_ message: GameMessage, from peerID: MCPeerID) {
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
            if let assigned = players.first(where: { $0.displayName == myPlayer.displayName }) {
                myPlayer = assigned
            }
        }

        if case .gameStart(let mode, let config) = message, isFromHost(peerID) {
            lastGameStart = (mode, config)
            lastGameStartToken += 1
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
                    self.roster.hostPlayerJoined(peer: peerID, displayName: displayName)
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
        Task { @MainActor in
            // Enforce the player cap (host occupies one of maxPlayers slots)
            // and hold at most one pending request at a time. Everything else
            // waits for an explicit host decision — never auto-accept.
            guard self.connectedPeers.count < Self.maxPlayers - 1,
                  self.pendingInvitation == nil else {
                Self.logger.info("Declined invitation from \(peerID.displayName) (full or busy)")
                invitationHandler(false, nil)
                return
            }
            self.pendingInvitation = PendingInvitation(
                peerName: peerID.displayName,
                respond: invitationHandler
            )
        }
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
