//
//  StrokeSync.swift
//  proximiPlay
//

import Foundation

/// A small, tightly-scoped buffer of the active Speed Draw drawer's strokes,
/// rebuilt entirely from peer-to-peer `.drawStroke` messages.
///
/// Stroke display sync is deliberately **not** routed through `GameEngine` —
/// `GameEngine.submitInput` treats `.drawStroke` as a no-op (it's transient
/// rendering data with no bearing on round completion or scoring), so this
/// type exists purely to give guesser devices something to render from. It
/// is owned by `AppState` and fed by `AppState`'s message-receive path; every
/// mode view (drawer or guesser) only ever reads `segments`.
///
/// ## Wire convention
///
/// Each received `points` batch is appended as one independent polyline
/// **segment**. The sender (`DrawingCanvasView`, via `DrawGameView`) includes
/// the previously-sent point as the first element of the next batch so
/// consecutive segments from the same physical stroke render with no visual
/// gap, even though each batch is stored as its own segment here. An
/// **empty** `points` array is the clear marker: it resets `segments` to
/// `[]`, standing in for both an explicit "Clear" tap and the drawer's
/// "Undo" (which clears then re-streams the remaining strokes).
@Observable
@MainActor
final class StrokeSync {

    /// One received polyline batch, rendered as a single connected stroke.
    struct Segment: Identifiable, Equatable {
        let id = UUID()
        let points: [CodablePoint]
    }

    /// Hard cap on stored segments per round — a defensive bound against an
    /// unbounded drawing session (e.g. a stuck client streaming forever)
    /// consuming ever-growing memory. Oldest segments are dropped first.
    static let maxSegments = 500

    private(set) var segments: [Segment] = []

    /// Applies one inbound `.drawStroke` batch: an empty `points` array
    /// clears the buffer; otherwise the batch is appended as a new segment,
    /// trimming from the front once `maxSegments` is exceeded.
    func receive(points: [CodablePoint]) {
        guard !points.isEmpty else {
            segments = []
            return
        }

        segments.append(Segment(points: points))
        if segments.count > Self.maxSegments {
            segments.removeFirst(segments.count - Self.maxSegments)
        }
    }

    /// Clears the buffer locally — called on every round transition so a new
    /// drawer never starts with a stale drawing still on screen.
    func clear() {
        segments = []
    }
}
