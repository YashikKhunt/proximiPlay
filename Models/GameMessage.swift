//
//  GameMessage.swift
//  proximiPlay
//

import Foundation

/// The wire protocol for all messages exchanged over Multipeer Connectivity.
///
/// Every message is encoded as JSON via `Codable`. Use `encoded()` and
/// `decoded(from:)` for convenient serialization round-trips.
nonisolated enum GameMessage: Codable, Sendable {
    case lobbyUpdate(players: [Player])
    /// Host → one specific joiner: "this is the `Player` I assigned you."
    ///
    /// Sent point-to-point (never broadcast) the moment the host registers a
    /// newly-connected peer in its roster, so the joiner adopts its identity
    /// verbatim instead of trying to recognise itself inside a broadcast
    /// roster. Guessing by `displayName` used to work only until two people
    /// picked the same nickname, at which point both devices adopted the
    /// same entry and one of them silently lost every input it sent (the
    /// host validates `playerId` against the delivering `MCPeerID`).
    ///
    /// Host-authoritative and therefore origin-gated: only honoured when it
    /// arrives from the joined host peer (`GameSessionManager.isFromHost`),
    /// which is always `false` on the host itself.
    case identityAssignment(player: Player)
    case gameStart(mode: GameMode, config: GameConfig)
    /// `round` is the host's `GameEngine.roundNumber` at the moment this
    /// round started, so followers can track the in-progress round number
    /// precisely (see `GameEngine.applyFollowerMessage`) — needed to stamp
    /// and validate outgoing `.playerInput` messages against the round they
    /// were actually submitted for (`GameEngine.submitInput`'s `round`
    /// parameter).
    case roundStart(data: RoundData, round: Int = 0)
    /// `round` is the submitting device's own view of the round in
    /// progress at submission time — `0` for `.drawStroke` batches, which
    /// carry no round semantics and bypass `GameEngine.submitInput`
    /// entirely (see `AppState`'s message-receive path). Every other input
    /// case is validated against the host's current round before being
    /// applied, so a late submission from a round the host has already
    /// moved past is ignored rather than misapplied to the next round.
    case playerInput(playerId: UUID, input: PlayerInput, round: Int = 0)
    case roundResult(result: RoundResult)
    case gameEnd(scores: [PlayerScore])
    case heartbeat(timestamp: Date)
    case disconnect(playerId: UUID)
    /// Host → everyone: "the game is over, come back to the lobby."
    ///
    /// Broadcast when the host taps "Back to Lobby" on `ResultsView`. The
    /// Multipeer session stays up — only the finished game is torn down —
    /// so joiners return to `LobbyView` and wait for the next `.gameStart`
    /// instead of sitting on stale final scores.
    ///
    /// Host-authoritative like `.gameStart`/`.roundStart`: honoured only
    /// when `GameSessionManager.isFromHost` vouches for the sender, so a
    /// joiner cannot yank everyone out of a game and the host can never be
    /// made to follow its own message.
    case lobbyReturn

    // MARK: - Serialization Helpers

    // nonisolated: serialization is pure value work invoked from nonisolated
    // networking contexts — it must not be bound to the main actor (the
    // project's default isolation).
    private nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Encode this message to JSON `Data` for transmission.
    nonisolated func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// Decode a `GameMessage` from JSON `Data` received over the network.
    nonisolated static func decoded(from data: Data) throws -> GameMessage {
        try Self.decoder.decode(GameMessage.self, from: data)
    }
}
