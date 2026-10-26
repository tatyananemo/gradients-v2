#!/usr/bin/env python3
import subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[3]
source=r'''
import Foundation
import CoreGraphics
let p=GradientResetPresentation(started:10,counter:0.8,mask:0.7)
precondition(p.values(at:10).counter==0.8 && p.values(at:10).mask==0.7)
precondition(abs(p.values(at:10.175).counter-0.4)<0.000001)
precondition(p.values(at:10.35).finished && p.values(at:10.35).counter==0)
var previous=CGFloat(1)
for i in 0...350 {let v=p.values(at:10+Double(i)/1000);precondition(v.counter<=previous);previous=v.counter}
let session=GradientSession(at:10,initialProgress:0.8)
session.reset(at:10)
for i in 0...350 {let f=session.frame(at:10+Double(i)/1000,size:CGSize(width:390,height:844),dark:true,yellow:true);precondition(f.progress==0 && f.uniforms[2]==0 && f.history.isEmpty)}
print("Presentation: 0.35 s easeInOut, monotonic endpoints; reset never interpolates behavioral/GPU progress")
'''
with tempfile.TemporaryDirectory() as folder:
 folder=Path(folder);(folder/'main.swift').write_text(source)
 for mode in ['-Onone','-O']:
  subprocess.run(['xcrun','swiftc',mode,str(root/'GradientsKit-V4/Sources/GradientsKit/Core/GradientSession.swift'),str(root/'GradientsKit-V4/Sources/GradientsKit/Core/GradientResetPresentation.swift'),str(folder/'main.swift'),'-o',str(folder/'test')],check=True)
  subprocess.run([str(folder/'test')],check=True)
