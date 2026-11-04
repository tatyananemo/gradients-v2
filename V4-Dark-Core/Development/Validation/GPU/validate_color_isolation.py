#!/usr/bin/env python3
"""Offscreen Mac GPU isolation; mutate only an in-memory config, never the SDK.
No Simulator, app launch, PNG, video, HTML, oracle writes or relaxed tolerances.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3];SDK=ROOT/'GradientsKit-V4'
sys.path.insert(0,str(SDK/'Scripts'))
from compose_uikit_metal import compose_sdk
from source_colors import bind_metal,load

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--reference-run',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
cases=json.loads((a.reference_run/'yellow-cases.json').read_text())
inputs=out/'cases.json';inputs.write_text(json.dumps(cases))
expected=json.loads((ROOT/'Development/Validation/reference.json').read_text())['render_sha256']
binary=out/'adapter-check'
subprocess.run(['xcrun','swiftc','-O',str(Path(__file__).with_name('check_adapter.swift')),'-o',str(binary)],check=True)
canonical=compose_sdk().decode();default=load(SDK);results={}
for theme,opposite in [('dark','light'),('light','dark')]:
    config=copy.deepcopy(default)
    # Exercise every RGB binding, including common helper instantiation, not
    # just the easy direct CONTACT literal path. Keep values within warm gamut.
    for role,value in config[theme].items():
        config[theme][role]=['0.97','0.64','0.04'] if isinstance(value,list) else '0.97'
    shader=out/(theme+'.metal');shader.write_text(bind_metal(canonical,SDK,config))
    for mode in ['fragment','compute']:
        folder=out/(theme+'-'+mode)
        subprocess.run([str(binary),str(shader),str(inputs),str(folder),mode],check=True)
        exact_other=0;changed_target=0
        for item in cases:
            name=item['name']+'.rgba16f'
            same=hashlib.sha256((folder/name).read_bytes()).hexdigest()==expected[name]
            if item['name'].startswith('yellow-'+opposite+'-'):
                assert same,('Opposite theme changed',theme,mode,name)
                exact_other+=1
            elif not same:changed_target+=1
        assert exact_other==18 and changed_target>0
        results[theme+'-'+mode]={'opposite_theme_exact':exact_other,'target_frames_changed':changed_target}
(out/'result.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
