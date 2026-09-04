//
//  HapticEngine.swift
//  proximiPlay
//

#if canImport(UIKit)
import UIKit
#endif

/// The single haptic feedback vocabulary for ProximiPlay.
///
/// Every haptic in the app fires through `HapticEngine.shared.play(_:)` with
/// one of the named `Event` cases below, rather than views reaching for
/// `UIImpactFeedbackGenerator`/`UINotificationFeedbackGenerator` ad hoc with
/// whatever style felt right at the time. That used to mean the same kind of
/// moment (e.g. "you picked an answer" in Quick Trivia vs. "you picked a
/// vote target" in Vote Battle) could grade completely differently from
/// screen to screen. Routing every call site through one small, named
/// vocabulary keeps the *meaning* of a haptic consistent everywhere it's
/// used, and gives future call sites (e.g. Lobby's `.playerJoined`) an event
/// to reach for instead of inventing a new generator/style pairing.
///
/// ## Event -> generator mapping
///
/// Each event is bound to exactly one generator/style pair, chosen so a
/// player learns "what a given feel means" once and it holds everywhere:
/// - `.selection` -- `UISelectionFeedbackGenerator`: picking among choices
///   (a trivia answer, a vote target).
/// - `.tapRegistered` -- light impact: a generic action was registered (a
///   valid reflex tap, a canvas undo).
/// - `.roundStart` -- medium impact: a new round/phase began (a fresh
///   question, a reflex flash).
/// - `.answerCorrect` / `.winnerReveal` -- success notification: a positive
///   reveal. Kept as two names (not collapsed to one) even though they're
///   physically identical today, so a future celebratory tuning for
///   game-winner reveals specifically doesn't require touching every
///   correct-answer call site.
/// - `.answerWrong` -- error notification: a negative reveal (wrong answer,
///   tapped too soon).
/// - `.playerJoined` -- light impact: someone joined the lobby.
///
/// ## Respecting the mute toggle
///
/// Every call checks `FeedbackSettings.hapticsEnabled` before touching a
/// generator at all, so flipping the Settings toggle off actually silences
/// every haptic in the app the next time one would fire — there is no
/// separate "am I muted" check callers need to remember to add themselves.
///
/// ## Preparing for latency-sensitive moments
///
/// `UIFeedbackGenerator.prepare()` primes the Taptic Engine so the *next*
/// `impactOccurred()`/`notificationOccurred()`/`selectionChanged()` call
/// fires with minimal latency, at the cost of a brief bump in power draw
/// until the generator is used or the system lets it idle back down. Reflex
/// Tap is the one mode where that latency actually matters — the whole game
/// is "how fast can you react" — so `ReflexGameView` calls `prepare(_:)` for
/// `.roundStart` (the flash) and `.tapRegistered` (a valid tap) the moment a
/// round begins, well before either haptic is due to fire.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    /// The app's full named haptic vocabulary. See the type's doc comment
    /// for what each case means and which generator it maps to.
    enum Event {
        case selection
        case tapRegistered
        case roundStart
        case answerCorrect
        case answerWrong
        case winnerReveal
        case playerJoined
    }

    #if canImport(UIKit)
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    #endif

    private init() {}

    /// Primes the Taptic Engine for `event` ahead of a latency-sensitive
    /// moment. Safe to call speculatively — a no-op (beyond the negligible
    /// cost of a `prepare()` call) if `event` never actually fires, and a
    /// no-op entirely while haptics are muted.
    func prepare(_ event: Event) {
        #if canImport(UIKit)
        guard FeedbackSettings.hapticsEnabled else { return }
        generator(for: event)?.prepare()
        #endif
    }

    /// Fires `event`'s haptic, unless the player has muted haptics in
    /// Settings.
    func play(_ event: Event) {
        #if canImport(UIKit)
        guard FeedbackSettings.hapticsEnabled else { return }
        switch event {
        case .selection:
            selectionGenerator.selectionChanged()
        case .tapRegistered, .playerJoined:
            lightImpactGenerator.impactOccurred()
        case .roundStart:
            mediumImpactGenerator.impactOccurred()
        case .answerCorrect, .winnerReveal:
            notificationGenerator.notificationOccurred(.success)
        case .answerWrong:
            notificationGenerator.notificationOccurred(.error)
        }
        #endif
    }

    #if canImport(UIKit)
    private func generator(for event: Event) -> UIFeedbackGenerator? {
        switch event {
        case .selection:
            return selectionGenerator
        case .tapRegistered, .playerJoined:
            return lightImpactGenerator
        case .roundStart:
            return mediumImpactGenerator
        case .answerCorrect, .winnerReveal, .answerWrong:
            return notificationGenerator
        }
    }
    #endif
}
