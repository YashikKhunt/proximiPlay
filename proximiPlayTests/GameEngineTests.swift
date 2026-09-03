//
//  GameEngineTests.swift
//  proximiPlayTests
//

import Testing
import Foundation
@testable import proximiPlay

// MARK: - Test Double

/// Captures every `GameMessage` broadcast by a `GameEngine` under test, so
/// assertions can inspect the exact host-authoritative sequence without any
/// live Multipeer Connectivity session.
///
/// `broadcast(_:)` is only ever called from `@MainActor` in practice (the
/// engine is `@MainActor`), but the protocol requires it `nonisolated`, so
/// storage is guarded by a lock to satisfy strict concurrency checking.
final class MockMessageSender: GameMessageSending, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GameMessage] = []

    var sentMessages: [GameMessage] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    nonisolated func broadcast(_ message: GameMessage) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }
}

// MARK: - Helpers

@MainActor
private func makePlayers(_ count: Int) -> [Player] {
    (0..<count).map { index in
        Player(displayName: "Player \(index)", color: PlayerColor.allCases[index % PlayerColor.allCases.count])
    }
}

private func roundStartData(_ messages: [GameMessage], round: Int) -> RoundData? {
    var seen = 0
    for message in messages {
        if case .roundStart(let data, _) = message {
            seen += 1
            if seen == round { return data }
        }
    }
    return nil
}

private func roundResult(_ messages: [GameMessage], round: Int) -> RoundResult? {
    for message in messages {
        if case .roundResult(let result) = message, result.roundNumber == round {
            return result
        }
    }
    return nil
}

private func finalScores(_ messages: [GameMessage]) -> [PlayerScore]? {
    for message in messages {
        if case .gameEnd(let scores) = message { return scores }
    }
    return nil
}

// MARK: - Full Trivia Game Simulation

@MainActor
struct GameEngineTriviaSimulationTests {

    @Test func fullTriviaGameBroadcastsEveryRoundAndFinalScores() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = makePlayers(3)
        let config = GameConfig(roundCount: 3, timePerRound: 20)

        engine.startGame(mode: .quickTrivia, roster: players, config: config)

        for round in 1...3 {
            guard case .trivia(_, _, let correctIndex)? = roundStartData(sender.sentMessages, round: round) else {
                Issue.record("Missing .roundStart for round \(round)")
                continue
            }

            // Player 0 answers correctly and instantly (max speed bonus).
            engine.submitInput(
                playerId: players[0].id,
                input: .triviaAnswer(index: correctIndex, timestamp: Date())
            )
            // Player 1 answers incorrectly.
            let wrongIndex = (correctIndex + 1) % 4
            engine.submitInput(
                playerId: players[1].id,
                input: .triviaAnswer(index: wrongIndex, timestamp: Date())
            )
            // Player 2 answers correctly but submits last.
            engine.submitInput(
                playerId: players[2].id,
                input: .triviaAnswer(index: correctIndex, timestamp: Date())
            )
        }

        // Every round submitted all 3 inputs, so each round should have
        // finished early (not via timeout) and broadcast a result.
        for round in 1...3 {
            #expect(roundResult(sender.sentMessages, round: round) != nil)
        }

        guard let scores = finalScores(sender.sentMessages) else {
            Issue.record("Game never broadcast .gameEnd")
            return
        }

        #expect(scores.count == 3)
        let byId = Dictionary(uniqueKeysWithValues: scores.map { ($0.playerId, $0.score) })
        #expect((byId[players[0].id] ?? 0) > 0) // correct every round
        #expect((byId[players[1].id] ?? 0) == 0) // wrong every round
        #expect((byId[players[2].id] ?? 0) > 0) // correct every round

        #expect(!engine.isRunning)
        #expect(engine.finalScores != nil)

        let roundStartCount = sender.sentMessages.filter { if case .roundStart = $0 { return true } else { return false } }.count
        let roundResultCount = sender.sentMessages.filter { if case .roundResult = $0 { return true } else { return false } }.count
        let gameEndCount = sender.sentMessages.filter { if case .gameEnd = $0 { return true } else { return false } }.count
        #expect(roundStartCount == 3)
        #expect(roundResultCount == 3)
        #expect(gameEndCount == 1)
    }

    @Test func startGameIgnoredWithFewerThanTwoPlayers() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)

        engine.startGame(mode: .quickTrivia, roster: makePlayers(1))

        #expect(!engine.isRunning)
        #expect(sender.sentMessages.isEmpty)
    }

    @Test func startGameIgnoredWhenAlreadyRunning() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = makePlayers(2)
        let config = GameConfig(roundCount: 5, timePerRound: 20)

        engine.startGame(mode: .quickTrivia, roster: players, config: config)
        let countAfterFirstStart = sender.sentMessages.count

        engine.startGame(mode: .quickTrivia, roster: players, config: config)

        #expect(sender.sentMessages.count == countAfterFirstStart)
    }
}

// MARK: - Timeout Path

@MainActor
struct GameEngineTimeoutTests {

    @Test func timeoutAdvancesTheRoundWithoutAllInputs() async throws {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = makePlayers(3)
        // A very short timeout so the test doesn't wait real-world seconds.
        let config = GameConfig(roundCount: 2, timePerRound: 0.05)

        engine.startGame(mode: .quickTrivia, roster: players, config: config)

        // Nobody answers round 1 — wait past the timeout.
        try await Task.sleep(for: .seconds(0.3))

        #expect(roundResult(sender.sentMessages, round: 1) != nil)
        // The game should have advanced into (or finished) round 2 without
        // any player ever submitting an input.
        #expect(sender.sentMessages.filter { if case .roundStart = $0 { return true } else { return false } }.count >= 2
                || finalScores(sender.sentMessages) != nil)
    }

    @Test func timeoutIsCancelledWhenRoundFinishesEarly() async throws {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = makePlayers(2)
        let config = GameConfig(roundCount: 1, timePerRound: 5)

        engine.startGame(mode: .quickTrivia, roster: players, config: config)

        guard case .trivia(_, _, let correctIndex)? = roundStartData(sender.sentMessages, round: 1) else {
            Issue.record("Missing round 1 data")
            return
        }

        engine.submitInput(playerId: players[0].id, input: .triviaAnswer(index: correctIndex, timestamp: Date()))
        engine.submitInput(playerId: players[1].id, input: .triviaAnswer(index: correctIndex, timestamp: Date()))

        // Both players answered immediately, so the round (and the game,
        // since roundCount == 1) should have already finished — well
        // before the 5-second timeout could ever fire.
        #expect(!engine.isRunning)
        #expect(finalScores(sender.sentMessages) != nil)
    }
}

// MARK: - Disconnect Handling

@MainActor
struct GameEngineDisconnectTests {

    @Test func disconnectMidRoundIsTreatedAsNoInputAndContinues() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = makePlayers(3)
        let config = GameConfig(roundCount: 2, timePerRound: 20)

        engine.startGame(mode: .quickTrivia, roster: players, config: config)

        guard case .trivia(_, _, let correctIndex)? = roundStartData(sender.sentMessages, round: 1) else {
            Issue.record("Missing round 1 data")
            return
        }

        engine.submitInput(playerId: players[0].id, input: .triviaAnswer(index: correctIndex, timestamp: Date()))
        engine.playerDisconnected(players[1].id)
        // Only player[2] remains unanswered; submitting their input should
        // now finish the round early since the disconnected player is no
        // longer expected to respond.
        engine.submitInput(playerId: players[2].id, input: .triviaAnswer(index: correctIndex, timestamp: Date()))

        #expect(roundResult(sender.sentMessages, round: 1) != nil)
        #expect(engine.isRunning) // 2 players remain — game continues into round 2
    }

    @Test func fewerThanTwoRemainingPlayersEndsTheGameGracefully() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = makePlayers(2)
        let config = GameConfig(roundCount: 5, timePerRound: 20)

        engine.startGame(mode: .quickTrivia, roster: players, config: config)
        #expect(engine.isRunning)

        engine.playerDisconnected(players[1].id)

        #expect(!engine.isRunning)
        #expect(finalScores(sender.sentMessages) != nil)
        #expect(finalScores(sender.sentMessages)?.count == 1)
    }

    @Test func disconnectedPlayerInputIsIgnored() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = makePlayers(3)
        let config = GameConfig(roundCount: 1, timePerRound: 20)

        engine.startGame(mode: .quickTrivia, roster: players, config: config)
        engine.playerDisconnected(players[2].id)

        // Submitting an input for a player who already left must not crash
        // or resurrect them into the round.
        engine.submitInput(playerId: players[2].id, input: .triviaAnswer(index: 0, timestamp: Date()))

        #expect(engine.isRunning)
    }

    @Test func disconnectedPlayerIsRemovedFromTheDrawerQueueAndNeverDrawsAgain() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = makePlayers(3)
        // Force exactly 3 rounds regardless of the roster size, so the test
        // isn't coupled to `GameConfig.defaultConfig`'s player-count-aware
        // round count.
        let config = GameConfig(roundCount: 3, timePerRound: 20)

        engine.startGame(mode: .speedDraw, roster: players, config: config)

        // Round 1's drawer is assigned by join order — players[0].
        #expect(engine.currentDrawerId == players[0].id)

        // Disconnect players[1], who is queued to draw next but never gets
        // the chance — a dead round assigned to them would otherwise run
        // the full round timeout with no possible correct guess.
        engine.playerDisconnected(players[1].id)

        guard case .draw(let word1, _)? = engine.currentRound else {
            Issue.record("Missing round 1 draw payload")
            return
        }
        // The only remaining non-drawer (players[2]) guesses correctly,
        // finishing round 1 early and advancing to round 2.
        engine.submitInput(playerId: players[2].id, input: .guess(text: word1))

        #expect(engine.isRunning)
        #expect(engine.currentDrawerId != players[1].id)
        let round2Drawer = engine.currentDrawerId

        guard case .draw(let word2, _)? = engine.currentRound else {
            Issue.record("Missing round 2 draw payload")
            return
        }
        // Whoever isn't drawing round 2 guesses correctly, advancing to
        // round 3 — the drawer queue refill (`players.map(\.id)`) must
        // still never reintroduce the disconnected player.
        let round2Guesser = players.first { $0.id != round2Drawer }!
        engine.submitInput(playerId: round2Guesser.id, input: .guess(text: word2))

        #expect(engine.currentDrawerId != players[1].id)
    }
}

// MARK: - Round Tagging (stale input rejection)

@MainActor
struct GameEngineRoundTaggingTests {

    @Test func lateInputStampedWithAPreviousRoundIsIgnored() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = makePlayers(2)
        let config = GameConfig(roundCount: 2, timePerRound: 20)

        engine.startGame(mode: .quickTrivia, roster: players, config: config)
        #expect(engine.roundNumber == 1)

        guard case .trivia(_, _, let correctIndexRound1)? = roundStartData(sender.sentMessages, round: 1) else {
            Issue.record("Missing round 1 data")
            return
        }

        // Both players answer round 1, advancing the engine into round 2.
        engine.submitInput(playerId: players[0].id, input: .triviaAnswer(index: correctIndexRound1, timestamp: Date()), round: 1)
        engine.submitInput(playerId: players[1].id, input: .triviaAnswer(index: correctIndexRound1, timestamp: Date()), round: 1)
        #expect(engine.roundNumber == 2)

        guard case .trivia(_, _, let correctIndexRound2)? = roundStartData(sender.sentMessages, round: 2) else {
            Issue.record("Missing round 2 data")
            return
        }

        // A message that arrives late, still stamped with round 1, must be
        // ignored rather than consuming player[0]'s first-wins slot for the
        // round that's actually in progress now.
        let wrongIndex = (correctIndexRound2 + 1) % 4
        engine.submitInput(playerId: players[0].id, input: .triviaAnswer(index: wrongIndex, timestamp: Date()), round: 1)

        // Player[0]'s real, correctly-stamped round 2 answer must still be
        // accepted — proving the stale submission above didn't silently
        // consume their first-wins slot for this round.
        engine.submitInput(playerId: players[0].id, input: .triviaAnswer(index: correctIndexRound2, timestamp: Date()), round: 2)
        engine.submitInput(playerId: players[1].id, input: .triviaAnswer(index: correctIndexRound2, timestamp: Date()), round: 2)

        guard let result = roundResult(sender.sentMessages, round: 2) else {
            Issue.record("Round 2 never finished")
            return
        }
        let player0Score = result.scores.first { $0.playerId == players[0].id }?.score ?? 0
        // Player[0] answered round 1 correctly (200) and round 2 correctly
        // (also scores > 0); had the stale round-1-tagged wrong answer been
        // misapplied to round 2, their round 2 contribution would be 0.
        #expect(player0Score > 200)
    }

    @Test func hostLocalSubmissionWithNoRoundIsAlwaysTreatedAsCurrent() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let players = makePlayers(2)
        let config = GameConfig(roundCount: 1, timePerRound: 20)

        engine.startGame(mode: .quickTrivia, roster: players, config: config)
        guard case .trivia(_, _, let correctIndex)? = roundStartData(sender.sentMessages, round: 1) else {
            Issue.record("Missing round 1 data")
            return
        }

        // No `round:` argument — the trusted host-local path used by
        // `AppState.submitPlayerInput` for the host's own player.
        engine.submitInput(playerId: players[0].id, input: .triviaAnswer(index: correctIndex, timestamp: Date()))
        engine.submitInput(playerId: players[1].id, input: .triviaAnswer(index: correctIndex, timestamp: Date()))

        #expect(finalScores(sender.sentMessages) != nil)
    }
}

// MARK: - Round Data Validation

@MainActor
struct GameEngineRoundDataValidationTests {

    @Test func wellFormedTriviaPayloadIsValid() {
        let data = RoundData.trivia(question: "2+2?", options: ["1", "2", "3", "4"], correctIndex: 3)
        #expect(GameEngine.isValidRoundData(data))
    }

    @Test func triviaPayloadWithWrongOptionCountIsInvalid() {
        let data = RoundData.trivia(question: "2+2?", options: ["1", "2", "3", "4", "5"], correctIndex: 0)
        #expect(!GameEngine.isValidRoundData(data))
    }

    @Test func triviaPayloadWithOutOfRangeCorrectIndexIsInvalid() {
        let data = RoundData.trivia(question: "2+2?", options: ["1", "2", "3", "4"], correctIndex: 9)
        #expect(!GameEngine.isValidRoundData(data))
        let negative = RoundData.trivia(question: "2+2?", options: ["1", "2", "3", "4"], correctIndex: -1)
        #expect(!GameEngine.isValidRoundData(negative))
    }

    @Test func triviaPayloadWithEmptyQuestionOrOptionIsInvalid() {
        let emptyQuestion = RoundData.trivia(question: "   ", options: ["1", "2", "3", "4"], correctIndex: 0)
        #expect(!GameEngine.isValidRoundData(emptyQuestion))
        let emptyOption = RoundData.trivia(question: "2+2?", options: ["1", "", "3", "4"], correctIndex: 0)
        #expect(!GameEngine.isValidRoundData(emptyOption))
    }

    @Test func votePayloadWithEmptyPromptIsInvalid() {
        #expect(!GameEngine.isValidRoundData(.vote(prompt: "")))
        #expect(GameEngine.isValidRoundData(.vote(prompt: "Most likely to...")))
    }

    @Test func drawPayloadWithEmptyWordIsInvalid() {
        #expect(!GameEngine.isValidRoundData(.draw(word: "  ", drawerId: UUID())))
        #expect(GameEngine.isValidRoundData(.draw(word: "banana", drawerId: UUID())))
    }

    @Test func reflexPayloadIsAlwaysValid() {
        #expect(GameEngine.isValidRoundData(.reflex))
    }

    @Test func followerRejectsAStructurallyInvalidRoundStartPayload() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)

        let forged = RoundData.trivia(
            question: "Forged",
            options: ["1", "2", "3", "4", "5"],
            correctIndex: 9
        )
        engine.applyFollowerMessage(.roundStart(data: forged, round: 1))

        #expect(engine.currentRound == nil)
        #expect(!engine.isRunning)
    }
}

// MARK: - Follower (Joiner) State

@MainActor
struct GameEngineFollowerTests {

    @Test func followerMirrorsRoundStartResultAndGameEnd() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        let playerId = UUID()

        let data = RoundData.trivia(question: "2+2?", options: ["3", "4", "5", "6"], correctIndex: 1)
        engine.applyFollowerMessage(.roundStart(data: data, round: 1))
        #expect(engine.isRunning)
        #expect(engine.roundNumber == 1)
        if case .trivia(let question, _, _)? = engine.currentRound {
            #expect(question == "2+2?")
        } else {
            Issue.record("currentRound not mirrored")
        }

        let result = RoundResult(roundNumber: 1, scores: [PlayerScore(playerId: playerId, displayName: "A", score: 100)], highlightPlayerId: playerId)
        engine.applyFollowerMessage(.roundResult(result: result))
        #expect(engine.lastRoundResult?.roundNumber == 1)
        #expect(engine.currentRound == nil)

        let scores = [PlayerScore(playerId: playerId, displayName: "A", score: 300)]
        engine.applyFollowerMessage(.gameEnd(scores: scores))
        #expect(!engine.isRunning)
        #expect(engine.finalScores?.first?.score == 300)
    }

    @Test func resetClearsAllState() {
        let sender = MockMessageSender()
        let engine = GameEngine(sender: sender)
        engine.startGame(mode: .quickTrivia, roster: makePlayers(2), config: GameConfig(roundCount: 1, timePerRound: 20))

        engine.reset()

        #expect(!engine.isRunning)
        #expect(engine.mode == nil)
        #expect(engine.currentRound == nil)
        #expect(engine.roundNumber == 0)
    }
}

// MARK: - Pure Scoring Functions

struct GameEngineScoringTests {

    // MARK: Trivia

    @Test func triviaWrongAnswerScoresZeroRegardlessOfTiming() {
        let start = Date()
        let score = GameEngine.triviaScore(
            isCorrect: false,
            answeredAt: start,
            roundStartedAt: start,
            timeLimit: 20
        )
        #expect(score == 0)
    }

    @Test func triviaInstantCorrectAnswerScoresMaxBonus() {
        let start = Date()
        let score = GameEngine.triviaScore(
            isCorrect: true,
            answeredAt: start,
            roundStartedAt: start,
            timeLimit: 20
        )
        #expect(score == 200) // 100 base + 100 max speed bonus
    }

    @Test func triviaAnswerAtTimeLimitScoresBaseOnly() {
        let start = Date()
        let score = GameEngine.triviaScore(
            isCorrect: true,
            answeredAt: start.addingTimeInterval(20),
            roundStartedAt: start,
            timeLimit: 20
        )
        #expect(score == 100)
    }

    @Test func triviaAnswerPastTimeLimitClampsToBaseScore() {
        let start = Date()
        let score = GameEngine.triviaScore(
            isCorrect: true,
            answeredAt: start.addingTimeInterval(45),
            roundStartedAt: start,
            timeLimit: 20
        )
        #expect(score == 100)
    }

    @Test func triviaTieTimestampsBothScoreIdentically() {
        let start = Date()
        let a = GameEngine.triviaScore(isCorrect: true, answeredAt: start, roundStartedAt: start, timeLimit: 20)
        let b = GameEngine.triviaScore(isCorrect: true, answeredAt: start, roundStartedAt: start, timeLimit: 20)
        #expect(a == b)
        #expect(a == 200)
    }

    @Test func triviaHalfwayAnswerScoresHalfBonus() {
        let start = Date()
        let score = GameEngine.triviaScore(
            isCorrect: true,
            answeredAt: start.addingTimeInterval(10),
            roundStartedAt: start,
            timeLimit: 20
        )
        #expect(score == 150)
    }

    // MARK: Draw

    @Test func drawFirstCorrectGuessWinsGuesserAndDrawerScore() {
        let start = Date()
        let drawerId = UUID()
        let guesserA = UUID()
        let guesserB = UUID()

        let scores = GameEngine.drawScores(
            guesses: [
                (guesserA, "banana", start.addingTimeInterval(1)),
                (guesserB, "apple", start.addingTimeInterval(2))
            ],
            word: "apple",
            drawerId: drawerId
        )

        #expect(scores[guesserB] == 150)
        #expect(scores[drawerId] == 100)
        #expect(scores[guesserA] == nil)
    }

    @Test func drawWrongGuessThenCorrectGuessOnlyRewardsTheCorrectOne() {
        let start = Date()
        let drawerId = UUID()
        let guesser = UUID()

        let scores = GameEngine.drawScores(
            guesses: [
                (guesser, "banan", start),
                (guesser, "banana", start.addingTimeInterval(3))
            ],
            word: "banana",
            drawerId: drawerId
        )

        #expect(scores[guesser] == 150)
        #expect(scores[drawerId] == 100)
    }

    @Test func drawNoCorrectGuessAwardsNothing() {
        let scores = GameEngine.drawScores(
            guesses: [(UUID(), "nope", Date())],
            word: "banana",
            drawerId: UUID()
        )
        #expect(scores.isEmpty)
    }

    @Test func drawGuessIsCaseInsensitiveAndTrimmed() {
        let drawerId = UUID()
        let guesser = UUID()
        let scores = GameEngine.drawScores(
            guesses: [(guesser, "  BaNaNa  ", Date())],
            word: "banana",
            drawerId: drawerId
        )
        #expect(scores[guesser] == 150)
    }

    // MARK: Reflex

    @Test func reflexFastestValidTapWins() {
        let flash = Date()
        let a = UUID()
        let b = UUID()

        let scores = GameEngine.reflexScores(
            taps: [
                (a, flash.addingTimeInterval(0.5)),
                (b, flash.addingTimeInterval(0.2))
            ],
            flashAt: flash
        )

        #expect(scores[b] == 100)
        #expect(scores[a] == nil)
    }

    @Test func reflexEarlyTapIsPenalizedAndDisqualified() {
        let flash = Date()
        let earlyTapper = UUID()
        let validTapper = UUID()

        let scores = GameEngine.reflexScores(
            taps: [
                (earlyTapper, flash.addingTimeInterval(-0.1)),
                (validTapper, flash.addingTimeInterval(0.3))
            ],
            flashAt: flash
        )

        #expect(scores[earlyTapper] == -50)
        #expect(scores[validTapper] == 100)
    }

    @Test func reflexAllEarlyTapsAwardOnlyPenalties() {
        let flash = Date()
        let a = UUID()
        let b = UUID()

        let scores = GameEngine.reflexScores(
            taps: [
                (a, flash.addingTimeInterval(-1)),
                (b, flash.addingTimeInterval(-0.5))
            ],
            flashAt: flash
        )

        #expect(scores[a] == -50)
        #expect(scores[b] == -50)
        #expect(scores.values.contains(100) == false)
    }

    // MARK: Vote

    @Test func voteTallyCountsVotesPerTarget() {
        let voterA = UUID()
        let voterB = UUID()
        let voterC = UUID()
        let target1 = UUID()
        let target2 = UUID()

        let tally = GameEngine.voteTally(votes: [
            voterA: target1,
            voterB: target1,
            voterC: target2
        ])

        #expect(tally[target1] == 2)
        #expect(tally[target2] == 1)
    }

    @Test func voteTallyEmptyWhenNoVotesCast() {
        let tally = GameEngine.voteTally(votes: [:])
        #expect(tally.isEmpty)
    }
}
