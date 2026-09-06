//
//  ShareCardView.swift
//  proximiPlay
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One ranked (or, for Vote Battle, unranked) row on a `ShareCardView` —
/// already resolved by `ResultsView` from `PlayerScore`/`RoundResult` into
/// the handful of fields the card actually draws, so this view stays a pure
/// renderer with no dependency on `GameEngine`/`GameSessionManager` and can
/// be previewed and reasoned about in isolation.
struct ShareCardEntry: Identifiable, Sendable {
    let id: UUID
    let displayName: String
    let color: PlayerColor
    /// Final score for every scoring mode; last-round vote count for Vote
    /// Battle (see `ShareCardView.isVoteBattle`).
    let value: Int
    /// Winner (competitive modes, ties included) or last-round fan
    /// favorite (Vote Battle). Drives the gold row treatment and crown.
    let isHighlighted: Bool
}

/// The rendered scoreboard image shared out of `ResultsView` — this is the
/// app's one organic growth lever (per `.planning/APP.md`), so it's built
/// and laid out as a *graphic*, not a screen:
///
/// - **Fixed size**, independent of the presenting device. `ResultsView`
///   sees wildly different screen widths across iPhone SE through Pro Max;
///   the shared image must not, or the same game would produce visibly
///   different cards depending on whose phone rendered it. See `size` /
///   `renderScale` and `rendered(scale:)` below.
/// - **Legible at thumbnail size.** This gets glanced at in a group chat,
///   not studied — few, large elements (a handful of rows, one big
///   headline) rather than a dense stat table, and font sizes are fixed
///   points rather than Dynamic Type styles for exactly the same reason a
///   poster's type doesn't resize with the viewer's phone settings: once
///   rasterized, this is a picture, not UI, so it should look the same in
///   every chat thread rather than reflowing per sharer.
/// - **Still colour-scheme aware.** Unlike Dynamic Type, light/dark *is*
///   worth carrying into the render — `ResultsView` passes its own
///   `colorScheme` into the environment before rendering, so the card
///   matches whatever appearance the sharer's device was actually in
///   rather than being locked to one, and both must independently read
///   correctly (checked via the light/dark previews below).
struct ShareCardView: View {

    /// Point size of the rendered card. A 2:3 portrait — tall enough that
    /// an 8-player roster still gets a legible row height once the header/
    /// footer chrome is subtracted (see `rowArea`'s `GeometryReader`),
    /// while a 2-player roster just gets generously large rows rather than
    /// a mostly-empty card.
    /// `nonisolated` so it can be used as a default-parameter expression
    /// below (default-argument expressions evaluate outside the
    /// declaring method's actor context) without tripping the project's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — it's an inert value
    /// type, so there's nothing actually unsafe about reading it from
    /// anywhere.
    nonisolated static let size = CGSize(width: 360, height: 540)

    /// `ImageRenderer.scale` used by `rendered(scale:)`. Deliberately
    /// independent of the presenting device's own screen scale (a
    /// non-Retina simulator, or any future 1x/2x device, must not produce
    /// a soft image) and capped at 3x per the platform's Retina ceiling —
    /// going higher would only bloat the PNG `ShareLink` attaches.
    nonisolated static let renderScale: CGFloat = 3

    let mode: GameMode
    let isVoteBattle: Bool
    let entries: [ShareCardEntry]
    /// Vote Battle's "no points awarded" disclaimer; `nil` for every
    /// scoring mode.
    let subtitle: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            VStack(spacing: 0) {
                header
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 32)
                    .padding(.bottom, 10)

                rowArea

                footer
                    .padding(.bottom, 18)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    // MARK: - Header

    /// Deliberately compact — every point of header height is a point not
    /// available to `rowArea`, and this card's actual payload is the
    /// roster, not the headline.
    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: isVoteBattle ? "party.popper.fill" : "trophy.fill")
                .font(.system(size: 26, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.yellow)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.15), in: Circle())

            Text(mode.displayName.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.secondary)

            Text(isVoteBattle ? "Vote Battle" : "Final Results")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Color.primary)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Rows

    /// Reads the *actual* vertical space left after the header/footer
    /// chrome and divides it evenly by `entries.count`, rather than
    /// guessing a handful of discrete size tiers from the count alone.
    /// That guarantee is what makes the fixed `size` above survive both a
    /// 2-player and an 8-player roster: whatever height each row gets,
    /// `RowMetrics(rowHeight:)` derives every font/avatar size from it, so
    /// a row can never be taller than the slot `GeometryReader` measured
    /// for it.
    @ViewBuilder
    private var rowArea: some View {
        if entries.isEmpty {
            Text("No scores to show")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                let rowHeight = proxy.size.height / CGFloat(entries.count)
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(rank: index + 1, entry: entry, rowHeight: rowHeight)
                            .frame(height: rowHeight)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
    }

    /// Every size below is derived from `rowHeight` — the one number
    /// `GeometryReader` guarantees is actually available — and clamped so a
    /// 2-player card's oversized slot doesn't blow the avatar/font up
    /// absurdly large, and an 8-player card's tight slot never asks for a
    /// size that would visually collide with its neighbors.
    private struct RowMetrics {
        let avatarSize: CGFloat
        let nameFontSize: CGFloat
        let valueFontSize: CGFloat
        let verticalPadding: CGFloat

        /// The pill's own height is capped well below `rowHeight` (at most
        /// 62% of it, and never past 100pt) rather than stretched to fill
        /// the slot: on a 2-player card `rowHeight` is huge, and a pill
        /// sized to match would just be a mostly-empty box. Centering a
        /// content-sized pill inside the fixed `rowHeight` slot (the
        /// caller's plain `.frame(height:)`, which centers by default)
        /// turns that leftover space into breathing room between rows
        /// instead.
        init(rowHeight: CGFloat) {
            let pillHeight = min(100, max(40, rowHeight * 0.62))
            avatarSize = min(52, max(24, pillHeight * 0.62))
            nameFontSize = min(18, max(11, pillHeight * 0.30))
            valueFontSize = min(19, max(12, pillHeight * 0.32))
            verticalPadding = max(4, (pillHeight - avatarSize) / 2)
        }
    }

    private func row(rank: Int, entry: ShareCardEntry, rowHeight: CGFloat) -> some View {
        let metrics = RowMetrics(rowHeight: rowHeight)
        return HStack(spacing: metrics.avatarSize * 0.24) {
            if !isVoteBattle {
                Text("\(rank)")
                    .font(.system(size: metrics.nameFontSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(entry.isHighlighted ? Color.yellow : Color.secondary)
                    .frame(width: metrics.nameFontSize + 6)
            }

            avatar(for: entry, metrics: metrics)

            Text(entry.displayName)
                .font(.system(size: metrics.nameFontSize, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if entry.isHighlighted {
                Image(systemName: "crown.fill")
                    .font(.system(size: metrics.nameFontSize * 0.75))
                    .foregroundStyle(Color.yellow)
            }

            Text(valueText(for: entry.value))
                .font(.system(size: metrics.valueFontSize, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(entry.isHighlighted ? Color.yellow : Color.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, metrics.verticalPadding)
        .frame(maxWidth: .infinity)
        .background(
            entry.isHighlighted ? Color.yellow.opacity(0.15) : Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(entry.isHighlighted ? Color.yellow : .clear, lineWidth: 1.5)
        }
    }

    private func avatar(for entry: ShareCardEntry, metrics: RowMetrics) -> some View {
        Circle()
            .fill(entry.color.swiftUIColor)
            .frame(width: metrics.avatarSize, height: metrics.avatarSize)
            .overlay {
                Text(String(entry.displayName.prefix(1)).uppercased())
                    .font(.system(size: metrics.avatarSize * 0.42, weight: .bold))
                    .foregroundStyle(entry.color.accessibleForeground(for: colorScheme, contrast: colorSchemeContrast))
            }
    }

    private func valueText(for value: Int) -> String {
        isVoteBattle ? (value == 1 ? "1 vote" : "\(value) votes") : "\(value)"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("ProximiPlay")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.primary)
        }
    }
}

// MARK: - Rendering

extension ShareCardView {
    /// Rasterizes this card to a fixed-size, Retina-quality `UIImage` for
    /// `ShareLink`. `@MainActor` because `ImageRenderer` is main-actor
    /// bound; every caller (`ResultsView`) already is, per the project's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION`.
    @MainActor
    func rendered(scale: CGFloat = ShareCardView.renderScale) -> UIImage? {
        Self.rasterize(self, scale: scale)
    }

    /// Same as `rendered(scale:)`, but overriding `colorScheme` first. A
    /// bare `ImageRenderer` has no window to inherit the device's current
    /// appearance from (it defaults to light), so a live view that already
    /// knows the real appearance -- `ResultsView`, via its own
    /// `@Environment(\.colorScheme)` -- passes it through here to keep the
    /// rendered card matching what's actually on screen.
    @MainActor
    func rendered(colorScheme: ColorScheme, scale: CGFloat = ShareCardView.renderScale) -> UIImage? {
        Self.rasterize(self.environment(\.colorScheme, colorScheme), scale: scale)
    }

    @MainActor
    private static func rasterize(_ content: some View, scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        // No transparency in the design — an opaque render skips
        // compositing an alpha channel that would never actually show
        // anything through it, keeping the attached PNG a bit smaller.
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

// MARK: - Previews

#if DEBUG
private func triviaEntries(count: Int) -> [ShareCardEntry] {
    let names = ["Ari", "Bo", "Priyanka Chandrasekaran", "Deepak", "Emi", "Farid", "Grace", "Hana"]
    let colors: [PlayerColor] = [.blue, .green, .purple, .orange, .pink, .teal, .indigo, .red]
    let scores = [450, 450, 320, 300, 260, 210, 180, 90]
    let topScore = scores.prefix(count).max() ?? 0
    return (0..<count).map { index in
        ShareCardEntry(
            id: UUID(),
            displayName: names[index],
            color: colors[index],
            value: scores[index],
            isHighlighted: scores[index] == topScore
        )
    }
}

private func voteBattleEntries(count: Int) -> [ShareCardEntry] {
    let names = ["Ari", "Bo", "Priyanka Chandrasekaran", "Deepak", "Emi", "Farid", "Grace", "Hana"]
    let colors: [PlayerColor] = [.blue, .green, .purple, .orange, .pink, .teal, .indigo, .red]
    let votes = [1, 3, 2, 0, 1, 0, 2, 1]
    let counted = Array(votes.prefix(count))
    let favoriteIndex = counted.max().flatMap { max in max > 0 ? counted.firstIndex(of: max) : nil }
    return (0..<count).map { index in
        ShareCardEntry(
            id: UUID(),
            displayName: names[index],
            color: colors[index],
            value: votes[index],
            isHighlighted: index == favoriteIndex
        )
    }
}

#Preview("2 Players") {
    ShareCardView(mode: .quickTrivia, isVoteBattle: false, entries: triviaEntries(count: 2), subtitle: nil)
}

#Preview("8 Players") {
    ShareCardView(mode: .quickTrivia, isVoteBattle: false, entries: triviaEntries(count: 8), subtitle: nil)
}

#Preview("Vote Battle") {
    ShareCardView(
        mode: .voteBattle,
        isVoteBattle: true,
        entries: voteBattleEntries(count: 4),
        subtitle: "Votes are just for fun — no points awarded."
    )
}

#Preview("8 Players — Dark") {
    ShareCardView(mode: .quickTrivia, isVoteBattle: false, entries: triviaEntries(count: 8), subtitle: nil)
        .preferredColorScheme(.dark)
}

#Preview("Long Names — 5 Players") {
    ShareCardView(mode: .speedDraw, isVoteBattle: false, entries: triviaEntries(count: 5), subtitle: nil)
}

/// The same 8-player card scaled down to roughly the thumbnail size it'll
/// actually be viewed at in a Messages bubble — the legibility check that
/// matters, rather than eyeballing it at full size.
#Preview("Thumbnail Scale") {
    ShareCardView(mode: .quickTrivia, isVoteBattle: false, entries: triviaEntries(count: 8), subtitle: nil)
        .scaleEffect(0.35)
        .frame(width: ShareCardView.size.width * 0.35, height: ShareCardView.size.height * 0.35)
}
#endif
