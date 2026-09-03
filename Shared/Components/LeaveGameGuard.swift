//
//  LeaveGameGuard.swift
//  proximiPlay
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Locks down back navigation on an active-round screen so a stray back tap
/// or edge swipe can't silently strand a player out of a live round.
///
/// Applies three things to the view it's attached to:
/// 1. `.navigationBarBackButtonHidden(true)` — removes the default back
///    button (which has no confirmation and no "the round keeps going
///    without you" warning).
/// 2. A disabled interactive (edge-swipe) pop gesture — hiding the back
///    button alone doesn't stop `UINavigationController`'s swipe-to-pop
///    recognizer, so this uses `DisableInteractivePopGesture` to turn it
///    off for as long as this view is on screen.
/// 3. An explicit, destructive "Leave" toolbar action that requires
///    confirmation via `.confirmationDialog` before it calls
///    `AppState.leaveSession()` and pops to root — mirroring the existing
///    Leave pattern in `LobbyView`'s toolbar and `ResultsView`'s
///    `leaveGameButton`, just gated behind a confirmation since leaving
///    mid-round is far higher-stakes than leaving the lobby.
///
/// Usage: `.leaveGameGuard()` on any of the four mode views' root content.
private struct LeaveGameGuardModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router
    @State private var isConfirmingLeave = false

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .disableInteractivePopGesture()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        isConfirmingLeave = true
                    } label: {
                        Label("Leave", systemImage: "xmark.circle")
                    }
                    .accessibilityLabel("Leave Game")
                    .accessibilityHint("Ends your connection to this game session")
                }
            }
            .confirmationDialog(
                "Leave this game?",
                isPresented: $isConfirmingLeave,
                titleVisibility: .visible
            ) {
                Button("Leave Game", role: .destructive) {
                    appState.leaveSession()
                    router.popToRoot()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The round will keep going without you, and you won't be able to rejoin this session.")
            }
    }
}

extension View {
    /// See `LeaveGameGuardModifier`.
    func leaveGameGuard() -> some View {
        modifier(LeaveGameGuardModifier())
    }
}

// MARK: - Interactive Pop Gesture

/// Disables the navigation stack's edge-swipe-to-pop gesture for as long as
/// this view is mounted, restoring it on removal.
///
/// SwiftUI has no direct modifier for this — `UINavigationController`'s
/// `interactivePopGestureRecognizer` is a UIKit-only hook, so this reaches it
/// through a zero-size `UIViewControllerRepresentable` inserted into the view
/// tree purely to access `self.navigationController` once installed in the
/// hierarchy.
private struct DisableInteractivePopGesture: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        PopGestureController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private final class PopGestureController: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Restore the gesture for whatever screen comes after this one
            // (e.g. after `.popToRoot()`), so leaving via the confirmed
            // "Leave" action doesn't leave swipe-to-pop permanently off.
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}

private extension View {
    func disableInteractivePopGesture() -> some View {
        background(DisableInteractivePopGesture().frame(width: 0, height: 0))
    }
}
