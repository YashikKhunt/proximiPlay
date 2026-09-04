//
//  RoundFlow.swift
//  proximiPlay
//

import Foundation
import SwiftUI

/// How long a round reveal stays on screen before the next round takes over.
/// Shared by every mode so the between-round beat feels identical across the
/// whole app.
private let revealDuration: Duration = .seconds(2.5)

// MARK: - RoundFlow

/// The round-sequencing machinery every game mode view sits on top of:
/// queueing round starts, pairing each round with its own result, presenting
/// that reveal for a fixed beat, and owning the auto-advance `Task` that
/// tears the reveal down again.
///
/// Parameterized over `Payload` — the mode-specific, *client-only* state for
/// one round (trivia's question plus the local player's selection, reflex's
/// flash delay and tap phase, …). `RoundFlow` never interprets a payload; it
/// only carries it from the round that started to the reveal that closes it,
/// so each mode view keeps its own rendering and input handling and shares
/// none of it.
///
/// ## Why round starts are a FIFO queue, not a single slot
///
/// `GameEngine`'s host loop can advance `currentRound` to the *next* round in
/// the very same synchronous turn that set `lastRoundResult` (`finishRound()`
/// calls `runRound()` directly, with no delay in between), so by the time
/// SwiftUI re-renders, the engine may already be a whole round ahead. A naïve
/// "watch `currentRound`, watch `lastRoundResult`" pair of observations can
/// therefore drop a round entirely, or pair round N's reveal with round N+1's
/// payload.
///
/// This type defends against that by treating round starts and round results
/// as two independent, strictly-ordered streams: every observed start is
/// **appended** to ``pending`` (never overwriting an entry that hasn't been
/// revealed yet), and every observed result **pops the oldest** entry via
/// `removeFirst()`. Round N's reveal is consequently always paired with round
/// N's payload no matter how far ahead the engine has run, and `current`
/// (the newest entry) is always what the player should be playing right now.
/// That pairing guarantee is load-bearing — do not collapse ``pending`` into
/// a single optional.
@Observable
@MainActor
final class RoundFlow<Payload> {

    /// One round this device has seen start.
    struct Round: Identifiable {
        /// 1-based position in the stream of round starts this device
        /// observed, used for "Round X of Y" headers and view identity.
        let index: Int

        /// Mode-specific state for this round — see ``RoundFlow``.
        var payload: Payload

        var id: Int { index }
    }

    /// A completed round paired with the result that closed it.
    struct Reveal: Identifiable {
        let round: Round
        let result: RoundResult

        /// Cumulative scores as of the *previous* reveal — the baseline a
        /// reveal diffs `result.scores` against to show per-round point
        /// gains. Empty before round 1 (everyone starts at 0). Modes with no
        /// per-round delta to show (Vote Battle) simply ignore it.
        let baselineScores: [UUID: Int]

        /// `true` when the game ended with this round, so the reveal stays
        /// put instead of auto-advancing.
        let isFinal: Bool

        var id: Int { round.index }
    }

    /// Rounds seen start, oldest-first, still awaiting their reveal. In
    /// practice at most one or two entries deep.
    private(set) var pending: [Round] = []

    /// The reveal on screen right now, `nil` while a round is in progress.
    private(set) var reveal: Reveal?

    /// Cumulative scores as of the most recently shown reveal.
    private(set) var baselineScores: [UUID: Int] = [:]

    /// The in-flight "dismiss this reveal" task. Owned here — and only here
    /// — so it is cancelled exactly once, on ``cancelAutoAdvance()``.
    private var autoAdvanceTask: Task<Void, Never>?

    /// The round the player is playing right now: the newest start that
    /// hasn't been revealed. `nil` before the first round begins.
    var current: Round? { pending.last }

    /// The index ``begin(_:)`` would assign to a round starting now.
    var nextRoundIndex: Int { (pending.last?.index ?? 0) + 1 }

    // MARK: - Round Starts

    /// Queues a newly started round carrying `payload`, returning the `Round`
    /// it became (for any per-mode side effect that needs its index).
    @discardableResult
    func begin(_ payload: Payload) -> Round {
        let round = Round(index: nextRoundIndex, payload: payload)
        pending.append(round)
        return round
    }

    /// Mutates the payload of the round in progress (``current``) — the
    /// hook for local input that isn't engine state yet, e.g. "I picked
    /// option B". No-op when no round is in progress.
    func updateCurrent(_ transform: (inout Payload) -> Void) {
        guard !pending.isEmpty else { return }
        transform(&pending[pending.count - 1].payload)
    }

    /// The payload of a specific queued round, or `nil` if that round has
    /// already been revealed and popped.
    func payload(forRound index: Int) -> Payload? {
        pending.first { $0.index == index }?.payload
    }

    /// Mutates the payload of a specific queued round. No-op once that round
    /// has been revealed and popped — which is exactly what a late timer
    /// firing for an already-finished round should do.
    func update(round index: Int, _ transform: (inout Payload) -> Void) {
        guard let position = pending.firstIndex(where: { $0.index == index }) else { return }
        transform(&pending[position].payload)
    }

    // MARK: - Reveals

    /// Pops the oldest pending round, pairs it with `result`, and shows it as
    /// the current ``reveal`` — auto-dismissing after ``revealDuration``
    /// unless `isFinal`, in which case the reveal stays put for the player to
    /// continue from.
    ///
    /// Returns the reveal it presented (carrying the pre-`result` score
    /// baseline, for modes that react to their own score changing), or `nil`
    /// if no round was pending — i.e. this result belongs to a round this
    /// device never saw start, so there is nothing to reveal.
    @discardableResult
    func presentReveal(result: RoundResult, isFinal: Bool) -> Reveal? {
        guard !pending.isEmpty else { return nil }
        let completedRound = pending.removeFirst()

        autoAdvanceTask?.cancel()
        let presented = Reveal(
            round: completedRound,
            result: result,
            baselineScores: baselineScores,
            isFinal: isFinal
        )
        reveal = presented
        baselineScores = Dictionary(uniqueKeysWithValues: result.scores.map { ($0.playerId, $0.score) })

        guard !isFinal else { return presented }
        autoAdvanceTask = Task { [weak self] in
            try? await Task.sleep(for: revealDuration)
            guard !Task.isCancelled else { return }
            self?.reveal = nil
        }
        return presented
    }

    /// Cancels the pending auto-advance. Applied automatically on disappear
    /// by ``SwiftUICore/View/roundFlow(_:engine:roundTrigger:beginRound:onRoundStart:onReveal:)``,
    /// so no mode view has to remember to do it.
    func cancelAutoAdvance() {
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
    }
}

// MARK: - View Wiring

/// Drives a ``RoundFlow`` from `GameEngine`'s observable state: queueing a
/// round whenever `roundTrigger` reports a new one, popping a reveal whenever
/// a new `lastRoundResult` lands, and cancelling the reveal's auto-advance
/// task on disappear.
///
/// Deliberately role-agnostic, like the mode views it serves: it reads
/// `GameEngine` only, so host and joiner devices sequence rounds identically.
private struct RoundFlowModifier<Payload, Trigger: Equatable>: ViewModifier {
    let flow: RoundFlow<Payload>
    let engine: GameEngine
    let trigger: Trigger
    let beginRound: (Trigger, Int) -> Payload?
    let onRoundStart: (RoundFlow<Payload>.Round) -> Void
    let onReveal: (RoundFlow<Payload>.Reveal) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger, initial: true) { _, newValue in
                guard let payload = beginRound(newValue, flow.nextRoundIndex) else { return }
                onRoundStart(flow.begin(payload))
            }
            .onChange(of: engine.lastRoundResult?.roundNumber, initial: true) { _, newRoundNumber in
                guard newRoundNumber != nil, let result = engine.lastRoundResult else { return }
                guard let presented = flow.presentReveal(
                    result: result,
                    isFinal: engine.finalScores != nil
                ) else { return }
                onReveal(presented)
            }
            .onDisappear {
                flow.cancelAutoAdvance()
            }
    }
}

extension View {
    /// Wires `flow` to `engine` for the lifetime of this view — see
    /// ``RoundFlowModifier``.
    ///
    /// - Parameters:
    ///   - flow: The mode view's `@State`-owned coordinator.
    ///   - engine: The game engine every device renders from.
    ///   - roundTrigger: Whatever identifies a *new* round for this mode:
    ///     trivia's question payload, vote's prompt, draw's word/drawer, or —
    ///     for reflex, whose `RoundData` carries no payload at all — the
    ///     `nil` → non-`nil` edge of `currentRound` as a `Bool`.
    ///   - beginRound: Maps a changed trigger (and the index the round would
    ///     get) to the round's payload, or `nil` when the change isn't a
    ///     round start (e.g. a round *ending*).
    ///   - onRoundStart: Per-mode side effect once the round is queued, e.g.
    ///     stamping a round-start time or clearing the shared canvas.
    ///   - onReveal: Per-mode side effect once a reveal is presented, e.g. a
    ///     success haptic when the local player's score went up.
    func roundFlow<Payload, Trigger: Equatable>(
        _ flow: RoundFlow<Payload>,
        engine: GameEngine,
        roundTrigger: Trigger,
        beginRound: @escaping (Trigger, Int) -> Payload?,
        onRoundStart: @escaping (RoundFlow<Payload>.Round) -> Void = { _ in },
        onReveal: @escaping (RoundFlow<Payload>.Reveal) -> Void = { _ in }
    ) -> some View {
        modifier(
            RoundFlowModifier(
                flow: flow,
                engine: engine,
                trigger: roundTrigger,
                beginRound: beginRound,
                onRoundStart: onRoundStart,
                onReveal: onReveal
            )
        )
    }
}
