//
//  Player.swift
//  proximiPlay
//

import Foundation

/// A participant in a game session, sent over the wire as part of lobby updates.
struct Player: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var color: PlayerColor
    var isHost: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        color: PlayerColor,
        isHost: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.color = color
        self.isHost = isHost
    }
}
