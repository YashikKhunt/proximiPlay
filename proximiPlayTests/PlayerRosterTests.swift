//
//  PlayerRosterTests.swift
//  proximiPlayTests
//

import Testing
import Foundation
import MultipeerConnectivity
@testable import proximiPlay

// MARK: - PlayerRoster: ordering + color assignment

@MainActor
struct PlayerRosterTests {

    @Test func hostOccupiesIndexZero() {
        let roster = PlayerRoster()
        let host = Player(displayName: "Host", color: .blue, isHost: true)

        roster.setHost(host)

        #expect(roster.players.count == 1)
        #expect(roster.players[0].id == host.id)
        #expect(roster.players[0].isHost)
    }

    @Test func joinOrderAssignsSequentialColors() {
        let roster = PlayerRoster()
        let host = Player(displayName: "Host", color: .blue, isHost: true)
        roster.setHost(host)

        let peerA = MCPeerID(displayName: "Alice")
        let peerB = MCPeerID(displayName: "Bob")
        let peerC = MCPeerID(displayName: "Charlie")

        let playerA = roster.hostPlayerJoined(peer: peerA, displayName: "Alice")
        let playerB = roster.hostPlayerJoined(peer: peerB, displayName: "Bob")
        let playerC = roster.hostPlayerJoined(peer: peerC, displayName: "Charlie")

        // Host stays at index 0; joiners are appended in the order they connected.
        #expect(roster.players.map(\.id) == [host.id, playerA.id, playerB.id, playerC.id])

        // Colors are assigned by position in `PlayerColor.allCases`.
        #expect(playerA.color == PlayerColor.allCases[1])
        #expect(playerB.color == PlayerColor.allCases[2])
        #expect(playerC.color == PlayerColor.allCases[3])
        #expect(!playerA.isHost)
    }

    @Test func duplicateConnectCallbackIsANoOp() {
        let roster = PlayerRoster()
        let peer = MCPeerID(displayName: "Alice")

        let first = roster.hostPlayerJoined(peer: peer, displayName: "Alice")
        let second = roster.hostPlayerJoined(peer: peer, displayName: "Alice")

        #expect(first.id == second.id)
        #expect(roster.players.count == 1)
    }

    @Test func leavingRemovesThePlayerAndItsPeerMapping() {
        let roster = PlayerRoster()
        let host = Player(displayName: "Host", color: .blue, isHost: true)
        roster.setHost(host)

        let peer = MCPeerID(displayName: "Alice")
        let player = roster.hostPlayerJoined(peer: peer, displayName: "Alice")
        #expect(roster.players.count == 2)

        roster.hostPlayerLeft(peer: peer)

        #expect(roster.players.map(\.id) == [host.id])
        #expect(roster.peerID(for: player.id) == nil)
    }

    @Test func joinerReplacesLocalRosterOnLobbyUpdate() {
        let roster = PlayerRoster()
        let synced = [
            Player(displayName: "Host", color: .blue, isHost: true),
            Player(displayName: "Alice", color: .red)
        ]

        roster.applyLobbyUpdate(synced)

        #expect(roster.players.map(\.id) == synced.map(\.id))
    }
}

// MARK: - PlayerRoster: peer↔player identity validation

@MainActor
struct PlayerRosterValidationTests {

    @Test func playerIdMatchingItsOwningPeerIsValid() {
        let roster = PlayerRoster()
        let peer = MCPeerID(displayName: "Alice")
        let player = roster.hostPlayerJoined(peer: peer, displayName: "Alice")

        #expect(roster.isValid(playerId: player.id, from: peer))
    }

    @Test func spoofedPlayerIdFromTheWrongPeerIsRejected() {
        let roster = PlayerRoster()
        let peerA = MCPeerID(displayName: "Alice")
        let peerB = MCPeerID(displayName: "Bob")
        let playerA = roster.hostPlayerJoined(peer: peerA, displayName: "Alice")
        _ = roster.hostPlayerJoined(peer: peerB, displayName: "Bob")

        // Bob's peer claims Alice's playerId — must not validate.
        #expect(!roster.isValid(playerId: playerA.id, from: peerB))
    }

    @Test func unknownPeerFailsClosed() {
        let roster = PlayerRoster()
        let stranger = MCPeerID(displayName: "Stranger")

        #expect(!roster.isValid(playerId: UUID(), from: stranger))
    }
}

// MARK: - GameSessionManager: message authenticity gate

@MainActor
struct GameSessionManagerValidationTests {

    @Test func spoofedPlayerInputIsRejected() {
        let sut = GameSessionManager()
        let peerA = MCPeerID(displayName: "Alice")
        let peerB = MCPeerID(displayName: "Bob")
        let playerA = sut.roster.hostPlayerJoined(peer: peerA, displayName: "Alice")
        _ = sut.roster.hostPlayerJoined(peer: peerB, displayName: "Bob")

        let spoofed = GameMessage.playerInput(playerId: playerA.id, input: .reflexTap(timestamp: Date()))
        #expect(!sut.isMessageAuthentic(spoofed, from: peerB))

        let legitimate = GameMessage.playerInput(playerId: playerA.id, input: .reflexTap(timestamp: Date()))
        #expect(sut.isMessageAuthentic(legitimate, from: peerA))
    }

    @Test func spoofedDisconnectIsRejected() {
        let sut = GameSessionManager()
        let peerA = MCPeerID(displayName: "Alice")
        let peerB = MCPeerID(displayName: "Bob")
        let playerA = sut.roster.hostPlayerJoined(peer: peerA, displayName: "Alice")
        _ = sut.roster.hostPlayerJoined(peer: peerB, displayName: "Bob")

        #expect(!sut.isMessageAuthentic(.disconnect(playerId: playerA.id), from: peerB))
        #expect(sut.isMessageAuthentic(.disconnect(playerId: playerA.id), from: peerA))
    }

    @Test func messageTypesWithoutAnAssertedPlayerIdAlwaysPass() {
        let sut = GameSessionManager()
        let stranger = MCPeerID(displayName: "Stranger")

        #expect(sut.isMessageAuthentic(.heartbeat(timestamp: Date()), from: stranger))
        #expect(sut.isMessageAuthentic(.lobbyUpdate(players: []), from: stranger))
    }
}

// MARK: - GameSessionManager: inbound payload size cap

struct PayloadCapTests {

    @Test func payloadAtTheCapIsAccepted() {
        let data = Data(repeating: 0, count: GameSessionManager.maxPayloadBytes)
        #expect(!GameSessionManager.isOversizedPayload(data))
    }

    @Test func payloadOneByteOverTheCapIsDropped() {
        let data = Data(repeating: 0, count: GameSessionManager.maxPayloadBytes + 1)
        #expect(GameSessionManager.isOversizedPayload(data))
    }

    @Test func wellUnderTheCapIsAccepted() {
        let data = Data(repeating: 0, count: 1024)
        #expect(!GameSessionManager.isOversizedPayload(data))
    }
}
