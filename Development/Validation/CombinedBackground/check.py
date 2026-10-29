#!/usr/bin/env python3
"""Prepare reproducible native-Mac checks only; --run never launches iOS/Simulator."""
import argparse,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'Development/DeviceComparison'))
from prepare_sources import outputs
p=argparse.ArgumentParser();p.add_argument('--cases',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--run',action='store_true');a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
reference,combined,new=outputs('reference'),outputs('precalc',True),outputs('precalc',True,True)
for name,data in [('candidate936.metal',reference['GradientsUIKit.metal']),('precalculated.metal',combined['GradientsUIKit.metal']),('optimized.metal',new['GradientsUIKit.metal']),('colors.swift',new['GradientYellowColors.swift']),('DomainMaskRenderer.swift',new['GradientMaskRenderer.swift'].replace(b'GradientMaskRenderer',b'DomainMaskRenderer'))]:(out/name).write_bytes(data)
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
(out/'main.swift').write_text(s)
(out/'cases.json').write_bytes(a.cases.read_bytes())
common=[ROOT/'GradientsKit-V4/Sources/GradientsKit'/n for n in ['GradientRenderSafety.swift','GradientMaskRenderer.swift','GradientPerformanceMetrics.swift']]
subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(out/'Cache'),*map(str,common),str(out/'DomainMaskRenderer.swift'),str(out/'colors.swift'),str(out/'main.swift'),'-o',str(out/'check')],check=True)
if a.run:subprocess.run([str(out/'check'),str(out),str(out/'cases.json'),str(out/'result')],check=True,timeout=120)
