#!/usr/bin/env python3
"""Isolated Mac GPU experiments. No app launch, image files, or oracle updates.

Trial sources are test inputs only. Xcode always reads the maintained SDK MSL.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'Development/Validation'))
sys.path.insert(0,str(ROOT/'GradientsKit-V4/Scripts'))
from metal_dedup import undo_lazy_main
from compose_uikit_metal import compose_sdk

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--reference-run',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--rounds',type=int,choices=range(1,8),default=5)
p.add_argument('--prepare-only',action='store_true')
a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
reference=a.reference_run.resolve()
assert json.loads((reference/'result.json').read_text())['passed']
cases=json.loads((reference/'cases.json').read_text())
assert all(c['uniforms'][i]==0 for c in cases for i in (3,8,9,18))
current=compose_sdk().decode()
baseline=undo_lazy_main(current)
assert undo_lazy_main((ROOT/'GradientsKit-V4/ShaderSources/ApprovedBlue.metal.source').read_text())==subprocess.check_output(
    ['git','show','54863da:GradientsKit-V4/ShaderSources/ApprovedBlue.metal.source'],cwd=ROOT,text=True)
(out/'baseline.metal').write_text(baseline)
(out/'lazy.metal').write_text(current)
marker='kernel void prototypeComputeBackground('
assert baseline.count(marker)==1
prefix,body=baseline.split(marker)
for index in (3,8,9,18):
    token=f'u[{index}],';assert body.count(token)==1
    body=body.replace(token,f'(v4ZeroInputs ? 0.0 : u[{index}]),')
constants='constant bool v4UseFixedZeroInputs [[function_constant(0)]];\nconstant bool v4ZeroInputs = is_function_constant_defined(v4UseFixedZeroInputs) ? v4UseFixedZeroInputs : false;\n'
(out/'zeros.metal').write_text(prefix+constants+marker+body)
variants=[]
for name,source,w,h,zeros in [('baseline','baseline',16,16,False),('group32x4','baseline',32,4,False),
                            ('group8x8','baseline',8,8,False),('lazy','lazy',16,16,False),('zeros','zeros',16,16,True)]:
    variants.append(dict(name=name,source=str(out/(source+'.metal')),width=w,height=h,zeros=zeros))
manifest=dict(variants=variants,cases=str(reference/'cases.json'),oracle=str(ROOT/'Development/Validation/reference.json'),
              output=str(out/'isolated-results.json'),rounds=a.rounds)
(out/'isolated-manifest.json').write_text(json.dumps(manifest,indent=2))
if a.prepare_only:
    print('Prepared independent sources; no GPU work submitted.')
    sys.exit(0)
binary=out/'compare-background'
subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(out/'ModuleCache'),
                str(Path(__file__).with_name('compare_background_variants.swift')),'-o',str(binary)],check=True,timeout=120)
def run(name,config):
    path=out/(name+'-manifest.json');path.write_text(json.dumps(config,indent=2))
    with (out/(name+'.log')).open('w') as log:
        subprocess.run([str(binary),str(path)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=300)
    return json.loads(Path(config['output']).read_text())
isolated=run('isolated',manifest)
def exact(name):
    v=isolated['exact'][name]
    return not v['changed'] and not v['nativeSizeChanged']
if exact('lazy'):
    combined=[variants[0],dict(variants[3],name='lazy16')]
    if exact('group8x8'):combined.append(dict(variants[3],name='lazy8',width=8,height=8))
    run('combined',dict(manifest,variants=combined,output=str(out/'combined-results.json')))
print(json.dumps({'baselineCommit':'54863da','baselineCompilerInputSHA256':hashlib.sha256(baseline.encode()).hexdigest(),
                  'pixelExact':{v['name']:exact(v['name']) for v in variants},'results':str(out)},indent=2))
