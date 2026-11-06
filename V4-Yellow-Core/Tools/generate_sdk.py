#!/usr/bin/env python3
"""Expand the reviewed source inputs; no runtime or shader formula substitutions."""
from pathlib import Path
import argparse,sys,hashlib,json
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'Development/DeviceComparison'))
import prepare_sources

def generate(destination):
    outputs=prepare_sources.outputs('precalc',True,True,True,True,True)
    destination.mkdir(parents=True,exist_ok=True)
    for name,data in outputs.items():
        path=destination/name
        if not path.exists() or path.read_bytes()!=data:path.write_bytes(data)
    manifest={'mode':'precalc','mask_domain':True,'shared_background':True,'idle_zero_work':True,
        'swipe_optimization':True,'mask_roi':True,
        'files':{name:hashlib.sha256(data).hexdigest() for name,data in outputs.items()}}
    (destination/'SourceManifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    return manifest

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args();generate(args.output)
