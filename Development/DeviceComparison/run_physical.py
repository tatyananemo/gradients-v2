#!/usr/bin/env python3
"""One bounded, authorized iPhone A/B run. Never launches a Simulator or main Demo.

Every invocation handles one run only and terminates its own launched PID.
Thermal pausing occurs autonomously in test-Demo code. No automatic retries.
"""
import argparse
from datetime import datetime
from zoneinfo import ZoneInfo
import json
import os
from pathlib import Path
import signal
import subprocess
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--device',required=True);p.add_argument('--instruments-device',required=True)
p.add_argument('--variant',choices=['reference','precalc'],required=True)
p.add_argument('--theme',choices=['dark','light'],default='dark')
p.add_argument('--mode',choices=['probe','idle','mixed'],required=True)
p.add_argument('--output',type=Path,required=True);p.add_argument('--trace',action='store_true')
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
bundle='com.local.gradients.v4.compare.'+a.variant
run_id=out.name
result={'runID':run_id,'variant':a.variant,'theme':a.theme,'mode':a.mode,'bundleID':bundle,'startedMoscow':datetime.now(ZoneInfo('Europe/Moscow')).isoformat(),'trace':a.trace}
duration=12 if a.mode=='idle' else 20
pid=None;trace=None;trace_log=None;snapshots=[]

def device(args,name,timeout=20,required=True):
    command=['xcrun','devicectl',*args,'--timeout',str(timeout),'--json-output',str(out/(name+'.json'))]
    with (out/(name+'.log')).open('w') as log:
        done=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=timeout+5)
    if done.returncode and required:raise RuntimeError('devicectl '+name+' failed; see '+str(out/(name+'.log')))
    path=out/(name+'.json')
    return json.loads(path.read_text()) if done.returncode==0 and path.exists() else None

def copy(name,local,required=False):
    return device(['device','copy','from','--device',a.device,'--source','Documents/'+name,'--destination',str(out/local),'--domain-type','appDataContainer','--domain-identifier',bundle],'copy-'+local.replace('.','-'),timeout=6,required=required)
try:
    env={'GRADIENTS_THEME':a.theme,'GRADIENTS_PROGRESS':'0.63','V4_PHYSICAL_MONITOR':'1','V4_RUN_ID':run_id}
    if a.mode=='probe':env['V4_THERMAL_PROBE']='1'
    else:env.update(GRADIENTS_DIAGNOSTICS='1',GRADIENTS_BENCHMARK='1',GRADIENTS_BENCHMARK_DURATION=str(duration),GRADIENTS_BENCHMARK_IDLE_ONLY='1' if a.mode=='idle' else '0')
    result['environment']=env
    launched=device(['device','process','launch','--device',a.device,'--terminate-existing','--environment-variables',json.dumps(env),bundle],'launch')
    pid=launched['result']['process']['processIdentifier'];result['pid']=pid
    start=time.monotonic()
    if a.trace:
        trace_log=(out/'trace-record.log').open('w')
        trace=subprocess.Popen(['xcrun','xctrace','record','--device',a.instruments_device,'--template','Metal System Trace','--instrument','Time Profiler','--time-limit',str(duration+5)+'s','--attach',str(pid),'--output',str(out/'metal.trace')],stdout=trace_log,stderr=subprocess.STDOUT)
    last=None
    while time.monotonic()-start<(12 if a.mode=='probe' else duration+10):
        copy('physical-monitor.json','monitor-latest.json')
        if (out/'monitor-latest.json').exists():
            monitor=json.loads((out/'monitor-latest.json').read_text())
            if monitor.get('runID')==run_id:
                last=monitor
                snapshots.append(monitor)
                if monitor['thermalState']>=2 or (monitor.get('stopped') and monitor['stopped']!='completed'):
                    result['status']='aborted';result['reason']=monitor.get('stopped') or 'thermal';break
                if a.mode=='probe':
                    result['status']='probe-completed'
                    if monitor['statistics'].get('submitted',0)!=0:raise RuntimeError('Thermal probe unexpectedly rendered GPU frames')
                    break
                if monitor.get('stopped')=='completed':result['status']='completed';break
        if trace is not None and trace.poll() not in (None,0):raise RuntimeError('Instruments failed; see trace-record.log')
        time.sleep(1.0)
    if last is not None:result['monitor']=last
    if 'status' not in result:result['status']='timeout';result['reason']='No completed/abort signal within bounded run'
    if result['status']=='completed':
        for _ in range(3):
            copy('performance.json','performance.json')
            if (out/'performance.json').exists():break
            time.sleep(0.25)
except BaseException as error:
    result['status']='error';result['reason']=str(error)
finally:
    if pid is not None:
        # Terminate only the PID returned for this exact test bundle.
        device(['device','process','terminate','--device',a.device,'--pid',str(pid)],'terminate',required=False)
    if trace is not None:
        if trace.poll() is None:
            trace.send_signal(signal.SIGINT)
        try:result['traceExit']=trace.wait(timeout=45)
        except subprocess.TimeoutExpired:
            trace.kill();result['traceExit']=trace.wait(timeout=5);result['traceSaveTimedOut']=True
    if trace_log is not None:trace_log.close()
    for name in ['physical-monitor.json','physical-stop.json','performance.json','renderer-state.json']:
        try:copy(name,name)
        except Exception as error:result['copyError-'+name]=str(error)
    result['endedMoscow']=datetime.now(ZoneInfo('Europe/Moscow')).isoformat()
    (out/'monitor-snapshots.json').write_text(json.dumps(snapshots,indent=2,ensure_ascii=False))
    (out/'result.json').write_text(json.dumps(result,indent=2,ensure_ascii=False))
    print(json.dumps({k:result.get(k) for k in ['runID','status','reason','pid','traceExit']},ensure_ascii=False))
    if 'monitor' in result:
        m=result['monitor'];print('Thermal',m['thermalState'],'elapsed',m['elapsed'],'brightness',m['screenBrightness'],'lowPowerMode',m['lowPowerMode'])
        print('Statistics',m['statistics'])
