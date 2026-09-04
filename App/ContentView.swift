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
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(Router())
}
