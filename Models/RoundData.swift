//
//  RoundData.swift
//  proximiPlay
//

import Foundation

/// Mode-specific payload sent at the start of each round.
enum RoundData: Codable, Sendable {
    case trivia(question: String, options: [String], correctIndex: Int)
    case vote(prompt: String)
    case draw(word: String, drawerId: UUID)
    case reflex
}
