//
//  RemovePlayerConfirmation.swift
//  proximiPlay
//

import SwiftUI

/// The host's "remove this player?" confirmation, shared by the lobby roster
/// and the in-game player menu.
///
/// Extracted for two reasons. It is word-for-word the same decision in both
/// places, and a removal that reads differently depending on where it was
/// started is a bug waiting to happen. And inlining it in `LobbyView` pushed
/// that file's single `List` expression past what the type checker can solve
/// in reasonable time — the same failure its other sections are already
/// factored out to avoid.
///
/// Presentation only: it decides nothing and removes nobody. The caller owns
/// the pending player and performs the removal in `onConfirm`.
private struct RemovePlayerConfirmationModifier: ViewModifier {
    @Binding var player: Player?
    let onConfirm: (Player) -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { player != nil },
            set: { if !$0 { player = nil } }
        )
    }

    private var title: String {
        guard let player else { return "Remove Player?" }
        return "Remove \(player.displayName)?"
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: player
        ) { pending in
            Button("Remove", role: .destructive) {
                onConfirm(pending)
                player = nil
            }
            Button("Cancel", role: .cancel) {
                player = nil
            }
        } message: { pending in
            Text("\(pending.displayName) will be disconnected and can't rejoin this game.")
        }
    }
}

extension View {
    /// Presents the host's removal confirmation whenever `player` is
    /// non-`nil`. See ``RemovePlayerConfirmationModifier``.
    ///
    /// - Parameters:
    ///   - player: The player awaiting confirmation. Cleared on either
    ///     outcome, so the caller never has to reset it.
    ///   - onConfirm: Performs the removal. Called only on an explicit
    ///     confirming tap.
    func removePlayerConfirmation(
        for player: Binding<Player?>,
        onConfirm: @escaping (Player) -> Void
    ) -> some View {
        modifier(RemovePlayerConfirmationModifier(player: player, onConfirm: onConfirm))
    }
}

// MARK: - Previews

#if DEBUG
private struct RemovePlayerConfirmationPreview: View {
    @State private var pending: Player? = Player(displayName: "Bo", color: .red)
    @State private var removed: String?

    var body: some View {
        VStack(spacing: 16) {
            Button("Remove Bo") {
                pending = Player(displayName: "Bo", color: .red)
            }
            if let removed {
                Text("Removed \(removed)")
                    .foregroundStyle(Color.secondary)
            }
        }
        .removePlayerConfirmation(for: $pending) { player in
            removed = player.displayName
        }
    }
}

#Preview("Confirmation") {
    RemovePlayerConfirmationPreview()
}
#endif
