#!/usr/bin/env python3
"""Capture the Simulator compositor, including MTKView; no synthetic screenshots."""
import argparse,hashlib,json,subprocess,time
from pathlib import Path
HERE=Path(__file__).resolve().parent
DEVICE='468B8589-9260-4F1B-8958-63737D5D8BB6'
BUNDLE='com.local.gradients.v2.migrationprobe'
def run(*args):return subprocess.check_output(args,text=True,stderr=subprocess.DEVNULL).strip()
def cases():
    for dark,yellow,name in [(True,False,'blue-dark'),(False,False,'blue-light'),(True,True,'yellow-dark'),(False,True,'yellow-light')]:
        for p in [0,30,60,80,100]:
            for kind in ['main','contact']:
                yield dict(id=f'{name}-{p:03}-{kind}',dark=dark,yellow=yellow,progress=p/100,kind=kind,phase=1.65)
        for p in [30,60,80]:
            for phase in [1.2,2.1]:
                yield dict(id=f'{name}-{p:03}-contact-{phase}',dark=dark,yellow=yellow,progress=p/100,kind='contact',phase=phase)
        for kind,phase in [('swipe',0),('hold',0.3),('release',0.299),('release',0.7),('release',1.12),('reset',0.35)]:
            yield dict(id=f'{name}-060-{kind}-{phase}',dark=dark,yellow=yellow,progress=.6,kind=kind,phase=phase)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--mode',default='swiftui');parser.add_argument('--filter',default='');parser.add_argument('--suffix',default='');parser.add_argument('--set',choices=['all','diagnostic','core'],default='all');args=parser.parse_args()
    out=HERE/'Results'/(args.mode+args.suffix)
    if out==HERE/'Results/swiftui' and (HERE/'baseline.json').exists():raise SystemExit('Frozen reference exists; use --suffix for repeat capture')
    out.mkdir(parents=True,exist_ok=True)
    container=Path(run('xcrun','simctl','get_app_container',DEVICE,BUNDLE,'data'))/'Documents';container.mkdir(exist_ok=True)
    manifest=json.loads((out/'manifest.json').read_text()) if (out/'manifest.json').exists() else {}
    selected=[c for c in cases() if args.filter in c['id']]
    if args.set=='diagnostic':selected=[c for c in selected if (c['kind']=='contact' and c['progress'] in [.3,.6,.8] and c['phase']==1.65) or c['kind']=='swipe']
    if args.set=='core':selected=[c for c in selected if c['kind'] in ['main','contact'] and c['phase']==1.65]
    for i,case in enumerate(selected):
        request=dict(case,mode=args.mode);request['id']+=args.suffix+'-'+str(time.time_ns())
        target=out/(case['id']+'.png')
        (container/'request.json').write_text(json.dumps(request))
        deadline=time.monotonic()+90
        while True:
            try:
                metadata=json.loads((container/'ready.json').read_text())
                if metadata['id']==request['id']:
                    if 'error' in metadata:raise RuntimeError(metadata)
                    break
            except (FileNotFoundError,json.JSONDecodeError):pass
            if time.monotonic()>deadline:raise TimeoutError(request)
            time.sleep(.1)
        run('xcrun','simctl','io',DEVICE,'screenshot',str(target))
        (out/(case['id']+'.json')).write_text(json.dumps(metadata,indent=2))
        manifest[case['id']]={'case':case,'png_sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'metadata':metadata}
        (out/'manifest.json').write_text(json.dumps(manifest,indent=2))
        print(f'{i+1}/{len(selected)} {case["id"]}: activation={metadata["activation"]:.5f}',flush=True)
    print(out,flush=True)
