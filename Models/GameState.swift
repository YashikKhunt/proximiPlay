//
//  GameState.swift
//  proximiPlay
//

import Foundation

/// Tracks the high-level phase of a game session.
enum GameState: Codable, Equatable, Sendable {
    case idle
    case lobby
    case playing(GameMode)
    case roundResult
    case gameOver
}
