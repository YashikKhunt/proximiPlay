//
//  LobbyView.swift
//  proximiPlay
//

import SwiftUI
import MultipeerConnectivity

struct LobbyView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    /// Host-only local selection — never synced live to joiners (see
    /// `startGame()` doc comment for why). Defaults to the first mode.
    @State private var selectedMode: GameMode = .quickTrivia

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
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(GameMode.allCases) { mode in
                                    GameModeCard(
                                        mode: mode,
                                        isSelected: mode == selectedMode
                                    ) {
                                        selectedMode = mode
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        Text(selectedMode.description)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Game Mode")
                }

                Section {
                    Button {
                        startGame()
                    } label: {
                        Text("Start Game")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(otherPlayers.isEmpty)
                    .accessibilityLabel("Start Game")
                    .accessibilityHint(
                        otherPlayers.isEmpty
                            ? "Requires at least one other player to join"
                            : "Starts \(selectedMode.displayName) for everyone in the lobby"
                    )
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                            .accessibilityHidden(true)
                        Text("Host is choosing a game…")
                            .foregroundStyle(Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Waiting for the host to choose and start a game")
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
        // Joiner-side navigation trigger: the host drives its own navigation
        // directly from `startGame()` below (it never receives its own
        // broadcast), so this only ever fires on non-host devices once
        // `sessionManager.lastGameStart` is populated by the `.gameStart`
        // message arriving over the wire.
        .onChange(of: sessionManager.lastGameStart?.mode) { _, newMode in
            guard !sessionManager.isHost, let newMode else { return }
            appState.currentGameState = .playing(newMode)
            router.navigate(to: .game(newMode))
        }
    }

    // MARK: - Actions

    /// Host-only: broadcasts `.gameStart` for the currently selected mode and
    /// navigates locally.
    ///
    /// There is deliberately no live "host is previewing X" broadcast to
    /// joiners as `selectedMode` changes — `Models/GameMessage.swift` is
    /// shared with a concurrent agent building the game engine, so no new
    /// case is added there. Joiners instead see a generic "Host is choosing
    /// a game…" line until the real `.gameStart` arrives.
    private func startGame() {
        let config = GameConfig.defaultConfig(for: selectedMode)
        sessionManager.broadcast(.gameStart(mode: selectedMode, config: config))
        appState.currentGameState = .playing(selectedMode)
        router.navigate(to: .game(selectedMode))
    }
}

// MARK: - GameModeCard

/// A selectable card representing one `GameMode`, used in the host's game
/// mode picker.
private struct GameModeCard: View {
    let mode: GameMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: mode.sfSymbol)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? .white : Color.indigo)
                    .frame(width: 44, height: 44)
                    .background(
                        isSelected ? Color.indigo : Color.indigo.opacity(0.12),
                        in: Circle()
                    )
                    .accessibilityHidden(true)

                Text(mode.displayName)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                if mode.isPremium {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 88, minHeight: 44)
            .background(
                isSelected ? Color.indigo.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.indigo : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint("Double-tap to select \(mode.displayName) as the game mode")
    }

    private var accessibilityDescription: String {
        var parts = [mode.displayName, mode.description]
        if mode.isPremium { parts.append("Premium") }
        return parts.joined(separator: ", ")
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
