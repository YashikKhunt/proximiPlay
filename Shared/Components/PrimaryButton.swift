//
//  PrimaryButton.swift
//  proximiPlay
//

import SwiftUI

/// A full-width capsule-shaped primary action button with haptic feedback.
///
/// Use this for the main call-to-action on any screen (e.g., "Start Game",
/// "Join Game"). The button delivers `HapticEngine`'s `.tapRegistered`
/// feedback on tap — the same named event every other generic "an action was
/// registered" tap in the app uses, so this doesn't grade differently from,
/// say, a reflex tap. It adapts to Dynamic Type and respects the system's
/// reduced-motion and increased-contrast preferences through the
/// `.borderedProminent` button style.
///
/// ```swift
/// PrimaryButton("Start Game", systemImage: "play.fill") {
///     store.startGame()
/// }
/// ```
struct PrimaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void
    var isDisabled: Bool

    init(
        _ title: String,
        systemImage: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button {
            HapticEngine.shared.play(.tapRegistered)
            SoundPlayer.shared.play(.tapRegistered)
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            // Stretch label to fill available width so the tap target is wide.
            .frame(maxWidth: .infinity)
            // 14 pt vertical padding: combined with the label height this
            // comfortably exceeds the 44 pt minimum touch target.
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Capsule())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
        .accessibilityLabel(title)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Variants") {
    VStack(spacing: 16) {
        PrimaryButton("Start Game", systemImage: "play.fill") { }
        PrimaryButton("Join Game", systemImage: "person.2.fill") { }
        PrimaryButton("No Icon") { }
        PrimaryButton("Disabled", systemImage: "lock.fill", isDisabled: true) { }
    }
    .padding()
}

#Preview("Dark mode") {
    VStack(spacing: 16) {
        PrimaryButton("Start Game", systemImage: "play.fill") { }
        PrimaryButton("Disabled", isDisabled: true) { }
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    VStack(spacing: 16) {
        PrimaryButton("Start Game", systemImage: "play.fill") { }
        PrimaryButton("Join Game", systemImage: "person.2.fill") { }
    }
    .padding()
    .dynamicTypeSize(.accessibility3)
}
#endif
