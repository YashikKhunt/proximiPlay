//
//  ContentView.swift
//  proximiPlay
//
//  Created by Yashik Khunt on 03.09.26.
//

import SwiftUI

struct ContentView: View {
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
                        // Placeholder for Phase 2
                        Text("Game: \(mode.displayName)")
                    case .results:
                        // Placeholder for Phase 2
                        Text("Results")
                    }
                }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(Router())
}
