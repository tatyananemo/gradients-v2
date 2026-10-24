#!/usr/bin/env python3
"""Repeated cold/warm full-frame captures. Uses existing isolated probe only."""
import json,time,subprocess,argparse
from pathlib import Path
from capture import DEVICE,BUNDLE,run
p=argparse.ArgumentParser();p.add_argument('--label',required=True);a=p.parse_args()
h=Path(__file__).resolve().parent;o=h/'Results/behavior-core/first-frame'/a.label;o.mkdir(parents=True,exist_ok=True)
c=Path(run('xcrun','simctl','get_app_container',DEVICE,BUNDLE,'data'))/'Documents'
for cycle in range(2):
 subprocess.run(['xcrun','simctl','terminate',DEVICE,BUNDLE],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 run('xcrun','simctl','launch',DEVICE,BUNDLE)
 for repeat in range(3):
  name=f'cold{cycle}-repeat{repeat}';q=dict(id=name+'-'+str(time.time_ns()),mode='behavior-uikit',dark=True,yellow=False,progress=.6,kind='contact',phase=2.1)
  (c/'request.json').write_text(json.dumps(q));deadline=time.monotonic()+90
  while True:
   try:
    ready=json.loads((c/'ready.json').read_text())
    if ready['id']==q['id']:
     if 'error' in ready:raise RuntimeError(ready)
     break
   except (FileNotFoundError,json.JSONDecodeError):pass
   if time.monotonic()>deadline:raise TimeoutError(q)
   time.sleep(.1)
  for delay in [0,1]:
   if delay:time.sleep(delay)
   run('xcrun','simctl','io',DEVICE,'screenshot',str(o/(name+f'-delay{delay}.png')))
  (o/(name+'.json')).write_text(json.dumps(ready,indent=2))
  print(a.label,name,flush=True)
