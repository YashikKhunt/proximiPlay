//
//  LobbyView.swift
//  proximiPlay
//

import SwiftUI
import MultipeerConnectivity

struct LobbyView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    private var sessionManager: GameSessionManager { appState.gameSessionManager }

    /// Every synced roster player except the local device — the "You"
    /// section above already covers self.
    private var otherPlayers: [Player] {
        sessionManager.roster.players.filter { $0.id != sessionManager.myPlayer.id }
    }

    var body: some View {
        List {
            // MARK: - My Player Section
            Section {
                HStack(spacing: 12) {
                    Circle()
                        .fill(sessionManager.myPlayer.color.swiftUIColor)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Text(sessionManager.myPlayer.displayName.prefix(1).uppercased())
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        }
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(sessionManager.myPlayer.displayName)
                            .font(.headline)

                        Text("You")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }

                    Spacer()

                    if sessionManager.isHost {
                        Label("Host", systemImage: "crown.fill")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.indigo, in: Capsule())
                            .accessibilityLabel("Host badge")
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("You")
            }

            // MARK: - Connected Players Section
            Section {
                if otherPlayers.isEmpty {
                    Label("No other players yet", systemImage: "person.2")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .accessibilityLabel("No other players connected yet")
                } else {
                    ForEach(otherPlayers) { player in
                        PlayerBadge(player: player, peerHealth: appState.peerHealth(for: player))
                            .padding(.vertical, 4)
                    }
                }
            } header: {
                HStack {
                    Text("Players")
                    Spacer()
                    Text("\(sessionManager.roster.players.count)/\(GameSessionManager.maxPlayers)")
                        .monospacedDigit()
                        .accessibilityLabel(
                            "\(sessionManager.roster.players.count) of \(GameSessionManager.maxPlayers) players"
                        )
                }
            }

            // MARK: - Host Controls / Waiting Message
            if sessionManager.isHost {
                // Game mode picker placeholder (Phase 2)
                Section {
                    HStack {
                        Label("Game Mode", systemImage: "gamecontroller")
                        Spacer()
                        Text("Quick Trivia")
                            .foregroundStyle(Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Game Mode: Quick Trivia. Game mode selection is coming soon.")
                } header: {
                    Text("Settings")
                } footer: {
                    Text("Game mode selection coming in a future update.")
                }

                Section {
                    Button {
                        // Phase 2: start game
                    } label: {
                        Text("Start Game")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .accessibilityLabel("Start Game")
                    .accessibilityHint("Requires at least one other player to join")
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                            .accessibilityHidden(true)
                        Text("Waiting for host to start...")
                            .foregroundStyle(Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Waiting for host to start the game")
                }
            }
        }
        .navigationTitle("Game Lobby")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) {
                    appState.leaveSession()
                    router.popToRoot()
                } label: {
                    Label("Leave", systemImage: "xmark.circle")
                }
                .accessibilityLabel("Leave Game")
                .accessibilityHint("Disconnects you from this game session")
            }
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionIndicator(state: sessionManager.connectionState)
            }
        }
        .alert(
            "Join Request",
            isPresented: Binding(
                get: { sessionManager.pendingInvitation != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionManager.respondToPendingInvitation(accept: false)
                    }
                }
            ),
            presenting: sessionManager.pendingInvitation
        ) { _ in
            Button("Accept") {
                sessionManager.respondToPendingInvitation(accept: true)
            }
            Button("Decline", role: .cancel) {
                sessionManager.respondToPendingInvitation(accept: false)
            }
        } message: { invitation in
            Text("\(invitation.peerName) wants to join your game.")
        }
        .task {
            appState.connectionMonitor.startMonitoring(sessionManager: sessionManager)
        }
        .onDisappear {
            // Phase 2 pushes a game screen on top of the Lobby, which also
            // triggers `.onDisappear` — only treat this as a genuine
            // departure (not a mid-game push-cover) when we're not actively
            // playing. Mirrors JoinView's connected-guard pattern.
            guard appState.currentGameState == .idle || appState.currentGameState == .lobby else { return }
            appState.leaveSession()
        }
    }
}

// MARK: - Previews

#Preview("Host – Empty") {
    NavigationStack {
        LobbyView()
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Dark") {
    NavigationStack {
        LobbyView()
    }
    .environment(AppState())
    .environment(Router())
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        LobbyView()
    }
    .environment(AppState())
    .environment(Router())
    .dynamicTypeSize(.accessibility3)
}
