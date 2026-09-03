//
//  ConnectionIndicator.swift
//  proximiPlay
//

import SwiftUI

/// A pill-shaped status indicator that reflects the current Multipeer
/// Connectivity session state.
///
/// Active states (advertising, browsing, connecting) animate a pulsing dot to
/// communicate ongoing work without requiring the user to read the label.
/// The entire element is exposed to VoiceOver as a single labelled unit.
struct ConnectionIndicator: View {
    let state: GameSessionManager.ConnectionState

    // Drive the pulse animation via a @State toggle flipped in `.onAppear`.
    @State private var pulseTick = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
                .opacity(isPulsing ? (pulseTick ? 0.3 : 1.0) : 1.0)
                .animation(
                    isPulsing
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: pulseTick
                )

            Text(stateText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        // Ensure the pill meets the 44 pt minimum touch-target height even
        // though this element is non-interactive (guards against accidental
        // shrinkage if embedded in a tight layout).
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(stateText)")
        .onAppear {
            if isPulsing { pulseTick = true }
        }
        .onChange(of: isPulsing) { _, nowPulsing in
            pulseTick = nowPulsing
        }
    }

    // MARK: - State-derived properties

    private var stateColor: Color {
        switch state {
        case .idle:           .gray
        case .advertising:    .blue
        case .browsing:       .blue
        case .connecting:     .orange
        case .connected:      .green
        case .disconnected:   .red
        }
    }

    private var stateText: String {
        switch state {
        case .idle:                      "Idle"
        case .advertising:               "Hosting"
        case .browsing:                  "Searching"
        case .connecting:                "Connecting..."
        case .connected:                 "Connected"
        case .disconnected:              "Disconnected"
        }
    }

    private var isPulsing: Bool {
        switch state {
        case .connecting, .browsing, .advertising: true
        default: false
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("All states") {
    VStack(spacing: 12) {
        ConnectionIndicator(state: .idle)
        ConnectionIndicator(state: .advertising)
        ConnectionIndicator(state: .browsing)
        ConnectionIndicator(state: .connecting)
        ConnectionIndicator(state: .connected)
        ConnectionIndicator(state: .disconnected(reason: "Peer left"))
    }
    .padding()
}

#Preview("Dark mode") {
    VStack(spacing: 12) {
        ConnectionIndicator(state: .idle)
        ConnectionIndicator(state: .advertising)
        ConnectionIndicator(state: .browsing)
        ConnectionIndicator(state: .connecting)
        ConnectionIndicator(state: .connected)
        ConnectionIndicator(state: .disconnected(reason: "Peer left"))
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    VStack(spacing: 12) {
        ConnectionIndicator(state: .connected)
        ConnectionIndicator(state: .disconnected(reason: "Host closed session"))
    }
    .padding()
    .dynamicTypeSize(.accessibility3)
}
#endif
