//
//  PlayerStatsBatchLoaderTests.swift
//  proximiPlayTests
//

import Testing
import Foundation
import SwiftData
@testable import proximiPlay

@MainActor
struct PlayerStatsBatchLoaderTests {

    /// A fresh in-memory container per test, so no test observes another's
    /// persisted rows.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: PlayerStats.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func emptyNamesReturnsEmptyWithoutFetching() throws {
        let context = try makeContext()
        let result = try PlayerStatsBatchLoader.existingStats(for: [], in: context)
        #expect(result.isEmpty)
    }

    @Test func returnsNoEntryForANameWithNoExistingRow() throws {
        let context = try makeContext()
        let result = try PlayerStatsBatchLoader.existingStats(for: ["Nobody"], in: context)
        #expect(result["Nobody"] == nil)
    }

    @Test func fetchesEveryMatchingRowInOneBatch() throws {
        let context = try makeContext()
        context.insert(PlayerStats(displayName: "Ari", gamesPlayed: 3))
        context.insert(PlayerStats(displayName: "Bo", gamesPlayed: 5))
        context.insert(PlayerStats(displayName: "Priyanka", gamesPlayed: 1))
        try context.save()

        let result = try PlayerStatsBatchLoader.existingStats(for: ["Ari", "Bo"], in: context)

        #expect(result.count == 2)
        #expect(result["Ari"]?.gamesPlayed == 3)
        #expect(result["Bo"]?.gamesPlayed == 5)
        // Not requested, so not fetched even though a row exists.
        #expect(result["Priyanka"] == nil)
    }

    @Test func mixOfExistingAndNewNamesOnlyReturnsExistingOnes() throws {
        let context = try makeContext()
        context.insert(PlayerStats(displayName: "Ari", gamesPlayed: 2))
        try context.save()

        let result = try PlayerStatsBatchLoader.existingStats(for: ["Ari", "NewPlayer"], in: context)

        #expect(result.count == 1)
        #expect(result["Ari"] != nil)
        #expect(result["NewPlayer"] == nil)
    }

    @Test func duplicateRequestedNamesCollapseToOneLookupEntry() throws {
        let context = try makeContext()
        context.insert(PlayerStats(displayName: "Ari", gamesPlayed: 7))
        try context.save()

        let result = try PlayerStatsBatchLoader.existingStats(for: ["Ari", "Ari"], in: context)

        #expect(result.count == 1)
        #expect(result["Ari"]?.gamesPlayed == 7)
    }

    /// Mutating the returned `PlayerStats` reference and saving must persist
    /// -- proving the batch fetch hands back the same managed objects a
    /// per-player fetch would have, not a detached copy the caller's
    /// mutation-then-save upsert pattern would silently no-op against.
    @Test func returnedStatsAreLiveManagedObjectsSafeToMutateAndSave() throws {
        let context = try makeContext()
        context.insert(PlayerStats(displayName: "Ari", gamesPlayed: 1))
        try context.save()

        let result = try PlayerStatsBatchLoader.existingStats(for: ["Ari"], in: context)
        let stats = try #require(result["Ari"])
        stats.gamesPlayed += 1
        try context.save()

        let refetched = try PlayerStatsBatchLoader.existingStats(for: ["Ari"], in: context)
        #expect(refetched["Ari"]?.gamesPlayed == 2)
    }
}
