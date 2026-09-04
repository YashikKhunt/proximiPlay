//
//  PlayerRoster.swift
//  proximiPlay
//

import Foundation
import MultipeerConnectivity
import os

// MARK: - PlayerRoster

/// Host-authoritative roster of players in the current game session.
///
/// The host is the single source of truth for player identity: a stable
/// `Player.id` and a `PlayerColor` are assigned by join order the moment a
/// peer connects, and the resulting list is broadcast to every device via
/// `.lobbyUpdate(players:)` so all screens render an identical roster.
/// Joiners never compute their own identity or color locally — they adopt
/// whatever the host assigns.
///
/// Deliberately decoupled from `MCSession`: every mutation is a plain
/// method driven by `MCPeerID` values, so join order, color assignment, and
/// peer↔player validation are unit-testable without a live session
/// (`MCPeerID(displayName:)` can be constructed directly in tests).
@Observable
@MainActor
final class PlayerRoster {

    private nonisolated static let logger = Logger(
        subsystem: "com.proximiplay",
        category: "roster"
    )

    // MARK: - Observable State

    /// The synced player list. Host occupies index 0 once `setHost` has run.
    private(set) var players: [Player] = []

    /// Maps each connected peer (never the local device itself) to the
    /// `Player.id` the host assigned them at join time. Consulted by
    /// `GameSessionManager` to validate that inbound messages carry the
    /// `playerId` the delivering peer actually owns.
    private(set) var peerToPlayerId: [MCPeerID: UUID] = [:]

    // MARK: - Host-side mutation

    /// Places (or refreshes) the host's own `Player` at index 0.
    func setHost(_ host: Player) {
        if players.isEmpty {
            players.insert(host, at: 0)
        } else {
            players[0] = host
        }
    }

    /// Registers a newly-connected peer, assigning a stable identity and a
    /// color drawn from `PlayerColor.allCases` by join order. No-op (returns
    /// the existing player) if the peer is already registered, guarding
    /// against duplicate `.connected` delegate callbacks.
    @discardableResult
    func hostPlayerJoined(peer: MCPeerID, displayName: String) -> Player {
        if let existingId = peerToPlayerId[peer],
           let existing = players.first(where: { $0.id == existingId }) {
            return existing
        }

        let colorIndex = players.count % PlayerColor.allCases.count
        let player = Player(
            displayName: displayName,
            color: PlayerColor.allCases[colorIndex],
            isHost: false
        )
        peerToPlayerId[peer] = player.id
        players.append(player)
        Self.logger.info("Roster: \(displayName) joined at index \(self.players.count - 1)")
        return player
    }

    /// Removes a disconnected peer's `Player` entry from the roster.
    ///
    /// Returns the departed player's id so callers can propagate the
    /// departure to game state that is keyed by `Player.id` rather than by
    /// peer (e.g. `GameEngine.playerDisconnected(_:)`).
    @discardableResult
    func hostPlayerLeft(peer: MCPeerID) -> UUID? {
        guard let playerId = peerToPlayerId.removeValue(forKey: peer) else { return nil }
        players.removeAll { $0.id == playerId }
        Self.logger.info("Roster: peer \(peer.displayName) left")
        return playerId
    }

    // MARK: - Joiner-side mutation

    /// Replaces the entire local roster with a host-broadcast
    /// `.lobbyUpdate`. Joiners never compute this list themselves — they
    /// only ever mirror what the host sends.
    func applyLobbyUpdate(_ players: [Player]) {
        self.players = players
    }

    /// Records the mapping from the host's own `MCPeerID` to its
    /// `Player.id`, for a joiner device — the one `peerToPlayerId` entry a
    /// joiner ever needs, since this app's Multipeer session is
    /// star-shaped (a joiner only ever directly connects to the host).
    ///
    /// Without this, `peerToPlayerId` stays empty on every joiner (only
    /// `hostPlayerJoined` populates it, and that only ever runs on the
    /// host), which silently breaks two things: `peerID(for:)` can never
    /// resolve the host's peer, so a joiner can never address outbound
    /// messages (`AppState.submitPlayerInput`, Speed Draw's stroke
    /// sending) to the host at all; and `isValid(playerId:from:)` fails
    /// closed for every relayed message, since it has nothing to check
    /// against. Call this every time a `.lobbyUpdate` arrives from the
    /// host (idempotent — just overwrites the same entry).
    func setHostPeerMapping(peer: MCPeerID, hostPlayerId: UUID) {
        peerToPlayerId[peer] = hostPlayerId
    }

    // MARK: - Validation

    /// Returns `true` when `playerId` matches the `Player` the host mapped
    /// to `peer` at join time — i.e. `peer` is not asserting another
    /// player's identity.
    ///
    /// Peers with no roster mapping (e.g. the local device evaluating a
    /// message it should never have received) fail closed and return
    /// `false`.
    func isValid(playerId: UUID, from peer: MCPeerID) -> Bool {
        peerToPlayerId[peer] == playerId
    }

    /// The `MCPeerID` mapped to `playerId`, if any — used to bridge synced
    /// roster players to peer-keyed state such as
    /// `ConnectionMonitor.peerHealth`.
    func peerID(for playerId: UUID) -> MCPeerID? {
        peerToPlayerId.first { $0.value == playerId }?.key
    }

    // MARK: - Reset

    /// Clears all roster state. Call when a session tears down.
    func reset() {
        players = []
        peerToPlayerId = [:]
    }
}
