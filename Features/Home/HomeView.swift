//
//  HomeView.swift
//  proximiPlay
//

import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router

    /// Presents `NicknameEditorView`. A sheet rather than a `Router`
    /// destination: editing your name is a self-contained detour off the
    /// root, not part of the host/join flow the navigation stack models.
    @State private var isEditingNickname = false

    /// Presents `SettingsView`, for the same reason `NicknameEditorView`
    /// does: sound/haptics preferences are a self-contained detour off the
    /// root, not a destination in the host/join navigation flow.
    @State private var isShowingSettings = false

    /// The name every nearby device will see. Read from the live
    /// `myPlayer` (kept in step with the persisted nickname by
    /// `GameSessionManager.updateNickname(_:)`), so returning from the
    /// editor immediately shows the new value here.
    private var nickname: String {
        appState.gameSessionManager.myPlayer.displayName
    }

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

                // Identity + action buttons
                VStack(spacing: 16) {
                    nicknameRow

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("Settings")
                .accessibilityHint("Adjust sound and haptics preferences")
            }
        }
        .sheet(isPresented: $isEditingNickname) {
            NavigationStack {
                NicknameEditorView()
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView()
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Nickname

    /// The edit affordance for the player's name, deliberately above the
    /// Start/Join buttons: it's the one thing worth setting *before* a
    /// session exists, and it's what everyone nearby will see.
    private var nicknameRow: some View {
        Button {
            isEditingNickname = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.indigo)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Playing as")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    Text(nickname)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Label("Edit", systemImage: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.indigo)
                    .labelStyle(.titleAndIcon)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit your name, currently \(nickname)")
        .accessibilityHint("Changes the name other players see")
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
