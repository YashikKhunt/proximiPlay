//
//  RoundHeaderView.swift
//  proximiPlay
//

import SwiftUI

/// A small "Round N of M" label shown at the top of every active-play screen
/// (Quick Trivia, Vote Battle, Speed Draw). Extracted here so all three mode
/// views share one implementation instead of three byte-for-byte copies.
struct RoundHeaderView: View {
    let roundNumber: Int
    let totalRounds: Int

    var body: some View {
        HStack {
            Text("Round \(roundNumber) of \(totalRounds)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Round \(roundNumber) of \(totalRounds)")
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Round Header") {
    VStack(spacing: 16) {
        RoundHeaderView(roundNumber: 1, totalRounds: 5)
        RoundHeaderView(roundNumber: 3, totalRounds: 10)
    }
    .padding()
}

#Preview("Dark") {
    RoundHeaderView(roundNumber: 2, totalRounds: 5)
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    RoundHeaderView(roundNumber: 2, totalRounds: 5)
        .padding()
        .dynamicTypeSize(.accessibility3)
}
#endif
