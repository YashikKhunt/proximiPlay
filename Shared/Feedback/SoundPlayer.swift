//
//  SoundPlayer.swift
//  proximiPlay
//

import AVFoundation
import os

/// Plays the short sound effects that mirror `HapticEngine`'s named
/// vocabulary, so every meaningful event in the app has a matching feel and
/// sound (subject to each being independently mutable in Settings).
///
/// ## Audio session: `.ambient`
///
/// ProximiPlay is played in a room with other people, often with someone
/// else's music already going — the category is deliberately `.ambient`,
/// **not** `.playback` or `.soloAmbient`:
/// - `.ambient` is silenced by the Ring/Silent switch, so a player who's
///   silenced their phone stays silenced; a party game has no business
///   overriding that.
/// - `.ambient` mixes with whatever else is already playing rather than
///   interrupting/ducking it (`.mixWithOthers` is set explicitly below for
///   clarity, even though it's `.ambient`'s default) — a round-start chime
///   should never pause someone's music.
///
/// The session is configured once, lazily, the first time a sound would
/// actually play — not at app launch — so a device that never touches sound
/// (e.g. sound already muted in Settings) never pays the session-activation
/// cost at all.
///
/// ## Why `AVAudioPlayer`, not `AVAudioEngine`
///
/// These are short, fire-and-forget one-shot effects with no need for
/// mixing/effects graphs or precise sample-accurate scheduling — one
/// `AVAudioPlayer` per playback keeps this simple and is exactly the API
/// Apple recommends for this use case. Each event's audio bytes are read
/// from the bundle once and cached as `Data`, so repeated plays only pay the
/// (cheap) cost of constructing a new `AVAudioPlayer` from already-in-memory
/// bytes, not a fresh disk read.
///
/// ## Why a retaining `Set`
///
/// An `AVAudioPlayer` with no strong reference held past the `play()` call
/// that starts it would be deallocated (and playback cut off) as soon as the
/// call site's local variable goes out of scope. `activePlayers` holds a
/// strong reference to every in-flight player; the delegate callback removes
/// it once playback actually finishes, so this never accumulates unbounded
/// state across a long play session.
@MainActor
final class SoundPlayer: NSObject {
    static let shared = SoundPlayer()

    /// The app's sound-effect vocabulary, one file per `HapticEngine.Event`
    /// (see that type's doc comment for what each name means). Deliberately
    /// kept as a *separate* enum rather than reusing `HapticEngine.Event`
    /// directly — sound and haptics are independently toggleable in
    /// Settings, and coupling their vocabularies would make that harder to
    /// keep clear at each call site.
    enum Event: String, CaseIterable {
        case selection
        case tapRegistered = "tap_registered"
        case roundStart = "round_start"
        case answerCorrect = "answer_correct"
        case answerWrong = "answer_wrong"
        case winnerReveal = "winner_reveal"
        case playerJoined = "player_joined"
    }

    private nonisolated static let logger = Logger(subsystem: "com.proximiplay", category: "SoundPlayer")

    private var cachedBuffers: [Event: Data] = [:]
    private var activePlayers: Set<AVAudioPlayer> = []
    private var didConfigureSession = false

    private override init() {}

    /// Plays `event`'s sound effect, unless the player has muted sound in
    /// Settings. Silently does nothing (beyond a debug log) if the bundled
    /// resource is missing or fails to decode — a missing sound effect
    /// should never crash a party game.
    func play(_ event: Event) {
        guard FeedbackSettings.soundEnabled else { return }
        configureSessionIfNeeded()

        guard let data = buffer(for: event) else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.volume = 0.7
            activePlayers.insert(player)
            player.play()
        } catch {
            Self.logger.error("Failed to play \(event.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Session

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.logger.error("Failed to configure ambient audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Buffer Cache

    /// Reads every effect into the cache ahead of time.
    ///
    /// Without this, the first play of each effect does a synchronous
    /// `Data(contentsOf:)` on the main actor. `.roundStart`'s first play is
    /// scheduled at the exact instant Reflex Tap's flash appears — the single
    /// most latency-critical moment in the app, which is why `HapticEngine`
    /// is already primed two lines earlier there. This gives sound the same
    /// treatment. Cheap (seven short WAVs) and idempotent.
    func preloadAll() {
        for event in Event.allCases where cachedBuffers[event] == nil {
            _ = buffer(for: event)
        }
    }

    private func buffer(for event: Event) -> Data? {
        if let cached = cachedBuffers[event] { return cached }
        guard let url = Bundle.main.url(forResource: event.rawValue, withExtension: "wav"),
              let data = try? Data(contentsOf: url) else {
            Self.logger.error("Missing bundled sound resource: \(event.rawValue, privacy: .public).wav")
            return nil
        }
        cachedBuffers[event] = data
        return data
    }
}

// MARK: - AVAudioPlayerDelegate

extension SoundPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            SoundPlayer.shared.activePlayers.remove(player)
        }
    }
}
