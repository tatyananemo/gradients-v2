// Test-Demo-only telemetry. Never compiled into the standalone GradientsKit SDK.
import UIKit
import GradientsKit

@MainActor final class PhysicalRunMonitor {
    private static var active:PhysicalRunMonitor?
    private weak var gradient:GradientViewController?
    private var timer:Timer?,thermalObserver:NSObjectProtocol?
    private let started=ProcessInfo.processInfo.systemUptime
    private let probe:Bool,duration:Double,runID:String
    private var stopped:String?,lastSubmitted:Double=0,lastChange=ProcessInfo.processInfo.systemUptime
    private let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    private var thermalSamples:[[String:Double]]=[]
    static func install(_ gradient:GradientViewController,_ environment:[String:String]) {
        guard environment["V4_PHYSICAL_MONITOR"]=="1" else{return}
        active=PhysicalRunMonitor(gradient,environment)
    }
    static func sceneActivated(_ gradient:GradientViewController) {
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
