//
//  CodablePoint.swift
//  proximiPlay
//

import Foundation

/// A `Codable` wrapper around `CGPoint`, since `CGPoint` does not conform to `Codable`.
struct CodablePoint: Codable, Sendable, Hashable {
    var x: CGFloat
    var y: CGFloat

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }
}
