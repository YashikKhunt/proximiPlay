//
//  PlayerRow.swift
//  proximiPlay
//

import SwiftUI

/// A full-width, horizontally laid out player row: avatar, name (and an
/// optional subtitle) leading, status trailing.
///
/// The list-row counterpart to ``PlayerBadge``, which is a *vertical* badge —
/// avatar above a centred name — built for the side-by-side grids on the
/// results and Vote Battle screens. Dropping that vertical badge into a
/// `List` row stretched it to the row's full width and centred the name under
/// it, which read as broken next to the lobby's hand-rolled "You" row right
/// above. Both lobby sections now render through this one type, so the two
/// cannot drift apart again.
///
/// Collapsed into a single accessibility element so VoiceOver reads a row as
/// one unit ("Bo, host, connected") rather than three unrelated fragments.
struct PlayerRow: View {
    let player: Player

    /// Secondary line under the name — "You" for the local device's own row,
    /// `nil` for everyone else.
    var subtitle: String?

    /// Drives the trailing "Host" capsule. Defaults to the player's own flag;
    /// the local device's row passes `GameSessionManager.isHost` explicitly,
    /// since that is the authority on whether *this* device is hosting.
    var isHost: Bool

    /// Trailing connection-health dot. `nil` (the default) renders no dot —
    /// the correct state for the local device, which has no heartbeat with
    /// itself.
    var peerHealth: ConnectionMonitor.PeerHealth?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        player: Player,
        subtitle: String? = nil,
        isHost: Bool? = nil,
        peerHealth: ConnectionMonitor.PeerHealth? = nil
    ) {
        self.player = player
        self.subtitle = subtitle
        self.isHost = isHost ?? player.isHost
        self.peerHealth = peerHealth
    }

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(player.displayName)
                    .font(.headline)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer(minLength: 8)

            if let peerHealth {
                Circle()
                    .fill(peerHealth.indicatorColor)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }

            if isHost {
                Label("Host", systemImage: "crown.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.indigo, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Avatar

    private var avatar: some View {
        Circle()
            .fill(player.color.swiftUIColor)
            .frame(width: 36, height: 36)
            .overlay {
                Text(String(player.displayName.prefix(1)).uppercased())
                    .font(.headline)
                    .fontWeight(.bold)
                    // Same WCAG-derived choice `PlayerBadge` makes — white
                    // fails AA on half the palette.
                    .foregroundStyle(
                        player.color.accessibleForeground(
                            for: colorScheme,
                            contrast: colorSchemeContrast
                        )
                    )
            }
            .accessibilityHidden(true)
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var parts = [player.displayName]
        if let subtitle { parts.append(subtitle) }
        if isHost { parts.append("host") }
        if let peerHealth { parts.append(peerHealth.accessibilityDescription) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Peer Health Presentation

/// Shared presentation for a peer's connection health, so ``PlayerRow`` and
/// ``PlayerBadge`` cannot describe or colour the same state differently.
extension ConnectionMonitor.PeerHealth {
    var indicatorColor: Color {
        switch self {
        case .healthy:  .green
        case .degraded: .yellow
        case .lost:     .red
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .healthy:  "connected"
        case .degraded: "weak connection"
        case .lost:     "connection lost"
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Lobby roster") {
    List {
        Section("You") {
            PlayerRow(
                player: Player(displayName: "Ari", color: .blue, isHost: true),
                subtitle: "You",
                isHost: true
            )
        }
        Section("Players") {
            PlayerRow(
                player: Player(displayName: "Bo", color: .red),
                peerHealth: .healthy
            )
            PlayerRow(
                player: Player(displayName: "Cass", color: .green),
                peerHealth: .degraded
            )
            PlayerRow(
                player: Player(displayName: "Dev", color: .purple),
                peerHealth: .lost
            )
        }
    }
}

#Preview("Joiner's view — host in the roster") {
    List {
        Section("You") {
            PlayerRow(
                player: Player(displayName: "Bo", color: .red),
                subtitle: "You",
                isHost: false
            )
        }
        Section("Players") {
            PlayerRow(
                player: Player(displayName: "Ari", color: .blue, isHost: true),
                peerHealth: .healthy
            )
        }
    }
}

#Preview("Long name") {
    List {
        PlayerRow(
            player: Player(displayName: "Bartholomew Maximilian", color: .orange, isHost: true),
            subtitle: "You",
            isHost: true,
            peerHealth: .healthy
        )
    }
}

#Preview("Dark") {
    List {
        PlayerRow(
            player: Player(displayName: "Ari", color: .blue, isHost: true),
            subtitle: "You",
            isHost: true
        )
        PlayerRow(player: Player(displayName: "Bo", color: .red), peerHealth: .healthy)
    }
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    List {
        PlayerRow(
            player: Player(displayName: "Ari", color: .blue, isHost: true),
            subtitle: "You",
            isHost: true
        )
        PlayerRow(player: Player(displayName: "Bo", color: .red), peerHealth: .healthy)
    }
    .dynamicTypeSize(.accessibility3)
}
#endif
