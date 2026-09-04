//
//  Motion.swift
//  proximiPlay
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Reduce Motion (writable mirror)

private struct ReduceMotionKey: EnvironmentKey {
    /// Falls back to the real system setting, the same source SwiftUI's own
    /// `accessibilityReduceMotion` reads — this default only ever applies
    /// when nothing upstream (a `#Preview`, most notably) has already
    /// supplied a value.
    static var defaultValue: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #else
        false
        #endif
    }
}

extension EnvironmentValues {
    /// A **writable** mirror of `accessibilityReduceMotion`.
    ///
    /// On this SDK, `\.accessibilityReduceMotion`'s key path is read-only —
    /// `.environment(\.accessibilityReduceMotion, true)` fails to compile
    /// (`cannot convert key path type 'KeyPath<...>' to ... 'WritableKeyPath<...>'`)
    /// — which makes it impossible to author a `#Preview` that exercises a
    /// Reduce-Motion branch against the real key at all. Every
    /// Reduce-Motion-aware view this pass touches reads `motionReduceMotion`
    /// instead: identical real-device behavior (it defaults straight to
    /// `UIAccessibility.isReduceMotionEnabled`), but overridable with
    /// `.environment(\.motionReduceMotion, true)` in a `#Preview`.
    var motionReduceMotion: Bool {
        get { self[ReduceMotionKey.self] }
        set { self[ReduceMotionKey.self] = newValue }
    }
}

// MARK: - Motion

/// The single choke point every animation in the app resolves through
/// before it reaches Reduce Motion.
///
/// Before this file, respecting Reduce Motion was something each view had
/// to remember to do — `ReflexGameView`'s `ReflexPromptView` did
/// (`reduceMotion ? nil : .easeIn(duration: 0.12)`), `VoteRevealView`'s
/// staggered springs and `ResultsView`'s winner celebration didn't. That's
/// the failure mode this type closes off: every call site here reaches for
/// `.motion(_:value:)` (or `Motion.withAnimation`/`Motion.staggerDelay`)
/// instead of SwiftUI's raw `.animation(_:value:)`/`withAnimation(_:)`, and
/// every one of those helpers reads `EnvironmentValues.motionReduceMotion`
/// itself. A future animation would have to deliberately reach past the
/// ergonomic, already-imported helper and back to a raw SwiftUI API to skip
/// the check — the easy path and the correct path are the same path.
enum Motion {

    // MARK: - Presets

    /// The app's standard "something arrived" spring — list rows, cards,
    /// and badges appearing or reordering. Reach for this instead of a
    /// bespoke `.spring(...)` literal so every arrival in the app moves the
    /// same way.
    static let arrival = Animation.spring(response: 0.45, dampingFraction: 0.7)

    /// A snappier, smaller-scale spring for in-place emphasis — e.g. the
    /// digit roll behind `.contentTransition(.numericText())` in
    /// ``AnimatedScoreText``-style counters.
    static let emphasis = Animation.spring(response: 0.35, dampingFraction: 0.75)

    /// A bouncier, longer spring reserved for one-time payoff moments —
    /// currently just the `ResultsView` winner celebration. Deliberately
    /// distinct from ``arrival`` so the *one* moment the app is designed to
    /// feel celebratory actually reads as more emphatic than an ordinary
    /// row appearing.
    static let celebration = Animation.spring(response: 0.55, dampingFraction: 0.62)

    // MARK: - Resolution

    /// Resolves `animation` against Reduce Motion: `nil` (an instant,
    /// non-animated state change — the content still updates, it just
    /// doesn't move to get there) when the setting is on, `animation`
    /// otherwise.
    ///
    /// Every other function in this file funnels through this one — it's
    /// the actual "physically cannot skip the check" boundary; everything
    /// else is convenience wrapping around it.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// A per-item stagger delay for card/row reveals (e.g. `VoteRevealView`
    /// and `TriviaRoundResultView`'s standings) — `0` under Reduce Motion so
    /// a staggered list becomes fully visible in one instantaneous step
    /// rather than trickling in with each row still carrying its slice of
    /// the original delay.
    static func staggerDelay(index: Int, step: TimeInterval = 0.08, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : Double(index) * step
    }

    /// Reduce-Motion-aware replacement for the global `withAnimation(_:)`,
    /// for imperative call sites (`onAppear`, button handlers) that can't
    /// use the `.motion(_:value:)` view modifier below.
    ///
    /// Under Reduce Motion this still runs `body` — every state mutation
    /// inside it still happens, and happens synchronously — it just isn't
    /// wrapped in an animated transaction. That's the guarantee that makes
    /// this safe to use unconditionally: the dangerous failure mode isn't
    /// "the animation didn't play," it's "the content the animation was
    /// supposed to reveal never appeared." This function can't produce that
    /// failure, because `body` always runs.
    @discardableResult
    static func withAnimation<Result>(
        _ animation: Animation = .default,
        reduceMotion: Bool,
        _ body: () throws -> Result
    ) rethrows -> Result {
        if reduceMotion {
            return try body()
        }
        return try SwiftUI.withAnimation(animation, body)
    }
}

// MARK: - View Modifier

extension View {
    /// Reduce-Motion-aware drop-in for `.animation(_:value:)`. Prefer this
    /// over the raw modifier everywhere in the app: it reads
    /// `EnvironmentValues.motionReduceMotion` from the environment itself,
    /// so there is no separate step a caller has to remember — passing a
    /// real `Animation` here is *always* safe, on every device, regardless
    /// of the setting.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionEffect(targetAnimation: animation, value: value))
    }

    /// Gates a purely decorative, non-`Animation`-based effect (e.g.
    /// `.symbolEffect(.bounce, value:)`, which has no `Animation` to hand to
    /// `.motion(_:value:)`) behind Reduce Motion: `transform` only runs when
    /// motion is allowed, otherwise the view passes through unchanged.
    ///
    /// Only appropriate when `transform` is additive flourish, never the
    /// only way a piece of content becomes visible — the content itself
    /// must already be fully present without it.
    @ViewBuilder
    func motionEffect<Content: View>(
        reduceMotion: Bool,
        @ViewBuilder _ transform: (Self) -> Content
    ) -> some View {
        if reduceMotion {
            self
        } else {
            transform(self)
        }
    }
}

/// Backing `ViewModifier` for `.motion(_:value:)` — see that function's doc
/// comment.
private struct MotionEffect<V: Equatable>: ViewModifier {
    let targetAnimation: Animation
    let value: V

    @Environment(\.motionReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Motion.animation(targetAnimation, reduceMotion: reduceMotion), value: value)
    }
}
