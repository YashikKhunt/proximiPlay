//
//  ContentView.swift
//  proximiPlay
//
//  Created by Yashik Khunt on 03.09.26.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    /// SwiftUI's own Reduce Motion key — reactive, but read-only, so it
    /// can't be overridden in a `#Preview`.
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Router.Destination.self) { destination in
                    switch destination {
                    case .lobby:
                        LobbyView()
                    case .join:
                        JoinView()
                    case .game(let mode):
                        GameHostView(mode: mode)
                    case .results:
                        ResultsView()
                    }
                }
        }
        // Joiner-side follow for the host's "Back to Lobby" (`.lobbyReturn`).
        // Handled here, at the navigation root, rather than on `ResultsView`:
        // a joiner can still be on a mode view's final-round reveal when the
        // host taps it, and only a root-level observer can bring *every*
        // screen back. The token is incremented solely by
        // `GameSessionManager.receive(_:from:)` behind its `isFromHost`
        // gate, so this can never fire on the host or from a forged message
        // — see `GameSessionManager.lobbyReturnToken`.
        .onChange(of: appState.gameSessionManager.lobbyReturnToken) { _, newToken in
            guard newToken > 0 else { return }
            appState.returnToLobbyAfterHostReturn()
            router.popToRoot()
            router.navigate(to: .lobby)
        }
        // Drive the writable `motionReduceMotion` mirror from SwiftUI's real
        // key. `ReduceMotionKey.defaultValue` reads
        // `UIAccessibility.isReduceMotionEnabled` directly, which SwiftUI does
        // NOT observe — so without this bridge, toggling Reduce Motion while
        // the app is running would leave already-rendered views animating
        // until something else happened to invalidate them. Injecting the
        // reactive key here makes the mirror update live, while a deeper
        // `.environment(\.motionReduceMotion, true)` in a `#Preview` still
        // wins for that subtree.
        .environment(\.motionReduceMotion, systemReduceMotion)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(Router())
}
