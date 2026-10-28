#!/usr/bin/env python3
"""Native Mac integration check: actual cache helper vs reviewed compositor readbacks.

No iOS process, image generation, oracle updates or changes to the SDK.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
sys.path.insert(0,str(HERE))
from prepare_sources import outputs
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--review',type=Path,required=True,help='Existing visual-review capture with cases.json and frames/')
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
review=a.review.resolve();cases=json.loads((review/'cases.json').read_text());cases=[c for c in cases if c['group']!='sequence']
assert len(cases)==132
(out/'cases.json').write_text(json.dumps(cases))
reference=outputs('reference');candidate=outputs('precalc')
(out/'candidate936.metal').write_bytes(reference['GradientsUIKit.metal'])
(out/'precalculated.metal').write_bytes(candidate['GradientsUIKit.metal'])
(out/'colors.swift').write_bytes(reference['GradientYellowColors.swift'])
text=(ROOT/'Development/Validation/Perceptual/RenderComparison.swift').read_text()
def change(old,new):
 global text
 assert text.count(old)==1,old[:100]
 text=text.replace(old,new)
change('import Foundation','import Foundation\nimport CryptoKit')
change('cache:MTLBuffer','cache:GradientPrecalculationBuffers')
change('cache:device.makeBuffer(length:count*4,options:.storageModePrivate)!','cache:GradientPrecalculationBuffers(device:device,width:w,height:h)!')
first=text.index('  if variant==1 {');last=text.index('  let e=cb.makeComputeCommandEncoder()!;var factor=scale',first)
text=text[:first]+'''  var backgroundHistory=history
  if variant==1 {
   guard let cache=t.cache.encode(command:cb,pipeline:prep,uniformBuffer:u,historyBuffer:history,
       historyCount:frame.history.count,scale:scale,slot:index%3) else {fatalError("Actual helper could not encode")}
   backgroundHistory=cache
  }
'''+text[last:]
change('variant==1 ? t.cache:history','backgroundHistory')
change(' try data.write(to:file)',''' let expected=URL(fileURLWithPath:CommandLine.arguments[4],isDirectory:true).appendingPathComponent(file.lastPathComponent)
 let recorded=try Data(contentsOf:expected)
 guard SHA256.hash(data:data)==SHA256.hash(data:recorded) else {fatalError("Integrated output differs from reviewed pixels: \\(file.lastPathComponent)")}
''')
(out/'main.swift').write_text(text)
common=[ROOT/'GradientsKit-V4/Sources/GradientsKit'/name for name in ['GradientRenderSafety.swift','GradientMaskRenderer.swift','GradientPerformanceMetrics.swift']]
subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(out/'ModuleCache'),*map(str,common),str(out/'colors.swift'),str(HERE/'GradientPrecalculationBuffers.swift'),str(out/'main.swift'),'-o',str(out/'validate')],check=True)
with (out/'run.log').open('w') as log:
 subprocess.run([str(out/'validate'),str(out),str(out/'cases.json'),str(out/'verified'),str(review/'frames')],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=300)
(out/'result.json').write_text(json.dumps({'passed':True,'frames':len(cases),'formats':['BGRA8','diagnostic RGBA16F'],'variants':2,'comparisons':len(cases)*2*2,'actual_runtime_cache_helper':True,'target':'native macOS Metal; no iOS launch'},indent=2))
print((out/'run.log').read_text());print('Verified 132 paired final-compositor frames (528 raw readbacks) against reviewed output')
