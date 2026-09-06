//
//  PlayerColor.swift
//  proximiPlay
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    /// The higher-contrast of black/white text over this color, computed
    /// from the color's *actual* on-screen relative luminance for the given
    /// appearance rather than a memorized per-case lookup.
    ///
    /// This matters because every case above is a system dynamic color:
    /// its rendered RGB shifts between light mode, dark mode, and Increase
    /// Contrast, so a single hardcoded "white always" (the previous
    /// behavior of every consumer) silently drops well under the WCAG AA
    /// floor for several cases — measured around 2.2:1 for `.green` and
    /// `.orange` in light mode, both far short of the 4.5:1 body-text / 3:1
    /// large-text minimums. Deriving the choice from luminance means it
    /// stays correct automatically if a case's color value changes, or a
    /// new case is added, with no ratio to re-verify by hand.
    ///
    /// `import UIKit` is safe unconditionally on this iPhone-only target,
    /// but the `canImport` guard is kept for parity with the rest of the
    /// model layer (see `Player.swift`).
    @MainActor
    func accessibleForeground(for colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        #if canImport(UIKit)
        let traits = UITraitCollection { mutableTraits in
            mutableTraits.userInterfaceStyle = colorScheme == .dark ? .dark : .light
            mutableTraits.accessibilityContrast = contrast == .increased ? .high : .normal
        }
        let resolved = UIColor(swiftUIColor).resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let luminance = Self.relativeLuminance(red: red, green: green, blue: blue)
        let contrastWithWhite = 1.05 / (luminance + 0.05)
        let contrastWithBlack = (luminance + 0.05) / 0.05
        return contrastWithWhite >= contrastWithBlack ? .white : .black
        #else
        return .white
        #endif
    }

    /// WCAG relative luminance (sRGB, gamma-decoded per the standard's
    /// piecewise curve) — the shared basis for both the white- and
    /// black-text contrast ratios above.
    private static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> Double {
        func linearize(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }
}
