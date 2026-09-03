//
//  GuessInputView.swift
//  proximiPlay
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The guesser's text-entry bar for Speed Draw: a `TextField` + submit
/// button that reports each non-empty guess through `onSubmit`, plus a
/// small local ticker of this device's own recently-submitted guesses.
///
/// A pure, self-contained component — it has no idea whether any given
/// guess was correct. `DrawGameView` is the single source of truth for that
/// (a correct guess ends the round via `GameEngine`'s host-authoritative
/// broadcast, which `DrawGameView` observes through `lastRoundResult` and
/// transitions away from this view entirely), so the ticker is a plain
/// **local echo** of what this device has sent, not a verified "wrong
/// guesses" log. `DrawGameView` applies `.id(round.roundIndex)` when
/// embedding this view so its state — including the ticker — resets
/// cleanly on every new round.
struct GuessInputView: View {
    /// Invoked with a trimmed, non-empty guess every time the player
    /// submits one.
    let onSubmit: (String) -> Void

    @State private var text: String = ""
    @State private var recentGuesses: [Guess] = []
    @FocusState private var isFocused: Bool

    /// The ticker shows at most this many of the most recent guesses.
    private static let maxTickerEntries = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !recentGuesses.isEmpty {
                ticker
            }

            HStack(spacing: 10) {
                TextField("Guess the word…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .submitLabel(.send)
                    .onSubmit(submit)
                    .accessibilityLabel("Guess the word")
                    .accessibilityHint("Enter your guess, then double-tap Send")

                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send guess")
            }
        }
    }

    // MARK: - Ticker

    private var ticker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recentGuesses) { guess in
                    Text(guess.text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(uiColor: .tertiarySystemBackground), in: Capsule())
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your recent guesses: \(recentGuesses.map(\.text).joined(separator: ", "))")
    }

    // MARK: - Submit

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif

        onSubmit(trimmed)

        recentGuesses.append(Guess(text: trimmed))
        if recentGuesses.count > Self.maxTickerEntries {
            recentGuesses.removeFirst(recentGuesses.count - Self.maxTickerEntries)
        }
        text = ""
    }

    // MARK: - Types

    private struct Guess: Identifiable {
        let id = UUID()
        let text: String
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Empty") {
    GuessInputView(onSubmit: { _ in })
        .padding()
}

#Preview("Dark") {
    GuessInputView(onSubmit: { _ in })
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    GuessInputView(onSubmit: { _ in })
        .padding()
        .dynamicTypeSize(.accessibility3)
}
#endif
