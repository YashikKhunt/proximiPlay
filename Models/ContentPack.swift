//
//  ContentPack.swift
//  proximiPlay
//

import Foundation

/// A single trivia question bundled in a `Resources/QuestionPacks/*.json`
/// content pack.
///
/// Exactly four `options` are required and `correctIndex` must index into
/// them; `ContentPackLoader` validates both invariants at load time so the
/// game engine can trust every question it draws from a deck.
nonisolated struct TriviaQuestion: Codable, Sendable, Hashable {
    var text: String
    var options: [String]
    var correctIndex: Int
}

/// The category of vote prompt -- determines the phrasing shown to players
/// (e.g. "Most likely to..." vs. "Would you rather...").
nonisolated enum VotePromptKind: String, Codable, Sendable, Hashable {
    case mostLikely
    case wouldYouRather
}

/// A single vote prompt bundled in a `Resources/PromptPacks/*.json` content
/// pack, used by the Vote Battle game mode.
nonisolated struct VotePrompt: Codable, Sendable, Hashable {
    var text: String
    var kind: VotePromptKind
}
