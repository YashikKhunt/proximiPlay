//
//  AppStateMessageRoutingTests.swift
//  proximiPlayTests
//

import Testing
import Foundation
import MultipeerConnectivity
@testable import proximiPlay

// MARK: - Helpers

@MainActor
private func makePlayers(_ count: Int) -> [Player] {
    (0..<count).map { index in
        Player(displayName: "Player \(index)", color: PlayerColor.allCases[index % PlayerColor.allCases.count])
    }
}

// MARK: - Host-Origin Discipline (AppState.onMessageReceived)

/// Exercises the *production* `onMessageReceived` closure directly —
/// `GameSessionManager.onMessageReceived` is a plain settable property, so
/// invoking it here runs exactly the same routing/validation logic real
/// inbound Multipeer traffic would, with no live session required.
@MainActor
struct AppStateFollowerOriginTests {

    @Test func forgedFollowerMessageIsRejectedOnHost() {
        let appState = AppState()
        appState.gameSessionManager.isHost = true

        // A forged `.gameEnd` "arriving" at the host — regardless of which
        // peer claims to send it, the host must never treat itself as a
        // follower of its own broadcasts.
        let forger = MCPeerID(displayName: "Forger")
        let forgedScores = [PlayerScore(playerId: UUID(), displayName: "Attacker", score: 9_999)]
        appState.gameSessionManager.onMessageReceived?(.gameEnd(scores: forgedScores), forger)

        #expect(appState.gameEngine.finalScores == nil)
    }

    @Test func roundStartIsAcceptedOnlyFromTheJoinedHostPeer() {
        let appState = AppState()
        appState.gameSessionManager.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        let impostor = MCPeerID(displayName: "Impostor")
        appState.gameSessionManager.hostPeerID = hostPeer

        let data = RoundData.trivia(question: "2+2?", options: ["3", "4", "5", "6"], correctIndex: 1)

        // A fellow joiner forging a `.roundStart` must not be mirrored.
        appState.gameSessionManager.onMessageReceived?(.roundStart(data: data, round: 1), impostor)
        #expect(appState.gameEngine.currentRound == nil)

        // The same message from the actual joined host peer is mirrored.
        appState.gameSessionManager.onMessageReceived?(.roundStart(data: data, round: 1), hostPeer)
        #expect(appState.gameEngine.currentRound != nil)
        #expect(appState.gameEngine.roundNumber == 1)
    }

    @Test func structurallyInvalidRoundStartFromTheHostIsStillRejected() {
        let appState = AppState()
        appState.gameSessionManager.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        appState.gameSessionManager.hostPeerID = hostPeer

        // Passes the origin check (genuinely from the host peer) but is
        // structurally malformed — five options with an out-of-range
        // `correctIndex`.
        let forged = RoundData.trivia(question: "Forged", options: ["1", "2", "3", "4", "5"], correctIndex: 9)
        appState.gameSessionManager.onMessageReceived?(.roundStart(data: forged, round: 1), hostPeer)

        #expect(appState.gameEngine.currentRound == nil)
        #expect(!appState.gameEngine.isRunning)
    }
}

// MARK: - Speed Draw Stroke Routing

@MainActor
struct AppStateStrokeRoutingTests {

    @Test func nonDrawerStrokeIsRejected() {
        let appState = AppState()
        let players = makePlayers(3)
        appState.gameSessionManager.isHost = true
        appState.gameSessionManager.myPlayer = players[0]
        appState.gameSessionManager.roster.setHost(players[0])

        appState.gameEngine.startGame(mode: .speedDraw, roster: players, config: GameConfig(roundCount: 1, timePerRound: 30))
        guard let actualDrawerId = appState.gameEngine.currentDrawerId else {
            Issue.record("No drawer assigned")
            return
        }
        let impostor = players.first { $0.id != actualDrawerId }!
        let impostorPeer = MCPeerID(displayName: "Impostor")

        appState.gameSessionManager.onMessageReceived?(
            .playerInput(playerId: impostor.id, input: .drawStroke(points: [CodablePoint(x: 1, y: 1)]), round: 0),
            impostorPeer
        )

        #expect(appState.strokeSync.segments.isEmpty)
    }

    @Test func actualDrawerStrokeIsAcceptedAndRelayed() {
        let appState = AppState()
        let players = makePlayers(3)
        appState.gameSessionManager.isHost = true
        appState.gameSessionManager.myPlayer = players[0]
        appState.gameSessionManager.roster.setHost(players[0])

        appState.gameEngine.startGame(mode: .speedDraw, roster: players, config: GameConfig(roundCount: 1, timePerRound: 30))
        guard let actualDrawerId = appState.gameEngine.currentDrawerId else {
            Issue.record("No drawer assigned")
            return
        }
        let drawerPeer = MCPeerID(displayName: "Drawer")

        appState.gameSessionManager.onMessageReceived?(
            .playerInput(playerId: actualDrawerId, input: .drawStroke(points: [CodablePoint(x: 1, y: 1)]), round: 0),
            drawerPeer
        )

        #expect(appState.strokeSync.segments.count == 1)
    }

    @Test func strokeRelayThrottleDropsFloodedBatches() {
        let appState = AppState()
        let players = makePlayers(3)
        appState.gameSessionManager.isHost = true
        appState.gameSessionManager.myPlayer = players[0]
        appState.gameSessionManager.roster.setHost(players[0])

        appState.gameEngine.startGame(mode: .speedDraw, roster: players, config: GameConfig(roundCount: 1, timePerRound: 30))
        guard let actualDrawerId = appState.gameEngine.currentDrawerId else {
            Issue.record("No drawer assigned")
            return
        }
        let drawerPeer = MCPeerID(displayName: "Drawer")

        // A modified client streaming far faster than any legitimate
        // ~20-batches/sec drawing session — sent back-to-back with no
        // delay, well under the throttle's minimum interval.
        for i in 0..<50 {
            appState.gameSessionManager.onMessageReceived?(
                .playerInput(playerId: actualDrawerId, input: .drawStroke(points: [CodablePoint(x: CGFloat(i), y: 0)]), round: 0),
                drawerPeer
            )
        }

        #expect(appState.strokeSync.segments.count < 50)
        #expect(!appState.strokeSync.segments.isEmpty)
    }

    @Test func relayedStrokeFromTheHostReachesAGuesserJoiner() {
        // Simulates the joiner side of the relay path finding 5 fixes:
        // once this joiner's engine knows the round's drawer (mirrored via
        // `.roundStart`), a `.drawStroke` whose immediate sender is the
        // joined host peer must reach `strokeSync`.
        let appState = AppState()
        appState.gameSessionManager.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        appState.gameSessionManager.hostPeerID = hostPeer

        let drawerId = UUID()
        appState.gameEngine.applyFollowerMessage(
            .roundStart(data: .draw(word: "banana", drawerId: drawerId), round: 1)
        )
        #expect(appState.gameEngine.currentDrawerId == drawerId)

        appState.gameSessionManager.onMessageReceived?(
            .playerInput(playerId: drawerId, input: .drawStroke(points: [CodablePoint(x: 2, y: 2)]), round: 0),
            hostPeer
        )

        #expect(appState.strokeSync.segments.count == 1)
    }
}

// MARK: - GameSessionManager: relay authenticity (finding 5)

@MainActor
struct GameSessionManagerRelayAuthenticityTests {

    @Test func isFromHostIsFalseOnTheHostRegardlessOfPeer() {
        let sut = GameSessionManager()
        sut.isHost = true
        let somePeer = MCPeerID(displayName: "Someone")
        sut.hostPeerID = somePeer

        #expect(!sut.isFromHost(somePeer))
    }

    @Test func isFromHostIsTrueOnlyForTheJoinedHostPeer() {
        let sut = GameSessionManager()
        sut.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        let otherPeer = MCPeerID(displayName: "Other")
        sut.hostPeerID = hostPeer

        #expect(sut.isFromHost(hostPeer))
        #expect(!sut.isFromHost(otherPeer))
    }

    @Test func relayedPlayerInputFromTheHostIsAuthenticEvenWithNoLocalPeerMapping() {
        let sut = GameSessionManager()
        sut.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        sut.hostPeerID = hostPeer

        // The asserted `playerId` is the original drawer, not the host —
        // this joiner has no `peerToPlayerId` entry for them at all, yet
        // the message must still be trusted because it was relayed by the
        // known host peer.
        let relayed = GameMessage.playerInput(
            playerId: UUID(),
            input: .drawStroke(points: [CodablePoint(x: 0, y: 0)]),
            round: 0
        )
        #expect(sut.isMessageAuthentic(relayed, from: hostPeer))
    }

    @Test func playerInputFromANonHostPeerStillRequiresARosterMatch() {
        let sut = GameSessionManager()
        sut.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        let strangerPeer = MCPeerID(displayName: "Stranger")
        sut.hostPeerID = hostPeer

        let spoofed = GameMessage.playerInput(playerId: UUID(), input: .guess(text: "banana"), round: 1)
        #expect(!sut.isMessageAuthentic(spoofed, from: strangerPeer))
    }
}
