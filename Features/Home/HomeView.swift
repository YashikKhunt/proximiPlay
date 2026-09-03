//
//  HomeView.swift
//  proximiPlay
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.indigo.opacity(0.15), Color.purple.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 48) {
                Spacer()

                // Hero section
                VStack(spacing: 20) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 72))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.indigo)
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text("ProximiPlay")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.primary)

                        Text("Local multiplayer, no internet needed")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                Spacer()

                // Action buttons
                VStack(spacing: 16) {
                    HomeActionButton(
                        title: "Start Game",
                        subtitle: "Host a game for nearby players",
                        systemImage: "play.fill",
                        tint: .indigo
                    ) {
                        appState.gameSessionManager.startHosting()
                        router.navigate(to: .lobby)
                    }
                    .accessibilityLabel("Start Game")
                    .accessibilityHint("Host a new game session for nearby players to join")

                    HomeActionButton(
                        title: "Join Game",
                        subtitle: "Find a nearby game to join",
                        systemImage: "person.badge.plus",
                        tint: .purple
                    ) {
                        appState.gameSessionManager.startBrowsing()
                        router.navigate(to: .join)
                    }
                    .accessibilityLabel("Join Game")
                    .accessibilityHint("Browse nearby devices and join an existing game session")
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - HomeActionButton

private struct HomeActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text(subtitle)
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
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            // Ensures the full row is tappable — meets the 44pt minimum touch target height.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Default") {
    NavigationStack {
        HomeView()
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Dark") {
    NavigationStack {
        HomeView()
    }
    .environment(AppState())
    .environment(Router())
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        HomeView()
    }
    .environment(AppState())
    .environment(Router())
    .dynamicTypeSize(.accessibility3)
}
