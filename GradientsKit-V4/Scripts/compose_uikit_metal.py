#!/usr/bin/env python3
"""Compose the single SDK Metal path and internal build-time CPU color constants."""
import argparse
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from compose_metal import compose,ROOT
from source_colors import load,bind_metal,swift_source


def compose_sdk(root=ROOT):
    config=load(root)
    canonical=compose(root).replace(b'[[ stitchable ]]',b'')+b'\n'+(root/'Sources/GradientsKit/Shaders/GradientAdapters.metal').read_bytes()
    return bind_metal(canonical.decode(),root,config).encode()


def write(path,data):
    if not path.exists() or path.read_bytes()!=data:
        path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swift-output',type=Path);a=p.parse_args()
    write(a.output,compose_sdk())
    if a.swift_output:write(a.swift_output,swift_source(load(ROOT)).encode())
