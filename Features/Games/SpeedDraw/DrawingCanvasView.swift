//
//  DrawingCanvasView.swift
//  proximiPlay
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The Speed Draw canvas, used in two mutually-exclusive modes:
///
/// - **Editable** (the drawer): a `DragGesture` captures the finger's path,
///   rendering it live and streaming normalized point batches out through
///   `onStrokeBatch` — batched every ~50 ms or 20 points, whichever comes
///   first, to keep unreliable MPC packets small and frequent. Clear and
///   Undo controls appear beneath the canvas.
/// - **Read-only** (every guesser): renders `segments` — normalized
///   `CodablePoint` polylines received from `StrokeSync` — with no gesture
///   recognition at all.
///
/// All points are normalized to the unit square (0...1) before leaving this
/// view, so a drawing streamed from one device's canvas renders correctly at
/// another device's (possibly different) canvas size.
///
/// ## Stroke batching wire convention
///
/// Every batch sent through `onStrokeBatch` is treated by the receiver
/// (`StrokeSync`) as an independent polyline segment. To avoid a visible gap
/// between consecutive batches from the same physical stroke, each batch
/// after the first includes the prior batch's last point as its own first
/// point. An **empty** array is the reserved "clear" marker (see
/// `StrokeSync`), sent by `clear()` and by `undo()` (which clears, then
/// re-streams every remaining stroke as fresh full-stroke batches).
struct DrawingCanvasView: View {
    /// `true` for the drawer's own canvas (draws + streams); `false` for
    /// every guesser's read-only rendering of the drawer's strokes.
    let isEditable: Bool

    /// Read-only segments to render. Ignored when `isEditable`. Takes
    /// `StrokeSync.Segment` (not a bare `[[CodablePoint]]`) specifically for
    /// its stable `id` — `strokeCache` memoizes each segment's denormalized
    /// points by that id, so a redraw doesn't have to re-transform segments
    /// it's already seen. See `StrokeRenderCache`'s doc comment.
    var segments: [StrokeSync.Segment] = []

    /// Invoked with each outbound point batch — drawer mode only. An empty
    /// array signals "clear this drawing everywhere."
    var onStrokeBatch: (([CodablePoint]) -> Void)?

    /// Completed strokes so far, normalized (0...1). Drawer mode only. Each
    /// stroke carries a stable `id` purely so `strokeCache` can memoize its
    /// denormalized (canvas-space) points across redraws — see
    /// `StrokeRenderCache`'s doc comment.
    @State private var strokes: [Stroke] = []
    /// The in-progress stroke, normalized (0...1). Drawer mode only.
    @State private var currentStroke: [CGPoint] = []
    /// `currentStroke`, already denormalized to the last-known canvas size,
    /// kept incrementally in step with `currentStroke` (one point appended
    /// per touch-move in `dragGesture`) so `renderedStrokes(canvasSize:)`
    /// never has to re-transform the in-progress stroke from scratch on
    /// every redraw while dragging.
    @State private var currentStrokeRendered: [CGPoint] = []
    /// The canvas size `currentStrokeRendered` was computed against; if the
    /// canvas resizes mid-stroke, `currentStrokeRendered` is rebuilt fresh
    /// once rather than silently going stale.
    @State private var currentStrokeRenderedSize: CGSize = .zero
    /// How many points of `currentStroke` have already been included in a
    /// sent batch (as that batch's trailing point, for continuity).
    @State private var sentPointCount: Int = 0
    @State private var lastBatchDate: Date = .distantPast
    /// Memoized per-stroke denormalized points — see `StrokeRenderCache`.
    @State private var strokeCache = StrokeRenderCache()

    private static let batchInterval: TimeInterval = 0.05
    private static let batchPointThreshold = 20

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                Canvas { context, size in
                    for stroke in renderedStrokes(canvasSize: size) {
                        var path = Path()
                        guard let first = stroke.first else { continue }
                        path.move(to: first)
                        for point in stroke.dropFirst() {
                            path.addLine(to: point)
                        }
                        context.stroke(
                            path,
                            with: .color(.indigo),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
                // Metal-backed compositing: with up to `StrokeSync
                // .maxSegments` (500) polylines redrawn on a guesser's
                // screen late in a round, letting Core Animation cache this
                // subtree as a single rasterized layer keeps that cost off
                // the CPU on every frame.
                .drawingGroup()
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(canvasSize: proxy.size))
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isEditable ? "Drawing canvas" : "Live drawing")
            .accessibilityHint(isEditable ? "Drag your finger to draw the word" : "")

            if isEditable {
                controls
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button(role: .destructive, action: clear) {
                Label("Clear", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Erases the whole drawing for everyone")

            Button(action: undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(strokes.isEmpty && currentStroke.isEmpty)
            .accessibilityHint("Removes your last stroke")
        }
        .frame(minHeight: 44)
    }

    // MARK: - Rendering

    /// Denormalizes every stroke/segment to draw this frame, reusing
    /// `strokeCache`'s memo for anything already transformed rather than
    /// re-mapping every point of every completed stroke/segment on every
    /// redraw (see `StrokeRenderCache`'s doc comment). The one thing never
    /// cached is `currentStrokeRendered` — the actively-dragged stroke — but
    /// that's built incrementally in `dragGesture`, not re-transformed here
    /// either.
    private func renderedStrokes(canvasSize: CGSize) -> [[CGPoint]] {
        if isEditable {
            if strokes.isEmpty && currentStroke.isEmpty {
                strokeCache.removeAll()
            }
            var all = strokes.map { stroke in
                strokeCache.denormalized(id: stroke.id, normalizedPoints: stroke.points, canvasSize: canvasSize)
            }
            if !currentStrokeRendered.isEmpty {
                all.append(currentStrokeRendered)
            }
            return all
        } else {
            if segments.isEmpty {
                strokeCache.removeAll()
            }
            return segments.map { segment in
                strokeCache.denormalized(
                    id: segment.id,
                    normalizedPoints: segment.points.map(\.cgPoint),
                    canvasSize: canvasSize
                )
            }
        }
    }

    // MARK: - Drawing Gesture

    private func dragGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEditable, canvasSize.width > 0, canvasSize.height > 0 else { return }
                let normalized = CGPoint(
                    x: min(max(value.location.x / canvasSize.width, 0), 1),
                    y: min(max(value.location.y / canvasSize.height, 0), 1)
                )
                currentStroke.append(normalized)

                // Denormalize just the new point (or rebuild once if the
                // canvas resized mid-stroke) instead of leaving this for
                // `renderedStrokes` to redo in full on every touch-move —
                // this is what actually keeps a long, still-in-progress
                // stroke cheap to redraw at ~60-120 Hz.
                if currentStrokeRenderedSize != canvasSize {
                    currentStrokeRendered = currentStroke.map {
                        CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height)
                    }
                    currentStrokeRenderedSize = canvasSize
                } else {
                    currentStrokeRendered.append(
                        CGPoint(x: normalized.x * canvasSize.width, y: normalized.y * canvasSize.height)
                    )
                }

                sendPendingBatchIfDue()
            }
            .onEnded { _ in
                guard isEditable else { return }
                sendPendingBatchIfDue(force: true)
                if !currentStroke.isEmpty {
                    let stroke = Stroke(points: currentStroke)
                    // Seed the cache with what was already computed
                    // incrementally above, so the very next redraw doesn't
                    // have to re-transform a stroke that just finished.
                    strokeCache.seed(id: stroke.id, denormalizedPoints: currentStrokeRendered, canvasSize: canvasSize)
                    strokes.append(stroke)
                }
                currentStroke = []
                currentStrokeRendered = []
                sentPointCount = 0
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
            }
    }

    private func sendPendingBatchIfDue(force: Bool = false) {
        let pendingCount = currentStroke.count - sentPointCount
        guard pendingCount > 0 else { return }

        let elapsed = Date().timeIntervalSince(lastBatchDate)
        guard force || pendingCount >= Self.batchPointThreshold || elapsed >= Self.batchInterval else { return }

        // Include the previous batch's trailing point (if any) so this
        // segment visually connects to the last one sent.
        let startIndex = sentPointCount > 0 ? sentPointCount - 1 : 0
        let batch = Array(currentStroke[startIndex...])
        onStrokeBatch?(batch.map { CodablePoint($0) })

        sentPointCount = currentStroke.count
        lastBatchDate = Date()
    }

    // MARK: - Clear / Undo

    private func clear() {
        strokes = []
        currentStroke = []
        currentStrokeRendered = []
        sentPointCount = 0
        onStrokeBatch?([])
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// Removes the local player's most recent completed stroke, then
    /// re-syncs every device: a clear marker followed by one full-stroke
    /// batch per remaining stroke. There is no dedicated "undo" wire
    /// message, so resending from a known-clean slate keeps every device's
    /// `StrokeSync` buffer exactly in step with the drawer's own canvas.
    private func undo() {
        if !currentStroke.isEmpty {
            currentStroke = []
            currentStrokeRendered = []
            sentPointCount = 0
        } else if !strokes.isEmpty {
            strokes.removeLast()
        } else {
            return
        }

        onStrokeBatch?([])
        for stroke in strokes {
            onStrokeBatch?(stroke.points.map { CodablePoint($0) })
        }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    // MARK: - Types

    /// A completed, normalized (0...1) stroke, identified purely so
    /// `StrokeRenderCache` can memoize its denormalized points across
    /// redraws without depending on array position (which shifts under
    /// `undo()`'s `removeLast()`).
    private struct Stroke: Identifiable {
        let id = UUID()
        var points: [CGPoint]
    }
}

/// Memoizes each stroke/segment's denormalized (canvas-space) points, keyed
/// by stable identity, so a redraw only transforms strokes/segments that are
/// actually new rather than re-mapping every point of every already-drawn
/// polyline on every frame — the cost `DrawingCanvasView.renderedStrokes(
/// canvasSize:)` used to pay unconditionally, up to `StrokeSync
/// .maxSegments` (500) polylines deep on a guesser's screen late in a round.
///
/// A plain reference type, deliberately **not** `@Observable`/
/// `ObservableObject`: mutating it must never trigger a SwiftUI re-render —
/// this is a rendering-time memo the view reads from, not state the view
/// needs to react to — and that also makes it safe to mutate synchronously
/// from inside `Canvas`'s drawing closure (which runs on the main actor
/// during the render pass, outside SwiftUI's normal state-update cycle).
/// Held via `@State` purely so one instance's identity — and thus its cache
/// contents — survives across `DrawingCanvasView` value-type recreations.
private final class StrokeRenderCache {
    private var canvasSize: CGSize = .zero
    private var cache: [UUID: [CGPoint]] = [:]

    /// Returns the cached denormalized points for `id` if present and still
    /// valid for `canvasSize`; otherwise transforms `normalizedPoints` once
    /// and caches the result. A `canvasSize` change (e.g. rotation) first
    /// invalidates every entry, since previously-denormalized points are
    /// only valid for the size they were computed against.
    func denormalized(id: UUID, normalizedPoints: [CGPoint], canvasSize: CGSize) -> [CGPoint] {
        invalidateIfNeeded(for: canvasSize)
        if let cached = cache[id] { return cached }
        let result = normalizedPoints.map { CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height) }
        cache[id] = result
        return result
    }

    /// Seeds the cache for a just-completed stroke with points already
    /// denormalized incrementally during the drag (see
    /// `DrawingCanvasView.dragGesture`), so the very next redraw doesn't
    /// have to re-transform a stroke that only just finished. A no-op if
    /// `canvasSize` no longer matches the cache's current size (a resize
    /// raced the drag ending) — `denormalized(id:normalizedPoints:
    /// canvasSize:)` recomputes correctly on its own in that case.
    func seed(id: UUID, denormalizedPoints: [CGPoint], canvasSize: CGSize) {
        guard canvasSize == self.canvasSize || cache.isEmpty else { return }
        self.canvasSize = canvasSize
        cache[id] = denormalizedPoints
    }

    /// Drops every cached entry — called once a round's strokes/segments
    /// have all been cleared, so ids from a finished round don't linger in
    /// memory indefinitely across a long play session.
    func removeAll() {
        cache.removeAll(keepingCapacity: true)
    }

    private func invalidateIfNeeded(for size: CGSize) {
        guard size != canvasSize else { return }
        canvasSize = size
        cache.removeAll(keepingCapacity: true)
    }
}

// MARK: - Previews

#if DEBUG
private extension DrawingCanvasView {
    static let sampleSegments: [StrokeSync.Segment] = [
        StrokeSync.Segment(points: [
            CodablePoint(x: 0.2, y: 0.2), CodablePoint(x: 0.5, y: 0.3), CodablePoint(x: 0.8, y: 0.2)
        ]),
        StrokeSync.Segment(points: [CodablePoint(x: 0.3, y: 0.5), CodablePoint(x: 0.3, y: 0.8)]),
        StrokeSync.Segment(points: [CodablePoint(x: 0.7, y: 0.5), CodablePoint(x: 0.7, y: 0.8)])
    ]
}

#Preview("Drawer (editable)") {
    DrawingCanvasView(isEditable: true, onStrokeBatch: { _ in })
        .padding()
}

#Preview("Guesser (read-only)") {
    DrawingCanvasView(isEditable: false, segments: DrawingCanvasView.sampleSegments)
        .padding()
}

#Preview("Dark") {
    DrawingCanvasView(isEditable: false, segments: DrawingCanvasView.sampleSegments)
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("XXL Text") {
    DrawingCanvasView(isEditable: true, onStrokeBatch: { _ in })
        .padding()
        .dynamicTypeSize(.accessibility3)
}
#endif
