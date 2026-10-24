#!/usr/bin/env python3
"""Run unchanged compute control and actual fragment/compute adapters on Metal."""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
import numpy as np
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.dont_write_bytecode=True
sys.path.insert(0,str(ROOT/'Scripts'))
from compose_metal import compose

def compare(reference,folder,suffixes):
    files=sorted(p for p in folder.iterdir() if p.suffix in suffixes)
    changed=[]
    for path in files:
        a=(reference/path.name).read_bytes();b=path.read_bytes()
        if a!=b:
            dtype='<f2' if path.suffix=='.rgba16f' else '<f4'
            x=np.frombuffer(a,dtype=dtype).astype(np.float64);y=np.frombuffer(b,dtype=dtype).astype(np.float64)
            changed.append({'name':path.name,'different_components':int(np.count_nonzero(x!=y)), 'max_absolute_difference':float(np.max(np.abs(x-y))), 'reference_sha256':hashlib.sha256(a).hexdigest(),'candidate_sha256':hashlib.sha256(b).hexdigest()})
    return {'compared':len(files),'byte_identical':len(files)-len(changed),'changed':changed}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--reference-run',type=Path,required=True);p.add_argument('--suffix',default='');args=p.parse_args()
    base=args.reference_run
    assert json.loads((base/'result.json').read_text())['passed']
    frozen=json.loads((ROOT/'Validation/reference.json').read_text())['render_sha256']
    for name,sha in frozen.items():assert hashlib.sha256((base/'frames'/name).read_bytes()).hexdigest()==sha,name
    out=HERE/'Results'/('gpu'+args.suffix);out.mkdir(exist_ok=False)
    binary=out/'adapter-check'
    subprocess.run(['xcrun','swiftc','-O',str(HERE/'check_adapter.swift'),'-o',str(binary)],check=True)
    adapters=(HERE/'PrototypeAdapters.metal').read_bytes()
    shader=out/'prototype.metal';shader.write_bytes(compose()+b'\n'+adapters)
    reports={}
    for label,mode in [('fragment','fragment'),('compute','compute')]:
        dest=out/label
        command=[str(binary),str(shader),str(base/'cases.json'),str(dest)]
        if mode=='compute':command.append('compute')
        subprocess.run(command,check=True)
        reports[label]=compare(base/'frames',dest,{'.rgba16f'})
    dest=out/'unchanged-compute-control'
    subprocess.run([str(base/'render'),str(shader),str(base/'cases.json'),str(dest)],check=True)
    reports['unchanged_compute_control']=compare(base/'frames',dest,{'.rgba16f','.probe','.distortion'})
    specialized=Path('/tmp/gradients-uikit-compute-specialized-results')
    if len(list(specialized.glob('*.rgba16f')))==72:
        reports['rejected_scale_specialization']=compare(base/'frames',specialized,{'.rgba16f'})
    reports['conditions']={'gpu':'Apple M3 Pro','size':[390,844],'format':'rgba16Float','fastMath':True,'shader_source_sha256':hashlib.sha256(shader.read_bytes()).hexdigest(),'reference':'original 542b89b; verified, not rerecorded','scale':1,'limits':'This does not prove 3x Simulator full-composition equality; see screenshots.'}
    (HERE/'gpu-results.json').write_text(json.dumps(reports,indent=2))
    (out/'results.json').write_text(json.dumps(reports,indent=2))
    print(json.dumps({k:{'compared':v['compared'],'byte_identical':v['byte_identical'],'changed_outputs':len(v['changed'])} for k,v in reports.items() if 'compared' in v},indent=2),flush=True)
