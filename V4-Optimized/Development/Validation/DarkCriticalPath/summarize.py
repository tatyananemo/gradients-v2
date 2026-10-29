"""Summarize already completed Mac trials; does not execute GPU work."""
import argparse,json,math,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
def stats(values):
    s=sorted(values);return {'count':len(s),'mean':statistics.mean(s),'p95':s[math.ceil(len(s)*.95)-1],'p99':s[math.ceil(len(s)*.99)-1]}
result={}
for group,runs in [('idle',['bench-whole1','bench-whole2']),('gestureInputs',['bench-gestures']),('screening',['bench1'])]:
    data=[]
    for run in runs:data += [x for x in json.loads((a.root/run/'timings.json').read_text()) if 'round0-' not in x['name']]
    result[group]={v:{k:stats([x[k] for x in data if x['variant']==v]) for k in ['fullFrameWallMS','fullFrameCPUms','maskWallMS','gpuMS']} for v in sorted({x['variant'] for x in data})}
comparisons=json.loads((a.root/'all-domain/comparisons.json').read_text())
result['images']={}
for theme in ['dark','light']:
    z=[x for x in comparisons if x['theme']==theme];n=sum(x['vsApproved']['totalPixels'] for x in z)
    result['images'][theme]={'frames':len(z),'maxRGBA8':max(x['vsApproved']['maxDelta8'] for x in z),
        'maxChangedPixelPercentPerFrame':max(x['vsApproved']['pixels']/x['vsApproved']['totalPixels']*100 for x in z),
        'meanChannelDelta8':sum(x['vsApproved']['sumDelta8'] for x in z)/(n*4),
        'maxRGBA8vsPrecalc':max(x['vsPrecalc']['maxDelta8'] for x in z)}
raw=json.loads((a.root/'raw/raw-masks.json').read_text());result['rawMasks']={'compared':len(raw),'maxFloatDelta':max(x['maxFloatDelta'] for x in raw),'changedComponents':sum(x['components'] for x in raw),'totalComponents':sum(x['totalPixels']*4 for x in raw),'meanFloatDelta':sum(x['sumFloatDelta'] for x in raw)/sum(x['totalPixels']*4 for x in raw),'pixelExact':False}
temporal=json.loads((a.root/'temporal/temporal.json').read_text())
result['temporal']={theme:{'pairs':len([x for x in temporal if theme in x['name']]),'maxSignedErrorChange8':max(x['maxSignedErrorChange8'] for x in temporal if theme in x['name'])} for theme in ['dark','light']}
result['physicalTrace']=json.loads((a.root/'timeline.json').read_text())
result['scope']='Native Mac M3 Pro offscreen completion latency, not presentation FPS. Full-frame wall time includes masks and GPU completion, excludes UIKit, drawable wait, caption probe and display presentation. GPU command time includes dependency overlap; do not sum with mask commands.'
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n')
print('Wrote',a.output)
