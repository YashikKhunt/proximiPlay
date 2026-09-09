//
//  PlayerBadge.swift
//  proximiPlay
//

import SwiftUI

/// A compact player avatar used in lobby and results screens.
///
/// Displays the player's color-coded initial circle, an optional host crown,
/// and an optional peer-health dot. The entire element is collapsed into a
/// single accessibility element so VoiceOver reads it as one unit.
struct PlayerBadge: View {
    let player: Player
    var peerHealth: ConnectionMonitor.PeerHealth?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // Color-coded avatar circle with player initial.
                //
                // Deliberately a flat fill rather than `.gradient`: the
                // gradient's highlight/shadow bands shift the rendered
                // luminance slightly across the circle, which would make
                // `initialForegroundColor` (computed once, from the base
                // color) an approximation rather than a guarantee at every
                // point behind the letter. A flat fill keeps the contrast
                // math exact.
                Circle()
                    .fill(player.color.swiftUIColor)
                    .frame(width: 50, height: 50)
                    .overlay {
                        Text(String(player.displayName.prefix(1)).uppercased())
                            .font(.title2.bold())
                            .foregroundStyle(initialForegroundColor)
                    }
                    // Connection health dot (only rendered when a health
                    // value is provided).
                    //
                    // Deliberately an `.overlay` on the avatar rather than a
                    // third `ZStack` child: as a sibling it needed
                    // `.frame(maxWidth: .infinity, maxHeight: .infinity,
                    // alignment: .bottomTrailing)` to reach the corner, and
                    // that `.infinity` sized the whole `ZStack` to every
                    // point of width offered. In a full-width container the
                    // badge then stretched edge to edge, and the `ZStack`'s
                    // `.topTrailing` alignment dragged the 50pt avatar to the
                    // trailing edge while the name below stayed centred — the
                    // lobby roster rendered as "avatar hard right, name in the
                    // middle". An overlay is bounded by the circle it decorates,
                    // so the badge keeps its intrinsic size and the corner
                    // placement both.
                    .overlay(alignment: .bottomTrailing) {
                        if let health = peerHealth {
                            Circle()
                                .fill(health.indicatorColor)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.background, lineWidth: 2))
                                .offset(x: 2, y: 2)
                                .accessibilityHidden(true)
                        }
                    }

                // Host crown badge
                if player.isHost {
                    Image(systemName: "crown.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                        .offset(x: 4, y: -4)
                        .accessibilityHidden(true)
                }
            }

            Text(player.displayName)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Helpers

    /// The initial's text color, chosen per WCAG relative luminance so it
    /// stays >= AA contrast against every `PlayerColor` in both light and
    /// dark mode and under Increase Contrast — see
    /// `PlayerColor.accessibleForeground(for:contrast:)`.
    private var initialForegroundColor: Color {
        player.color.accessibleForeground(for: colorScheme, contrast: colorSchemeContrast)
    }

    private var accessibilityDescription: String {
        var parts = [player.displayName]
        if player.isHost { parts.append("host") }
        if let health = peerHealth { parts.append(health.accessibilityDescription) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

#if DEBUG
#Preview("All states") {
    HStack(spacing: 20) {
        PlayerBadge(
            player: Player(displayName: "Alice", color: .blue, isHost: true),
            peerHealth: .healthy
        )
        PlayerBadge(
            player: Player(displayName: "Bob", color: .red),
            peerHealth: .degraded
        )
        PlayerBadge(
            player: Player(displayName: "Charlie", color: .green),
            peerHealth: .lost
        )
        // No health indicator
        PlayerBadge(player: Player(displayName: "Diana", color: .purple))
    }
    .padding()
}

#Preview("Long name truncation") {
    HStack(spacing: 20) {
        PlayerBadge(
            player: Player(displayName: "Bartholomew", color: .orange, isHost: true),
            peerHealth: .healthy
        )
        PlayerBadge(
            player: Player(displayName: "Maximilian", color: .teal),
            peerHealth: .degraded
        )
    }
    .padding()
    .frame(width: 200)
}

#Preview("Dark mode") {
    HStack(spacing: 20) {
        PlayerBadge(
            player: Player(displayName: "Alice", color: .blue, isHost: true),
            peerHealth: .healthy
        )
        PlayerBadge(
            player: Player(displayName: "Bob", color: .red),
            peerHealth: .degraded
        )
        PlayerBadge(
            player: Player(displayName: "Charlie", color: .green),
            peerHealth: .lost
        )
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    HStack(spacing: 20) {
        PlayerBadge(
            player: Player(displayName: "Alice", color: .blue, isHost: true),
            peerHealth: .healthy
        )
        PlayerBadge(
            player: Player(displayName: "Bob", color: .red),
            peerHealth: .degraded
        )
    }
    .padding()
    .dynamicTypeSize(.accessibility3)
}

/// Every `PlayerColor` case side by side, so the light/dark chosen
/// foreground (black vs. white) is visible for the whole palette at once —
/// the check that matters for `accessibleForeground(for:contrast:)`.
#Preview("All colors — contrast check") {
    ScrollView(.horizontal) {
        HStack(spacing: 16) {
            ForEach(PlayerColor.allCases, id: \.self) { color in
                PlayerBadge(player: Player(displayName: color.rawValue, color: color))
            }
        }
        .padding()
    }
}

#Preview("All colors — dark") {
    ScrollView(.horizontal) {
        HStack(spacing: 16) {
            ForEach(PlayerColor.allCases, id: \.self) { color in
                PlayerBadge(player: Player(displayName: color.rawValue, color: color))
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("All colors — accessibility3") {
    ScrollView(.horizontal) {
        HStack(spacing: 16) {
            ForEach(PlayerColor.allCases, id: \.self) { color in
                PlayerBadge(player: Player(displayName: color.rawValue, color: color))
            }
        }
        .padding()
    }
    .dynamicTypeSize(.accessibility3)
}
#endif
