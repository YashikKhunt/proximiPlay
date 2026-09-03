//
//  ConnectionMonitor.swift
//  proximiPlay
//

import Foundation
import MultipeerConnectivity
import os

/// Tracks heartbeat-based connection health for all peers in a Multipeer
/// Connectivity session.
///
/// Designed to layer on top of `GameSessionManager`. After the session
/// connects, call `startMonitoring(sessionManager:)` to begin the 2-second
/// heartbeat loop. Call `stopMonitoring()` when the session ends.
///
/// All state mutations are confined to `@MainActor` so SwiftUI views can
/// observe `peerHealth` and `isMonitoring` directly.
@Observable
@MainActor
final class ConnectionMonitor {

    // MARK: - Peer Health

    /// The connection health of a single peer, classified by how recently
    /// their last heartbeat was received.
    enum PeerHealth: Sendable {
        /// A heartbeat was received within the last 2 seconds.
        case healthy
        /// The last heartbeat arrived 2–5 seconds ago.
        case degraded
        /// No heartbeat has been received for more than 5 seconds.
        case lost
    }

    // MARK: - Observable State

    /// The current health classification for each connected peer.
    var peerHealth: [MCPeerID: PeerHealth] = [:]

    /// Whether the heartbeat monitoring loop is running.
    private(set) var isMonitoring: Bool = false

    // MARK: - Internal Tracking

    /// The most-recent timestamp at which a heartbeat was received from each peer.
    private var lastHeartbeat: [MCPeerID: Date] = [:]

    /// The background task driving the monitoring loop.
    private var monitoringTask: Task<Void, Never>?

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: "com.proximiplay",
        category: "connection-monitor"
    )

    // MARK: - Monitoring Lifecycle

    /// Starts the heartbeat monitoring loop.
    ///
    /// Any existing monitoring session is stopped before the new one begins.
    /// If this device is the host, a `.heartbeat` message is broadcast to all
    /// connected peers every 2 seconds. The health of every connected peer is
    /// evaluated on the same cadence.
    ///
    /// - Parameter sessionManager: The active `GameSessionManager` instance.
    func startMonitoring(sessionManager: GameSessionManager) {
        stopMonitoring()
        isMonitoring = true

        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // If host, send heartbeat to all peers.
                if sessionManager.isHost {
                    sessionManager.broadcast(.heartbeat(timestamp: Date()))
                }

                // Evaluate health for all currently connected peers.
                self.healthCheck(connectedPeers: sessionManager.connectedPeers)

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Stops the monitoring loop and clears all tracking state.
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
        peerHealth = [:]
        lastHeartbeat = [:]
    }

    // MARK: - Heartbeat Recording

    /// Records the receipt of a heartbeat from `peerID` and immediately marks
    /// that peer as `.healthy`.
    ///
    /// Call this from the `GameSessionManager.onMessageReceived` callback
    /// whenever a `.heartbeat` message arrives.
    ///
    /// - Parameter peerID: The peer that sent the heartbeat.
    func recordHeartbeat(from peerID: MCPeerID) {
        lastHeartbeat[peerID] = Date()
        peerHealth[peerID] = .healthy
    }

    // MARK: - Health Evaluation

    /// Classifies every peer in `connectedPeers` based on elapsed time since
    /// their last recorded heartbeat, and removes entries for peers that are
    /// no longer in the connected set.
    ///
    /// - Parameter connectedPeers: The snapshot of currently connected peers
    ///   taken from `GameSessionManager.connectedPeers`.
    private func healthCheck(connectedPeers: [MCPeerID]) {
        let now = Date()

        for peer in connectedPeers {
            guard let last = lastHeartbeat[peer] else {
                peerHealth[peer] = .lost
                continue
            }

            let elapsed = now.timeIntervalSince(last)

            if elapsed < 2 {
                peerHealth[peer] = .healthy
            } else if elapsed < 5 {
                peerHealth[peer] = .degraded
            } else {
                peerHealth[peer] = .lost
                Self.logger.warning(
                    "Peer \(peer.displayName) heartbeat lost (last: \(elapsed, format: .fixed(precision: 1))s ago)"
                )
            }
        }

        // Remove entries for peers that have disconnected.
        let connectedSet = Set(connectedPeers)
        for key in peerHealth.keys where !connectedSet.contains(key) {
            peerHealth.removeValue(forKey: key)
            lastHeartbeat.removeValue(forKey: key)
        }
    }
}
