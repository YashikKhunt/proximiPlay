//
//  RoundFlowTests.swift
//  proximiPlayTests
//
//  `RoundFlow` is the coordinator all four game modes sequence their rounds
//  through, and its doc comment calls the FIFO pairing "load-bearing" — yet
//  it shipped with no tests at all. That gap is exactly what let a Critical
//  bug reach the review: Reflex Tap's round trigger could not distinguish
//  round N from N+1, so every round after the first was silently never
//  queued and the mode stalled on its waiting view.
//
//  These pin the pairing guarantee itself.
//

import Testing
import Foundation
@testable import proximiPlay

@Suite("RoundFlow pairing")
@MainActor
struct RoundFlowTests {

    private func result(round: Int, scores: [PlayerScore] = []) -> RoundResult {
        RoundResult(roundNumber: round, scores: scores, highlightPlayerId: nil, voteCounts: nil)
    }

    // MARK: - The race the FIFO exists for

    /// `GameEngine.finishRound()` calls `runRound()` synchronously, so a round
    /// can start before the previous round's reveal has been presented. The
    /// queue must hold both and pair each with its own result, in order.
    @Test func twoRoundsQueuedBeforeAnyRevealStillPairInOrder() {
        let flow = RoundFlow<String>()

        flow.begin("round-1")
        flow.begin("round-2")
        #expect(flow.pending.count == 2)

        let first = flow.presentReveal(result: result(round: 1), isFinal: false)
        #expect(first?.round.payload == "round-1", "The first reveal must pair with the FIRST queued round")
        #expect(first?.round.index == 1)

        let second = flow.presentReveal(result: result(round: 2), isFinal: false)
        #expect(second?.round.payload == "round-2", "The second reveal must pair with the SECOND queued round")
        #expect(second?.round.index == 2)
    }

    @Test func revealWithNothingQueuedIsIgnoredRatherThanMispaired() {
        let flow = RoundFlow<String>()
        #expect(flow.presentReveal(result: result(round: 1), isFinal: false) == nil)
    }

    @Test func roundIndicesIncrementMonotonically() {
        let flow = RoundFlow<String>()
        #expect(flow.begin("a").index == 1)
        #expect(flow.begin("b").index == 2)
        #expect(flow.begin("c").index == 3)
    }

    @Test func currentIsTheMostRecentlyQueuedRound() {
        let flow = RoundFlow<String>()
        flow.begin("a")
        flow.begin("b")
        #expect(flow.current?.payload == "b")
    }

    // MARK: - Payload mutation

    @Test func updateCurrentMutatesOnlyTheLiveRound() {
        let flow = RoundFlow<String>()
        flow.begin("a")
        flow.begin("b")
        flow.updateCurrent { $0 = "b-edited" }

        #expect(flow.current?.payload == "b-edited")
        // The older queued round is untouched, so its reveal still shows what
        // was actually played.
        #expect(flow.presentReveal(result: result(round: 1), isFinal: false)?.round.payload == "a")
    }

    @Test func payloadForRoundIsAddressableUntilItIsRevealed() {
        let flow = RoundFlow<String>()
        let round = flow.begin("a")

        #expect(flow.payload(forRound: round.index) == "a")
        flow.update(round: round.index, { $0 = "a-edited" })
        #expect(flow.payload(forRound: round.index) == "a-edited")

        _ = flow.presentReveal(result: result(round: 1), isFinal: false)
        #expect(flow.payload(forRound: round.index) == nil, "A revealed round is popped and no longer addressable")
    }

    // MARK: - Score baseline

    /// Trivia and Speed Draw show per-round point deltas, which need the
    /// cumulative scores as they stood *before* the round being revealed.
    @Test func revealCarriesTheScoreBaselineFromBeforeTheRound() {
        let flow = RoundFlow<String>()
        let alice = UUID()

        flow.begin("round-1")
        let firstReveal = flow.presentReveal(
            result: result(round: 1, scores: [PlayerScore(playerId: alice, displayName: "Ari", score: 100)]),
            isFinal: false
        )
        // Nothing had been scored before round 1.
        #expect(firstReveal?.baselineScores[alice] == nil)

        flow.begin("round-2")
        let secondReveal = flow.presentReveal(
            result: result(round: 2, scores: [PlayerScore(playerId: alice, displayName: "Ari", score: 250)]),
            isFinal: false
        )
        // Round 2's delta is measured against round 1's total, not zero.
        #expect(secondReveal?.baselineScores[alice] == 100)
    }

    /// The user-visible half of the joiner-results regression: a reveal
    /// presented as final must still be on screen after the auto-advance
    /// window a non-final reveal would have been dismissed in. When the
    /// final round was mistakenly presented as non-final, this is the beat
    /// where the joiner's results vanished and the waiting view took over
    /// for the rest of the game.
    @Test func finalRevealSurvivesTheAutoAdvanceWindow() async throws {
        let flow = RoundFlow<String>()
        flow.begin("last-round")

        #expect(flow.presentReveal(result: result(round: 1), isFinal: true) != nil)

        // Comfortably past the 2.5s a non-final reveal is dismissed after.
        try await Task.sleep(for: .seconds(3))

        #expect(flow.reveal != nil, "A final reveal must never auto-dismiss — there is no next round to advance to")
        #expect(flow.reveal?.isFinal == true)
    }

    /// The joiner's exact message ordering, in one assertion.
    ///
    /// `.roundResult` and `.gameEnd` reach a joiner as two separate
    /// messages, each dispatched in its own main-actor `Task`. At the moment
    /// the round-result observer runs — which is when the reveal is built —
    /// `.gameEnd` has not been applied yet, so `finalScores` is still `nil`.
    /// `result.isFinal` is therefore the *only* signal available in-band at
    /// render time, which is precisely why it must live on `RoundResult`.
    @Test func joinerKnowsARoundWasFinalBeforeGameEndArrives() {
        let engine = GameEngine(sender: MockMessageSender())
        let players = [
            Player(displayName: "Ari", color: .blue),
            Player(displayName: "Bo", color: .red)
        ]
        let scores = players.map { PlayerScore(playerId: $0.id, displayName: $0.displayName, score: 10) }

        engine.applyFollowerMessage(.gameStart(mode: .quickTrivia, config: GameConfig(roundCount: 1, timePerRound: 20)))
        engine.applyFollowerMessage(.roundStart(data: .trivia(question: "Q", options: ["A", "B", "C", "D"], correctIndex: 0), round: 1))

        // Turn one: the final round's result lands, alone.
        let final = RoundResult(roundNumber: 1, scores: scores, isFinal: true)
        engine.applyFollowerMessage(.roundResult(result: final))

        #expect(
            engine.finalScores == nil,
            "Precondition: .gameEnd has not arrived yet — deriving isFinal from finalScores here is what broke joiners"
        )
        #expect(
            engine.lastRoundResult?.isFinal == true,
            "The flag must already be readable from the result itself"
        )

        // Turn two: .gameEnd finally lands, a whole main-actor turn later.
        engine.applyFollowerMessage(.gameEnd(scores: scores))
        #expect(engine.finalScores != nil)
    }

    @Test func finalFlagIsCarriedThrough() {
        let flow = RoundFlow<String>()
        flow.begin("last")
        #expect(flow.presentReveal(result: result(round: 1), isFinal: true)?.isFinal == true)
    }
}
