// Behavior extracted from the approved swipe V2. No UIKit/SwiftUI dependencies.
// Event timestamps are supplied by the host, in one monotonic reference domain.
import Foundation
import CoreGraphics



struct SessionProgressIncrement {
    let amount: CGFloat
    let startTime: TimeInterval
}

final class SessionTouchRuntime {
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

struct SessionTrailSegment {
    let from: CGPoint
    let to: CGPoint
    let startTime: TimeInterval
    let time: TimeInterval
    let distance: CGFloat
    var releaseTime: TimeInterval? = nil
}

/// Own on the UI thread (or one serial executor). Rendering never mutates input state.
public final class GradientSession {
    private let progressAnimationDuration: TimeInterval = 0.48
    private let progressStep: CGFloat = 0.013
    private let maximumProgressRate: CGFloat = 0.0585
    let touchRuntime = SessionTouchRuntime()
    var progress: CGFloat = 0
    var progressIncrements: [SessionProgressIncrement] = []
    var startTime: TimeInterval = 0
    var waterTouchPoint: CGPoint?
    var waterTouchPreviousPoint: CGPoint?
    var waterTouchLastMove: TimeInterval = -10
    var waterTouchIsActive = false
    var idleWaveStartTime: TimeInterval = 0
    var waterDragEnergy: CGFloat = 0
    var interactionTrail: [SessionTrailSegment] = []
    public private(set) var settingsVisible = false
    public var targetProgress: CGFloat { progress }

    public init(at time: TimeInterval, initialProgress: CGFloat = 0) {
        reset(at: time)
        progress = min(max(initialProgress, 0), 1)
    }
    public func setSettingsVisible(_ visible: Bool, at time: TimeInterval) {
        guard visible != settingsVisible else { return }
        settingsVisible = visible
        idleWaveStartTime = time + 0.42
    }
    public func reset(at now: TimeInterval) {
        progress = 0
        progressIncrements.removeAll(keepingCapacity: true)
        startTime = now
        waterTouchPoint = nil
        waterTouchPreviousPoint = nil
        waterTouchLastMove = -10
        waterTouchIsActive = false
        idleWaveStartTime = now
        waterDragEnergy = 0
        interactionTrail.removeAll(keepingCapacity: true)
        touchRuntime.resetAll()
    
    }
    public func dragChanged(to location: CGPoint, at time: TimeInterval, size: CGSize) {
        let gestureNow = time
        if !waterTouchIsActive || waterTouchPoint == nil {
            waterTouchPoint = location
            waterTouchPreviousPoint = location
            touchRuntime.smoothedWaterPoint = location
            waterTouchLastMove = gestureNow
            waterTouchIsActive = true
            waterDragEnergy = 0
            touchRuntime.lastWaterUpdateTime = gestureNow
        }

        let previousWaterPoint = waterTouchPoint ?? location
        // Keep the existing energy envelope without delaying the touch position.
        let previousSmoothedWaterPoint = touchRuntime.smoothedWaterPoint ?? location
        let waterDeltaX = location.x - previousSmoothedWaterPoint.x
        let waterDeltaY = location.y - previousSmoothedWaterPoint.y
        let waterDistance = sqrt(waterDeltaX * waterDeltaX + waterDeltaY * waterDeltaY)
        let shouldUpdateWater =
            waterDistance > 0.18 ||
            gestureNow - touchRuntime.lastWaterUpdateTime > 1.0 / 60.0

        if shouldUpdateWater {
            let waterSmoothing = CGFloat(0.36)
            let smoothedWaterPoint = CGPoint(
                x: previousSmoothedWaterPoint.x + waterDeltaX * waterSmoothing,
                y: previousSmoothedWaterPoint.y + waterDeltaY * waterSmoothing
            )
            let waterTravel = min(waterDistance / max(max(size.width, size.height), 1), 1)
            let targetWaterEnergy = min(max(waterTravel * 6.2, 0.0), 0.72)

            waterTouchPreviousPoint = previousWaterPoint
            waterTouchPoint = location
            touchRuntime.smoothedWaterPoint = smoothedWaterPoint
            waterTouchLastMove = gestureNow
            waterTouchIsActive = true
            waterDragEnergy = min(max(waterDragEnergy * 0.88 + targetWaterEnergy * 0.12, 0.0), 0.80)

            touchRuntime.lastWaterUpdateTime = gestureNow

        }

        recordInteractionTrail(from: previousWaterPoint, to: location, at: gestureNow)

        let clampedReadPoint = CGPoint(
            x: min(max(location.x, 0), max(size.width - 0.1, 0)),
            y: min(max(location.y, 0), max(size.height - 0.1, 0))
        )
        let previousReadPoint = touchRuntime.lastReadPoint
        let readInterval = max(0, gestureNow - touchRuntime.lastProgressReadTime)
        touchRuntime.lastReadPoint = clampedReadPoint
        touchRuntime.lastProgressReadTime = gestureNow

        if let previousReadPoint, readInterval > 0 {
            let distance = hypot(
                clampedReadPoint.x - previousReadPoint.x,
                clampedReadPoint.y - previousReadPoint.y
            )
            // Credit motion continuously, with only a modest speed boost.
            // A gap in input must not bank time for the next movement.
            let speed = distance / (max(min(size.width, size.height), 1) * CGFloat(readInterval))
            let movement = min(speed / 0.10, 1)
            let speedBoost = speed / (1 + speed)
            // Extra gain fades in only above two screen widths per second.
            let fastSwipeFraction = min(max((speed - 2) / 2, 0), 1)
            let fastSwipeBoost = fastSwipeFraction * fastSwipeFraction * (3 - 2 * fastSwipeFraction)
            let amount = progressStep * (2 + speedBoost + 1.5 * fastSwipeBoost) * movement * CGFloat(min(readInterval, 0.05))
            advanceProgress(by: amount, at: gestureNow)
        } else if previousReadPoint == nil {
            advanceProgress(by: progressStep, at: gestureNow)
        }
    }
    public func dragEnded(at time: TimeInterval) {
        let gestureNow = time
        waterTouchIsActive = false
        // Retain each release time across a new drag, so old
        // light cannot brighten again when the finger returns.
        for index in interactionTrail.indices where interactionTrail[index].releaseTime == nil {
            interactionTrail[index].releaseTime = gestureNow
        }
        idleWaveStartTime = gestureNow + 0.42
        waterTouchLastMove = gestureNow
        touchRuntime.resetGesture()
    }
    func interpolatedProgress(at time: TimeInterval) -> CGFloat {
        // Each increment completes on its own clock; new input must not restart
        // the easing of progress already in flight or build a release-time catch-up.
        let pendingProgress = progressIncrements.reduce(CGFloat(0)) { pending, increment in
            let raw = (time - increment.startTime) / progressAnimationDuration
            let t = min(max(CGFloat(raw), 0), 1)
            let eased = t * t * t * (t * (t * 6 - 15) + 10)
            return pending + increment.amount * (1 - eased)
        }

        return max(0, progress - pendingProgress)
    }
    func advanceProgress(by amount: CGFloat, at time: TimeInterval) {
        // Share the rate limit across gesture boundaries, so rapid short swipes
        // cannot bypass it through their initial touch credit.
        let interval = touchRuntime.lastProgressAdvanceTime.map { max(0, time - $0) }
        touchRuntime.lastProgressAdvanceTime = time
        let allowedAmount = min(progressStep, CGFloat(interval ?? Double(progressStep / maximumProgressRate)) * maximumProgressRate)
        let targetProgress = min(progress + min(amount, allowedAmount), 1.0)

        guard targetProgress > progress else {
            return
        }

        progressIncrements.removeAll { time - $0.startTime >= progressAnimationDuration }
        progressIncrements.append(SessionProgressIncrement(amount: targetProgress - progress, startTime: time))
        progress = targetProgress
    }
    func recordInteractionTrail(from: CGPoint, to: CGPoint, at time: TimeInterval) {
        let distance = hypot(to.x - from.x, to.y - from.y)
        guard distance > 0.01 else { return }
        interactionTrail.removeAll { time - $0.time >= 1.8 }
        if let last = interactionTrail.last,
           last.releaseTime == nil,
           time - last.startTime < 0.065,
           last.to == from,
           (last.to.x - last.from.x) * (to.x - from.x) +
           (last.to.y - last.from.y) * (to.y - from.y) >= 0 {
            interactionTrail[interactionTrail.count - 1] = SessionTrailSegment(
                from: last.from, to: to, startTime: last.startTime, time: time,
                distance: last.distance + distance
            )
        } else {
            interactionTrail.append(SessionTrailSegment(
                from: from, to: to, startTime: time, time: time, distance: distance
            ))
        }
        if interactionTrail.count > 40 {
            interactionTrail.removeFirst(interactionTrail.count - 40)
        }
    }
    func interactionTrailArguments(at time: TimeInterval, origin: CGPoint, size: CGSize) -> [Float] {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        return interactionTrail.flatMap { segment -> [Float] in
            let age = max(0, time - segment.time)
            guard age < 1.8 else { return [] }
            // Match the earlier touch-light release: 0.30 s delay, 0.82 s fade.
            // Active samples keep their original age, geometry and accumulation.
            let releaseProgress = segment.releaseTime.map {
                min(max((time - $0 - 0.30) / 0.82, 0), 1)
            } ?? 0
            let releaseFade = 1 - releaseProgress * releaseProgress * (3 - 2 * releaseProgress)
            return [
                Float((segment.from.x + origin.x) / width), Float((segment.from.y + origin.y) / height),
                Float((segment.to.x + origin.x) / width), Float((segment.to.y + origin.y) / height),
                Float(age), Float(min(segment.distance / (width * 0.125), 1.8)) * Float(releaseFade)
            ]
        }
    }
    public func frame(at now: TimeInterval, size: CGSize, origin: CGPoint = .zero,
                      dark: Bool, yellow: Bool) -> GradientRenderFrame {
        let elapsed = now - startTime
        let age = max(0, now - waterTouchLastMove)
        let fadeProgress = min(max((CGFloat(age) - 0.30) / 0.82, 0), 1)
        let fadeEase = fadeProgress * fadeProgress * (3 - 2 * fadeProgress)
        let fade = waterTouchPoint == nil ? CGFloat(0) : (waterTouchIsActive ? CGFloat(1) : 1 - fadeEase)
        let pulse = fade * fade * (3 - 2 * fade)
        let idleActivity: CGFloat = waterTouchIsActive || settingsVisible ? 0 : 1
        let idleElapsed = idleActivity == 0 ? 0 : max(0, now - idleWaveStartTime)
        let rendered = interpolatedProgress(at: now)
        let point = waterTouchPoint ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let previous = waterTouchPreviousPoint ?? waterTouchPoint ?? point
        let history = interactionTrailArguments(at: now, origin: origin, size: size)
        let uniforms: [Float] = [Float(size.width), Float(size.height), Float(rendered), 0,
            Float((point.x + origin.x) / max(size.width, 1)), Float((point.y + origin.y) / max(size.height, 1)),
            Float((previous.x + origin.x) / max(size.width, 1)), Float((previous.y + origin.y) / max(size.height, 1)), 0, 0,
            Float(elapsed), 0.150, 1, 1, 1, 1, 1, 1, 0, 0.62, 1, 0.74, 2,
            dark ? 1 : 0, yellow ? 3 : 0, Float(idleActivity), Float(idleElapsed), Float(history.count)]
        return GradientRenderFrame(time: now, uniforms: uniforms, history: history,
            distortion: Float(min(max(waterDragEnergy * 1.45, 0), 1) * pulse),
            progress: progress, dark: dark, yellow: yellow)
    }
}

public struct GradientRenderFrame {
    public let time: TimeInterval
    public let uniforms: [Float]
    public let history: [Float]
    public let distortion: Float
    public let progress: CGFloat
    public let dark: Bool
    public let yellow: Bool
}
