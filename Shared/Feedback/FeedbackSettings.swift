//
//  FeedbackSettings.swift
//  proximiPlay
//

import Foundation

/// The `UserDefaults` keys backing the sound/haptics mute toggles, shared by
/// `HapticEngine`, `SoundPlayer`, and `SettingsView`.
///
/// `HapticEngine`/`SoundPlayer` are plain (non-View) types, so they can't use
/// `@AppStorage` directly — they read these same keys straight from
/// `UserDefaults.standard`. `SettingsView`'s `@AppStorage(FeedbackSettings
/// .soundEnabledKey)` binds to the identical key, so a toggle flip there is
/// immediately visible to every feedback call site without any additional
/// plumbing.
///
/// Both default to **on**: this is a party game meant to be felt and heard
/// across a loud room, so feedback should work out of the box with an
/// obvious way to mute it, not the other way around. `@AppStorage`'s default
/// parameter only applies within the view that declares it, so the read-side
/// helpers below fall back to `true` themselves whenever the key has never
/// been written (`object(forKey:)` returns `nil`, not `bool(forKey:)`, which
/// would otherwise silently read absent keys as `false`).
enum FeedbackSettings {
    static let soundEnabledKey = "settings.soundEnabled"
    static let hapticsEnabledKey = "settings.hapticsEnabled"

    static var soundEnabled: Bool {
        (UserDefaults.standard.object(forKey: soundEnabledKey) as? Bool) ?? true
    }

    static var hapticsEnabled: Bool {
        (UserDefaults.standard.object(forKey: hapticsEnabledKey) as? Bool) ?? true
    }
}
