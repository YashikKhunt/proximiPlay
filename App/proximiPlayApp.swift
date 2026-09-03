//
//  proximiPlayApp.swift
//  proximiPlay
//
//  Created by Yashik Khunt on 03.09.26.
//

import SwiftUI
import SwiftData

@main
struct proximiPlayApp: App {
    @State private var appState = AppState()
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(router)
        }
        .modelContainer(for: [GameHistory.self, PlayerStats.self])
    }
}
