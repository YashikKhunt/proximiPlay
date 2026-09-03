//
//  GameEngine.swift
//  proximiPlay
//

import Foundation
import os

// MARK: - GameMessageSending

/// Abstraction over broadcasting outbound `GameMessage`s to connected
/// peers, allowing `GameEngine`'s host-authoritative lifecycle to run
/// entirely in unit tests without a live Multipeer Connectivity session.
///
/// `broadcast(_:)` is `nonisolated` because it does purely nonisolated
/// networking work in the real implementation (`GameSessionManager`) — see
/// that type's doc comment for why.
protocol GameMessageSending: AnyObject, Sendable {
    nonisolated func broadcast(_ message: GameMessage)
}

extension GameSessionManager: GameMessageSending {}

// MARK: - GameEngine

/// The single source of truth for a running game.
///
/// On the **host** device, `startGame(mode:roster:)` drives the full
/// round lifecycle — `roundStart` → collect inputs → `roundResult` →
/// (next round | `gameEnd`) — broadcasting each transition through the
/// injected `GameMessageSending` abstraction. Round timeouts use
/// structured concurrency (`Task.sleep`) and are cancelled the moment a
/// round completes early (every expected player responded, or — for Speed
/// Draw — the first correct guess arrives).
///
/// On **joiner** devices, the host never drives the state machine; instead
/// `applyFollowerMessage(_:)` mirrors the host's broadcasts into the exact
/// same observable properties (`currentRound`, `lastRoundResult`,
/// `finalScores`), so every mode view reads one API regardless of role.
@Observable
@MainActor
final class GameEngine {

    private nonisolated static let logger = Logger(
        subsystem: "com.proximiplay",
        category: "game-engine"
    )

    // MARK: - Observable State (host + joiner both render from this)

    /// The mode currently in play, `nil` before the first round starts.
    private(set) var mode: GameMode?

    /// `true` from `startGame` (host) or the first `.roundStart` (joiner)
    /// until the game ends.
    private(set) var isRunning: Bool = false

    /// 1-indexed round number, matching `RoundResult.roundNumber`.
    private(set) var roundNumber: Int = 0

    /// The total number of rounds this game will run, from `GameConfig`.
    private(set) var totalRounds: Int = 0

    /// The payload for the round in progress, `nil` between rounds.
    private(set) var currentRound: RoundData?

    /// The most recently broadcast round summary.
    private(set) var lastRoundResult: RoundResult?

    /// Final standings, set once `.gameEnd` is broadcast (host) or
    /// received (joiner).
    private(set) var finalScores: [PlayerScore]?

    // MARK: - Host-only Bookkeeping

    private let sender: GameMessageSending
    private var config: GameConfig?
    private var players: [Player] = []
    private var scores: [UUID: Int] = [:]

    /// This round's inputs, keyed by player. Trivia answers and reflex taps
    /// are first-wins (a resubmission is ignored); votes and guesses are
    /// latest-wins. Draw strokes are never stored here — they are transient
    /// rendering data with no bearing on round completion or scoring.
    private var inputs: [UUID: PlayerInput] = [:]

    /// Host-clock receipt time for each stored input, used to order guesses
    /// and votes (neither `PlayerInput.guess` nor `.vote` carries its own
    /// timestamp — unlike `.triviaAnswer`/`.reflexTap`, whose timestamps are
    /// the client's own clock and used directly for scoring).
    private var inputReceivedAt: [UUID: Date] = [:]

    /// When the in-progress round's `.roundStart` was broadcast. Used as
    /// the elapsed-time reference for trivia's speed bonus and as the
    /// "flash" reference for reflex's early-tap penalty.
    private var roundStartedAt: Date = .distantPast

    /// The in-flight round-timeout task, cancelled the moment a round
    /// completes for any other reason.
    private var roundTask: Task<Void, Never>?

    // Mode-specific content, prepared once at `startGame`.
    private var triviaDeck: ShuffledDeck<TriviaQuestion>?
    private var voteDeck: ShuffledDeck<VotePrompt>?
    private var wordDeck: ShuffledDeck<String>?
    private var drawerQueue: [UUID] = []
    private var currentCorrectIndex: Int?
    private var currentDrawWord: String?

    /// The player id assigned as this round's Speed Draw drawer, derived
    /// from `currentRound` rather than stored separately — `currentRound`
    /// is already mirrored identically on host and joiner devices (host:
    /// set directly in `runRound()`; joiner: mirrored via
    /// `applyFollowerMessage`'s `.roundStart` case), so this reads
    /// correctly on every device without any host-only bookkeeping. `nil`
    /// outside Speed Draw or between rounds.
    ///
    /// Consulted by `AppState`'s message-receive path to reject
    /// `.drawStroke` input asserted by anyone other than the actual drawer.
    var currentDrawerId: UUID? {
        guard case .draw(_, let drawerId)? = currentRound else { return nil }
        return drawerId
    }

    // MARK: - Init

    init(sender: GameMessageSending) {
        self.sender = sender
    }

    // MARK: - Host: Lifecycle

    /// Starts a new host-authoritative game for `mode` across `roster`.
    ///
    /// No-op if a game is already running or fewer than two players are
    /// present. `overrideConfig` lets callers (namely tests) bypass the
    /// player-count-aware `GameConfig.defaultConfig(for:playerCount:)` — in
    /// particular to use a very short `timePerRound` when exercising the
    /// timeout path without a real multi-second wait.
    func startGame(mode: GameMode, roster: [Player], config overrideConfig: GameConfig? = nil) {
        guard !isRunning else {
            Self.logger.warning("startGame ignored — a game is already running")
            return
        }
        guard roster.count >= 2 else {
            Self.logger.warning("startGame ignored — fewer than 2 players")
            return
        }

        self.mode = mode
        players = roster
        scores = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, 0) })
        roundNumber = 0
        finalScores = nil
        lastRoundResult = nil
        currentRound = nil
        inputs = [:]
        inputReceivedAt = [:]
        isRunning = true

        let resolvedConfig = overrideConfig ?? GameConfig.defaultConfig(for: mode, playerCount: roster.count)
        config = resolvedConfig
        totalRounds = resolvedConfig.roundCount

        prepareContent(for: mode)
        runRound()
    }

    /// Records `input` from `playerId` for the round in progress, applying
    /// each mode's first-wins/latest-wins rule, and ends the round early
    /// once every expected player has responded (or, for Speed Draw, the
    /// moment a correct guess arrives).
    ///
    /// - Parameter round: The round the submitting device believed was in
    ///   progress when it sent this input. `nil` is reserved for trusted
    ///   host-local submissions — the host's own player acting on its own
    ///   `GameEngine` instance directly, with no network hop and therefore
    ///   no possibility of arriving after the round has moved on — and is
    ///   always treated as current. Every wire-relayed input (from
    ///   `AppState`'s `.playerInput` handling) must pass its stamped round
    ///   explicitly; a value that doesn't match `roundNumber` means the
    ///   input was submitted against a round the host has since finished
    ///   (e.g. it arrived just after that round's timeout), and is ignored
    ///   rather than being misapplied — and misscored — against whichever
    ///   round is running now.
    ///
    /// Ignored if no game is running, `playerId` is not part of the
    /// current roster (e.g. it already disconnected), or `round` is stale.
    func submitInput(playerId: UUID, input: PlayerInput, round: Int? = nil) {
        guard isRunning, let mode, players.contains(where: { $0.id == playerId }) else { return }
        if let round, round != roundNumber {
            Self.logger.warning(
                "Ignored input for stale round \(round) (current round is \(self.roundNumber))"
            )
            return
        }

        switch input {
        case .drawStroke:
            // Transient rendering data — never stored, never counted.
            return

        case .triviaAnswer, .reflexTap:
            guard inputs[playerId] == nil else { return }
            inputs[playerId] = input
            inputReceivedAt[playerId] = Date()

        case .vote, .guess:
            inputs[playerId] = input
            inputReceivedAt[playerId] = Date()
        }

        if case .speedDraw = mode, case .guess(let text) = input, isCorrectGuess(text) {
            roundTask?.cancel()
            roundTask = nil
            finishRound()
            return
        }

        checkAllInputsReceived(mode: mode)
    }

    /// Removes a disconnected player mid-round, treating their absence as
    /// "no input" and letting the round continue. If fewer than 2 players
    /// remain, finishes the current round (broadcasting its result) and
    /// then ends the game gracefully.
    func playerDisconnected(_ playerId: UUID) {
        guard isRunning else { return }

        players.removeAll { $0.id == playerId }
        inputs.removeValue(forKey: playerId)
        inputReceivedAt.removeValue(forKey: playerId)
        scores.removeValue(forKey: playerId)
        // A departed player must never be assigned as a future Speed Draw
        // drawer — left in place, `nextDrawerId()` would eventually
        // `removeFirst()` their id into a dead round nobody can guess
        // correctly, running the full round timeout for nothing.
        drawerQueue.removeAll { $0 == playerId }

        guard players.count >= 2 else {
            finishRound()
            return
        }

        if let mode {
            checkAllInputsReceived(mode: mode)
        }
    }

    // MARK: - Joiner: Follower State

    /// Mirrors a host-broadcast `.roundStart`/`.roundResult`/`.gameEnd`
    /// message into the same observable properties a host-side view would
    /// read, so mode views render identically regardless of role. Every
    /// other `GameMessage` case is ignored.
    ///
    /// Callers are expected to have already verified the message actually
    /// originates from the host (see `AppState`'s message-receive path) —
    /// this method's own responsibility is limited to validating that a
    /// `.roundStart` payload is structurally sane before mirroring it, so a
    /// forged or corrupted broadcast (e.g. a trivia round with the wrong
    /// option count or an out-of-range `correctIndex`) cannot reach mode
    /// views and crash or misrender.
    func applyFollowerMessage(_ message: GameMessage) {
        switch message {
        case .roundStart(let data, let round):
            guard Self.isValidRoundData(data) else {
                Self.logger.warning("Rejected structurally invalid .roundStart payload")
                return
            }
            currentRound = data
            roundNumber = round
            isRunning = true

        case .roundResult(let result):
            lastRoundResult = result
            currentRound = nil
            roundNumber = result.roundNumber

        case .gameEnd(let finalScores):
            self.finalScores = finalScores
            currentRound = nil
            isRunning = false

        default:
            break
        }
    }

    /// Clears all engine state. Call after a game ends and its results have
    /// been shown, or when recovering from a host-left disconnect.
    func reset() {
        roundTask?.cancel()
        roundTask = nil

        mode = nil
        isRunning = false
        roundNumber = 0
        totalRounds = 0
        currentRound = nil
        lastRoundResult = nil
        finalScores = nil

        config = nil
        players = []
        scores = [:]
        inputs = [:]
        inputReceivedAt = [:]
        roundStartedAt = .distantPast

        triviaDeck = nil
        voteDeck = nil
        wordDeck = nil
        drawerQueue = []
        currentCorrectIndex = nil
        currentDrawWord = nil
        // currentDrawerId is computed from currentRound (already cleared
        // above), so no separate reset is needed.
    }

    // MARK: - Host: Round Lifecycle

    private func prepareContent(for mode: GameMode) {
        switch mode {
        case .quickTrivia:
            triviaDeck = try? ContentPackLoader.triviaDeck(named: "general")
        case .voteBattle:
            voteDeck = try? ContentPackLoader.votePromptDeck(named: "mostlikely")
        case .speedDraw:
            wordDeck = ShuffledDeck(DrawWords.all)
            drawerQueue = players.map(\.id)
        case .reflexTap:
            break
        }
    }

    private func runRound() {
        guard isRunning, let mode else { return }
        roundNumber += 1
        inputs = [:]
        inputReceivedAt = [:]
        roundStartedAt = Date()

        guard let data = makeRoundData(for: mode) else {
            Self.logger.error("No round content available — ending game early")
            endGame()
            return
        }

        currentRound = data
        sender.broadcast(.roundStart(data: data, round: roundNumber))

        let timeout = config?.timePerRound ?? 20
        let expectedRound = roundNumber
        roundTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.handleTimeout(for: expectedRound)
        }
    }

    private func handleTimeout(for round: Int) {
        guard isRunning, roundNumber == round else { return }
        finishRound()
    }

    private func checkAllInputsReceived(mode: GameMode) {
        guard expectedRespondersMet(mode: mode) else { return }
        roundTask?.cancel()
        roundTask = nil
        finishRound()
    }

    private func expectedRespondersMet(mode: GameMode) -> Bool {
        switch mode {
        case .quickTrivia, .voteBattle, .reflexTap:
            return !players.isEmpty && players.allSatisfy { inputs[$0.id] != nil }
        case .speedDraw:
            // Speed Draw only finishes early on a correct guess (handled
            // directly in `submitInput`) or the round timeout.
            return false
        }
    }

    private func finishRound() {
        roundTask?.cancel()
        roundTask = nil
        guard isRunning, let mode else { return }

        let deltas = computeScoreDeltas(mode: mode)
        for (playerId, delta) in deltas where delta != 0 {
            scores[playerId, default: 0] += delta
        }

        let highlightId = computeHighlight(mode: mode, deltas: deltas)
        let scoreList = players.map {
            PlayerScore(playerId: $0.id, displayName: $0.displayName, score: scores[$0.id] ?? 0)
        }
        let result = RoundResult(roundNumber: roundNumber, scores: scoreList, highlightPlayerId: highlightId)
        lastRoundResult = result
        currentRound = nil
        sender.broadcast(.roundResult(result: result))

        guard let config, players.count >= 2, roundNumber < config.roundCount else {
            endGame()
            return
        }

        runRound()
    }

    private func endGame() {
        roundTask?.cancel()
        roundTask = nil
        isRunning = false
        currentRound = nil

        let scoreList = players.map {
            PlayerScore(playerId: $0.id, displayName: $0.displayName, score: scores[$0.id] ?? 0)
        }
        finalScores = scoreList
        sender.broadcast(.gameEnd(scores: scoreList))

        Self.logger.info("Game ended with \(scoreList.count) player(s) scored")
    }

    // MARK: - Host: Round Content

    private func makeRoundData(for mode: GameMode) -> RoundData? {
        switch mode {
        case .quickTrivia:
            guard var deck = triviaDeck else { return nil }
            let question = deck.draw()
            triviaDeck = deck
            currentCorrectIndex = question.correctIndex
            return .trivia(question: question.text, options: question.options, correctIndex: question.correctIndex)

        case .voteBattle:
            guard var deck = voteDeck else { return nil }
            let prompt = deck.draw()
            voteDeck = deck
            return .vote(prompt: prompt.text)

        case .speedDraw:
            guard var deck = wordDeck else { return nil }
            let word = deck.draw()
            wordDeck = deck
            let drawerId = nextDrawerId()
            currentDrawWord = word
            // currentDrawerId is derived from currentRound, which the
            // caller (`runRound()`) sets to this returned `.draw` payload
            // immediately after this call returns.
            return .draw(word: word, drawerId: drawerId)

        case .reflexTap:
            return .reflex
        }
    }

    private func nextDrawerId() -> UUID {
        if drawerQueue.isEmpty {
            drawerQueue = players.map(\.id)
        }
        return drawerQueue.removeFirst()
    }

    private func isCorrectGuess(_ text: String) -> Bool {
        guard let word = currentDrawWord else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(word.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    // MARK: - Host: Round Scoring

    private func computeScoreDeltas(mode: GameMode) -> [UUID: Int] {
        switch mode {
        case .quickTrivia:
            guard let correctIndex = currentCorrectIndex, let timeLimit = config?.timePerRound else { return [:] }
            var deltas: [UUID: Int] = [:]
            for player in players {
                guard case .triviaAnswer(let index, let timestamp)? = inputs[player.id] else { continue }
                deltas[player.id] = Self.triviaScore(
                    isCorrect: index == correctIndex,
                    answeredAt: timestamp,
                    roundStartedAt: roundStartedAt,
                    timeLimit: timeLimit
                )
            }
            return deltas

        case .voteBattle:
            // Tally only — no score change.
            return [:]

        case .speedDraw:
            guard let word = currentDrawWord, let drawerId = currentDrawerId else { return [:] }
            let guesses: [(playerId: UUID, text: String, timestamp: Date)] = players.compactMap { player in
                guard case .guess(let text)? = inputs[player.id],
                      let receivedAt = inputReceivedAt[player.id] else { return nil }
                return (player.id, text, receivedAt)
            }
            return Self.drawScores(guesses: guesses, word: word, drawerId: drawerId)

        case .reflexTap:
            let taps: [(playerId: UUID, tappedAt: Date)] = players.compactMap { player in
                guard case .reflexTap(let timestamp)? = inputs[player.id] else { return nil }
                return (player.id, timestamp)
            }
            return Self.reflexScores(taps: taps, flashAt: roundStartedAt)
        }
    }

    private func computeHighlight(mode: GameMode, deltas: [UUID: Int]) -> UUID? {
        switch mode {
        case .voteBattle:
            var votes: [UUID: UUID] = [:]
            for player in players {
                if case .vote(let targetId)? = inputs[player.id] {
                    votes[player.id] = targetId
                }
            }
            return Self.voteTally(votes: votes).max(by: { $0.value < $1.value })?.key
        default:
            return deltas.max(by: { $0.value < $1.value })?.key
        }
    }
}

// MARK: - Pure Scoring Functions

/// Every scoring rule is a pure, `nonisolated` function of its inputs —
/// unit-testable without any engine, actor hop, or MPC machinery.
extension GameEngine {

    /// Structural sanity check for an inbound `.roundStart` payload, applied
    /// before `applyFollowerMessage` mirrors it into `currentRound`.
    ///
    /// A follower device has no other way to know a broadcast is
    /// well-formed — the host normally guarantees this by construction via
    /// `makeRoundData(for:)`, but a forged message (e.g. a malicious peer
    /// impersonating the host, or a bit-flipped payload) could otherwise
    /// carry a trivia round with the wrong option count or an
    /// out-of-range `correctIndex`, crashing or misrendering every mode
    /// view that force-unwraps `options[correctIndex]`.
    nonisolated static func isValidRoundData(_ data: RoundData) -> Bool {
        switch data {
        case .trivia(let question, let options, let correctIndex):
            return !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && options.count == 4
                && options.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && (0..<options.count).contains(correctIndex)

        case .vote(let prompt):
            return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        case .draw(let word, _):
            return !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        case .reflex:
            return true
        }
    }

    /// Trivia round score: `0` if incorrect; otherwise a base of `100` plus
    /// a speed bonus up to `100`, scaled linearly by the fraction of
    /// `timeLimit` remaining when `answeredAt` was recorded relative to
    /// `roundStartedAt`. Answers at or after the time limit still earn the
    /// full base score with no bonus; ties (identical timestamps) earn the
    /// maximum bonus.
    nonisolated static func triviaScore(
        isCorrect: Bool,
        answeredAt: Date,
        roundStartedAt: Date,
        timeLimit: TimeInterval
    ) -> Int {
        guard isCorrect else { return 0 }
        guard timeLimit > 0 else { return 100 }

        let elapsed = answeredAt.timeIntervalSince(roundStartedAt)
        let remainingFraction = max(0, min(1, (timeLimit - elapsed) / timeLimit))
        let speedBonus = Int((remainingFraction * 100).rounded())
        return 100 + speedBonus
    }

    /// Speed Draw round scores: the earliest guess (by `timestamp`) that
    /// case-insensitively matches `word` (both trimmed) earns its author
    /// `150`; the drawer earns `100`. Returns an empty result if nobody
    /// guesses correctly. `guesses` need not be pre-sorted.
    nonisolated static func drawScores(
        guesses: [(playerId: UUID, text: String, timestamp: Date)],
        word: String,
        drawerId: UUID
    ) -> [UUID: Int] {
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let firstCorrect = guesses
            .filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedWord }
            .sorted { $0.timestamp < $1.timestamp }
            .first

        guard let winner = firstCorrect else { return [:] }

        var result: [UUID: Int] = [:]
        result[drawerId, default: 0] += 100
        result[winner.playerId, default: 0] += 150
        return result
    }

    /// Reflex round scores: any tap strictly before `flashAt` is a `-50`
    /// penalty and disqualifies that player from winning the round; among
    /// the remaining valid taps, the earliest earns `100`. A player who
    /// only ever taps early receives just the penalty.
    nonisolated static func reflexScores(
        taps: [(playerId: UUID, tappedAt: Date)],
        flashAt: Date
    ) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var validTaps: [(playerId: UUID, tappedAt: Date)] = []

        for tap in taps {
            if tap.tappedAt < flashAt {
                result[tap.playerId] = -50
            } else {
                validTaps.append(tap)
            }
        }

        if let fastest = validTaps.min(by: { $0.tappedAt < $1.tappedAt }) {
            result[fastest.playerId] = 100
        }

        return result
    }

    /// Vote Battle tally: counts votes per target player. Vote Battle never
    /// awards points — this is used only to pick `RoundResult.highlightPlayerId`.
    nonisolated static func voteTally(votes: [UUID: UUID]) -> [UUID: Int] {
        var tally: [UUID: Int] = [:]
        for target in votes.values {
            tally[target, default: 0] += 1
        }
        return tally
    }
}
