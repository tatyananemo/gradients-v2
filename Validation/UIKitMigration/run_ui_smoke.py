#!/usr/bin/env python3
"""Run the same real UIKit gesture smoke test in all four themes."""
import json,time,subprocess,argparse
from pathlib import Path
from capture import run,DEVICE,BUNDLE
h=Path(__file__).resolve().parent;o=h/'Results/behavior-core';o.mkdir(exist_ok=True)
p=argparse.ArgumentParser();p.add_argument('--derived-data',default='/tmp/gradients-uikit-behavior-build');a=p.parse_args()
c=Path(run('xcrun','simctl','get_app_container',DEVICE,BUNDLE,'data'))/'Documents';reports={}
for dark,yellow,name in [(True,False,'blue-dark'),(False,False,'blue-light'),(True,True,'yellow-dark'),(False,True,'yellow-light')]:
 q=dict(id='uitest-'+name+'-'+str(time.time_ns()),mode='behavior-uikit',dark=dark,yellow=yellow,progress=0,kind='interactive',phase=1.65)
 (c/'request.json').write_text(json.dumps(q));deadline=time.monotonic()+60
 while True:
  try:
   ready=json.loads((c/'ready.json').read_text())
   if ready['id']==q['id']:
    if 'error' in ready:raise RuntimeError(ready)
    break
  except (FileNotFoundError,json.JSONDecodeError):pass
  if time.monotonic()>deadline:raise TimeoutError(q)
  time.sleep(.1)
 log=Path('/tmp')/('gradients-uikit-touch-'+name+'.log')
 with log.open('w') as f:
  result=subprocess.run(['xcodebuild','-project',str(h/'Build/MigrationProbe.xcodeproj'),'-scheme','222','-configuration','Debug','-destination','platform=iOS Simulator,id='+DEVICE,'-derivedDataPath',a.derived_data,'-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO','test-without-building'],stdout=f,stderr=subprocess.STDOUT)
 time.sleep(.3)
 state=json.loads((c/'interactive-state.json').read_text())
 reports[name]={'passed':result.returncode==0,'state_after_reset':state,'log':str(log)}
 (o/'ui-smoke.json').write_text(json.dumps(reports,indent=2))
 print(name,result.returncode,state,flush=True)
 if result.returncode:raise SystemExit(result.returncode)
