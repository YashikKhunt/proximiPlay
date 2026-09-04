//
//  Player.swift
//  proximiPlay
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A participant in a game session, sent over the wire as part of lobby updates.
struct Player: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var color: PlayerColor
    var isHost: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        color: PlayerColor,
        isHost: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.color = color
        self.isHost = isHost
    }
}

// MARK: - PlayerNickname

/// The player's app-level display name: persisted locally, editable from
/// `NicknameEditorView`, and carried in the `Player` the host assigns.
///
/// **Deliberately separate from `MCPeerID`.** The peer identity stays the
/// archived `MCPeerID` cached at first launch (see
/// `GameSessionManager.loadOrCreatePeerID`) and is *never* rebuilt from the
/// nickname — Multipeer Connectivity refuses to reconnect when a new
/// `MCPeerID` reuses a `displayName` it has already seen (documented in
/// `.planning/spikes/multipeer-connectivity.md`). The nickname travels as
/// ordinary app data instead: a joiner puts it in its invitation context,
/// the host sanitizes it into the roster entry it assigns, and every device
/// renders that.
///
/// Every entry point takes an injectable `UserDefaults` so tests can use a
/// throwaway suite instead of touching `.standard`.
///
/// `@MainActor` (the project default) because `deviceName` reads
/// `UIDevice.current`; every caller — views, `GameSessionManager`'s
/// main-actor methods, `PlayerRoster` — is already main-actor bound.
enum PlayerNickname {

    /// UserDefaults key for the persisted nickname.
    static let defaultsKey = "proximiplay.nickname"

    /// Longest nickname accepted. Keeps lobby rows and player badges
    /// readable at accessibility text sizes, and bounds what a peer can
    /// push into every other device's roster.
    static let maxLength = 20

    /// The seed value used on first launch and whenever a nickname is
    /// cleared — the same device name Multipeer would otherwise expose.
    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    /// Trims whitespace/newlines and truncates to `maxLength`, falling back
    /// to `fallback` (itself trimmed/truncated) when nothing usable remains.
    ///
    /// Applied both to what the local user types *and* to any nickname
    /// arriving from a peer, so a hostile client cannot inject an empty or
    /// arbitrarily long name into everyone's roster.
    static func sanitize(_ raw: String, fallback: String = deviceName) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let cleanedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(cleanedFallback.isEmpty ? "Player" : cleanedFallback.prefix(maxLength))
        }
        return String(trimmed.prefix(maxLength))
    }

    /// The persisted nickname, seeding (and storing) the device name on
    /// first launch so every later read is stable.
    @discardableResult
    static func load(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: defaultsKey) {
            let sanitized = sanitize(stored)
            if sanitized != stored { defaults.set(sanitized, forKey: defaultsKey) }
            return sanitized
        }
        let seeded = sanitize(deviceName)
        defaults.set(seeded, forKey: defaultsKey)
        return seeded
    }

    /// Persists `raw` after sanitizing it, returning the value actually
    /// stored so callers can update their in-memory `Player` with the same
    /// string every other device will see.
    @discardableResult
    static func save(_ raw: String, defaults: UserDefaults = .standard) -> String {
        let sanitized = sanitize(raw)
        defaults.set(sanitized, forKey: defaultsKey)
        return sanitized
    }
}
