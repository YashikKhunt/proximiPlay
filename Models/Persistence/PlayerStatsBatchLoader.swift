//
//  PlayerStatsBatchLoader.swift
//  proximiPlay
//

import Foundation
import SwiftData

/// Batches the `PlayerStats` lookup `ResultsView.upsertPlayerStats` needs at
/// game end.
///
/// `ResultsView.upsertPlayerStats(for:isWinner:mode:)` currently runs one
/// `FetchDescriptor<PlayerStats>` per finishing player (bounded at
/// `GameSessionManager.maxPlayers`, i.e. up to 8, but still up to 8 main-
/// thread SwiftData round trips every time a game ends) — an N+1 fetch
/// pattern where a single query would do.
///
/// `existingStats(for:in:)` replaces that with one `FetchDescriptor` for
/// every finishing player's display name at once, returned as a
/// `[String: PlayerStats]` lookup table so the call site's per-player loop
/// only ever touches `ModelContext` once instead of once per player.
///
/// A free function of `ModelContext`, not a `ResultsView` method, so it is
/// directly unit-testable against an in-memory container without a live
/// game/UI stack — see `PlayerStatsBatchLoaderTests`.
///

enum PlayerStatsBatchLoader {

    /// Fetches every existing `PlayerStats` row whose `displayName` appears
    /// in `displayNames`, in a single `FetchDescriptor`, keyed by
    /// `displayName` for O(1) lookup at the call site.
    ///
    /// A name with no existing row is simply absent from the result — the
    /// caller inserts a fresh `PlayerStats` for those, exactly as the
    /// current one-fetch-per-player code does today. Duplicate names in
    /// `displayNames` (not expected in practice — display names within one
    /// finished game's `finalScores` are unique per player) collapse to a
    /// single dictionary entry, which is harmless since every duplicate
    /// would have resolved to the same underlying row anyway.
    ///
    /// - Returns: `[:]` immediately, with no fetch at all, when
    ///   `displayNames` is empty.
    static func existingStats(
        for displayNames: [String],
        in context: ModelContext
    ) throws -> [String: PlayerStats] {
        guard !displayNames.isEmpty else { return [:] }

        let names = Array(Set(displayNames))
        let descriptor = FetchDescriptor<PlayerStats>(
            predicate: #Predicate { names.contains($0.displayName) }
        )
        let results = try context.fetch(descriptor)
        return Dictionary(results.map { ($0.displayName, $0) }, uniquingKeysWith: { existing, _ in existing })
    }
}
