//
//  LobbyView.swift
//  proximiPlay
//

import SwiftUI
import MultipeerConnectivity

struct LobbyView: View {
    @Environment(AppState.self) private var appState

    private var sessionManager: GameSessionManager { appState.gameSessionManager }

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
                if sessionManager.connectedPeers.isEmpty {
                    Label("No other players yet", systemImage: "person.2")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .accessibilityLabel("No other players connected yet")
                } else {
                    ForEach(sessionManager.connectedPeers, id: \.self) { peer in
                        ConnectedPlayerRow(peerID: peer)
                    }
                }
            } header: {
                HStack {
                    Text("Players")
                    Spacer()
                    Text("\(sessionManager.connectedPeers.count + 1)/8")
                        .monospacedDigit()
                        .accessibilityLabel("\(sessionManager.connectedPeers.count + 1) of 8 players")
                }
            }

            // MARK: - Connection Status Section
            Section {
                ConnectionStatusRow(state: sessionManager.connectionState)
            } header: {
                Text("Connection")
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
            appState.connectionMonitor.stopMonitoring()
            sessionManager.stopSession()
        }
    }
}

// MARK: - ConnectedPlayerRow

private struct ConnectedPlayerRow: View {
    let peerID: MCPeerID

    // Assign a deterministic color from the PlayerColor palette based on display name hash.
    private var playerColor: Color {
        let index = abs(peerID.displayName.hashValue) % PlayerColor.allCases.count
        return PlayerColor.allCases[index].swiftUIColor
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(playerColor)
                .frame(width: 36, height: 36)
                .overlay {
                    Text(peerID.displayName.prefix(1).uppercased())
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

            Text(peerID.displayName)
                .font(.body)

            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(peerID.displayName)
    }
}

// MARK: - ConnectionStatusRow

private struct ConnectionStatusRow: View {
    let state: GameSessionManager.ConnectionState

    private var label: String {
        switch state {
        case .idle:                     return "Not connected"
        case .advertising:             return "Waiting for players..."
        case .browsing:                return "Searching..."
        case .connecting:              return "Connecting..."
        case .connected:               return "Connected"
        case .disconnected(let reason): return "Disconnected: \(reason)"
        }
    }

    private var symbolName: String {
        switch state {
        case .connected:               return "checkmark.circle.fill"
        case .disconnected:            return "xmark.circle.fill"
        case .connecting:              return "arrow.triangle.2.circlepath"
        default:                       return "antenna.radiowaves.left.and.right"
        }
    }

    private var symbolColor: Color {
        switch state {
        case .connected:    return .green
        case .disconnected: return .red
        case .connecting:   return .orange
        default:            return .secondary
        }
    }

    var body: some View {
        Label {
            Text(label)
                .foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(label)")
    }
}

// MARK: - Previews

#Preview("Host – Empty") {
    NavigationStack {
        LobbyView()
    }
    .environment(AppState())
}

#Preview("Dark") {
    NavigationStack {
        LobbyView()
    }
    .environment(AppState())
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        LobbyView()
    }
    .environment(AppState())
    .dynamicTypeSize(.accessibility3)
}
