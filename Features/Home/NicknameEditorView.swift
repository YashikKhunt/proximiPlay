//
//  NicknameEditorView.swift
//  proximiPlay
//

import SwiftUI

/// Lets the player choose the name every nearby device will see.
///
/// Presented as a sheet from `HomeView`, before any session exists, so
/// editing is always a calm, offline action rather than something that has
/// to reshuffle a live lobby.
///
/// ## Why this screen exists
///
/// Without it the app broadcast the raw device name — "Yashik's iPhone" —
/// to every stranger in Bluetooth range, which is both a real privacy leak
/// and an App Store review liability. The nickname replaces it as the *app
/// level* identity carried in `Player`.
///
/// ## What it deliberately does not touch
///
/// `MCPeerID`. The peer identity stays the archived one cached at first
/// launch (`GameSessionManager.loadOrCreatePeerID`): Multipeer Connectivity
/// refuses to reconnect when a new `MCPeerID` reuses a `displayName` it has
/// already seen, so rebuilding it from an editable nickname would break
/// reconnection for anyone who renames themselves. See
/// `.planning/spikes/multipeer-connectivity.md`.
///
/// Saving routes through `GameSessionManager.updateNickname(_:)`, which
/// persists the sanitized value (`PlayerNickname`) and updates
/// `myPlayer.displayName` — the name a joiner sends in its invitation
/// context and the host stamps into the roster entry it assigns.
struct NicknameEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Pre-filled with the current nickname every time the sheet opens, so
    /// reopening shows what's actually in use rather than a blank field.
    @State private var draft: String = ""
    @FocusState private var isFieldFocused: Bool

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name that would actually be stored right now — the sanitized
    /// draft, or the device-name fallback when the field is empty.
    private var resolvedName: String {
        PlayerNickname.sanitize(draft)
    }

    private var isEmptyDraft: Bool { trimmed.isEmpty }

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $draft)
                    .font(.title3)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isFieldFocused)
                    .onSubmit(save)
                    .onChange(of: draft) { _, newValue in
                        // Cap at the source so the counter can never read
                        // past the limit and the user sees the real bound
                        // instead of silent truncation on save.
                        if newValue.count > PlayerNickname.maxLength {
                            draft = String(newValue.prefix(PlayerNickname.maxLength))
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityLabel("Your name")
                    .accessibilityHint("Shown to everyone in the game. Up to \(PlayerNickname.maxLength) characters.")
            } header: {
                Text("Nickname")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if isEmptyDraft {
                        Label(
                            "Leave this empty and we'll use \"\(PlayerNickname.deviceName)\".",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                    } else {
                        Text("This is the name nearby players see. Your device name is never shared.")
                    }

                    Text("\(trimmed.count) of \(PlayerNickname.maxLength) characters")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                        .accessibilityLabel(
                            "\(trimmed.count) of \(PlayerNickname.maxLength) characters used"
                        )
                }
            }

            Section {
                previewRow
            } header: {
                Text("Preview")
            }
        }
        .navigationTitle("Your Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityHint("Closes without changing your name")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { save() }
                    .fontWeight(.semibold)
                    .accessibilityHint("Saves your name and returns to the home screen")
            }
        }
        .onAppear {
            draft = appState.gameSessionManager.myPlayer.displayName
            isFieldFocused = true
        }
    }

    // MARK: - Preview Row

    /// Shows exactly what other devices will render for this player —
    /// including the device-name fallback when the field is cleared, so the
    /// "graceful fallback" is visible rather than a surprise.
    private var previewRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(appState.gameSessionManager.myPlayer.color.swiftUIColor)
                .frame(width: 40, height: 40)
                .overlay {
                    Text(resolvedName.prefix(1).uppercased())
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedName)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text("How others see you")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Others will see you as \(resolvedName)")
    }

    // MARK: - Actions

    /// Persists the draft and closes.
    ///
    /// Never blocks on an empty field: `PlayerNickname.sanitize` trims,
    /// caps the length, and substitutes the device name when nothing usable
    /// is left, so "Done" always has a sensible outcome.
    private func save() {
        appState.gameSessionManager.updateNickname(draft)
        dismiss()
    }
}

// MARK: - Previews

#Preview("Default") {
    NavigationStack {
        NicknameEditorView()
    }
    .environment(AppState())
}

#Preview("Dark") {
    NavigationStack {
        NicknameEditorView()
    }
    .environment(AppState())
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    NavigationStack {
        NicknameEditorView()
    }
    .environment(AppState())
    .dynamicTypeSize(.accessibility3)
}
