//
//  WireProtocolIdentityTests.swift
//  proximiPlayTests
//

import Testing
import Foundation
import MultipeerConnectivity
@testable import proximiPlay

// MARK: - Helpers

/// A throwaway `UserDefaults` suite, so nickname persistence tests never
/// touch (or depend on) `.standard`.
private func makeDefaults(_ label: String = #function) -> UserDefaults {
    let name = "proximiplay.tests.\(label).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// The most recent `.roundResult` a `MockMessageSender` captured.
private func lastRoundResult(_ sender: MockMessageSender) -> RoundResult? {
    sender.sentMessages.reversed().compactMap { message -> RoundResult? in
        guard case .roundResult(let result) = message else { return nil }
        return result
    }.first
}

// MARK: - Host removal (Guideline 1.2)

/// Removing a player is host-authoritative and, because Multipeer cannot
/// force-disconnect a peer, only partly enforced by the message itself.
/// These pin all three enforcement steps and the origin gate.
@MainActor
struct HostRemovePlayerTests {

    /// Builds a host with one connected joiner already in the roster.
    private func makeHostWithJoiner() -> (GameSessionManager, Player, MCPeerID) {
        let sut = GameSessionManager()
        sut.isHost = true
        let host = Player(displayName: "Ari", color: .blue, isHost: true)
        sut.myPlayer = host
        sut.roster.setHost(host)

        let peer = MCPeerID(displayName: "Bo")
        let joiner = sut.roster.hostPlayerJoined(peer: peer, displayName: "Bo")
        return (sut, joiner, peer)
    }

    @Test func removingAPlayerDropsThemFromTheRoster() {
        let (sut, joiner, _) = makeHostWithJoiner()
        #expect(sut.roster.players.count == 2)

        #expect(sut.removePlayer(joiner) == true)

        #expect(sut.roster.players.count == 1)
        #expect(!sut.roster.players.contains { $0.id == joiner.id })
    }

    /// The removal must survive a client that ignores `.removedByHost` and
    /// stays connected: with the peer→player mapping gone, anything they
    /// send fails validation.
    @Test func aRemovedPlayersInputNoLongerValidates() {
        let (sut, joiner, peer) = makeHostWithJoiner()
        #expect(sut.roster.isValid(playerId: joiner.id, from: peer) == true)

        sut.removePlayer(joiner)

        #expect(
            sut.roster.isValid(playerId: joiner.id, from: peer) == false,
            "A removed player must not be able to keep submitting input"
        )
    }

    /// Without this the host keeps advertising and the removed device
    /// re-invites itself back within seconds.
    @Test func aRemovedPeerIsBlockedForTheRestOfTheSession() {
        let (sut, joiner, peer) = makeHostWithJoiner()
        #expect(sut.isBlocked(peer) == false)

        sut.removePlayer(joiner)

        #expect(sut.isBlocked(peer) == true)
    }

    @Test func endingTheSessionClearsTheBlockList() {
        let (sut, joiner, peer) = makeHostWithJoiner()
        sut.removePlayer(joiner)
        #expect(sut.isBlocked(peer) == true)

        sut.stopSession()

        #expect(
            sut.isBlocked(peer) == false,
            "A removal is scoped to one session — never a permanent ban"
        )
    }

    @Test func theHostCannotRemoveItself() {
        let (sut, _, _) = makeHostWithJoiner()
        let host = sut.myPlayer

        #expect(sut.removePlayer(host) == false)
        #expect(sut.roster.players.contains { $0.id == host.id })
    }

    @Test func aJoinerCannotRemoveAnyone() {
        let (sut, joiner, _) = makeHostWithJoiner()
        sut.isHost = false

        #expect(sut.removePlayer(joiner) == false)
        #expect(sut.roster.players.count == 2)
    }

    @Test func removingSomeoneNotInTheRosterIsANoOp() {
        let (sut, _, _) = makeHostWithJoiner()
        let stranger = Player(displayName: "Nobody", color: .teal)

        #expect(sut.removePlayer(stranger) == false)
        #expect(sut.roster.players.count == 2)
    }

    // MARK: Origin discipline on the receiving side

    @Test func removedByHostFromTheJoinedHostIsHonoured() {
        let sut = GameSessionManager()
        sut.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        sut.hostPeerID = hostPeer

        #expect(sut.removedByHostToken == 0)
        sut.receive(.removedByHost, from: hostPeer)
        #expect(sut.removedByHostToken == 1)
    }

    /// The attack this gate exists for: one joiner evicting another.
    @Test func removedByHostFromAFellowJoinerIsIgnored() {
        let sut = GameSessionManager()
        sut.isHost = false
        sut.hostPeerID = MCPeerID(displayName: "Host")

        sut.receive(.removedByHost, from: MCPeerID(displayName: "Impostor"))

        #expect(sut.removedByHostToken == 0)
    }

    @Test func removedByHostIsIgnoredOnTheHostItself() {
        let sut = GameSessionManager()
        sut.isHost = true
        let somePeer = MCPeerID(displayName: "Joiner")
        sut.hostPeerID = somePeer

        sut.receive(.removedByHost, from: somePeer)

        #expect(sut.removedByHostToken == 0, "A host can never be made to remove itself")
    }

    @Test func removedByHostSurvivesAnEncodeDecodeRoundTrip() throws {
        let decoded = try GameMessage.decoded(from: GameMessage.removedByHost.encoded())
        guard case .removedByHost = decoded else {
            Issue.record("Expected .removedByHost, got \(decoded)")
            return
        }
    }
}

// MARK: - (a) .lobbyReturn origin discipline

/// `.lobbyReturn` is host-authoritative: it yanks every joiner out of the
/// finished game and back to the lobby, so a joiner forging one could kick
/// the whole party out of a game in progress.
///
/// These drive `GameSessionManager.receive(_:from:)` — the real production
/// routing path, minus a live `MCSession`.
@MainActor
struct LobbyReturnOriginTests {

    @Test func lobbyReturnFromTheJoinedHostIsHonoured() {
        let sut = GameSessionManager()
        sut.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        sut.hostPeerID = hostPeer

        #expect(sut.lobbyReturnToken == 0)
        sut.receive(.lobbyReturn, from: hostPeer)
        #expect(sut.lobbyReturnToken == 1)

        // A second return after a second game must re-fire, which is the
        // whole reason this is a token and not a Bool.
        sut.receive(.lobbyReturn, from: hostPeer)
        #expect(sut.lobbyReturnToken == 2)
    }

    @Test func lobbyReturnFromAFellowJoinerIsIgnored() {
        let sut = GameSessionManager()
        sut.isHost = false
        sut.hostPeerID = MCPeerID(displayName: "Host")

        sut.receive(.lobbyReturn, from: MCPeerID(displayName: "Impostor"))

        #expect(sut.lobbyReturnToken == 0)
    }

    @Test func lobbyReturnIsIgnoredOnTheHostItself() {
        let sut = GameSessionManager()
        sut.isHost = true
        let somePeer = MCPeerID(displayName: "Joiner")
        // Even with hostPeerID set (it never is while hosting), isFromHost
        // fails closed on the host.
        sut.hostPeerID = somePeer

        sut.receive(.lobbyReturn, from: somePeer)

        #expect(sut.lobbyReturnToken == 0)
    }

    @Test func lobbyReturnIsIgnoredWhenNoHostPeerIsKnown() {
        let sut = GameSessionManager()
        sut.isHost = false
        sut.hostPeerID = nil

        sut.receive(.lobbyReturn, from: MCPeerID(displayName: "Anyone"))

        #expect(sut.lobbyReturnToken == 0)
    }

    @Test func lobbyReturnSurvivesAnEncodeDecodeRoundTrip() throws {
        let data = try GameMessage.lobbyReturn.encoded()
        let decoded = try GameMessage.decoded(from: data)

        guard case .lobbyReturn = decoded else {
            Issue.record("Expected .lobbyReturn, got \(decoded)")
            return
        }
    }

    @Test func returningToTheLobbyDropsTheGameButKeepsTheSession() {
        // The teardown both roles run — the host from `ResultsView`'s
        // button, joiners from `ContentView`'s token observer.
        let appState = AppState()
        let players = (0..<2).map {
            Player(displayName: "P\($0)", color: PlayerColor.allCases[$0])
        }
        appState.gameEngine.startGame(
            mode: .quickTrivia,
            roster: players,
            config: GameConfig(roundCount: 5, timePerRound: 20)
        )
        appState.currentGameState = .playing(.quickTrivia)
        appState.gameSessionManager.isHost = true
        appState.gameSessionManager.roster.setHost(players[0])
        appState.gameSessionManager.roster.applyLobbyUpdate(players)

        appState.returnToLobbyAfterHostReturn()

        #expect(!appState.gameEngine.isRunning)
        #expect(appState.gameEngine.mode == nil)
        #expect(appState.currentGameState == .idle)
        // Crucially, the session itself is untouched: nobody has to
        // rediscover or re-invite anyone for the next game.
        #expect(appState.gameSessionManager.isHost)
        #expect(appState.gameSessionManager.roster.players.count == 2)
    }

    @Test func stopSessionClearsTheLobbyReturnToken() {
        let sut = GameSessionManager()
        sut.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        sut.hostPeerID = hostPeer
        sut.receive(.lobbyReturn, from: hostPeer)
        #expect(sut.lobbyReturnToken == 1)

        sut.stopSession()

        #expect(sut.lobbyReturnToken == 0)
    }
}

// MARK: - (b) Vote tallies on the wire

@MainActor
struct VoteTallyWireTests {

    @Test func voteCountsRoundTripThroughEncodeAndDecode() throws {
        let a = UUID()
        let b = UUID()
        let result = RoundResult(
            roundNumber: 3,
            scores: [
                PlayerScore(playerId: a, displayName: "Ari", score: 0),
                PlayerScore(playerId: b, displayName: "Bo", score: 0)
            ],
            highlightPlayerId: b,
            voteCounts: [b: 2, a: 1]
        )

        let decoded = try GameMessage.decoded(from: GameMessage.roundResult(result: result).encoded())

        guard case .roundResult(let received) = decoded else {
            Issue.record("Expected .roundResult, got \(decoded)")
            return
        }
        #expect(received.voteCount(for: b) == 2)
        #expect(received.voteCount(for: a) == 1)
        #expect(received.totalVotes == 3)
        #expect(received.highlightPlayerId == b)
    }

    @Test func absentVoteCountsDecodeAsNoTallyRatherThanFailing() throws {
        // Non-vote modes send no tally at all; the message must still
        // decode, and every count must read back as zero.
        let result = RoundResult(
            roundNumber: 1,
            scores: [PlayerScore(playerId: UUID(), displayName: "Ari", score: 200)],
            highlightPlayerId: nil
        )
        let decoded = try GameMessage.decoded(from: GameMessage.roundResult(result: result).encoded())

        guard case .roundResult(let received) = decoded else {
            Issue.record("Expected .roundResult, got \(decoded)")
            return
        }
        #expect(received.voteCounts == nil)
        #expect(received.voteCount(for: UUID()) == 0)
        #expect(received.totalVotes == 0)
    }

    @Test func hostBroadcastsTheRealTallyItComputed() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = (0..<3).map {
            Player(displayName: "P\($0)", color: PlayerColor.allCases[$0])
        }

        engine.startGame(
            mode: .voteBattle,
            roster: players,
            config: GameConfig(roundCount: 1, timePerRound: 30)
        )

        // Two votes for players[1], one for players[2] — the round ends
        // early once everyone has voted.
        engine.submitInput(playerId: players[0].id, input: .vote(targetPlayerId: players[1].id))
        engine.submitInput(playerId: players[1].id, input: .vote(targetPlayerId: players[2].id))
        engine.submitInput(playerId: players[2].id, input: .vote(targetPlayerId: players[1].id))

        guard let result = lastRoundResult(sender) else {
            Issue.record("Host never broadcast a .roundResult")
            return
        }
        #expect(result.voteCount(for: players[1].id) == 2)
        #expect(result.voteCount(for: players[2].id) == 1)
        #expect(result.voteCount(for: players[0].id) == 0)
        #expect(result.totalVotes == 3)
        // The highlight is derived from the same tally that shipped, so the
        // crown can never contradict the numbers next to it.
        #expect(result.highlightPlayerId == players[1].id)
    }

    @Test func aRoundNobodyVotedInCarriesNoTally() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = (0..<2).map {
            Player(displayName: "P\($0)", color: PlayerColor.allCases[$0])
        }

        engine.startGame(
            mode: .voteBattle,
            roster: players,
            config: GameConfig(roundCount: 1, timePerRound: 30)
        )
        // Force the round to end with no votes recorded by dropping to a
        // single player.
        engine.playerDisconnected(players[1].id)

        guard let result = lastRoundResult(sender) else {
            Issue.record("Host never broadcast a .roundResult")
            return
        }
        #expect(result.voteCounts == nil)
        #expect(result.highlightPlayerId == nil)
    }

    @Test func theTallyReachesAJoinersRevealState() {
        // End-to-end on the joiner side: a `.roundResult` from the joined
        // host lands in `lastRoundResult`, which is exactly what
        // `VoteGameView` snapshots into `VoteRevealView`.
        let appState = AppState()
        appState.gameSessionManager.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        appState.gameSessionManager.hostPeerID = hostPeer

        let favorite = UUID()
        let result = RoundResult(
            roundNumber: 2,
            scores: [PlayerScore(playerId: favorite, displayName: "Bo", score: 0)],
            highlightPlayerId: favorite,
            voteCounts: [favorite: 3]
        )
        appState.gameSessionManager.onMessageReceived?(.roundResult(result: result), hostPeer)

        #expect(appState.gameEngine.lastRoundResult?.voteCount(for: favorite) == 3)
        #expect(appState.gameEngine.lastRoundResult?.totalVotes == 3)
    }
}

// MARK: - (c) Follower state completeness

@MainActor
struct FollowerStateCompletenessTests {

    @Test func gameStartGivesAFollowerTheModeAndRoundCount() {
        let engine = GameEngine(sender: MockMessageSender())

        #expect(engine.mode == nil)
        #expect(engine.totalRounds == 0)

        engine.applyFollowerMessage(
            .gameStart(mode: .speedDraw, config: GameConfig(roundCount: 6, timePerRound: 60))
        )

        #expect(engine.mode == .speedDraw)
        #expect(engine.totalRounds == 6)
    }

    @Test func followerRoundNumberTracksRoundStartAndRoundResult() {
        let engine = GameEngine(sender: MockMessageSender())
        engine.applyFollowerMessage(
            .gameStart(mode: .quickTrivia, config: GameConfig(roundCount: 5, timePerRound: 20))
        )

        let data = RoundData.trivia(question: "2+2?", options: ["3", "4", "5", "6"], correctIndex: 1)
        engine.applyFollowerMessage(.roundStart(data: data, round: 3))
        #expect(engine.roundNumber == 3)
        #expect(engine.isRunning)
        // The mode/round count set at game start survive later messages.
        #expect(engine.mode == .quickTrivia)
        #expect(engine.totalRounds == 5)

        engine.applyFollowerMessage(
            .roundResult(result: RoundResult(roundNumber: 3, scores: []))
        )
        #expect(engine.roundNumber == 3)
        #expect(engine.mode == .quickTrivia)
        #expect(engine.totalRounds == 5)
    }

    @Test func gameStartClearsThePreviousGamesFinalScores() {
        // The host's "Play Again" rebroadcasts `.gameStart`; without this
        // clear, a joiner would open round 1 of the new game still holding
        // the old game's `finalScores` (which mode views read as "this was
        // the final round").
        let engine = GameEngine(sender: MockMessageSender())
        engine.applyFollowerMessage(.gameEnd(scores: [
            PlayerScore(playerId: UUID(), displayName: "Ari", score: 400)
        ]))
        #expect(engine.finalScores != nil)

        engine.applyFollowerMessage(
            .gameStart(mode: .voteBattle, config: GameConfig(roundCount: 5, timePerRound: 30))
        )

        #expect(engine.finalScores == nil)
        #expect(engine.mode == .voteBattle)
        #expect(engine.totalRounds == 5)
    }

    @Test func gameStartSyncsThroughTheRealRoutingPathOnAJoiner() {
        let appState = AppState()
        appState.gameSessionManager.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        appState.gameSessionManager.hostPeerID = hostPeer

        appState.gameSessionManager.onMessageReceived?(
            .gameStart(mode: .speedDraw, config: GameConfig(roundCount: 4, timePerRound: 60)),
            hostPeer
        )

        #expect(appState.gameEngine.mode == .speedDraw)
        #expect(appState.gameEngine.totalRounds == 4)
    }

    @Test func forgedGameStartFromAFellowJoinerNeverReachesTheEngine() {
        let appState = AppState()
        appState.gameSessionManager.isHost = false
        appState.gameSessionManager.hostPeerID = MCPeerID(displayName: "Host")

        appState.gameSessionManager.onMessageReceived?(
            .gameStart(mode: .reflexTap, config: GameConfig(roundCount: 99, timePerRound: 1)),
            MCPeerID(displayName: "Impostor")
        )

        #expect(appState.gameEngine.mode == nil)
        #expect(appState.gameEngine.totalRounds == 0)
    }

    @Test func gameStartIsNeverAppliedOnTheHost() {
        // The host is the origin of `.gameStart`; one arriving at the host
        // is necessarily forged, and applying it would blow away the
        // authoritative engine mid-game.
        let appState = AppState()
        appState.gameSessionManager.isHost = true
        let players = (0..<2).map {
            Player(displayName: "P\($0)", color: PlayerColor.allCases[$0])
        }
        appState.gameEngine.startGame(
            mode: .quickTrivia,
            roster: players,
            config: GameConfig(roundCount: 5, timePerRound: 20)
        )

        appState.gameSessionManager.onMessageReceived?(
            .gameStart(mode: .reflexTap, config: GameConfig(roundCount: 99, timePerRound: 1)),
            MCPeerID(displayName: "Forger")
        )

        #expect(appState.gameEngine.mode == .quickTrivia)
        #expect(appState.gameEngine.totalRounds == 5)
        #expect(appState.gameEngine.isRunning)
    }
}

// MARK: - (d) Host-assigned identity

@MainActor
struct HostAssignedIdentityTests {

    @Test func twoPeersWithTheSameNameGetDistinctIdentities() {
        let roster = PlayerRoster()
        let peerA = MCPeerID(displayName: "iPhone")
        let peerB = MCPeerID(displayName: "iPhone")

        let a = roster.hostPlayerJoined(peer: peerA, displayName: "Sam")
        let b = roster.hostPlayerJoined(peer: peerB, displayName: "Sam")

        #expect(a.id != b.id)
        #expect(roster.players.count == 2)
        #expect(roster.player(for: peerA)?.id == a.id)
        #expect(roster.player(for: peerB)?.id == b.id)
        // Each peer only validates against its *own* assigned id.
        #expect(roster.isValid(playerId: a.id, from: peerA))
        #expect(!roster.isValid(playerId: b.id, from: peerA))
    }

    @Test func aJoinerAdoptsTheIdentityTheHostAssignsNotTheNameMatch() {
        // The regression this replaces: with two "Sam"s in the roster, the
        // old name-matching path made both devices adopt the *first* Sam,
        // and the second one's input was then rejected by the host.
        let sut = GameSessionManager()
        sut.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        sut.hostPeerID = hostPeer
        sut.myPlayer = Player(displayName: "Sam", color: .blue)

        let host = Player(displayName: "Ari", color: .blue, isHost: true)
        let firstSam = Player(displayName: "Sam", color: .green)
        let secondSam = Player(displayName: "Sam", color: .purple)

        // Roster arrives first; it must NOT be used to guess an identity.
        sut.receive(.lobbyUpdate(players: [host, firstSam, secondSam]), from: hostPeer)
        #expect(sut.myPlayer.id != firstSam.id)

        sut.receive(.identityAssignment(player: secondSam), from: hostPeer)

        #expect(sut.myPlayer.id == secondSam.id)
        #expect(sut.myPlayer.color == .purple)
    }

    @Test func identityAssignmentFromANonHostPeerIsIgnored() {
        let sut = GameSessionManager()
        sut.isHost = false
        sut.hostPeerID = MCPeerID(displayName: "Host")
        let original = sut.myPlayer

        let stolen = Player(displayName: "Victim", color: .red, isHost: true)
        sut.receive(.identityAssignment(player: stolen), from: MCPeerID(displayName: "Impostor"))

        #expect(sut.myPlayer.id == original.id)
    }

    @Test func identityAssignmentIsIgnoredOnTheHost() {
        let sut = GameSessionManager()
        sut.isHost = true
        let joiner = MCPeerID(displayName: "Joiner")
        sut.hostPeerID = joiner
        let original = sut.myPlayer

        sut.receive(
            .identityAssignment(player: Player(displayName: "NotYou", color: .red)),
            from: joiner
        )

        #expect(sut.myPlayer.id == original.id)
    }

    @Test func aLobbyUpdateRefreshesTheLocalEntryByIdOnly() {
        let sut = GameSessionManager()
        sut.isHost = false
        let hostPeer = MCPeerID(displayName: "Host")
        sut.hostPeerID = hostPeer

        let host = Player(displayName: "Ari", color: .blue, isHost: true)
        let assigned = Player(displayName: "Sam", color: .green)
        sut.receive(.identityAssignment(player: assigned), from: hostPeer)

        // Same id, host changed the colour — adopt it. A same-name entry
        // with a different id must never be adopted.
        var recoloured = assigned
        recoloured.color = .orange
        let namesake = Player(displayName: "Sam", color: .pink)
        sut.receive(.lobbyUpdate(players: [host, recoloured, namesake]), from: hostPeer)

        #expect(sut.myPlayer.id == assigned.id)
        #expect(sut.myPlayer.color == .orange)
    }

    @Test func identityAssignmentSurvivesAnEncodeDecodeRoundTrip() throws {
        let player = Player(displayName: "Sam", color: .green)
        let decoded = try GameMessage.decoded(
            from: GameMessage.identityAssignment(player: player).encoded()
        )

        guard case .identityAssignment(let received) = decoded else {
            Issue.record("Expected .identityAssignment, got \(decoded)")
            return
        }
        #expect(received.id == player.id)
        #expect(received.displayName == "Sam")
        #expect(received.color == .green)
    }
}

// MARK: - Nickname

@MainActor
struct PlayerNicknameTests {

    @Test func nicknamePersistsAcrossReads() {
        let defaults = makeDefaults()

        let stored = PlayerNickname.save("  Sam  ", defaults: defaults)

        #expect(stored == "Sam")
        #expect(PlayerNickname.load(defaults: defaults) == "Sam")
    }

    @Test func firstLaunchSeedsTheDeviceName() {
        let defaults = makeDefaults()

        let seeded = PlayerNickname.load(defaults: defaults)

        #expect(seeded == PlayerNickname.sanitize(PlayerNickname.deviceName))
        // Seeding writes through, so the value is stable on the next read.
        #expect(defaults.string(forKey: PlayerNickname.defaultsKey) == seeded)
    }

    @Test func clearingTheNicknameFallsBackToTheDeviceName() {
        let defaults = makeDefaults()
        PlayerNickname.save("Sam", defaults: defaults)

        let stored = PlayerNickname.save("   ", defaults: defaults)

        #expect(stored == PlayerNickname.sanitize(PlayerNickname.deviceName))
        #expect(!stored.isEmpty)
    }

    @Test func overlongNicknamesAreTruncated() {
        let stored = PlayerNickname.sanitize(String(repeating: "a", count: 500))

        #expect(stored.count == PlayerNickname.maxLength)
    }

    @Test func updateNicknameAppliesToTheLocalPlayer() {
        let sut = GameSessionManager()

        let stored = sut.updateNickname("  Party Sam  ")

        #expect(stored == "Party Sam")
        #expect(sut.myPlayer.displayName == "Party Sam")
    }

    @Test func hostUsesItsNicknameForItsOwnRosterEntry() {
        let sut = GameSessionManager()
        sut.updateNickname("Ari")

        sut.startHosting()

        #expect(sut.roster.players.first?.displayName == "Ari")
        #expect(sut.roster.players.first?.isHost == true)
        sut.stopSession()
    }

    @Test func aJoinersRequestedNicknameIsSanitizedIntoTheRoster() {
        let roster = PlayerRoster()
        let peer = MCPeerID(displayName: "Someones iPhone")

        // A hostile/garbled request must not push an empty or unbounded
        // name into everybody's player list.
        let empty = roster.hostPlayerJoined(peer: peer, displayName: "   ")
        #expect(empty.displayName == "Someones iPhone")

        let other = MCPeerID(displayName: "Another iPhone")
        let long = roster.hostPlayerJoined(
            peer: other,
            displayName: String(repeating: "z", count: 1_000)
        )
        #expect(long.displayName.count == PlayerNickname.maxLength)
    }

    @Test func invitationContextCarriesTheNicknameAndRejectsJunk() {
        #expect(GameSessionManager.nickname(fromInvitationContext: Data("Sam".utf8)) == "Sam")
        #expect(GameSessionManager.nickname(fromInvitationContext: nil) == nil)
        #expect(GameSessionManager.nickname(fromInvitationContext: Data()) == nil)

        let oversize = Data(repeating: 0x41, count: GameSessionManager.maxInvitationContextBytes + 1)
        #expect(GameSessionManager.nickname(fromInvitationContext: oversize) == nil)
    }
}
