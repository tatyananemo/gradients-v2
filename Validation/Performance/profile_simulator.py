#!/usr/bin/env python3
"""Profile the UIKit demo without captures. Pass a JSON output path.
Build Release first, set GRADIENTS_PROFILE_APP to its .app and optionally
GRADIENTS_SIMULATOR to an already booted iPhone 14 / iOS 18 UDID.
Simulator reports GPU-completion cadence, NOT physical display FPS/latency.
The same deterministic idle/swipe/hold/release trace is used for all four themes.
"""
import subprocess,os,json,time,sys
from pathlib import Path
uid=os.environ.get('GRADIENTS_SIMULATOR','468B8589-9260-4F1B-8958-63737D5D8BB6');bundle='com.local.gradients.v2.uikit'
app=os.environ['GRADIENTS_PROFILE_APP']
subprocess.run(['xcrun','simctl','terminate',uid,bundle],capture_output=True,timeout=20)
subprocess.run(['xcrun','simctl','install',uid,app],check=True,timeout=40)
data=Path(subprocess.check_output(['xcrun','simctl','get_app_container',uid,bundle,'data'],text=True,timeout=20).strip())/'Documents'
out={}
for theme,color in [('dark','blue'),('dark','yellow'),('light','blue'),('light','yellow')]:
 subprocess.run(['xcrun','simctl','terminate',uid,bundle],capture_output=True,timeout=20)
 target=data/'performance.json';target.unlink(missing_ok=True)
 env=dict(os.environ,SIMCTL_CHILD_GRADIENTS_THEME=theme,SIMCTL_CHILD_GRADIENTS_COLOR=color,SIMCTL_CHILD_GRADIENTS_PROGRESS='0.6',SIMCTL_CHILD_GRADIENTS_DIAGNOSTICS='1',SIMCTL_CHILD_GRADIENTS_BENCHMARK='1')
 subprocess.run(['xcrun','simctl','launch',uid,bundle],env=env,check=True,timeout=20)
 deadline=time.monotonic()+65
 while not target.exists() and time.monotonic()<deadline:time.sleep(.5)
 if not target.exists():raise RuntimeError('Benchmark timed out')
 result=json.loads(target.read_text());out[theme+'-'+color]=result
 Path(sys.argv[1]).write_text(json.dumps(out,indent=2))
 print(theme,color,json.dumps({k:result.get(k) for k in ['completionFPS','completionIntervalMS','cpuFrameMS','maskPreparationMS','gpuWorkMS','gpuEnvelopeMS','inputToCompletionMS','missedVSyncsEstimate']}),flush=True)
