//
//  GameState.swift
//  proximiPlay
//

import Foundation

/// Tracks the high-level phase of a game session.
///
/// Only `.idle` and `.playing(_:)` are ever actually assigned anywhere in
/// the app — the lobby, round-result, and game-over phases are represented
/// by navigation (`Router.Destination`) and `GameEngine` state instead, not
/// by this type. `.lobby`/`.roundResult`/`.gameOver` cases used to exist
/// here too but were never constructed by any call site (confirmed via a
/// full-repo search of `GameState` usage), leaving one disjunct of
/// `LobbyView`'s `onDisappear` teardown guard permanently unreachable.
/// Removed rather than wired up, since nothing in the app needs a
/// `GameState`-level notion of those phases distinct from what
/// `Router`/`GameEngine` already track.
enum GameState: Codable, Equatable, Sendable {
    case idle
    case playing(GameMode)
}
