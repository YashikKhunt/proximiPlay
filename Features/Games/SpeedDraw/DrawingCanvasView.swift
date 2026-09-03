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

    /// Read-only segments to render. Ignored when `isEditable`.
    var segments: [[CodablePoint]] = []

    /// Invoked with each outbound point batch — drawer mode only. An empty
    /// array signals "clear this drawing everywhere."
    var onStrokeBatch: (([CodablePoint]) -> Void)?

    /// Completed strokes so far, normalized (0...1). Drawer mode only.
    @State private var strokes: [[CGPoint]] = []
    /// The in-progress stroke, normalized (0...1). Drawer mode only.
    @State private var currentStroke: [CGPoint] = []
    /// How many points of `currentStroke` have already been included in a
    /// sent batch (as that batch's trailing point, for continuity).
    @State private var sentPointCount: Int = 0
    @State private var lastBatchDate: Date = .distantPast

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

    private func renderedStrokes(canvasSize: CGSize) -> [[CGPoint]] {
        if isEditable {
            var all = strokes
            if !currentStroke.isEmpty { all.append(currentStroke) }
            return all.map { denormalize($0, in: canvasSize) }
        } else {
            return segments.map { segment in
                denormalize(segment.map(\.cgPoint), in: canvasSize)
            }
        }
    }

    private func denormalize(_ points: [CGPoint], in size: CGSize) -> [CGPoint] {
        points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
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
                sendPendingBatchIfDue()
            }
            .onEnded { _ in
                guard isEditable else { return }
                sendPendingBatchIfDue(force: true)
                if !currentStroke.isEmpty {
                    strokes.append(currentStroke)
                }
                currentStroke = []
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
            sentPointCount = 0
        } else if !strokes.isEmpty {
            strokes.removeLast()
        } else {
            return
        }

        onStrokeBatch?([])
        for stroke in strokes {
            onStrokeBatch?(stroke.map { CodablePoint($0) })
        }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

// MARK: - Previews

#if DEBUG
private extension DrawingCanvasView {
    static let sampleSegments: [[CodablePoint]] = [
        [CodablePoint(x: 0.2, y: 0.2), CodablePoint(x: 0.5, y: 0.3), CodablePoint(x: 0.8, y: 0.2)],
        [CodablePoint(x: 0.3, y: 0.5), CodablePoint(x: 0.3, y: 0.8)],
        [CodablePoint(x: 0.7, y: 0.5), CodablePoint(x: 0.7, y: 0.8)]
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
