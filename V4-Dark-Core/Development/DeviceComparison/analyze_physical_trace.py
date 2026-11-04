#!/usr/bin/env python3
"""Read selected Instruments XML exports without running the device."""
import collections,json,math,subprocess,sys
from pathlib import Path
import xml.etree.ElementTree as E
run=Path(sys.argv[1])
def parse(name):
 p=run/name
 if not p.exists() or p.stat().st_size==0:return None
 try:data=p.read_bytes()
 except PermissionError:data=subprocess.check_output(['cat',str(p)])
 r=E.fromstring(data);ids={e.attrib['id']:e for e in r.iter() if 'id'in e.attrib}
 def de(e):
  while e is not None and 'ref'in e.attrib:e=ids[e.attrib['ref']]
  return e
 def fmt(e):
  e=de(e);return '' if e is None else e.attrib.get('fmt',e.text or '')
 def value(e):
  e=de(e)
  try:return float(e.text)
  except (ValueError,TypeError,AttributeError):return None
 rows=[]
 for node in r:
  schema=node.find('schema')
  if schema is None:continue
  cols=[c.findtext('mnemonic') for c in schema]
  for row in node.findall('row'):
   rows.append({k:{'fmt':fmt(v),'value':value(v)} for k,v in zip(cols,row)})
 return rows
encoders=parse('encoders.xml') or []
bycb=collections.defaultdict(list);byencoder={}
for row in encoders:
 cb=row['cmdbuffer-id']['fmt'];label=row['encoder-label']['fmt']
 bycb[cb].append(label);byencoder[row['encoder-id']['fmt']]=label
roles={}
for cb,labels in bycb.items():
 roles[cb]='composition' if any('Render Command' in x for x in labels) else 'mask' if any('ci_'in x for x in labels) else 'caption'
rows=parse('gpu.xml') or []
groups=collections.defaultdict(list);depths=collections.Counter();intervals=collections.defaultdict(list)
for row in rows:
 time=row['start']['value'];duration=row['duration']['value'];cb=row['cmdbuffer-id']['fmt']
 if time is None or duration is None or time<1e9 or cb not in roles:continue
 role=roles[cb];label=byencoder.get(row['encoder-id']['fmt'],'unresolved encoder')
 channel=row['channel-name']['fmt'];depth=row['event-depth']['value']
 depths[(role,channel,depth)]+=1
 if role=='composition':
  stage='composition compute (background and any precalculation)' if channel=='Compute' else 'compositor'
 else:stage=role
 groups[f'{stage} | {channel} | depth={depth}'].append(duration/1e6)
 intervals[(role,channel,cb)].append((time,time+duration))
def stats(v):
 s=sorted(v)
 return {'count':len(s),'meanMS':sum(s)/len(s),'p95MS':s[math.ceil(.95*len(s))-1],'p99MS':s[math.ceil(.99*len(s))-1],'maxMS':s[-1]}
unions=collections.defaultdict(list)
for (role,channel,cb),values in intervals.items():
    merged=[]
    for start,end in sorted(values):
        if merged and start<=merged[-1][1]:merged[-1]=(merged[-1][0],max(end,merged[-1][1]))
        else:merged.append((start,end))
    unions[role+' | '+channel].append(sum(end-start for start,end in merged)/1e6)
result={'stages':{k:stats(v) for k,v in groups.items()},'perCommandUnion':{k:stats(v) for k,v in unions.items()},'matchedCommandBuffers':dict(collections.Counter(roles.values())),'depthCounts':{str(k):v for k,v in depths.items()},'note':'GPU intervals may include driver scheduling/dependency stalls. Compute encoders can be coalesced; do not label the whole composition compute interval as prepass time.'}
cpu_file=run/'cpu.xml'
if cpu_file.exists() and cpu_file.stat().st_size:
    try:data=cpu_file.read_bytes()
    except PermissionError:data=subprocess.check_output(['cat',str(cpu_file)])
    root=E.fromstring(data);ids={e.attrib['id']:e for e in root.iter() if 'id' in e.attrib}
    def de(e):
        while e is not None and 'ref' in e.attrib:e=ids[e.attrib['ref']]
        return e
    def fmt(e):
        e=de(e);return e.attrib.get('fmt',e.text or '')
    running=collections.Counter();categories=collections.Counter();functions=collections.Counter();times=[]
    for node in root:
        schema=node.find('schema')
        if schema is None or schema.attrib.get('name')!='time-profile':continue
        columns=[c.findtext('mnemonic') for c in schema]
        for row in node.findall('row'):
            v=dict(zip(columns,row));time=float(de(v['time']).text)
            if time<1e9:continue
            times.append(time)
            if fmt(v['thread-state'])!='Running':continue
            weight=float(de(v['weight']).text)/1e6
            running[fmt(v['thread'])]+=weight
            frames=[de(f).get('name','?') for f in de(v['stack']).findall('frame')]
            for name in set(frames):functions[name]+=weight
            groups={'CG rasterization':['CGContext','ripc_','RIP','CGGState','CGSFill','CGSShade'],
                'Core Image':['CI::','CIContext','CIRender','CoreImage'],'mask renderer':['GradientMaskRenderer'],
                'drawable acquisition':['nextDrawable','CAMetalLayer'],'IOSurface':['IOSurfaceLock','IOSurfaceUnlock']}
            for name,terms in groups.items():
                if any(any(t in f for t in terms) for f in frames):categories[name]+=weight
    seconds=(max(times)-min(times))/1e9 if len(times)>1 else 0
    result['cpuSampling']={'observedSeconds':seconds,'runningMSByThread':dict(running),'inclusiveCategoriesMS':dict(categories),
        'inclusiveFunctionsMS':functions.most_common(25),'estimatedTotalCPUPercentFromSamples':sum(running.values())/seconds/10 if seconds else None}
(run/'trace-summary.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
