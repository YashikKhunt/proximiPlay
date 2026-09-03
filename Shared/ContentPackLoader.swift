//
//  ContentPackLoader.swift
//  proximiPlay
//

import Foundation
import os

/// Errors that can occur while loading or validating a bundled content pack.
nonisolated enum ContentPackError: Error, Sendable, Equatable {
    /// No `<name>.json` resource exists in the given bundle.
    case resourceNotFound(name: String)
    /// The resource exists but its bytes could not be decoded as the
    /// requested type.
    case decodingFailed(name: String, underlying: String)
    /// A decoded `TriviaQuestion` failed validation.
    case invalidQuestion(text: String, reason: String)
    /// A decoded `VotePrompt` failed validation.
    case invalidPrompt(text: String, reason: String)
}

/// Decodes, validates, and hands out bundled trivia/prompt packs.
///
/// Packs are decoded from `Bundle.main` lazily -- at the moment a game mode
/// actually needs them -- rather than eagerly at app launch, keeping startup
/// fast while still failing loudly (via a thrown `ContentPackError`) if a
/// pack is missing or malformed.
nonisolated enum ContentPackLoader {
    private static let logger = Logger(subsystem: "com.yashik.proximiPlay", category: "ContentPackLoader")

    // MARK: - Trivia

    /// Decodes and validates the trivia pack named `name` (without the
    /// `.json` extension) from `bundle`.
    static func loadTriviaPack(named name: String, bundle: Bundle = .main) throws -> [TriviaQuestion] {
        let questions: [TriviaQuestion] = try decode(name, bundle: bundle)
        for question in questions {
            try validate(question)
        }
        return questions
    }

    /// Convenience that wraps `loadTriviaPack(named:bundle:)` in a
    /// draw-without-replacement `ShuffledDeck`.
    static func triviaDeck(named name: String, bundle: Bundle = .main) throws -> ShuffledDeck<TriviaQuestion> {
        ShuffledDeck(try loadTriviaPack(named: name, bundle: bundle))
    }

    /// Validates a single question: non-empty text, exactly four non-empty
    /// options, and a `correctIndex` that indexes into them.
    static func validate(_ question: TriviaQuestion) throws {
        guard !question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContentPackError.invalidQuestion(text: question.text, reason: "text must not be empty")
        }
        guard question.options.count == 4 else {
            throw ContentPackError.invalidQuestion(
                text: question.text,
                reason: "must have exactly 4 options, found \(question.options.count)"
            )
        }
        guard question.options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ContentPackError.invalidQuestion(text: question.text, reason: "options must not be empty")
        }
        guard question.options.indices.contains(question.correctIndex) else {
            throw ContentPackError.invalidQuestion(
                text: question.text,
                reason: "correctIndex \(question.correctIndex) is out of range 0..<4"
            )
        }
    }

    // MARK: - Vote Prompts

    /// Decodes and validates the vote prompt pack named `name` (without the
    /// `.json` extension) from `bundle`.
    static func loadVotePromptPack(named name: String, bundle: Bundle = .main) throws -> [VotePrompt] {
        let prompts: [VotePrompt] = try decode(name, bundle: bundle)
        for prompt in prompts {
            try validate(prompt)
        }
        return prompts
    }

    /// Convenience that wraps `loadVotePromptPack(named:bundle:)` in a
    /// draw-without-replacement `ShuffledDeck`.
    static func votePromptDeck(named name: String, bundle: Bundle = .main) throws -> ShuffledDeck<VotePrompt> {
        ShuffledDeck(try loadVotePromptPack(named: name, bundle: bundle))
    }

    /// Validates a single prompt: non-empty text.
    static func validate(_ prompt: VotePrompt) throws {
        guard !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContentPackError.invalidPrompt(text: prompt.text, reason: "text must not be empty")
        }
    }

    // MARK: - Decoding

    private static func decode<T: Decodable>(_ name: String, bundle: Bundle) throws -> T {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            logger.error("Missing bundled content pack resource: \(name, privacy: .public).json")
            throw ContentPackError.resourceNotFound(name: name)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("Failed to read content pack \(name, privacy: .public).json: \(error.localizedDescription, privacy: .public)")
            throw ContentPackError.decodingFailed(name: name, underlying: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("Failed to decode content pack \(name, privacy: .public).json: \(error.localizedDescription, privacy: .public)")
            throw ContentPackError.decodingFailed(name: name, underlying: error.localizedDescription)
        }
    }
}

/// A draw-without-replacement iterator over a fixed collection of elements.
///
/// Every element is drawn exactly once per pass in a random order; once the
/// deck is exhausted it reshuffles automatically so callers can keep
/// drawing indefinitely (e.g. across an entire game session) without ever
/// repeating a question within a single pass.
nonisolated struct ShuffledDeck<Element: Sendable>: Sendable {
    private let allElements: [Element]
    private var remaining: [Element]

    init(_ elements: [Element]) {
        precondition(!elements.isEmpty, "ShuffledDeck requires at least one element")
        allElements = elements
        remaining = elements.shuffled()
    }

    /// The number of elements left to draw before the deck reshuffles.
    var remainingCount: Int { remaining.count }

    /// The total number of elements in the deck.
    var count: Int { allElements.count }

    /// Draws the next element without replacement. Reshuffles the full deck
    /// (which may reorder previously-seen elements) once every element has
    /// been drawn in the current pass.
    mutating func draw() -> Element {
        if remaining.isEmpty {
            remaining = allElements.shuffled()
        }
        return remaining.removeLast()
    }
}
