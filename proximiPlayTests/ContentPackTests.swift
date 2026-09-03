//
//  ContentPackTests.swift
//  proximiPlayTests
//

import Testing
import Foundation
@testable import proximiPlay

struct ContentPackTests {

    // MARK: - Bundled Pack Decoding + Validation

    @Test func generalTriviaPackDecodesAndValidates() throws {
        let questions = try ContentPackLoader.loadTriviaPack(named: "general")
        #expect(questions.count >= 40)
        for question in questions {
            #expect(question.options.count == 4)
            #expect((0..<4).contains(question.correctIndex))
            #expect(!question.text.isEmpty)
        }
    }

    @Test func popCultureTriviaPackDecodesAndValidates() throws {
        let questions = try ContentPackLoader.loadTriviaPack(named: "popculture")
        #expect(questions.count >= 30)
        for question in questions {
            #expect(question.options.count == 4)
            #expect((0..<4).contains(question.correctIndex))
            #expect(!question.text.isEmpty)
        }
    }

    @Test func mostLikelyPromptPackDecodesAndValidates() throws {
        let prompts = try ContentPackLoader.loadVotePromptPack(named: "mostlikely")
        #expect(prompts.count >= 40)
        for prompt in prompts {
            #expect(!prompt.text.isEmpty)
            #expect(prompt.kind == .mostLikely)
        }
    }

    @Test func wouldYouRatherPromptPackDecodesAndValidates() throws {
        let prompts = try ContentPackLoader.loadVotePromptPack(named: "wouldyourather")
        #expect(prompts.count >= 30)
        for prompt in prompts {
            #expect(!prompt.text.isEmpty)
            #expect(prompt.kind == .wouldYouRather)
        }
    }

    // MARK: - Loader Errors

    @Test func loadingMissingPackThrowsResourceNotFound() {
        #expect(throws: ContentPackError.self) {
            try ContentPackLoader.loadTriviaPack(named: "does-not-exist")
        }
    }

    // MARK: - Validation Rejects Malformed Content

    @Test func validationRejectsWrongOptionCount() {
        let tooFewOptions = TriviaQuestion(text: "Which of these?", options: ["A", "B", "C"], correctIndex: 0)
        #expect(throws: ContentPackError.self) {
            try ContentPackLoader.validate(tooFewOptions)
        }

        let tooManyOptions = TriviaQuestion(text: "Which of these?", options: ["A", "B", "C", "D", "E"], correctIndex: 0)
        #expect(throws: ContentPackError.self) {
            try ContentPackLoader.validate(tooManyOptions)
        }
    }

    @Test func validationRejectsOutOfRangeCorrectIndex() {
        let negativeIndex = TriviaQuestion(text: "Which of these?", options: ["A", "B", "C", "D"], correctIndex: -1)
        #expect(throws: ContentPackError.self) {
            try ContentPackLoader.validate(negativeIndex)
        }

        let tooLargeIndex = TriviaQuestion(text: "Which of these?", options: ["A", "B", "C", "D"], correctIndex: 4)
        #expect(throws: ContentPackError.self) {
            try ContentPackLoader.validate(tooLargeIndex)
        }
    }

    @Test func validationRejectsEmptyQuestionText() {
        let blankText = TriviaQuestion(text: "   ", options: ["A", "B", "C", "D"], correctIndex: 0)
        #expect(throws: ContentPackError.self) {
            try ContentPackLoader.validate(blankText)
        }
    }

    @Test func validationRejectsEmptyOption() {
        let blankOption = TriviaQuestion(text: "Which of these?", options: ["A", "", "C", "D"], correctIndex: 0)
        #expect(throws: ContentPackError.self) {
            try ContentPackLoader.validate(blankOption)
        }
    }

    @Test func validationRejectsEmptyPromptText() {
        let blankPrompt = VotePrompt(text: "  ", kind: .mostLikely)
        #expect(throws: ContentPackError.self) {
            try ContentPackLoader.validate(blankPrompt)
        }
    }

    @Test func validationAcceptsWellFormedQuestion() throws {
        let question = TriviaQuestion(text: "Which of these?", options: ["A", "B", "C", "D"], correctIndex: 2)
        try ContentPackLoader.validate(question)
    }

    // MARK: - ShuffledDeck

    @Test func deckNeverRepeatsWithinOnePass() {
        let elements = Array(0..<50)
        var deck = ShuffledDeck(elements)

        var drawn: [Int] = []
        for _ in 0..<elements.count {
            drawn.append(deck.draw())
        }

        #expect(Set(drawn) == Set(elements))
        #expect(drawn.count == elements.count)
    }

    @Test func deckReshufflesAfterExhaustion() {
        let elements = Array(0..<10)
        var deck = ShuffledDeck(elements)

        // Exhaust the first pass.
        for _ in 0..<elements.count {
            _ = deck.draw()
        }
        #expect(deck.remainingCount == 0)

        // The next draw should trigger a reshuffle and keep producing
        // elements from the original set indefinitely.
        var secondPass: [Int] = []
        for _ in 0..<elements.count {
            secondPass.append(deck.draw())
        }

        #expect(Set(secondPass) == Set(elements))
        #expect(secondPass.count == elements.count)
    }

    @Test func deckDrawsIndefinitelyAcrossMultiplePasses() {
        let elements = ["a", "b", "c"]
        var deck = ShuffledDeck(elements)

        // Draw far more than a single pass worth of elements; every draw
        // must still be a member of the original set.
        for _ in 0..<30 {
            let drawn = deck.draw()
            #expect(elements.contains(drawn))
        }
    }
}
