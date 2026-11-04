// Test-Demo-only telemetry. Never compiled into the standalone GradientsKit SDK.
import UIKit
import GradientsKit

@MainActor final class PhysicalRunMonitor {
    private static var active:PhysicalRunMonitor?
    private static var scenario:PhysicalScenarioMonitor?
    private weak var gradient:GradientViewController?
    private var timer:Timer?,thermalObserver:NSObjectProtocol?
    private let started=ProcessInfo.processInfo.systemUptime
    private let probe:Bool,duration:Double,runID:String
    private var stopped:String?,lastSubmitted:Double=0,lastChange=ProcessInfo.processInfo.systemUptime
    private let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    private var thermalSamples:[[String:Double]]=[]
    static func install(_ gradient:GradientViewController,_ environment:[String:String]) {
        guard environment["V4_PHYSICAL_MONITOR"]=="1" else{return}
        if let mode=environment["V4_TEST_SCENARIO"],mode=="swipe" || mode=="idle" {
            scenario=PhysicalScenarioMonitor(gradient,environment,mode);return
        }
        active=PhysicalRunMonitor(gradient,environment)
    }
    static func sceneActivated(_ gradient:GradientViewController) {
        if let scenario {if scenario.stopped != nil {gradient.pauseRendering()} else {gradient.resumeRendering()};return}
        if let active,active.probe || active.stopped != nil {gradient.pauseRendering()}
        else {gradient.resumeRendering()}
    }
    private init(_ gradient:GradientViewController,_ env:[String:String]) {
        self.gradient=gradient;probe=env["V4_THERMAL_PROBE"]=="1"
        duration=min(max(Double(env["GRADIENTS_BENCHMARK_DURATION"] ?? "20") ?? 20,12),20)
        runID=env["V4_RUN_ID"] ?? UUID().uuidString
        for name in ["performance.json","renderer-state.json","physical-monitor.json","physical-stop.json"] {
            try? FileManager.default.removeItem(at:folder.appendingPathComponent(name))
        }
        UIApplication.shared.isIdleTimerDisabled=true
        if probe {gradient.pauseRendering()} else {gradient.beginPerformanceMeasurement()}
        thermalObserver=NotificationCenter.default.addObserver(forName:ProcessInfo.thermalStateDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        sample()
    }
    private func stop(_ reason:String) {
        guard stopped==nil else{return};stopped=reason
        gradient?.pauseRendering()
        UIApplication.shared.isIdleTimerDisabled=false
        timer?.invalidate();timer=nil
        if let thermalObserver {NotificationCenter.default.removeObserver(thermalObserver)}
    }
    private func sample() {
        guard let gradient else{return}
        let elapsed=ProcessInfo.processInfo.systemUptime-started
        let thermal=ProcessInfo.processInfo.thermalState.rawValue
        thermalSamples.append(["elapsed":elapsed,"state":Double(thermal)])
        if thermal>=ProcessInfo.ThermalState.serious.rawValue {stop("thermal-serious-or-critical")}
        let metrics=gradient.performanceReport
        let errors=["compositionCommandErrors","captionCommandErrors","maskCommandErrors"].reduce(0.0) {total,key in
            total+((metrics[key] as? [String:Double])?["count"] ?? 0)
        }
        if errors>0 {stop("metal-command-error")}
        let submitted=gradient.renderStatistics["submitted"] ?? 0
        if submitted != lastSubmitted {lastSubmitted=submitted;lastChange=ProcessInfo.processInfo.systemUptime}
        if !probe,elapsed>3,elapsed<duration+3,ProcessInfo.processInfo.systemUptime-lastChange>2,
           UIApplication.shared.applicationState == .active {stop("render-heartbeat-stalled")}
        if !probe,elapsed>=duration+3.5 {stop("completed")}
        let report:[String:Any]=["runID":runID,"elapsed":elapsed,"thermalState":thermal,
            "thermalSamples":thermalSamples,"probe":probe,"stopped":stopped as Any? ?? NSNull(),
            "lowPowerMode":ProcessInfo.processInfo.isLowPowerModeEnabled,"screenBrightness":UIScreen.main.brightness,
            "engine":gradient.engineDescription,"statistics":gradient.renderStatistics,"metrics":metrics,
            "progress":gradient.session.targetProgress]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {
            try? data.write(to:folder.appendingPathComponent("physical-monitor.json"),options:.atomic)
            if stopped != nil {try? data.write(to:folder.appendingPathComponent("physical-stop.json"),options:.atomic)}
        }
    }
}

/// Opt-in Demo driver. Uses the ordinary session input path, never overrides
/// progress or the renderer. Ten-second windows stay below SDK's sample cap.
@MainActor private final class PhysicalScenarioMonitor {
    private weak var gradient:GradientViewController?
    private let mode:String,runID:String,duration:Double
    private let launched=ProcessInfo.processInfo.systemUptime
    private let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    private var timer:Timer?,observer:NSObjectProtocol?
    private var measuring=false,measurementStart=0.0,windowStart=0.0,lastFrame=0.0
    private var windowProgress=0.0,startingStats:[String:Double]=[:]
    private var windows:[[String:Any]]=[],thermal:[[String:Double]]=[]
    private(set) var stopped:String?
    private var finalized=false

    init(_ gradient:GradientViewController,_ env:[String:String],_ mode:String) {
        self.gradient=gradient;self.mode=mode;runID=env["V4_RUN_ID"] ?? UUID().uuidString
        duration=min(max(Double(env["GRADIENTS_BENCHMARK_DURATION"] ?? "6") ?? 6,6),120)
        for name in ["physical-monitor.json","physical-stop.json","performance.json","renderer-state.json"] {
            try? FileManager.default.removeItem(at:folder.appendingPathComponent(name))
        }
        UIApplication.shared.isIdleTimerDisabled=true
        gradient.onFrame={ [weak self] frame in self?.frame(frame) }
        observer=NotificationCenter.default.addObserver(forName:ProcessInfo.thermalStateDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        sample()
    }
    private func beginWindow(_ time:Double) {
        guard let gradient else{return}
        windowStart=time;windowProgress=Double(gradient.session.targetProgress)
        startingStats=gradient.renderStatistics
        gradient.beginPerformanceMeasurement()
    }
    private func appendWindow(_ end:Double) {
        guard let gradient,measuring,end>windowStart else{return}
        let stats=gradient.renderStatistics.mapValues{$0}.reduce(into:[String:Double]()) {d,p in d[p.key]=p.value-(startingStats[p.key] ?? 0)}
        windows.append(["startSeconds":windowStart,"endSeconds":end,"metrics":gradient.performanceReport,
            "progressStart":windowProgress,"progressEnd":Double(gradient.session.targetProgress),"statistics":stats])
    }
    private func frame(_ frame:GradientRenderFrame) {
        guard stopped==nil,let gradient else{return}
        let now=ProcessInfo.processInfo.systemUptime;lastFrame=now
        guard now-launched>=3 else{return}
        if !measuring {measuring=true;measurementStart=now;beginWindow(0)}
        let elapsed=now-measurementStart
        if elapsed>=duration {stop("completed");return}
        if elapsed-windowStart>=10 {appendWindow(elapsed);beginWindow(elapsed)}
        if mode=="swipe" {
            let size=gradient.view.bounds.size
            gradient.recordPerformanceInput()
            gradient.session.dragChanged(to:CGPoint(x:size.width*(0.5+sin(elapsed*3.1)*145/390),
                y:size.height*(440+cos(elapsed*2.3)*220)/844),at:frame.time,size:size)
        }
    }
    private func stop(_ reason:String) {
        guard stopped==nil,let gradient else{return}
        stopped=reason
        let end=measuring ? ProcessInfo.processInfo.systemUptime-measurementStart:0
        if mode=="swipe" {gradient.session.dragEnded(at:Date().timeIntervalSinceReferenceDate)}
        gradient.pauseRendering();gradient.onFrame=nil
        timer?.invalidate();timer=nil
        if let observer {NotificationCenter.default.removeObserver(observer)}
        UIApplication.shared.isIdleTimerDisabled=false
        // Drain callbacks without blocking CPU/GPU or submitting another frame.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak self] in
            guard let self else{return}
            self.appendWindow(end);self.finalized=true;self.export()
        }
    }
    private func sample() {
        guard let gradient else{return}
        let now=ProcessInfo.processInfo.systemUptime
        let state=ProcessInfo.processInfo.thermalState.rawValue
        thermal.append(["elapsed":now-launched,"state":Double(state)])
        if stopped==nil {
            if state>=ProcessInfo.ThermalState.serious.rawValue {stop("thermal-serious-or-critical")}
            let report=gradient.performanceReport
            if ["compositionCommandErrors","captionCommandErrors","maskCommandErrors"].contains(where:{((report[$0] as? [String:Double])?["count"] ?? 0)>0}) {stop("metal-command-error")}
            if now-launched>3,lastFrame>0,now-lastFrame>2 {stop("render-heartbeat-stalled")}
            if now-launched>duration+5 {stop("watchdog-deadline")}
        }
        export()
    }
    private func export() {
        guard let gradient else{return}
        let report:[String:Any]=["runID":runID,"scenario":mode,"requestedSeconds":duration,
            "elapsed":ProcessInfo.processInfo.systemUptime-launched,"warmupSeconds":3,
            "thermalState":ProcessInfo.processInfo.thermalState.rawValue,"thermalSamples":thermal,
            "lowPowerMode":ProcessInfo.processInfo.isLowPowerModeEnabled,"screenBrightness":UIScreen.main.brightness,
            "progress":Double(gradient.session.targetProgress),"engine":gradient.engineDescription,
            "windows":windows,"metrics":gradient.performanceReport,"statistics":gradient.renderStatistics,
            "stopped":stopped as Any? ?? NSNull(),"finalized":finalized,
            "measurementNote":"MTLDrawable.presentedTime; independent <=10s windows; boundary in-flight samples belong to preceding accumulator; GPU command elapsed includes waits; no Instruments"]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {
            try? data.write(to:folder.appendingPathComponent("physical-monitor.json"),options:.atomic)
            if finalized {try? data.write(to:folder.appendingPathComponent("physical-stop.json"),options:.atomic)}
        }
    }
}
