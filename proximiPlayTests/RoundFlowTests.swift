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

    @Test func finalFlagIsCarriedThrough() {
        let flow = RoundFlow<String>()
        flow.begin("last")
        #expect(flow.presentReveal(result: result(round: 1), isFinal: true)?.isFinal == true)
    }
}
