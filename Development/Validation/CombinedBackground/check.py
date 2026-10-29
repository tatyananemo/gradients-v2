#!/usr/bin/env python3
"""Prepare reproducible native-Mac checks only; --run never launches iOS/Simulator."""
import argparse,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'Development/DeviceComparison'))
from prepare_sources import outputs
p=argparse.ArgumentParser();p.add_argument('--cases',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--run',action='store_true');p.add_argument('--idle-zero-work',action='store_true');p.add_argument('--swipe-optimization',action='store_true');p.add_argument('--mask-roi',action='store_true');a=p.parse_args()
if a.mask_roi:a.swipe_optimization=True
if a.swipe_optimization:a.idle_zero_work=True
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
reference,combined,new=outputs('reference'),outputs('precalc',True),outputs('precalc',True,True,a.idle_zero_work,a.swipe_optimization,a.mask_roi)
for name,data in [('candidate936.metal',reference['GradientsUIKit.metal']),('precalculated.metal',combined['GradientsUIKit.metal']),('optimized.metal',new['GradientsUIKit.metal']),('colors.swift',new['GradientYellowColors.swift']),('DomainMaskRenderer.swift',combined['GradientMaskRenderer.swift'].replace(b'GradientMaskRenderer',b'DomainMaskRenderer'))]:(out/name).write_bytes(data)
s=(ROOT/'Development/Validation/DarkCriticalPath/CompareMasks.swift').read_text()
s=s.replace('idle-cache.metal','optimized.metal').replace('\"idleCache\"','\"reuseMain\"').replace('\"maskDomain\"','\"combined\"')
s=s.replace('let localRenderer=LocalMaskRenderer(device:device,queue:queue)\n','')
s=s.replace('286+10*w+8*h+2+5*w+h','286+10*w+8*h')
s=s.replace('let selected=CommandLine.arguments.contains("domain-only") ? [0,1,4]:[0,1,2,3,4]','let selected=[0,4,3]')
s=s.replace('testVariant==4 {masks=','testVariant>=3 {masks=')
s='\n'.join(line for line in s.split('\n') if 'else if testVariant==2 {masks=' not in line)
s=s.replace('if testVariant<2 {referencePixels.append(data)}','if testVariant==0 || testVariant==4 {referencePixels.append(data)}')
s=s.replace('let maskRenderer=','let optimizedComposite=try pipeline(idle,"prototypeComposite",.bgra8Unorm,true)\nlet optimizedDistortion=try pipeline(idle,"prototypeDistortion",.rgba16Float)\nlet maskRenderer=')
s=s.replace('draw(cb,t.distorted,distortion[variant])','draw(cb,t.distorted,testVariant==3 ? optimizedDistortion:distortion[variant])')
s=s.replace('draw(cb,t.output,composite8[variant],bind)','draw(cb,t.output,testVariant==3 ? optimizedComposite:composite8[variant],bind)')
start=s.index('   if ["extra-dark-dynamic7"');end=s.index('   comparisons.append(',start);s=s[:start]+s[end:]
if a.swipe_optimization:
    s=s.replace('let count=286+10*w+8*h','let count=286+10*w+8*h+2*((w+15)/16)*((h+15)/16)')
    s=s.replace('let n=max(w,h,frame.history.count);','let n=max(w,h,frame.history.count,testVariant==3 && frame.history.count>=6 ? ((w+15)/16)*((h+15)/16):0);')
    s=s.replace('if frame.distortion>0.002 {','if testVariant != 3 && frame.distortion>0.002 {')
    s=s.replace('SIMD4<Float>(scale,1,dark ? 1:0,0)','SIMD4<Float>(scale,1,dark ? 1:0,testVariant==3 ? frame.distortion:0)')
if a.mask_roi:
    (out/'RoiMaskRenderer.swift').write_bytes(new['GradientMaskRenderer.swift'].replace(b'GradientMaskRenderer',b'RoiMaskRenderer'))
    s=s.replace('let domainRenderer=DomainMaskRenderer(device:device,queue:queue)','let domainRenderer=DomainMaskRenderer(device:device,queue:queue)\nlet roiRenderer=RoiMaskRenderer(device:device,queue:queue)')
    line=next(l for l in s.splitlines() if 'else if testVariant>=3 {masks=domainRenderer.render(' in l)
    s=s.replace(line,line.replace('testVariant>=3','testVariant==3').replace('domainRenderer.render','roiRenderer.render')+'\n'+line)
    s=s.replace('func bind(_ enc:MTLRenderCommandEncoder) {','func bind(_ enc:MTLRenderCommandEncoder) {\n   if testVariant==3 {var origins=roiRenderer.sampleOrigins;enc.setFragmentBytes(&origins,length:16,index:2)}')
(out/'main.swift').write_text(s)
(out/'cases.json').write_bytes(a.cases.read_bytes())
common=[ROOT/'GradientsKit-V4/Sources/GradientsKit'/n for n in ['GradientRenderSafety.swift','GradientMaskRenderer.swift','GradientPerformanceMetrics.swift']]
if a.mask_roi:common.append(out/'RoiMaskRenderer.swift')
subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(out/'Cache'),*map(str,common),str(out/'DomainMaskRenderer.swift'),str(out/'colors.swift'),str(out/'main.swift'),'-o',str(out/'check')],check=True)
if a.run:subprocess.run([str(out/'check'),str(out),str(out/'cases.json'),str(out/'result')],check=True,timeout=120)
