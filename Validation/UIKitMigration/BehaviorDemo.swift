// Comparison/demo host only. UIKitComponent has no dependency on this file.
import SwiftUI
import UIKit

final class BehaviorClock:ObservableObject {@Published var tick=0}
enum BehaviorEnvironment {
    static let clock=BehaviorClock()
    static var active=false
    static var driver:BehaviorDriver?
}

extension GradientSession {
    // Validation fixture import only; not part of the reusable component API.
    static func fixture(_ legacy:MigrationReplay)->GradientSession {
        let core=GradientSession(at:legacy.startTime,initialProgress:legacy.progress)
        core.progressIncrements=legacy.progressIncrements.map {SessionProgressIncrement(amount:$0.amount,startTime:$0.startTime)}
        core.waterTouchPoint=legacy.waterTouchPoint;core.waterTouchPreviousPoint=legacy.waterTouchPreviousPoint
        core.waterTouchLastMove=legacy.waterTouchLastMove;core.waterTouchIsActive=legacy.waterTouchIsActive
        core.idleWaveStartTime=legacy.idleWaveStartTime;core.waterDragEnergy=legacy.waterDragEnergy
        core.interactionTrail=legacy.interactionTrail.map {SessionTrailSegment(from:$0.from,to:$0.to,startTime:$0.startTime,time:$0.time,distance:$0.distance,releaseTime:$0.releaseTime)}
        return core
    }
}

extension MigrationController {
    @MainActor func renderBehavior(_ request:MigrationRequest) async throws {
        BehaviorEnvironment.driver?.stop();BehaviorEnvironment.driver=nil
        BehaviorEnvironment.active=false
        let frame=MigrationFrame(request)
        MigrationEnvironment.frame=frame
        MigrationEnvironment.uniforms=[];MigrationEnvironment.history=[]
        reference()
        try await Task.sleep(nanoseconds:350_000_000)
        let caption=MigrationEnvironment.captionFrame,counter=MigrationEnvironment.counterFrame
        let core=GradientSession.fixture(frame.replay)
        let native=request.mode.hasSuffix("uikit")
        if request.kind == "interactive" {
            let live=GradientSession(at:Date().timeIntervalSinceReferenceDate,initialProgress:CGFloat(request.progress))
            let controller=try GradientViewController(session:live,dark:request.dark,yellow:request.yellow)
            controller.onSettings={ [weak self,weak controller] in
                guard let self,let controller else{return}
                controller.session.setSettingsVisible(true,at:Date().timeIntervalSinceReferenceDate)
                let panel=UIViewController();panel.view.backgroundColor=request.dark ? UIColor(white:0.04,alpha:1):.white
                let color=UISegmentedControl(items:["Blue","Yellow"]);color.selectedSegmentIndex=controller.yellow ? 1:0
                let theme=UISegmentedControl(items:["Light","Dark"]);theme.selectedSegmentIndex=controller.dark ? 1:0
                color.frame=CGRect(x:24,y:64,width:342,height:32);theme.frame=CGRect(x:24,y:112,width:342,height:32)
                color.addAction(UIAction { [weak controller] action in controller?.yellow=(action.sender as? UISegmentedControl)?.selectedSegmentIndex==1 },for:.valueChanged)
                theme.addAction(UIAction { [weak controller] action in controller?.dark=(action.sender as? UISegmentedControl)?.selectedSegmentIndex==1 },for:.valueChanged)
                panel.view.addSubview(color);panel.view.addSubview(theme)
                let close=UIButton(type:.system);close.setTitle("Готово",for:.normal);close.frame=CGRect(x:24,y:180,width:342,height:44)
                close.addAction(UIAction { [weak controller,weak panel] _ in
                    panel?.dismiss(animated:true)
                    controller?.session.setSettingsVisible(false,at:Date().timeIntervalSinceReferenceDate)
                },for:.touchUpInside);panel.view.addSubview(close)
                panel.isModalInPresentation=true
                panel.sheetPresentationController?.detents=[.custom { _ in 300 }]
                self.present(panel,animated:true)
            }
            let controllerRef=WeakGradientController(controller)
            var lastWrite:TimeInterval=0
            let target=directory.appendingPathComponent("interactive-state.json")
            controller.onFrame={ [weak live] frame in
                guard frame.time-lastWrite>0.2,let live else{return};lastWrite=frame.time
                let data:[String:Any]=["progress":frame.progress,"rendered":frame.uniforms[2],"active":live.waterTouchIsActive,
                    "historyCount":frame.history.count,"distortion":frame.distortion,"idleActivity":frame.uniforms[25],
                    "idleElapsed":frame.uniforms[26],"dark":frame.dark,"yellow":frame.yellow,
                    "touchPoint":[live.waterTouchPoint?.x ?? -1,live.waterTouchPoint?.y ?? -1],
                    "frames":controllerRef.value?.framesSubmitted ?? 0,"skipped":controllerRef.value?.framesSkipped ?? 0,
                    "maskMS":controllerRef.value?.maskCPUTime ?? 0,"cpuMS":controllerRef.value?.cpuFrameTime ?? 0,"gpuMS":controllerRef.value?.gpuTime ?? 0,
                    "performanceSamples":controllerRef.value?.performanceSamples ?? 0,
                    "moveCallbacks":controllerRef.value?.moveCallbacks ?? 0,"inputCallbacks":controllerRef.value?.inputCallbacks ?? 0]
                try? JSONSerialization.data(withJSONObject:data).write(to:target,options:.atomic)
            }
            install(controller)
            try JSONSerialization.data(withJSONObject:["id":request.id,"interactive":true]).write(to:directory.appendingPathComponent("ready.json"),options:.atomic)
            return
        }
        var controller:GradientViewController?
        if native {
            let renderer=try GradientViewController(session:core,dark:request.dark,yellow:request.yellow)
            renderer.externallyDriven=true
            install(renderer);controller=renderer
        }
        let driver=BehaviorDriver(frame:frame,core:core,renderer:controller,directory:directory)
        BehaviorEnvironment.driver=driver
        if request.kind == "motion" {
            driver.start()
            try JSONSerialization.data(withJSONObject:["id":request.id,"motion":true,"duration":32,"startUptime":driver.startUptime]).write(to:directory.appendingPathComponent("ready.json"),options:.atomic)
        } else {
            let uniforms=core.frame(at:frame.time,size:view.bounds.size,dark:request.dark,yellow:request.yellow)
            let probe=V2CaptionProbe()
            for _ in 0..<90 {
                probe.migrationTime+=1.0/60
                await withCheckedContinuation {(c:CheckedContinuation<Void,Never>) in
                    probe.migrationCompletion={c.resume()};probe.sample(uniforms:uniforms.uniforms,history:uniforms.history,frame:caption,key:"fixture",dark:request.dark,yellow:request.yellow)
                }
            }
            frame.activation=probe.activation
            if native {controller?.present(uniforms,activation:frame.activation)} else {reference()}
            try await Task.sleep(nanoseconds:600_000_000)
            if let controller {
                for _ in 0..<500 where !controller.finished {try await Task.sleep(nanoseconds:10_000_000)}
                guard controller.finished else{throw NSError(domain:"Behavior.GPUIncomplete",code:1)}
            }
            let metadata:[String:Any]=["id":request.id,"mode":request.mode,"uniforms":uniforms.uniforms,"history":uniforms.history,
                "progress":uniforms.progress,"time":uniforms.time,"distortion":uniforms.distortion,"activation":frame.activation,
                "caption":rect(caption),"counter":rect(counter),"gpuErrors":controller?.gpuErrors ?? []]
            let remaining=captureWarmupDeadline-ProcessInfo.processInfo.systemUptime
            if remaining>0 {try await Task.sleep(nanoseconds:UInt64(remaining*1_000_000_000))}
            try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("ready.json"),options:.atomic)
        }
    }
}

final class BehaviorDriver:NSObject {
    let frame:MigrationFrame,core:GradientSession,directory:URL
    weak var renderer:GradientViewController?
    let probe=V2CaptionProbe()
    var link:CADisplayLink?
    var startUptime:Double=0
    var inputIndex=0
    var checks=0
    var milestones:[Int]=[]
    var samples:[[String:Any]]=[]
    var lastSample = -1
    init(frame:MigrationFrame,core:GradientSession,renderer:GradientViewController?,directory:URL) {
        self.frame=frame;self.core=core;self.renderer=renderer;self.directory=directory
    }
    func start() {
        frame.replay.reset(now:1000,animated:false);frame.replay.progress=0.3
        core.reset(at:1000);core.progress=0.3
        startUptime=ProcessInfo.processInfo.systemUptime+1
        frame.time=1000;BehaviorEnvironment.active=true
        link=CADisplayLink(target:self,selector:#selector(tick))
        link?.preferredFrameRateRange=CAFrameRateRange(minimum:30,maximum:60,preferred:60)
        link?.add(to:.main,forMode:.common)
    }
    func stop(){link?.invalidate();link=nil}
    func event(_ index:Int) {
        let t=Double(index)/60,now=1000+t
        if (index>=120 && index<=300) || (index>=540 && index<=1740) {
            let p=CGPoint(x:195+sin(t*15)*170,y:420+cos(t*10)*300)
            frame.replay.changed(GestureValue(location:p,startLocation:p),at:now)
            core.dragChanged(to:p,at:now,size:CGSize(width:390,height:844))
        }
        if index==360 || index==1741 {frame.replay.ended(at:now);core.dragEnded(at:now)}
        if index==1800 {frame.replay.reset(now:now,animated:false);core.reset(at:now)}
        precondition(frame.replay.progress==core.progress && frame.replay.waterDragEnergy==core.waterDragEnergy)
        precondition(frame.replay.interactionTrailArguments(at:now,origin:.zero,size:CGSize(width:390,height:844))==core.interactionTrailArguments(at:now,origin:.zero,size:CGSize(width:390,height:844)))
        checks+=1
        for p in [30,60,80,100] where core.progress>=CGFloat(p)/100 && !milestones.contains(p) {milestones.append(p)}
    }
    @objc func tick() {
        let elapsed=max(0,ProcessInfo.processInfo.systemUptime-startUptime)
        let index=min(Int(elapsed*60),1920)
        while inputIndex<=index {event(inputIndex);inputIndex+=1}
        frame.time=1000+Double(index)/60
        let render=core.frame(at:frame.time,size:CGSize(width:390,height:844),dark:frame.dark,yellow:frame.yellow)
        if !probe.busy {
            probe.migrationTime=frame.time
            probe.sample(uniforms:render.uniforms,history:render.history,frame:CGRect(x:0,y:698.6666666667,width:390,height:63.3333333333),key:"motion",dark:frame.dark,yellow:frame.yellow)
        }
        frame.activation=probe.activation
        BehaviorEnvironment.clock.tick+=1
        renderer?.present(render,activation:frame.activation)
        let sample=Int(elapsed*2)
        if sample != lastSample {
            lastSample=sample
            samples.append(["t":Double(index)/60,"target":Double(core.progress),"rendered":Double(core.interpolatedProgress(at:frame.time)),"history":render.history.count,"distortion":render.distortion,"activation":frame.activation])
        }
        if elapsed>=32 {
            stop()
            let metadata:[String:Any]=["id":frame.request.id,"checks":checks,"milestones":milestones,"samples":samples,
                "framesSubmitted":renderer?.framesSubmitted ?? 0,"framesSkipped":renderer?.framesSkipped ?? 0,"gpuErrors":renderer?.gpuErrors ?? [],
                "events":"0–2 idle/contact; 2–5 swipe; 5–6 hold; 6 release; 6–9 idle; 9–29 swipes to 100%; 29 release; 30 reset; 30–32 idle"]
            try? JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("motion-done.json"),options:.atomic)
        }
    }
}

private final class WeakGradientController {
    weak var value:GradientViewController?
    init(_ value:GradientViewController){self.value=value}
}
