#!/usr/bin/env python3
"""Compose SDK Metal from unchanged approved modules plus pipeline adapters."""
import argparse
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from compose_metal import compose,ROOT
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
source=compose().replace(b'[[ stitchable ]]',b'')+b'\n'+(ROOT/'UIKitComponent/Shaders/GradientAdapters.metal').read_bytes()
if not a.output.exists() or a.output.read_bytes()!=source:
 a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_bytes(source)
