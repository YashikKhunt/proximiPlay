//
//  DrawWords.swift
//  proximiPlay
//

import Foundation

/// The word list drawn from by Speed Draw rounds.
///
/// A flat, `nonisolated` list of simple, universally recognizable nouns —
/// deliberately free of near-synonyms/homophones that would make
/// correct-guess matching ambiguous (see `GameEngine.drawScores`).
nonisolated enum DrawWords {
    static let all: [String] = [
        "apple", "banana", "balloon", "bicycle", "book", "bridge", "butterfly",
        "cake", "camera", "candle", "car", "castle", "cat", "chair", "cloud",
        "clock", "crown", "dog", "door", "dragon", "drum", "duck", "elephant",
        "eye", "feather", "fire", "fish", "flag", "flower", "football",
        "fork", "ghost", "guitar", "hammer", "hat", "heart", "house",
        "ice cream", "island", "kite", "ladder", "lamp", "leaf", "lion",
        "moon", "mountain", "mouse", "mushroom", "octopus", "pencil", "pizza",
        "rainbow", "robot", "rocket", "shoe", "snake", "snowman", "spider",
        "star", "sun", "tree", "umbrella", "volcano", "whale", "windmill"
    ]
}
