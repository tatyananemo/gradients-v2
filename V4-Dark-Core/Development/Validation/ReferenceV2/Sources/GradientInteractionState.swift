import SwiftUI

struct ProgressIncrement {
    let amount: CGFloat
    let startTime: TimeInterval
}

final class TouchRuntime: ObservableObject {
    var lastProgressReadTime: TimeInterval = -10
    var lastWaterUpdateTime: TimeInterval = -10
    var smoothedWaterPoint: CGPoint?
    var lastReadPoint: CGPoint?
    var lastProgressAdvanceTime: TimeInterval?

    func resetGesture() {
        smoothedWaterPoint = nil
        lastWaterUpdateTime = -10
        lastReadPoint = nil
    }

    func resetAll() {
        lastProgressAdvanceTime = nil
        smoothedWaterPoint = nil
        lastProgressReadTime = -10
        lastWaterUpdateTime = -10
        lastReadPoint = nil
    }
}

struct InteractionTrailSegment {
    let from: CGPoint
    let to: CGPoint
    let startTime: TimeInterval
    let time: TimeInterval
    let distance: CGFloat
    var releaseTime: TimeInterval? = nil
}
