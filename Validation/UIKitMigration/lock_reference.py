#!/usr/bin/env python3
"""Verify a frozen reference; initial recording refuses an existing lock."""
import argparse,hashlib,json
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--record',action='store_true');args=p.parse_args()
    lock=HERE/'baseline.json'
    if args.record:
        if lock.exists():raise SystemExit('Refusing to overwrite baseline.json')
        manifest=json.loads((HERE/'Results/swiftui/manifest.json').read_text())
        if len(manifest)!=88:raise SystemExit('Expected all 88 full-screen cases')
        data={'source':json.loads((HERE/'Build/provenance.json').read_text()),'capture':{'device':'468B8589-9260-4F1B-8958-63737D5D8BB6','os':'18.6','pixels':[1170,2532],'points':[390,844],'scale':3,'count':88,'settled_probe_samples':90},'images':manifest}
        lock.write_text(json.dumps(data,indent=2))
    data=json.loads(lock.read_text())
    for path,value in data['source']['files'].items():assert sha(ROOT/path)==value,path
    for name,value in data['images'].items():assert sha(HERE/'Results/swiftui'/(name+'.png'))==value['png_sha256'],name
    repeat=HERE/'Results/swiftui-repeat/manifest.json'
    if repeat.exists():
        other=json.loads(repeat.read_text())
        for name,value in other.items():
            for field in ['uniforms','history','caption','counter','activation','distortion','progress','time']:
                assert value['metadata'][field]==data['images'][name]['metadata'][field],(name,field)
    print('Frozen sources and 88 full-screen reference hashes verified; original GPU reference untouched')
