//
//  JoinView.swift
//  proximiPlay
//

import SwiftUI
import MultipeerConnectivity

struct JoinView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    private var sessionManager: GameSessionManager { appState.gameSessionManager }

    var body: some View {
        List {
            // MARK: - Discovered Hosts Section
            Section {
                switch sessionManager.connectionState {
                case .browsing where sessionManager.discoveredHosts.isEmpty:
                    // Empty state — still searching
                    VStack(spacing: 16) {
                        ProgressView()
                            .accessibilityHidden(true)
                        Text("Searching for nearby games...")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Searching for nearby games")

                case .connecting:
                    // Connecting to a selected host
                    VStack(spacing: 16) {
                        ProgressView()
                            .accessibilityHidden(true)
                        Text("Connecting...")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Connecting to host")

                default:
                    // Show discovered hosts (or empty state for non-browsing states)
                    if sessionManager.discoveredHosts.isEmpty {
                        ContentUnavailableView(
                            "No Games Found",
                            systemImage: "wifi.slash",
                            description: Text("Make sure a host is nearby with ProximiPlay open.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(sessionManager.discoveredHosts, id: \.self) { host in
                            DiscoveredHostRow(peerID: host) {
                                sessionManager.joinHost(host)
                            }
                        }
                    }
                }
            } header: {
                Text("Nearby Games")
            } footer: {
                Text("Tap a game to join it. Both devices must have Wi-Fi or Bluetooth enabled.")
            }
        }
        .navigationTitle("Find a Game")
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: sessionManager.connectionState) { _, newState in
            if case .connected = newState {
                // Replace, don't push: back from the Lobby should return to
                // Home, not to this stale mid-connection screen.
                router.replaceTop(with: .lobby)
            }
        }
        .onDisappear {
            // Only stop the session if we haven't successfully connected.
            // When we navigate to .lobby the view disappears, but we want to
            // keep the session alive — stopSession() in LobbyView handles teardown.
            if case .connected = sessionManager.connectionState { return }
            sessionManager.stopSession()
        }
    }
}

// MARK: - DiscoveredHostRow

private struct DiscoveredHostRow: View {
    let peerID: MCPeerID
    let onJoin: () -> Void

    var body: some View {
        Button(action: onJoin) {
            HStack(spacing: 14) {
                Image(systemName: "person.wave.2.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.indigo)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(peerID.displayName)
                        .font(.headline)
                        .foregroundStyle(Color.primary)

                    Text("Tap to join")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Join \(peerID.displayName)'s game")
        .accessibilityHint("Double-tap to send a join request")
    }
}

// MARK: - Previews

#Preview("Searching") {
    NavigationStack {
        JoinView()
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Dark") {
    NavigationStack {
        JoinView()
    }
    .environment(AppState())
    .environment(Router())
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        JoinView()
    }
    .environment(AppState())
    .environment(Router())
    .dynamicTypeSize(.accessibility3)
}
