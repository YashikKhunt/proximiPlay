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
    nonisolated static let maxLength = 20

    /// The seed value used on first launch and whenever a nickname is
    /// cleared — the same device name Multipeer would otherwise expose.
    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    /// Upper bound on unicode scalars, independent of `maxLength`.
    ///
    /// `maxLength` counts *graphemes*, and a grapheme can absorb unlimited
    /// combining marks — `"A" + 200 combining accents` is one character that
    /// renders as a tall smear across neighbouring rows. Bounding scalars
    /// too closes that off while leaving room for legitimately
    /// multi-scalar names (accents, emoji ZWJ sequences).
    nonisolated static let maxScalars = 64

    /// Normalizes a nickname for display on every peer's device.
    ///
    /// This is the app's only piece of peer-supplied text: it arrives in a
    /// joiner's invitation context, enters the host-authoritative roster,
    /// is broadcast to everyone, rendered in lobby rows and game screens,
    /// and rasterized into a share card that leaves the device. Trimming
    /// and truncating alone is not enough for that path, so this also:
    ///
    /// - drops control characters and bidirectional overrides/isolates
    ///   (U+202A–U+202E, U+2066–U+2069), which reorder how surrounding text
    ///   renders and let a name masquerade as different text;
    /// - drops line/paragraph separators, surrogates, unassigned and
    ///   private-use scalars;
    /// - requires at least one *visible* scalar, so a name made purely of
    ///   zero-width characters (category Cf, which no trim removes) can't
    ///   become an unlabelled row in everyone's lobby;
    /// - bounds scalar count as well as grapheme count (see `maxScalars`).
    ///
    /// Zero-width joiners and variation selectors are deliberately kept —
    /// emoji like 👨‍👩‍👧 are built from them — which is why emptiness is
    /// decided by "has a visible scalar" rather than by filtering all
    /// format characters.
    ///
    /// Applied both to what the local user types and to any nickname
    /// arriving from a peer.
    nonisolated static func sanitize(_ raw: String, fallback: String) -> String {
        if let usable = usableName(from: raw) { return usable }
        if let usableFallback = usableName(from: fallback) { return usableFallback }
        return "Player"
    }

    /// Returns `raw` normalized and bounded, or `nil` if nothing renderable
    /// survives.
    private nonisolated static func usableName(from raw: String) -> String? {
        let filtered = String(String.UnicodeScalarView(
            raw.unicodeScalars.filter(isPermitted)
        ))
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.unicodeScalars.contains(where: isVisible) else { return nil }

        var bounded = String(trimmed.prefix(maxLength))
        if bounded.unicodeScalars.count > maxScalars {
            bounded = String(String.UnicodeScalarView(bounded.unicodeScalars.prefix(maxScalars)))
        }
        // Truncation can strip the last visible scalar off a mark-heavy
        // string; fall back rather than return something blank.
        return bounded.unicodeScalars.contains(where: isVisible) ? bounded : nil
    }

    private nonisolated static func isPermitted(_ scalar: Unicode.Scalar) -> Bool {
        // Keep ZWJ and variation selectors: emoji sequences need them.
        if scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) { return true }
        // Bidirectional overrides, embeddings and isolates.
        if (0x202A...0x202E).contains(scalar.value) { return false }
        if (0x2066...0x2069).contains(scalar.value) { return false }

        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator,
             .surrogate, .privateUse, .unassigned:
            return false
        default:
            return true
        }
    }

    /// Whether a scalar actually puts ink on screen — used to reject names
    /// that are technically non-empty but render as nothing.
    private nonisolated static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
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

    /// Sanitizes against the device name as the fallback. MainActor because
    /// `deviceName` reads `UIDevice.current`; use the two-argument
    /// `sanitize(_:fallback:)` from nonisolated contexts.
    static func sanitize(_ raw: String) -> String {
        sanitize(raw, fallback: deviceName)
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
