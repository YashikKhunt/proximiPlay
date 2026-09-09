//
//  LobbyView.swift
//  proximiPlay
//

import SwiftUI
import MultipeerConnectivity

struct LobbyView: View {
    @Environment(AppState.self) private var appState
    @Environment(Router.self) private var router
    @Environment(\.motionReduceMotion) private var reduceMotion

    /// Host-only local selection — never synced live to joiners (see
    /// `startGame()` doc comment for why). Defaults to the first mode.
    @State private var selectedMode: GameMode = .quickTrivia

    /// The player the host is being asked to confirm removing. Removal is
    /// destructive and irreversible for the session, so it never happens on
    /// a single swipe.
    @State private var playerPendingRemoval: Player?

    private var sessionManager: GameSessionManager { appState.gameSessionManager }

    /// Every synced roster player except the local device — the "You"
    /// section above already covers self.
    private var otherPlayers: [Player] {
        sessionManager.roster.players.filter { $0.id != sessionManager.myPlayer.id }
    }

    /// Surfaced whenever any connected peer's heartbeat has been missing for
    /// more than 5 seconds (`ConnectionMonitor.PeerHealth.lost`) — a real,
    /// observed connectivity problem, not a guess. `PlayerRow`'s own health
    /// dot already reports this per-player; this banner is the "something is
    /// actually wrong right now" heads-up that doesn't require scanning the
    /// roster to notice. Clears itself the moment a heartbeat is heard again.
    private var reconnectingBanner: StatusBanner? {
        guard appState.connectionMonitor.isMonitoring,
              appState.connectionMonitor.peerHealth.values.contains(.lost) else { return nil }
        return StatusBanner(
            tone: .warning,
            systemImage: "wifi.exclamationmark",
            message: "Connection lost — reconnecting…"
        )
    }

    var body: some View {
        List {
            myPlayerSection
            connectedPlayersSection
            // MARK: - Host Controls / Waiting Message
            hostControlsOrWaitingSection
        }
        // Players popping straight into (and out of) the list read as a
        // glitch, not a join — animate the roster's own arrivals/departures
        // with the app's standard arrival spring, keyed off the roster
        // itself (an `Equatable` `[Player]`, since `Player: Hashable`) so
        // only an actual join/leave/reorder triggers it, not every
        // unrelated re-render. See `playerRowTransition` for the per-row
        // half of this (`.animation` alone only covers layout — a row still
        // needs a `.transition` to know how to enter/exit rather than
        // simply popping).
        .motion(Motion.arrival, value: sessionManager.roster.players)
        .statusBannerOverlay(reconnectingBanner)
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
        .removePlayerConfirmation(for: $playerPendingRemoval) { player in
            sessionManager.removePlayer(player)
        }
        .task {
            appState.connectionMonitor.startMonitoring(sessionManager: sessionManager)
#if DEBUG
            // No-op unless launched with `-demo-roster`. Seeded here rather
            // than at app launch because starting to host rebuilds the
            // roster, which would wipe an earlier seed. See
            // `AppState.seedDemoRosterIfRequested()`.
            appState.seedDemoRosterIfRequested()
#endif
        }
        .onDisappear {
            // Phase 2 pushes a game screen on top of the Lobby, which also
            // triggers `.onDisappear` — only treat this as a genuine
            // departure (not a mid-game push-cover) when we're not actively
            // playing. Mirrors JoinView's connected-guard pattern.
            guard appState.currentGameState == .idle else { return }
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
        // The roster mutating is already visible on screen (rows slide in
        // and out via `playerRowTransition`), but nothing spoke it — a
        // VoiceOver user got no signal that someone joined or left short of
        // re-scanning the whole list. Diffing old vs. new here catches every
        // roster change regardless of source (a peer connecting, a peer
        // dropping mid-lobby) with no separate wiring per cause.
        .onChange(of: sessionManager.roster.players) { oldPlayers, newPlayers in
            announceRosterChanges(from: oldPlayers, to: newPlayers)
        }
    }

    // MARK: - VoiceOver Roster Announcements

    /// Posts an `AccessibilityNotification.Announcement` for every player who
    /// joined or left between `oldPlayers` and `newPlayers`, so a VoiceOver
    /// user hears roster changes as they happen instead of only discovering
    /// them by re-navigating the list.
    private func announceRosterChanges(from oldPlayers: [Player], to newPlayers: [Player]) {
        let oldIds = Set(oldPlayers.map(\.id))
        let newIds = Set(newPlayers.map(\.id))

        for player in newPlayers where !oldIds.contains(player.id) {
            AccessibilityNotification.Announcement("\(player.displayName) joined the lobby").post()
        }
        for player in oldPlayers where !newIds.contains(player.id) {
            AccessibilityNotification.Announcement("\(player.displayName) left the lobby").post()
        }
    }

    // MARK: - My Player Section

    /// Pulled out of `body` (alongside every other top-level section here)
    /// purely to keep the surrounding `List`'s single result-builder
    /// expression small enough for the type checker to solve in reasonable
    /// time — see `noOtherPlayersView`'s doc comment for the same rationale.
    @ViewBuilder
    private var myPlayerSection: some View {
        Section {
            // No `peerHealth`: this device has no heartbeat with itself.
            // `isHost` comes from the session manager rather than
            // `myPlayer.isHost`, since that is the authority on whether
            // *this* device is hosting.
            PlayerRow(
                player: sessionManager.myPlayer,
                subtitle: "You",
                isHost: sessionManager.isHost
            )
        } header: {
            Text("You")
        }
    }

    // MARK: - Connected Players Section

    /// Same extraction rationale as `myPlayerSection`.
    @ViewBuilder
    private var connectedPlayersSection: some View {
        Section {
            if otherPlayers.isEmpty {
                noOtherPlayersView
            } else {
                ForEach(otherPlayers) { player in
                    // `PlayerRow`, not `PlayerBadge`: the badge is the
                    // vertical avatar-over-centred-name form built for the
                    // results and Vote Battle grids, and it read as broken
                    // in a full-width list row next to the "You" row above.
                    PlayerRow(
                        player: player,
                        peerHealth: appState.peerHealth(for: player)
                    )
                    .transition(playerRowTransition)
                    // Host-only: Guideline 1.2's "remove an abusive user".
                    // `allowsFullSwipe: false` so removal always takes a
                    // deliberate tap on the revealed button, never a fast
                    // swipe past a row.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if sessionManager.isHost {
                            Button(role: .destructive) {
                                playerPendingRemoval = player
                            } label: {
                                Label("Remove", systemImage: "person.fill.xmark")
                            }
                        }
                    }
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
    }

    // MARK: - Host Controls / Waiting Message

    /// The host's game-mode picker + Start Game button, or (for a joiner)
    /// the "host is choosing" waiting message — pulled out of `body` into
    /// its own `@ViewBuilder` for the same reason as `noOtherPlayersView`:
    /// keeping `body`'s single `List` expression small enough for the type
    /// checker to solve without timing out.
    @ViewBuilder
    private var hostControlsOrWaitingSection: some View {
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
                    Text("Waiting for the host to choose a game…")
                        .foregroundStyle(Color.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Waiting for the host to choose and start a game")
            }
        }
    }

    // MARK: - Empty Roster

    /// Standardized on `ContentUnavailableView` to match `JoinView`'s empty
    /// state (see this file's flagged inconsistency) and made actionable: a
    /// device sitting on this screen already tapped Start Game or joined
    /// someone else's, so the concrete next step is inviting more people,
    /// not just naming the empty list. Pulled out of `body` into its own
    /// `@ViewBuilder` — inlined, its multi-line `description` pushed the
    /// surrounding `List`'s single result-builder expression past the type
    /// checker's time budget.
    @ViewBuilder
    private var noOtherPlayersView: some View {
        ContentUnavailableView(
            "No Other Players Yet",
            systemImage: "person.2",
            description: Text(
                "Ask a friend to open ProximiPlay on their iPhone and tap Join Game to find this game. Make sure both devices have Wi-Fi or Bluetooth turned on."
            )
        )
        .listRowBackground(Color.clear)
        .transition(playerRowTransition)
    }

    // MARK: - Player Row Motion

    /// A joining player slides in from the trailing edge while fading in; a
    /// leaving one just fades — matching how the row it's about to become
    /// (or just was) is laid out, rather than the same motion in both
    /// directions.
    ///
    /// `.identity` under Reduce Motion: the row still appears/disappears
    /// exactly when the roster changes (nothing is ever skipped or hidden),
    /// it just does so as a single instantaneous cut instead of a slide —
    /// the same "instant, not invisible" contract every other reduce-motion
    /// branch in this pass follows.
    private var playerRowTransition: AnyTransition {
        reduceMotion
            ? .identity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            )
    }

    // MARK: - Actions

    /// Host-only: broadcasts `.gameStart` for the currently selected mode and
    /// navigates locally.
    ///
    /// There is deliberately no live "host is previewing X" broadcast to
    /// joiners as `selectedMode` changes — joiners see a generic "Host is
    /// choosing a game…" line until the real `.gameStart` arrives.
    ///
    /// The broadcast config is built from the *actual* roster size, matching
    /// what `GameHostView` hands the engine. Joiners now take their
    /// `totalRounds` straight from this message
    /// (`GameEngine.applyFollowerMessage`), so a player-count-blind config
    /// here would show every joiner the wrong round count in Speed Draw,
    /// whose round count is one per player.
    private func startGame() {
        let config = GameConfig.defaultConfig(
            for: selectedMode,
            playerCount: sessionManager.roster.players.count
        )
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
                    // A fixed point size, not `.title2`: this is a small
                    // decorative glyph inside a fixed 44x44 badge, and
                    // `.title2` scaling with Dynamic Type at accessibility
                    // sizes made the symbol outgrow (and clip against) that
                    // fixed frame. `.system(size:)` never scales with
                    // Dynamic Type, which is exactly what a glyph pinned to a
                    // non-scaling badge needs.
                    .font(.system(size: 20, weight: .semibold))
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
        [mode.displayName, mode.description].joined(separator: ", ")
    }
}

// MARK: - Previews

#if DEBUG
/// Seeds a host `AppState` with a couple of already-joined players via
/// `PlayerRoster.applyLobbyUpdate(_:)` — the same joiner-side mutation path
/// `GameSessionManager` uses, so no `MCPeerID` (host-only `hostPlayerJoined`
/// needs one) is required just to populate a preview.
@MainActor
private func lobbyPreviewAppState() -> AppState {
    let appState = AppState()
    let host = Player(displayName: "Ari", color: .blue, isHost: true)
    let joiner = Player(displayName: "Priyanka Chandrasekaran", color: .green)

    appState.gameSessionManager.isHost = true
    appState.gameSessionManager.myPlayer = host
    appState.gameSessionManager.roster.setHost(host)
    appState.gameSessionManager.roster.applyLobbyUpdate([host, joiner])

    return appState
}
#endif

#Preview("Host – Empty") {
    NavigationStack {
        LobbyView()
    }
    .environment(AppState())
    .environment(Router())
}

#Preview("Host – Players Joined") {
    NavigationStack {
        LobbyView()
    }
    .environment(lobbyPreviewAppState())
    .environment(Router())
}

/// Seeds one real `MCPeerID` (via `hostPlayerJoined`, the same path a live
/// session uses) so `ConnectionMonitor.peerHealth` has something to key a
/// `.lost` entry against, confirming `reconnectingBanner`'s
/// `StatusBanner` renders atop the roster without disturbing its layout.
#Preview("Reconnecting") {
    NavigationStack {
        LobbyView()
    }
    .environment({
        let appState = AppState()
        let host = Player(displayName: "Ari", color: .blue, isHost: true)
        appState.gameSessionManager.isHost = true
        appState.gameSessionManager.myPlayer = host
        appState.gameSessionManager.roster.setHost(host)

        let peer = MCPeerID(displayName: "Priyanka Chandrasekaran")
        appState.gameSessionManager.roster.hostPlayerJoined(
            peer: peer,
            displayName: "Priyanka Chandrasekaran"
        )
        appState.connectionMonitor.peerHealth[peer] = .lost

        return appState
    }())
    .environment(Router())
}

/// Reduce Motion: the same joined roster as above, so the check isn't
/// "does the empty state look fine" — it confirms every already-connected
/// player is fully visible immediately, with no reliance on the
/// join/leave slide `playerRowTransition` no longer plays.
#Preview("Reduce Motion") {
    NavigationStack {
        LobbyView()
    }
    .environment(lobbyPreviewAppState())
    .environment(Router())
    .environment(\.motionReduceMotion, true)
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
