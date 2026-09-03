//
//  Router.swift
//  proximiPlay
//

import SwiftUI

/// Manages the app's NavigationStack path using a typed destination enum.
///
/// Inject via `.environment(router)` at the root and consume with
/// `@Environment(Router.self)` in any view. Use `@Bindable` when a two-way
/// binding to `path` is required (e.g. in `NavigationStack(path:)`).
@Observable @MainActor
final class Router {
    var path = NavigationPath()

    /// All navigable destinations in the app.
    enum Destination: Hashable {
        case lobby
        case join
        case game(GameMode)
        case results
    }

    /// Pushes a new destination onto the navigation stack.
    func navigate(to destination: Destination) {
        path.append(destination)
    }

    /// Pops the top-most destination from the stack, if any.
    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Clears the entire navigation stack, returning to the root view.
    func popToRoot() {
        path = NavigationPath()
    }
}
