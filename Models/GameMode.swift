//
//  GameMode.swift
//  proximiPlay
//

import Foundation

/// The available mini-game modes in ProximiPlay.
enum GameMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case quickTrivia
    case voteBattle
    case speedDraw
    case reflexTap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quickTrivia: "Quick Trivia"
        case .voteBattle:  "Vote Battle"
        case .speedDraw:   "Speed Draw"
        case .reflexTap:   "Reflex Tap"
        }
    }

    var sfSymbol: String {
        switch self {
        case .quickTrivia: "questionmark.circle"
        case .voteBattle:  "hand.thumbsup"
        case .speedDraw:   "pencil.tip"
        case .reflexTap:   "bolt.fill"
        }
    }

    var description: String {
        switch self {
        case .quickTrivia:
            "Race to answer trivia questions before your opponents."
        case .voteBattle:
            "Vote on who best fits each prompt -- majority wins."
        case .speedDraw:
            "Draw the word while others guess as fast as they can."
        case .reflexTap:
            "Tap the screen the instant the signal appears -- fastest finger wins."
        }
    }

    /// Premium modes require an in-app purchase to unlock.
    var isPremium: Bool {
        switch self {
        case .quickTrivia, .voteBattle: false
        case .speedDraw, .reflexTap:    true
        }
    }
}
