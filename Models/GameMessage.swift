//
//  GameMessage.swift
//  proximiPlay
//

import Foundation

/// The wire protocol for all messages exchanged over Multipeer Connectivity.
///
/// Every message is encoded as JSON via `Codable`. Use `encoded()` and
/// `decoded(from:)` for convenient serialization round-trips.
enum GameMessage: Codable, Sendable {
    case lobbyUpdate(players: [Player])
    case gameStart(mode: GameMode, config: GameConfig)
    case roundStart(data: RoundData)
    case playerInput(playerId: UUID, input: PlayerInput)
    case roundResult(result: RoundResult)
    case gameEnd(scores: [PlayerScore])
    case heartbeat(timestamp: Date)
    case disconnect(playerId: UUID)

    // MARK: - Serialization Helpers

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Encode this message to JSON `Data` for transmission.
    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// Decode a `GameMessage` from JSON `Data` received over the network.
    static func decoded(from data: Data) throws -> GameMessage {
        try Self.decoder.decode(GameMessage.self, from: data)
    }
}
