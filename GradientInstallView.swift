import SwiftUI
import Metal
import UIKit

struct ContentView: View {
    var body: some View {
        GradientInstallView()
    }
}

enum GradientAppTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light:
            return "Светлая"
        case .dark:
            return "Тёмная"
        }
    }

    var shaderValue: CGFloat {
        self == .dark ? 1 : 0
    }
}

enum GradientColorPreset: String, CaseIterable, Identifiable {
    case blue
    case yellow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue:
            return "Синий"
        case .yellow:
            return "Жёлтый"
        }
    }

    var shaderIndex: CGFloat {
        switch self {
        case .blue:
            return 0
        case .yellow:
            return 3
        }
    }

    var swatch: Color {
        switch self {
        case .blue:
            return Color(red: 0.26, green: 0.55, blue: 0.98)
        case .yellow:
            return Color(red: 1.0, green: 0.7, blue: 0.0)
        }
    }

    var darkMaskTint: Color {
        switch self {
        case .blue:
            return Color(red: 0.008, green: 0.036, blue: 0.115)
        case .yellow:
            return Color(red: 0.105, green: 0.060, blue: 0.008)
        }
    }
}

struct GradientInstallView: View {
    private let launchPreviewProgress: CGFloat?
    private let launchPreviewTheme: GradientAppTheme?
    private let launchPreviewColor: GradientColorPreset?
    private let progressAnimationDuration: TimeInterval = 0.48
    private let progressStep: CGFloat = 0.013
    private let maximumProgressRate: CGFloat = 0.0585

    @StateObject private var touchRuntime = TouchRuntime()
    @StateObject private var captionProbe = V2CaptionProbe()
    @State private var captionFrame: CGRect = .zero

    @State private var progress: CGFloat = 0.0
    @State private var progressIncrements: [ProgressIncrement] = []
    @State private var startTime = Date().timeIntervalSinceReferenceDate
    @State private var waterTouchPoint: CGPoint?
    @State private var waterTouchPreviousPoint: CGPoint?
    @State private var waterTouchLastMove: TimeInterval = -10
    @State private var waterTouchIsActive = false
    @State private var idleWaveStartTime = Date().timeIntervalSinceReferenceDate
    @State private var waterDragEnergy: CGFloat = 0.0
    @State private var interactionTrail: [InteractionTrailSegment] = []

    @State private var showSettings = false
    @AppStorage("gradientsV2.theme") private var appTheme: GradientAppTheme = .light
    @State private var gradientColor: GradientColorPreset = .blue

    private let progressSpeed: CGFloat = 0.150
    private let fillGain: CGFloat = 1.00
    private let waveStrength: CGFloat = 1.0
    private let waveSpread: CGFloat = 1.0
    private let topBloom: CGFloat = 1.0
    private let whiteCore: CGFloat = 1.0
    private let blueDepth: CGFloat = 1.0
    private let shockStrength: CGFloat = 0.62
    private let shockInteraction: CGFloat = 1.0
    private let shockTrail: CGFloat = 0.74
    private let waveCount: Int = 2
    private let waterIntensity: CGFloat = 0.94
    private let waterScale: CGFloat = 0.84
    private let waterSpeed: CGFloat = 0.72

    init() {
        let previewProgress = Self.previewProgressFromLaunchArguments()
        let previewTheme = Self.previewThemeFromLaunchArguments()
        let previewColor = Self.previewColorFromLaunchArguments()

        launchPreviewProgress = previewProgress
        launchPreviewTheme = previewTheme
        launchPreviewColor = previewColor
        _progress = State(initialValue: previewProgress ?? 0.0)
        _gradientColor = State(initialValue: previewColor ?? .blue)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let elapsed = now - startTime
            let waterTouchAge = max(0, now - waterTouchLastMove)
            let waterFadeDelay = CGFloat(0.30)
            let waterFadeDuration = CGFloat(0.82)
            let waterFadeProgress = min(max((CGFloat(waterTouchAge) - waterFadeDelay) / waterFadeDuration, 0), 1)
            let waterFadeEase = waterFadeProgress * waterFadeProgress * (3 - 2 * waterFadeProgress)
            let waterTouchFade = waterTouchPoint == nil
                ? CGFloat(0)
                : (waterTouchIsActive ? CGFloat(1) : 1 - waterFadeEase)
            let waterTouchPulse = waterTouchFade * waterTouchFade * (3 - 2 * waterTouchFade)
            let idleWaveActivity: CGFloat = waterTouchIsActive || showSettings ? 0 : 1
            let idleWaveElapsed = idleWaveActivity == 0 ? 0 : max(0, now - idleWaveStartTime)
            let renderedProgress = interpolatedProgress(at: now)
            let counterProgress = progress
            let trailDistortionStrength = min(max(waterDragEnergy * 1.45, 0), 1) * waterTouchPulse
            let isDarkTheme = appTheme == .dark
            let percentTextColor = isDarkTheme
                ? Color(red: 0.92, green: 0.95, blue: 1.0)
                : Color(
                    red: 0.18 - counterProgress * 0.02,
                    green: 0.18 - counterProgress * 0.02,
                    blue: 0.20
                )
            let bodyTextColor = isDarkTheme
                ? Color(red: 0.86, green: 0.91, blue: 0.98)
                : Color(red: 0.20, green: 0.20, blue: 0.20)
            let controlForeground = isDarkTheme ? Color.white.opacity(0.92) : Color.gray.opacity(0.88)
            GeometryReader { geo in
                let safeHeight = max(geo.size.height, 1)
                let globalFrame = geo.frame(in: .global)
                let screenBounds = UIScreen.main.bounds
                let gradientLayerSize = screenBounds.size
                let gradientLayerCenter = CGPoint(
                    x: screenBounds.midX - globalFrame.minX,
                    y: screenBounds.midY - globalFrame.minY
                )
                let waterPoint = waterTouchPoint ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let previousWaterPoint = waterTouchPreviousPoint ?? waterTouchPoint ?? waterPoint
                let centerMaskFlow = 0.62 + renderedProgress * 0.30
                let centerMaskBreath = 1 + CGFloat(sin(elapsed * 1.18 + Double(renderedProgress * 5.0))) * 0.025
                let v2Key = appTheme.rawValue + ":" + gradientColor.rawValue
                let v2History = interactionTrailArguments(at: now, origin: globalFrame.origin, size: gradientLayerSize)
                let v2Uniforms: [Float] = [Float(gradientLayerSize.width),Float(gradientLayerSize.height),Float(renderedProgress),0,
                    Float((waterPoint.x+globalFrame.minX)/max(gradientLayerSize.width,1)),Float((waterPoint.y+globalFrame.minY)/max(gradientLayerSize.height,1)),
                    Float((previousWaterPoint.x+globalFrame.minX)/max(gradientLayerSize.width,1)),Float((previousWaterPoint.y+globalFrame.minY)/max(gradientLayerSize.height,1)),0,0,
                    Float(elapsed),Float(progressSpeed),Float(fillGain),Float(waveStrength),Float(waveSpread),Float(topBloom),Float(whiteCore),Float(blueDepth),0,
                    Float(shockStrength),Float(shockInteraction),Float(shockTrail),Float(waveCount),Float(appTheme.shaderValue),Float(gradientColor.shaderIndex),Float(idleWaveActivity),Float(idleWaveElapsed),Float(v2History.count)]
                ZStack {
                    if isDarkTheme {
                        Color.black
                            .frame(width: geo.size.width, height: geo.size.height)
                            .allowsHitTesting(false)
                    }

                    ZStack {
                            Rectangle()
                            
                                .colorEffect(
                                    ShaderLibrary.gradientsV2Background(
                                        .float2(gradientLayerSize),
                                        .float(renderedProgress),
                                        .float(0),
                                        .float2(
                                            (waterPoint.x + globalFrame.minX) / max(gradientLayerSize.width, 1),
                                            (waterPoint.y + globalFrame.minY) / max(gradientLayerSize.height, 1)
                                        ),
                                        .float2(
                                            (previousWaterPoint.x + globalFrame.minX) / max(gradientLayerSize.width, 1),
                                            (previousWaterPoint.y + globalFrame.minY) / max(gradientLayerSize.height, 1)
                                        ),
                                        .float(0),
                                        .float(0),
                                        .float(elapsed),
                                        .float(progressSpeed),
                                        .float(fillGain),
                                        .float(waveStrength),
                                        .float(waveSpread),
                                        .float(topBloom),
                                        .float(whiteCore),
                                        .float(blueDepth),
                                        .float(0),
                                        .float(shockStrength),
                                        .float(shockInteraction),
                                        .float(shockTrail),
                                        .float(Float(waveCount)),
                                        .float(appTheme.shaderValue),
                                        .float(gradientColor.shaderIndex),
                                        .float(idleWaveActivity),
                                        .float(idleWaveElapsed),
                                        .floatArray(v2History)
                                    )
                                )
                                .optionalDistortion(
                                    trailDistortionStrength > 0.002,
                                    ShaderLibrary.gradientTrailDistortion(
                                        .float2(geo.size),
                                        .float2(
                                            waterPoint.x / max(geo.size.width, 1),
                                            waterPoint.y / safeHeight
                                        ),
                                        .float2(
                                            previousWaterPoint.x / max(geo.size.width, 1),
                                            previousWaterPoint.y / safeHeight
                                        ),
                                        .float(trailDistortionStrength),
                                        .float(elapsed)
                                    ),
                                    maxSampleOffset: CGSize(width: 12, height: 12)
                                )
                                .frame(width: gradientLayerSize.width, height: gradientLayerSize.height)

                    }
                        .frame(width: gradientLayerSize.width, height: gradientLayerSize.height)
                        .clipped()
                        .position(x: gradientLayerCenter.x, y: gradientLayerCenter.y)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .allowsHitTesting(false)

                    V2CaptionBackdrop(dark:isDarkTheme,yellow:gradientColor == .yellow,
                        activation:captionProbe.key == v2Key ? captionProbe.activation:0)
                        .frame(width:geo.size.width,height:geo.size.height).zIndex(1)

                    VStack {
                        HStack {
                            Button {
                                reset(now: now)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(isDarkTheme ? Color.white.opacity(0.78) : .gray)
                                    .frame(width: 32, height: 32)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Сбросить")

                            Spacer()

                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(renderedProgress > 0.42 || isDarkTheme ? Color.white.opacity(0.94) : controlForeground)
                                    .frame(width: 34, height: 34)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(
                                        Circle().stroke(.white.opacity(isDarkTheme ? 0.24 : 0.38), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Настройки")
                        }
                        .padding(.top, 56)
                        .padding(.horizontal, 24)

                        Spacer()

                        ZStack {
                            if isDarkTheme && (gradientColor == .blue || gradientColor == .yellow) {
                                PercentCenterMask(
                                    isDarkTheme: isDarkTheme,
                                    gradientColor: gradientColor,
                                    centerMaskFlow: centerMaskFlow,
                                    centerMaskBreath: centerMaskBreath,
                                    counterProgress: renderedProgress,
                                    renderedProgress: renderedProgress,
                                    elapsed: elapsed
                                )
                            }

                            Text("\(Int(round(counterProgress * 100)))%")
                                .font(.system(size: 64, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(percentTextColor)
                                .shadow(
                                    color: isDarkTheme ? Color.black.opacity(0.34) : Color.cyan.opacity(0.04 + counterProgress * 0.16),
                                    radius: isDarkTheme ? 16 : 2 + counterProgress * 9,
                                    x: 0,
                                    y: 0
                                )
                                .shadow(
                                    color: isDarkTheme ? Color.black.opacity(0.18) : Color.white.opacity(counterProgress > 0.55 ? 0.16 : 0.04),
                                    radius: isDarkTheme ? 8 : counterProgress > 0.55 ? 5 : 1,
                                    x: 0,
                                    y: 0
                                )
                        }
                        .frame(width: geo.size.width, height: 260, alignment: .center)

                        Spacer()

                        Text("Устанавливаем защищенное соединение. Водите пальцем в разных частях экрана")
                            .font(.system(size: 17, weight: .medium))
                            .multilineTextAlignment(.center)
                            .lineSpacing(1.2)
                            .foregroundStyle(bodyTextColor)
                            .padding(.horizontal, 34)
                            .frame(width: geo.size.width)
                            .background { GeometryReader { proxy in
                                Color.clear.preference(key:V2CaptionFrameKey.self,value:proxy.frame(in:.global))
                            }}
                            .padding(.bottom, 82)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .zIndex(10)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .environment(\.v2MaskUniforms, v2Uniforms)
                .onPreferenceChange(V2CaptionFrameKey.self) { captionFrame = $0 }
                .onChange(of: elapsed,initial:true) { _,_ in
                    captionProbe.sample(uniforms:v2Uniforms,history:v2History,frame:captionFrame,key:v2Key,dark:isDarkTheme,yellow:gradientColor == .yellow)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let gestureNow = Date().timeIntervalSinceReferenceDate
                            if !waterTouchIsActive || waterTouchPoint == nil {
                                waterTouchPoint = value.location
                                waterTouchPreviousPoint = value.location
                                touchRuntime.smoothedWaterPoint = value.location
                                waterTouchLastMove = gestureNow
                                waterTouchIsActive = true
                                waterDragEnergy = 0
                                touchRuntime.lastWaterUpdateTime = gestureNow
                            }

                            let previousWaterPoint = waterTouchPoint ?? value.startLocation
                            // Keep the existing energy envelope without delaying the touch position.
                            let previousSmoothedWaterPoint = touchRuntime.smoothedWaterPoint ?? value.startLocation
                            let waterDeltaX = value.location.x - previousSmoothedWaterPoint.x
                            let waterDeltaY = value.location.y - previousSmoothedWaterPoint.y
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
                                let waterTravel = min(waterDistance / max(max(geo.size.width, geo.size.height), 1), 1)
                                let targetWaterEnergy = min(max(waterTravel * 6.2, 0.0), 0.72)

                                waterTouchPreviousPoint = previousWaterPoint
                                waterTouchPoint = value.location
                                touchRuntime.smoothedWaterPoint = smoothedWaterPoint
                                waterTouchLastMove = gestureNow
                                waterTouchIsActive = true
                                waterDragEnergy = min(max(waterDragEnergy * 0.88 + targetWaterEnergy * 0.12, 0.0), 0.80)

                                touchRuntime.lastWaterUpdateTime = gestureNow

                            }

                            recordInteractionTrail(from: previousWaterPoint, to: value.location, at: gestureNow)

                            let clampedReadPoint = CGPoint(
                                x: min(max(value.location.x, 0), max(geo.size.width - 0.1, 0)),
                                y: min(max(value.location.y, 0), max(geo.size.height - 0.1, 0))
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
                                let speed = distance / (max(min(geo.size.width, geo.size.height), 1) * CGFloat(readInterval))
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
                        .onEnded { value in
                            let gestureNow = Date().timeIntervalSinceReferenceDate
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
                )
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .onAppear {
            if let launchPreviewTheme {
                appTheme = launchPreviewTheme
            }
            if let launchPreviewColor {
                gradientColor = launchPreviewColor
            }

            guard launchPreviewProgress == nil else {
                return
            }

            reset(now: Date().timeIntervalSinceReferenceDate, animated: false)
        }
        .task {
            guard let launchPreviewProgress else {
                return
            }

            await Task.yield()
            progress = launchPreviewProgress
            progressIncrements.removeAll(keepingCapacity: true)
            appTheme = launchPreviewTheme ?? .light
            gradientColor = launchPreviewColor ?? .blue
            showSettings = false
        }
        .onChange(of: showSettings) { _, _ in
            idleWaveStartTime = Date().timeIntervalSinceReferenceDate + 0.42
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(appTheme: $appTheme, gradientColor: $gradientColor)
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.hidden)
            .presentationBackground(appTheme == .dark ? Color(red: 0.04, green: 0.05, blue: 0.08) : Color.white)
            .preferredColorScheme(appTheme == .dark ? .dark : .light)
        }
    }

    private func reset(now: TimeInterval, animated: Bool = true) {
        let resetProgress = {
            progress = 0
            progressIncrements.removeAll(keepingCapacity: true)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                resetProgress()
            }
        } else {
            resetProgress()
        }

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

    private func interpolatedProgress(at time: TimeInterval) -> CGFloat {
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

    private func advanceProgress(by amount: CGFloat, at time: TimeInterval) {
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
        progressIncrements.append(ProgressIncrement(amount: targetProgress - progress, startTime: time))
        progress = targetProgress
    }

    private func recordInteractionTrail(from: CGPoint, to: CGPoint, at time: TimeInterval) {
        let distance = hypot(to.x - from.x, to.y - from.y)
        guard distance > 0.01 else { return }
        interactionTrail.removeAll { time - $0.time >= 1.8 }
        if let last = interactionTrail.last,
           last.releaseTime == nil,
           time - last.startTime < 0.065,
           last.to == from,
           (last.to.x - last.from.x) * (to.x - from.x) +
           (last.to.y - last.from.y) * (to.y - from.y) >= 0 {
            interactionTrail[interactionTrail.count - 1] = InteractionTrailSegment(
                from: last.from, to: to, startTime: last.startTime, time: time,
                distance: last.distance + distance
            )
        } else {
            interactionTrail.append(InteractionTrailSegment(
                from: from, to: to, startTime: time, time: time, distance: distance
            ))
        }
        if interactionTrail.count > 40 {
            interactionTrail.removeFirst(interactionTrail.count - 40)
        }
    }

    private func interactionTrailArguments(at time: TimeInterval, origin: CGPoint, size: CGSize) -> [Float] {
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

    private static func previewProgressFromLaunchArguments() -> CGFloat? {
        guard ProcessInfo.processInfo.environment["ENABLE_PREVIEW_PROGRESS"] == "1" else {
            return nil
        }

        let arguments = ProcessInfo.processInfo.arguments

        guard
            let flagIndex = arguments.firstIndex(of: "-PreviewProgress"),
            arguments.indices.contains(flagIndex + 1),
            let value = Double(arguments[flagIndex + 1])
        else {
            return nil
        }

        return CGFloat(min(max(value, 0), 1))
    }

    private static func previewThemeFromLaunchArguments() -> GradientAppTheme? {
        guard ProcessInfo.processInfo.environment["ENABLE_PREVIEW_PROGRESS"] == "1" else {
            return nil
        }

        return previewArgument(named: "-PreviewTheme").flatMap(GradientAppTheme.init(rawValue:))
    }

    private static func previewColorFromLaunchArguments() -> GradientColorPreset? {
        guard ProcessInfo.processInfo.environment["ENABLE_PREVIEW_PROGRESS"] == "1" else {
            return nil
        }

        return previewArgument(named: "-PreviewColor").flatMap(GradientColorPreset.init(rawValue:))
    }

    private static func previewArgument(named flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let flagIndex = arguments.firstIndex(of: flag),
            arguments.indices.contains(flagIndex + 1)
        else {
            return nil
        }

        return arguments[flagIndex + 1]
    }
}

private struct ProgressIncrement {
    let amount: CGFloat
    let startTime: TimeInterval
}

private final class TouchRuntime: ObservableObject {
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

private struct InteractionTrailSegment {
    let from: CGPoint
    let to: CGPoint
    let startTime: TimeInterval
    let time: TimeInterval
    let distance: CGFloat
    var releaseTime: TimeInterval? = nil
}

private struct PercentCenterMask: View {
    let isDarkTheme: Bool
    let gradientColor: GradientColorPreset
    let centerMaskFlow: CGFloat
    let centerMaskBreath: CGFloat
    let counterProgress: CGFloat
    let renderedProgress: CGFloat
    let elapsed: TimeInterval

    var body: some View {
        if isDarkTheme {
            ZStack {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.black.opacity(0.86),
                                Color.black.opacity(0.72 + centerMaskFlow * 0.10),
                                gradientColor.darkMaskTint.opacity(0.34 + renderedProgress * 0.12),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 12,
                            endRadius: 136
                        )
                    )
                    .frame(
                        width: 252 + counterProgress * 20,
                        height: 118 + counterProgress * 8
                    )
                    .scaleEffect(x: darkBlobScaleX, y: darkBlobScaleY)
                    .offset(x: darkBlobDriftX, y: darkBlobDriftY)
                    .blur(radius: 38)
                    .modifier(V2CounterExclusion(enabled: gradientColor == .yellow))

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                gradientColor.darkMaskTint.opacity(0.46),
                                Color.black.opacity(0.46),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 106
                        )
                    )
                    .frame(
                        width: 204 + counterProgress * 14,
                        height: 92 + counterProgress * 6
                    )
                    .scaleEffect(x: darkInnerBlobScaleX, y: darkInnerBlobScaleY)
                    .offset(x: -darkBlobDriftX * 0.62, y: darkBlobDriftY * 0.48)
                    .blur(radius: 30)
                    .modifier(V2CounterExclusion(enabled: gradientColor == .yellow))
                    .blendMode(.multiply)

                Ellipse()
                    .fill(gradientColor.darkMaskTint.opacity(0.22))
                    .frame(
                        width: 226 + counterProgress * 18,
                        height: 78 + counterProgress * 5
                    )
                    .scaleEffect(x: darkRibbonScaleX, y: darkRibbonScaleY)
                    .offset(x: darkBlobDriftX * 0.34, y: -4 + darkBlobDriftY * 0.34)
                    .blur(radius: 42)
                    .modifier(V2CounterExclusion(enabled: gradientColor == .yellow))
                    .blendMode(.screen)
            }
            .scaleEffect(centerMaskBreath)
            .offset(y: -18)
            .allowsHitTesting(false)
        }
    }

    private var darkBlobDriftX: CGFloat {
        CGFloat(sin(elapsed * 0.34 + 0.7)) * 10
    }

    private var darkBlobDriftY: CGFloat {
        CGFloat(cos(elapsed * 0.27 + 1.3)) * 5
    }

    private var darkBlobScaleX: CGFloat {
        1.04 + CGFloat(sin(elapsed * 0.22)) * 0.055
    }

    private var darkBlobScaleY: CGFloat {
        0.94 + CGFloat(cos(elapsed * 0.19 + 0.8)) * 0.045
    }

    private var darkInnerBlobScaleX: CGFloat {
        0.98 + CGFloat(cos(elapsed * 0.25 + 2.2)) * 0.050
    }

    private var darkInnerBlobScaleY: CGFloat {
        1.02 + CGFloat(sin(elapsed * 0.21 + 1.8)) * 0.050
    }

    private var darkRibbonScaleX: CGFloat {
        1.06 + CGFloat(cos(elapsed * 0.18 + 0.4)) * 0.060
    }

    private var darkRibbonScaleY: CGFloat {
        0.82 + CGFloat(sin(elapsed * 0.24 + 2.7)) * 0.040
    }

}

struct SettingsSheet: View {
    @Binding var appTheme: GradientAppTheme
    @Binding var gradientColor: GradientColorPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Настройки")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Text("Тема")
                    .font(.system(size: 13, weight: .medium))
                V2ThemePicker(selection: $appTheme)
                    .frame(height: 32)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Цвет градиента")
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 9) {
                    ForEach(GradientColorPreset.allCases) { colorPreset in
                        Button {
                            gradientColor = colorPreset
                        } label: {
                            VStack(spacing: 5) {
                                Circle()
                                    .fill(colorPreset.swatch)
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle()
                                            .stroke(.white.opacity(gradientColor == colorPreset ? 0.95 : 0.28), lineWidth: gradientColor == colorPreset ? 3 : 1)
                                    )
                                    .shadow(color: colorPreset.swatch.opacity(0.30), radius: 8, x: 0, y: 3)

                                Text(colorPreset.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        }
        .padding(.top, 34)
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
    }
}

private struct V2ThemePicker: UIViewRepresentable {
    @Binding var selection: GradientAppTheme

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: GradientAppTheme.allCases.map(\.title))
        control.accessibilityLabel = "Тема"
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = selection == .light ? 0 : 1
        // Live background updates must not reset a segment while a finger is tracking it.
        if !control.isTracking && control.selectedSegmentIndex != index {
            control.selectedSegmentIndex = index
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<GradientAppTheme>
        init(selection: Binding<GradientAppTheme>) { self.selection = selection }
        @objc func changed(_ control: UISegmentedControl) {
            selection.wrappedValue = control.selectedSegmentIndex == 0 ? .light : .dark
        }
    }
}

private struct OptionalDistortionModifier: ViewModifier {
    let isActive: Bool
    let shader: Shader
    let maxSampleOffset: CGSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content
                .distortionEffect(shader, maxSampleOffset: maxSampleOffset)
        } else {
            content
        }
    }
}

private extension View {
    func optionalDistortion(_ isActive: Bool, _ shader: Shader, maxSampleOffset: CGSize) -> some View {
        modifier(
            OptionalDistortionModifier(
                isActive: isActive,
                shader: shader,
                maxSampleOffset: maxSampleOffset
            )
        )
    }
}

private struct V2MaskUniformsKey: EnvironmentKey { static let defaultValue:[Float]=[] }
private extension EnvironmentValues {
 var v2MaskUniforms:[Float] {get{self[V2MaskUniformsKey.self]} set{self[V2MaskUniformsKey.self]=newValue}}
}
private struct V2CaptionFrameKey:PreferenceKey {
 static var defaultValue:CGRect = .zero
 static func reduce(value:inout CGRect,nextValue:()->CGRect){value=nextValue()}
}
private struct V2CounterExclusion:ViewModifier {
 let enabled:Bool
 @Environment(\.v2MaskUniforms) private var uniforms
 @ViewBuilder func body(content:Content)->some View {
  if enabled && uniforms.count>=28 {
   content.mask { GeometryReader { proxy in
    let rect=proxy.frame(in:.global)
    let sx=max(rect.width/max(proxy.size.width,1),0.001)
    let sy=max(rect.height/max(proxy.size.height,1),0.001)
    Rectangle().fill(.white)
     .frame(width:CGFloat(uniforms[0])/sx,height:CGFloat(uniforms[1])/sy)
     .colorEffect(ShaderLibrary.v2ReadabilityMask(.float2(0,0),.float2(sx,sy),.floatArray(uniforms)))
     .offset(x:-rect.minX/sx,y:-rect.minY/sy)
   }}
  }else{content}
 }
}
private struct V2CaptionBackdrop:View {
 let dark:Bool,yellow:Bool,activation:Double
 var body:some View {
  GeometryReader { geo in
   VStack(spacing:0){
    Spacer(minLength:0)
    if dark {
     // Fixed Dark backing: contact/idle brightness must not toggle this layer.
     LinearGradient(colors:[.black.opacity(0),.black.opacity(0.30)],startPoint:.top,endPoint:.bottom)
      .frame(height:geo.size.height*0.30)
    }else{
     // Yellow Light restores its transition-caption UI tint and profile;
     // Blue Light keeps the later approved adaptive UI support.
     let tint=yellow ? Color(red:1,green:1,blue:0.30):Color.white
     LinearGradient(stops:(0...16).map { i in
      let v=Double(i)/16
      return Gradient.Stop(color:tint.opacity(0.30*(1-pow(1-v,3))),location:v)
     },startPoint:.top,endPoint:.bottom)
      .frame(height:geo.size.height*0.30).opacity(activation)
    }
   }
  }.allowsHitTesting(false).accessibilityHidden(true)
 }
}
// Measures the real unwashed shader background in the actual caption bounds.
// Shared buffers and one in-flight asynchronous pass: never captures the UI or
// blocks the main thread. Touch/progress/idle clocks remain production-owned.
private final class V2CaptionProbe:ObservableObject {
 @Published private(set) var activation:Double=0
 @Published private(set) var key:String=""
 private let device:MTLDevice?
 private var queue:MTLCommandQueue?,pipeline:MTLComputePipelineState?
 private var uniformsBuffer:MTLBuffer?,historyBuffer:MTLBuffer?,resultBuffer:MTLBuffer?
 private var busy=false,needed=false,filteredRisk:Double=0,previousWave:Double=0
 private var lastTime:TimeInterval=0
 init(){
  device=MTLCreateSystemDefaultDevice()
  guard let device else{return}
  do {
   guard let library=device.makeDefaultLibrary(),let f=library.makeFunction(name:"v2CaptionProbe") else {
    throw NSError(domain:"GradientsV2.Metal",code:1)
   }
   pipeline=try device.makeComputePipelineState(function:f);queue=device.makeCommandQueue()
   uniformsBuffer=device.makeBuffer(length:32*4,options:.storageModeShared)
   historyBuffer=device.makeBuffer(length:512*4,options:.storageModeShared)
   resultBuffer=device.makeBuffer(length:360*16,options:.storageModeShared)
   NSLog("Gradients V2: live caption probe ready")
  }catch {NSLog("Gradients V2 caption probe: %@",String(describing:error))}
 }
 func sample(uniforms:[Float],history:[Float],frame:CGRect,key sampleKey:String,dark:Bool,yellow:Bool){
  guard !busy,uniforms.count==28,history.count<=240,
   let queue,let pipeline,let uniformsBuffer,let historyBuffer,let resultBuffer else{return}
  let currentTime=ProcessInfo.processInfo.systemUptime
  let dt=lastTime==0 ? 1.0/60:min(max(currentTime-lastTime,1.0/240),0.1)
  lastTime=currentTime
  if key != sampleKey {key=sampleKey;activation=0;filteredRisk=0;previousWave=0;needed=false}
  let w=CGFloat(uniforms[0]),h=CGFloat(uniforms[1])
  let box=frame.height>0 ? frame:CGRect(x:0,y:h*0.82,width:w,height:h*0.085)
  let x0=max(0,box.minX+34),x1=min(w,box.maxX-34)
  let y0=max(0,box.minY),y1=min(h,box.maxY)
  let u=uniforms+[Float(x0),Float(y0),Float(x1),Float(y1)]
  u.withUnsafeBytes{memcpy(uniformsBuffer.contents(),$0.baseAddress!,$0.count)}
  u.withUnsafeBytes{memcpy(historyBuffer.contents().advanced(by:256*4),$0.baseAddress!,$0.count)}
  if !history.isEmpty{history.withUnsafeBytes{memcpy(historyBuffer.contents(),$0.baseAddress!,$0.count)}}
  guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else{return}
  busy=true
  encoder.setComputePipelineState(pipeline);encoder.setBuffer(uniformsBuffer,offset:0,index:0)
  encoder.setBuffer(historyBuffer,offset:0,index:1);encoder.setBuffer(resultBuffer,offset:0,index:2)
  encoder.dispatchThreads(MTLSize(width:360,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:32,height:1,depth:1));encoder.endEncoding()
  command.addCompletedHandler { [weak self] command in
   let samples=Array(UnsafeBufferPointer(start:resultBuffer.contents().assumingMemoryBound(to:SIMD4<Float>.self),count:360))
   DispatchQueue.main.async {
    guard let self else{return};self.busy=false
    guard command.status == .completed,self.key==sampleKey else{return}
    let l=samples.map{Double($0.x)}.sorted(),wave=samples.map{Double($0.y)}.sorted(),delta=samples.map{Double($0.z)}.sorted()
    let low=l[36],high=l[324],W=wave[324],D=delta[324],sat=samples.reduce(0){$0+Double($1.w)}/360
    func ease(_ v:Double,_ a:Double,_ b:Double)->Double {let t=min(max((v-a)/(b-a),0),1);return t*t*(3-2*t)}
    let textLight=pow((0.20+0.055)/1.055,2.4),contrast=(low+0.05)/(textLight+0.05)
    var risk:Double
    var attack=0.05,release=0.08
    if dark {
     // Keep the temporal-blend fix: ignore the tiny W tail (.015), and
     // never release/replace a caption ellipse. Only the real gradient fades.
     let presence=max(ease(W,0.015,0.15),ease(D,0.02,0.12))
     risk=presence*ease(high,0.22,0.50)
     attack=0.065;release=0.16
    }else if yellow {
     // Exact transition-caption condition and temporal constants.
     risk=max(1-ease(contrast,4.8,5.8),ease(high,0.58,0.74)*ease(sat,0.20,0.35))
     attack=0.075;release=0.25
    }else{
     risk=ease(W,0.025,0.10)*max(1-ease(contrast,4.8,5.8),ease(high,0.38,0.60))
     if W+0.0005<self.previousWave && W<0.12 {risk=0}
    }
    self.previousWave=W
    self.filteredRisk+=(risk-self.filteredRisk)*(1-exp(-dt/0.025))
    if self.filteredRisk>0.42 {self.needed=true} else if self.filteredRisk<0.22 {self.needed=false}
    let target=self.needed ? 1.0:0.0,tau=self.needed ? attack:release
    var next=self.activation+(target-self.activation)*(1-exp(-dt/tau))
    if !self.needed && next<0.001 {next=0};if self.needed && next>0.999 {next=1}
    self.activation=min(max(next,0),1)
   }
  }
  command.commit()
 }
}
