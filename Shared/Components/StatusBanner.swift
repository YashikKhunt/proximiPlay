//
//  StatusBanner.swift
//  proximiPlay
//

import SwiftUI

/// A non-blocking, informational status chip for transient connection
/// states — "Connection lost — reconnecting…", "Ari disconnected" — so
/// every screen that needs to surface one of these reads identically
/// instead of each view inventing its own `Label`/background pairing (the
/// original sin this type fixes: `LobbyView` used to reach for a plain
/// inline `Label` for its own states while other screens improvised their
/// own looks).
///
/// Reserved for information the player doesn't need to act on: the
/// lobby/game underneath keeps working exactly as before, this just floats
/// on top of it. A decision the player *must* make before continuing —
/// "Host Left", the join-request prompt — stays an `.alert`, never a
/// banner; see `HostLeftAlertModifier` in `TriviaGameView.swift`.
struct StatusBanner: View, Equatable, Hashable {

    /// How urgent a banner's message is, driving its accent color. Deliberately
    /// just two cases — this is a small, informational vocabulary, not a
    /// general-purpose severity system.
    enum Tone: Hashable {
        /// An active connectivity problem — the thing the banner reports is
        /// still ongoing and could get worse (or resolve on its own).
        case warning
        /// A neutral heads-up about something that already happened and
        /// doesn't change whether the session keeps working — e.g. a fellow
        /// player left, but the game continues.
        case info
    }

    let tone: Tone
    let systemImage: String
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accentColor.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    private var accentColor: Color {
        switch tone {
        case .warning: .orange
        case .info: .secondary
        }
    }
}

// MARK: - Overlay Placement

extension View {
    /// Pins every banner in `banners` to the top of this view, stacked
    /// top-to-bottom, sliding in from above and fading with the app's
    /// standard arrival spring (an instant appear/disappear under Reduce
    /// Motion) as the list changes.
    ///
    /// Purely additive — the content underneath keeps its exact layout and
    /// stays fully interactive, which is what makes this "non-blocking" as
    /// opposed to an `.alert`.
    func statusBannerOverlay(_ banners: [StatusBanner]) -> some View {
        modifier(StatusBannerOverlay(banners: banners))
    }

    /// Single-banner convenience over the array-based overlay above.
    func statusBannerOverlay(_ banner: StatusBanner?) -> some View {
        statusBannerOverlay(banner.map { [$0] } ?? [])
    }
}

/// Backing `ViewModifier` for `.statusBannerOverlay(_:)` — see that
/// function's doc comment.
private struct StatusBannerOverlay: ViewModifier {
    let banners: [StatusBanner]

    @Environment(\.motionReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // safeAreaInset, not overlay: the reconnecting banner persists
            // for as long as a peer stays unreachable, and an overlay would
            // sit on top of the lobby's own roster header / the results
            // trophy for that whole time.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    ForEach(banners, id: \.self) { banner in
                        banner
                            .transition(
                                reduceMotion
                                    ? .identity
                                    : .move(edge: .top).combined(with: .opacity)
                            )
                    }
                }
                .padding(.top, 8)
            }
            .motion(Motion.arrival, value: banners)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Tones") {
    VStack(spacing: 12) {
        StatusBanner(
            tone: .warning,
            systemImage: "wifi.exclamationmark",
            message: "Connection lost — reconnecting…"
        )
        StatusBanner(
            tone: .info,
            systemImage: "person.fill.xmark",
            message: "Priyanka Chandrasekaran disconnected"
        )
    }
    .padding(.vertical)
}

#Preview("Overlay in context") {
    NavigationStack {
        List {
            Text("Row 1")
            Text("Row 2")
            Text("Row 3")
        }
        .navigationTitle("Example")
    }
    .statusBannerOverlay([
        StatusBanner(
            tone: .warning,
            systemImage: "wifi.exclamationmark",
            message: "Connection lost — reconnecting…"
        )
    ])
}

#Preview("Dark") {
    VStack(spacing: 12) {
        StatusBanner(
            tone: .warning,
            systemImage: "wifi.exclamationmark",
            message: "Connection lost — reconnecting…"
        )
        StatusBanner(
            tone: .info,
            systemImage: "person.fill.xmark",
            message: "Ari disconnected"
        )
    }
    .padding(.vertical)
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    VStack(spacing: 12) {
        StatusBanner(
            tone: .warning,
            systemImage: "wifi.exclamationmark",
            message: "Connection lost — reconnecting…"
        )
        StatusBanner(
            tone: .info,
            systemImage: "person.fill.xmark",
            message: "Priyanka Chandrasekaran disconnected"
        )
    }
    .padding(.vertical)
    .dynamicTypeSize(.accessibility3)
}
#endif
