#!/usr/bin/env python3
"""Record real Simulator compositor output. The same 60-Hz input trace feeds both engines."""
import json,subprocess,time,signal,argparse
from pathlib import Path
from capture import DEVICE,BUNDLE,run
HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--theme',default='');p.add_argument('--mode',default='');a=p.parse_args()
out=HERE/'Results/behavior-core/motion';out.mkdir(parents=True,exist_ok=True)
container=Path(run('xcrun','simctl','get_app_container',DEVICE,BUNDLE,'data'))/'Documents'
for dark,yellow,theme in [(True,False,'blue-dark'),(False,False,'blue-light'),(True,True,'yellow-dark'),(False,True,'yellow-light')]:
 if a.theme and a.theme!=theme:continue
 for mode in ['swiftui','uikit']:
  if a.mode and a.mode!=mode:continue
  name=f'{theme}-{mode}';movie=out/(name+'-raw.mov');target=out/(name+'.mp4')
  if target.exists():print('preserve existing',target,flush=True);continue
  recording=subprocess.Popen(['xcrun','simctl','io',DEVICE,'recordVideo','--codec=h264','--force',str(movie)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  while True:
   line=recording.stderr.readline()
   if 'Recording started' in line:break
   if recording.poll() is not None:raise RuntimeError('Recording failed: '+line)
  video_start=time.monotonic()
  request=dict(id=name+'-'+str(time.time_ns()),mode='behavior-'+mode,dark=dark,yellow=yellow,progress=.3,kind='motion',phase=1.65)
  (container/'request.json').write_text(json.dumps(request))
  ready=None;deadline=time.monotonic()+110
  try:
   while True:
    try:
     value=json.loads((container/'ready.json').read_text())
     if value['id']==request['id']:
      if 'error' in value:raise RuntimeError(value)
      if ready is None:ready=value;print('recording',name,'start',ready['startUptime']-video_start,flush=True)
     done=json.loads((container/'motion-done.json').read_text())
     if done['id']==request['id']:break
    except (FileNotFoundError,json.JSONDecodeError):pass
    if time.monotonic()>deadline:raise TimeoutError(request)
    time.sleep(.1)
   time.sleep(.5)
  finally:
   recording.send_signal(signal.SIGINT)
   try:recording.communicate(timeout=15)
   except subprocess.TimeoutExpired:recording.terminate();recording.communicate(timeout=5)
  # Both recordings begin at the shared logical t=0 and retain normal playback speed.
  offset=max(0,ready['startUptime']-video_start)
  subprocess.run(['ffmpeg','-v','error','-y','-ss',str(offset),'-i',str(movie),'-t','32','-vf','scale=390:844','-r','30','-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(target)],check=True)
  done.update(recording_offset=offset,request=request,ready=ready,real_simulator_recording=True,playback_speed=1,output_fps=30)
  (out/(name+'.json')).write_text(json.dumps(done,indent=2));print('done',name,done['milestones'],'frames',done['framesSubmitted'],'skipped',done['framesSkipped'],flush=True)
