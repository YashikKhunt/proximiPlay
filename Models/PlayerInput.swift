//
//  PlayerInput.swift
//  proximiPlay
//

import Foundation

/// Input actions a player can submit during a round, varying by game mode.
enum PlayerInput: Codable, Sendable {
    case triviaAnswer(index: Int, timestamp: Date)
    case vote(targetPlayerId: UUID)
    case drawStroke(points: [CodablePoint])
    case guess(text: String)
    case reflexTap(timestamp: Date)
}
