#!/usr/bin/env python3
"""Compare maintained SDK core with callbacks extracted from unchanged SwiftUI V2."""
import json,subprocess,sys,tempfile
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
sys.path.insert(0,str(ROOT/'Validation'))
import validate as v
legacy=v.behavior_source(v.app_source())
legacy=legacy[:legacy.index('private let replay = Replay()')].replace('private final class Replay','final class Replay').replace('private func ','func ')
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
print("Core equivalence: \(events) input events, \(frames) exact state/history/progress checks; 30/60/80/100%, hold/release/idle/reset/settings passed")
'''
with tempfile.TemporaryDirectory(prefix='v2-core-') as folder:
    folder=Path(folder);(folder/'main.swift').write_text(legacy+'\n'+comparison)
    for mode,flags in [('Debug',['-Onone']),('Release',['-O'])]:
        binary=folder/mode
        subprocess.run(['xcrun','swiftc',*flags,str(ROOT/'UIKitComponent/Core/GradientSession.swift'),str(folder/'main.swift'),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True)
