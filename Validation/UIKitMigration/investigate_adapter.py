#!/usr/bin/env python3
"""Offline experiments only. Does not edit the app or canonical Metal sources."""
from pathlib import Path
import json,subprocess,hashlib,sys
h=Path(__file__).resolve().parent;r=h.parents[1];o=h/'Results/behavior-investigation';o.mkdir(exist_ok=True)
sys.path.insert(0,str(r/'Scripts'));from compose_metal import compose
s=compose().decode()+'\n'+(h/'PrototypeAdapters.metal').read_text();source=o/'adapter.metal';source.write_text(s)
checker=(h/'check_adapter.swift').read_text()
reports={}
import argparse
p=argparse.ArgumentParser();p.add_argument('--reference-run',type=Path,required=True);args=p.parse_args();ref=args.reference_run
for name,group,noscale in [('repeat',16,False),('group8',8,False),('scale1-control',16,True)]:
 text=s.replace('float2 p=(float2(id)+0.5)/scale;','float2 p=float2(id)+0.5;') if noscale else s
 target=o/(name+'.metal');target.write_text(text)
 swift=o/(name+'.swift');swift.write_text(checker.replace('width:16,height:16','width:'+str(group)+',height:'+str(group)))
 binary=o/(name+'-check');subprocess.run(['xcrun','swiftc','-O',str(swift),'-o',str(binary)],check=True,stdout=subprocess.DEVNULL)
 dest=o/name;subprocess.run([str(binary),str(target),str(ref/'cases.json'),str(dest),'compute'],check=True)
 changes=[]
 import numpy as np
 for f in sorted(dest.glob('*.rgba16f')):
  a=np.frombuffer((ref/'frames'/f.name).read_bytes(),dtype='<f2').reshape(844,390,4);b=np.frombuffer(f.read_bytes(),dtype='<f2').reshape(844,390,4)
  if (a!=b).any():
   coords=np.argwhere(a!=b);changes.append({'frame':f.name,'components':len(coords),'locations':[{'y':int(y),'x':int(x),'channel':int(c),'reference':float(a[y,x,c]),'adapter':float(b[y,x,c])} for y,x,c in coords[:10]]})
 reports[name]={'exact':72-len(changes),'changes':changes,'source_sha256':hashlib.sha256(text.encode()).hexdigest()}
(o/'results.json').write_text(json.dumps(reports,indent=2));print(json.dumps(reports,indent=2))
