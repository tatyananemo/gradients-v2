#!/usr/bin/env python3
"""Build visual test inputs from 36 existing, unmodified Yellow validation cases."""
import argparse
import json
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--reference-cases',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
yellow=[c for c in json.loads(a.reference_cases.read_text()) if c['name'].startswith('yellow-')]
assert len(yellow)==36
frames=[]
def add(name,group,case,scale,distortion=0):
    frames.append(dict(name=name,group=group,uniforms=case['uniforms'],history=case['history'],scale=scale,distortion=distortion))
for c in yellow:
    distortion=0.65 if any(k in c['name'] for k in ['swipe','release','history']) else 0
    add('gold-'+c['name'],'golden',c,1,distortion)
for theme in ['dark','light']:
    template=next(c for c in yellow if c['name']==f'yellow-{theme}-p30-contact-t1.2')
    for pi,progress in enumerate([0,.33,.63,.8,1]):
        for ti,t in enumerate([0,.4,.8,1.2,1.65,2.1,2.4,2.999]):
            u=template['uniforms'].copy();u[2]=progress;u[10]=3+t;u[25]=1;u[26]=t;u[27]=0
            add(f'extra-{theme}-p{pi}-t{ti}','extra',{'uniforms':u,'history':[]},3)
    dynamic=[c for c in yellow if c['name'].startswith(f'yellow-{theme}-') and any(k in c['name'] for k in ['swipe','release','history','p30-main','p60-main','p80-main','p0-idle'])]
    assert len(dynamic)==8
    for i,c in enumerate(dynamic):
        u=c['uniforms'].copy();u[10]+=0.125
        add(f'extra-{theme}-dynamic{i}','extra',{'uniforms':u,'history':c['history']},3,.65 if c['history'] else 0)
    for i in range(181):
        u=template['uniforms'].copy();u[2]=.63;u[10]=3+i/60;u[25]=1;u[26]=i/60;u[27]=0
        add(f'seq-{theme}-{i:03}','sequence',{'uniforms':u,'history':[]},1)
assert [sum(f['group']==g for f in frames) for g in ('golden','extra','sequence')]==[36,96,362]
(a.output/'cases.json').write_text(json.dumps(frames,indent=2))
selected=[c for c in frames if c['group']=='extra' and 'dynamic' not in c['name'] and c['name'].endswith(('-t2','-t3','-t5'))]
bench=[]
for round in range(4):
    for c in selected:
        b=c.copy();b['name']=c['name']+'-round'+str(round);bench.append(b)
(a.output/'benchmark-cases.json').write_text(json.dumps(bench,indent=2))
dynamic=[c for c in frames if c['group']=='extra' and c['distortion']>0]
bench=[]
for round in range(3):
    for c in dynamic:
        b=c.copy();b['name']=c['name']+'-round'+str(round);bench.append(b)
(a.output/'benchmark-distortion.json').write_text(json.dumps(bench,indent=2))
print('Generated 36 goldens, 96 additional inputs and 362 sequential frames')
