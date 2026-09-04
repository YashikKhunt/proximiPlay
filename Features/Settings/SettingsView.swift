//
//  SettingsView.swift
//  proximiPlay
//

import SwiftUI

/// A minimal settings screen: independent mute toggles for sound and
/// haptics, persisted via `@AppStorage` so they survive a relaunch.
///
/// Both default **on** — this is a party game meant to be felt and heard,
/// and the whole point of a settings screen here is to give players an
/// obvious, one-tap way to mute it, not to make them opt in before it ever
/// makes a sound. The `@AppStorage` keys are `FeedbackSettings`'s shared
/// constants, the exact same keys `HapticEngine` and `SoundPlayer` read
/// before firing anything — so a toggle flip here takes effect immediately,
/// with no extra plumbing to keep the two in sync.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(FeedbackSettings.soundEnabledKey) private var soundEnabled = true
    @AppStorage(FeedbackSettings.hapticsEnabledKey) private var hapticsEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $soundEnabled) {
                    Label("Sound Effects", systemImage: "speaker.wave.2.fill")
                }
                .accessibilityHint("Plays a short sound for game events like correct answers and round starts")

                Toggle(isOn: $hapticsEnabled) {
                    Label("Haptics", systemImage: "waveform")
                }
                .accessibilityHint("Vibrates for game events like correct answers and round starts")
            } footer: {
                Text("Sound respects the Ring/Silent switch and won't interrupt music playing from another app.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Default") {
    NavigationStack {
        SettingsView()
    }
}

#Preview("Dark") {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        SettingsView()
    }
    .dynamicTypeSize(.accessibility3)
}
