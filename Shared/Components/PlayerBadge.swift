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

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // Color-coded avatar circle with player initial
                Circle()
                    .fill(player.color.swiftUIColor.gradient)
                    .frame(width: 50, height: 50)
                    .overlay {
                        Text(String(player.displayName.prefix(1)).uppercased())
                            .font(.title2.bold())
                            .foregroundStyle(.white)
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

                // Connection health dot (only rendered when a health value is provided)
                if let health = peerHealth {
                    Circle()
                        .fill(healthColor(health))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .offset(x: 2, y: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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

    private var accessibilityDescription: String {
        var parts = [player.displayName]
        if player.isHost { parts.append("host") }
        if let health = peerHealth {
            switch health {
            case .healthy:  parts.append("connected")
            case .degraded: parts.append("weak connection")
            case .lost:     parts.append("connection lost")
            }
        }
        return parts.joined(separator: ", ")
    }

    private func healthColor(_ health: ConnectionMonitor.PeerHealth) -> Color {
        switch health {
        case .healthy:  .green
        case .degraded: .yellow
        case .lost:     .red
        }
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
#endif
