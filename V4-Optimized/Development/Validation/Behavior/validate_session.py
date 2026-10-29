#!/usr/bin/env python3
"""Check V2-equivalent behavior with the explicitly authorized 9–10 s progress policy."""
import json,subprocess,sys,tempfile
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2]
sys.path.insert(0,str(ROOT/'Development/Validation'))
import validate as v
legacy=v.behavior_source(v.app_source())
legacy=legacy[:legacy.index('private let replay = Replay()')].replace('private final class Replay','final class Replay').replace('private func ','func ')
# Adjust only the in-memory reference progress policy, never the frozen V2 files.
# All gesture/history/idle/release/frame expressions remain the independent oracle.
for old,new in [
    ('maximumProgressRate: CGFloat = 0.0585','maximumProgressRate: CGFloat = 0.105'),
    ('let amount = progressStep * (2 + speedBoost + 1.5 * fastSwipeBoost)',
     'let amount = progressStep * 4 * (2 + speedBoost + 1.5 * fastSwipeBoost)')]:
    assert legacy.count(old)==1,old
    legacy=legacy.replace(old,new)
# Compile the original View's frame expressions too, not a second hand-written oracle.
view=(ROOT/'Development/Validation/ReferenceV2/GradientInstallView.swift').read_text()
a=view.index('            let elapsed = now - startTime');b=view.index('            let isDarkTheme',a)
clock=view[a:b]
a=view.index('                let waterPoint =');b=view.index('                ZStack {',a)
geometry=view[a:b]
import re
names=['progressSpeed','fillGain','waveStrength','waveSpread','topBloom','whiteCore','blueDepth','shockStrength','shockInteraction','shockTrail','waveCount']
constants='\n'.join(re.search(r'^    private let '+n+r'[^\n]+',view,re.M).group() for n in names)
method="""
    func frameOracle(at now:TimeInterval,dark:Bool,yellow:Bool)->([Float],[Float],Float) {
        let showSettings=false
        struct Theme { let rawValue:String; let shaderValue:Float }
        struct Color { let rawValue:String; let shaderIndex:Float }
        let appTheme=Theme(rawValue:dark ? "dark":"light",shaderValue:dark ? 1:0)
        let gradientColor=Color(rawValue:yellow ? "yellow":"blue",shaderIndex:yellow ? 3:0)
        let globalFrame=CGRect(origin:.zero,size:geo.size)
        let gradientLayerSize=geo.size
"""+clock+geometry+"\nreturn (v2Uniforms,v2History,Float(trailDistortionStrength))\n    }\n"
legacy=legacy.replace('final class Replay {','final class Replay {\n'+constants+'\n'+method)
comparison=r'''
func equal(_ a: Any, _ b: Any, _ name: String) {
    let x = try! JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .fragmentsAllowed])
    let y = try! JSONSerialization.data(withJSONObject: b, options: [.sortedKeys, .fragmentsAllowed])
    precondition(x == y, "Behavior mismatch: \(name)\n\(String(data:x,encoding:.utf8)!)\n\(String(data:y,encoding:.utf8)!)")
}
let reference=Replay(), core=GradientSession(at:0)
var events=0, frames=0
func check(_ time: Double) {
    equal(Double(reference.progress),Double(core.progress),"target")
    equal(Double(reference.interpolatedProgress(at:time)),Double(core.interpolatedProgress(at:time)),"rendered")
    equal(reference.interactionTrailArguments(at:time,origin:.zero,size:reference.geo.size),core.interactionTrailArguments(at:time,origin:.zero,size:reference.geo.size),"history")
    equal([reference.waterDragEnergy,CGFloat(reference.idleWaveStartTime)],[core.waterDragEnergy,CGFloat(core.idleWaveStartTime)],"energy/idle")
    precondition(reference.waterTouchPoint==core.waterTouchPoint && reference.waterTouchPreviousPoint==core.waterTouchPreviousPoint && reference.waterTouchLastMove==core.waterTouchLastMove && reference.waterTouchIsActive==core.waterTouchIsActive)
    let f=core.frame(at:time,size:reference.geo.size,dark:true,yellow:true)
    precondition(f.uniforms.count==28 && f.uniforms[2]==Float(reference.interpolatedProgress(at:time)))
    for dark in [false,true] {for yellow in [false,true] {
        let oracle=reference.frameOracle(at:time,dark:dark,yellow:yellow)
        let actual=core.frame(at:time,size:reference.geo.size,dark:dark,yellow:yellow)
        precondition(oracle.0==actual.uniforms && oracle.1==actual.history && oracle.2==actual.distortion,"Frame arguments changed")
    }}
    frames+=1
}
func changed(_ p:CGPoint,_ t:Double) {
    reference.changed(GestureValue(location:p,startLocation:p),at:t)
    core.dragChanged(to:p,at:t,size:reference.geo.size);events+=1;check(t)
}
func ended(_ t:Double) { reference.ended(at:t);core.dragEnded(at:t);events+=1;check(t) }
changed(CGPoint(x:50,y:700),0)
for i in 1...240 {let t=Double(i)/120;changed(CGPoint(x:195+sin(t*6)*170,y:420+cos(t*4)*300),t)}
for i in 0...120 {check(2+Double(i)/120)}
ended(3)
for i in 0...240 {check(3+Double(i)/120)}
for i in 0..<90 {let t=5+Double(i)*0.09;let p=CGPoint(x:i%2==0 ? 30:360,y:100+i%7*100);changed(p,t);changed(CGPoint(x:390-p.x,y:p.y+30),t+0.025);ended(t+0.035);check(t+0.04)}
var milestones:[Double]=[];var next=0.3
for i in 0..<6000 where core.progress<1 {let t=15+Double(i)/60;changed(CGPoint(x:i%2==0 ? 20:370,y:300),t);if Double(core.progress)>=next {milestones.append(next);next=next<0.6 ? 0.6:next<0.8 ? 0.8:1}}
precondition(core.progress==1)
check(120);reference.reset(now:121,animated:false);core.reset(at:121);check(121)
core.setSettingsVisible(true,at:122)
precondition(core.frame(at:123,size:reference.geo.size,dark:false,yellow:false).uniforms[25]==0)
core.setSettingsVisible(false,at:123)
precondition(core.idleWaveStartTime==123.42)

// End-to-end CPU replay of the ordinary input path; shader/idle clocks unchanged.
let size=CGSize(width:390,height:844)
for hz in [30,40,60,120] {for trajectory in ["ordinary","slow","fast"] {
    let session=GradientSession(at:0)
    var targetTime:Double?,settledTime:Double?
    for i in 0...hz*12 {
        let t=Double(i)/Double(hz)
        let point:CGPoint
        if trajectory=="ordinary" {
            point=CGPoint(x:195+sin(t*3.1)*145,y:440+cos(t*2.3)*220)
        } else {
            let speed=trajectory=="slow" ? 0.5:4.0
            let x=(t*speed*390).truncatingRemainder(dividingBy:700)
            point=CGPoint(x:x<=350 ? 20+x:720-x,y:400)
        }
        session.dragChanged(to:point,at:t,size:size)
        if targetTime==nil,session.targetProgress==1 {targetTime=t}
        if settledTime==nil,session.interpolatedProgress(at:t)==1 {settledTime=t}
        if targetTime != nil && settledTime != nil {break}
    }
    precondition(targetTime != nil && (9...10).contains(targetTime!),"Target fill outside 9–10 seconds")
    precondition(settledTime != nil && (9...10).contains(settledTime!),"Rendered fill outside 9–10 seconds")
    for dark in [true,false] {
        let frame=session.frame(at:12,size:size,dark:dark)
        precondition(frame.progress==1 && frame.uniforms[2]==1)
    }
    print("Fill replay \(hz) Hz / \(trajectory): target \(targetTime!) s, rendered \(settledTime!) s")
}}
let noInput=GradientSession(at:0)
for i in 0...1200 {_=noInput.frame(at:Double(i)/60,size:size,dark:true)}
precondition(noInput.targetProgress==0 && noInput.interpolatedProgress(at:20)==0,"Idle advanced progress")
let held=GradientSession(at:0);held.dragChanged(to:CGPoint(x:195,y:400),at:0,size:size)
let touchCredit=held.targetProgress
precondition(touchCredit==0.013,"Initial touch credit changed")
for i in 1...1200 {held.dragChanged(to:CGPoint(x:195,y:400),at:Double(i)/60,size:size)}
precondition(held.targetProgress==touchCredit,"Stationary hold advanced progress")
held.dragEnded(at:20)
for i in 1200...2400 {_=held.frame(at:Double(i)/60,size:size,dark:false)}
precondition(held.targetProgress==touchCredit,"Release/idle advanced progress")
held.reset(at:41);precondition(held.targetProgress==0)
print("Idle, stationary hold, release and reset: no autonomous progress")
print("Core equivalence: \(events) input events, \(frames) exact state/history/progress checks, \(frames*4) full frame-argument comparisons; 30/60/80/100%, hold/release/idle/reset/settings passed")
'''
with tempfile.TemporaryDirectory(prefix='v2-core-') as folder:
    folder=Path(folder);(folder/'main.swift').write_text(legacy+'\n'+comparison)
    for mode,flags in [('Debug',['-Onone']),('Release',['-O'])]:
        binary=folder/mode
        subprocess.run(['xcrun','swiftc',*flags,str(ROOT/'GradientsKit-V4/Sources/GradientsKit/Core/GradientSession.swift'),str(folder/'main.swift'),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
