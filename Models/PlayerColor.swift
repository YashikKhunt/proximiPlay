//
//  PlayerColor.swift
//  proximiPlay
//

import SwiftUI

/// Accessible player colors that remain distinct in both light and dark mode.
enum PlayerColor: String, Codable, CaseIterable, Sendable {
    case red
    case blue
    case green
    case orange
    case purple
    case pink
    case teal
    case indigo

    var swiftUIColor: Color {
        switch self {
        case .red:     .red
        case .blue:    .blue
        case .green:   .green
        case .orange:  .orange
        case .purple:  .purple
        case .pink:    .pink
        case .teal:    .teal
        case .indigo:  .indigo
        }
    }
}
