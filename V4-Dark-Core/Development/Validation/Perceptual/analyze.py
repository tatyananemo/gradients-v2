#!/usr/bin/env python3
"""Analyze final Metal-compositor readbacks; generate human-viewable output.

Inputs are unmodified raw BGRA8 and diagnostic RGBA16F pixels, not screenshots
or manually reconstructed gradients. UIKit overlay text is absent. The movie is
an offline 60-Hz phase sequence, not a measurement of actual presentation FPS.
"""
import csv
import html
import json
import math
import subprocess
import sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont

root=Path(sys.argv[1]);output=Path(sys.argv[2]);output.mkdir(parents=True,exist_ok=False)
images=output/'images';images.mkdir();movies=output/'cycles';movies.mkdir()
cases=json.loads((root/'cases.json').read_text());raw=root/'frames'
font_path='/System/Library/Fonts/Supplemental/Arial.ttf'
font=ImageFont.truetype(font_path,20)
records=[];sequences={};selected=[];global_timeline={}

def metrics(frame):
 name=frame['name'];scale=frame['scale'];w,h=390*scale,844*scale
 def read(variant,fmt,dtype):return np.memmap(raw/(name+'-'+variant+'.'+fmt),dtype=dtype,mode='r',shape=(h,w,4))
 before=read('before','bgra8',np.uint8);after=read('after','bgra8',np.uint8)
 # The render target is BGRA8, reorder to report RGBA.
 b=np.array(before[:,:,[2,1,0,3]],dtype=np.int16);a=np.array(after[:,:,[2,1,0,3]],dtype=np.int16)
 signed=a-b;delta=np.abs(signed);changed=np.any(delta!=0,axis=2);ys,xs=np.nonzero(changed)
 region=(max(0,int(236*scale)),min(h,int(553*scale)))
 gradient=np.maximum(np.max(np.abs(np.diff(b[:,:,:3],axis=0,prepend=b[:1,:,:3])),axis=2),np.max(np.abs(np.diff(b[:,:,:3],axis=1,prepend=b[:,:1,:3])),axis=2))
 edge=gradient>=2
 record={'name':name,'group':frame['group'],'theme':'dark' if frame['uniforms'][23]>.5 else 'light',
         'progress':frame['uniforms'][2],'idle_time':frame['uniforms'][26],
         'size':f'{w}x{h}','distortion':frame['distortion'],'pixels':w*h,'pixels_different':int(changed.sum()),
         'pixels_different_pct':float(changed.mean()*100),'max_rgba_8bit':delta.max(axis=(0,1)).tolist(),
         'mean_rgba_8bit':delta.mean(axis=(0,1)).tolist(),
         'bbox_pixels':[int(xs.min()),int(ys.min()),int(xs.max()),int(ys.max())] if xs.size else None,
         'changed_in_center_mask_zone':int(changed[region[0]:region[1],:].sum()),
         'changed_near_gradient_edges':int((changed&edge).sum()),'edge_pixels':int(edge.sum()),
         'changed_upper_third':int(changed[:h//3].sum()),'changed_middle_third':int(changed[h//3:2*h//3].sum()),'changed_lower_third':int(changed[2*h//3:].sum())}
 if frame['group']!='sequence':
  f0=read('before','rgba16f',np.float16);f1=read('after','rgba16f',np.float16)
  df=np.abs(np.asarray(f0,dtype=np.float32)-np.asarray(f1,dtype=np.float32))
  record['pixels_different_float16']=int(np.any(df!=0,axis=2).sum())
  record['max_rgba_float16']=df.max(axis=(0,1)).tolist();record['mean_rgba_float16']=df.mean(axis=(0,1),dtype=np.float64).tolist()
  del f0,f1,df
 return record,b.astype(np.uint8),a.astype(np.uint8),signed

def save_images(frame,record,b,a):
 name=frame['name'];delta=np.abs(a.astype(np.int16)-b.astype(np.int16));gain=64
 files={'original':b,'optimized':a,'difference':np.dstack([np.minimum(delta[:,:,:3]*gain,255).astype(np.uint8),np.full(delta.shape[:2],255,dtype=np.uint8)]),
        'overlay':((b.astype(np.uint16)+a.astype(np.uint16))//2).astype(np.uint8)}
 for label,arr in files.items():Image.fromarray(arr,'RGBA').save(images/(name+'-'+label+'.png'),optimize=False)
 selected.append(record)

def make_movie(theme):
 width,height=1170,876;path=movies/(theme+'-cycle-60fps.mp4')
 cmd=['/opt/homebrew/bin/ffmpeg','-v','error','-f','rawvideo','-pix_fmt','rgb24','-s',f'{width}x{height}','-r','60','-i','-','-an','-c:v','libx264','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart','-y',str(path)]
 process=subprocess.Popen(cmd,stdin=subprocess.PIPE)
 previous=None;steps=[];pixels=[];peak=[]
 for frame in (f for f in cases if f['name'].startswith('seq-'+theme+'-')):
  record,b,a,err=metrics(frame);records.append(record)
  if previous is not None:
   temporal=np.abs(err-previous)
   steps.append(int(temporal.max()));pixels.append(int(np.any(temporal!=0,axis=2).sum()))
  previous=err
  heat=np.minimum(np.abs(err[:,:,:3])*64,255).astype(np.uint8)
  board=Image.new('RGB',(width,height),(18,18,18));draw=ImageDraw.Draw(board)
  for i,(label,arr) in enumerate([('Original',b[:,:,:3]),('Optimized',a[:,:,:3]),('Absolute difference x64',heat)]):
   draw.text((i*390+8,4),label,font=font,fill='white');board.paste(Image.fromarray(arr,'RGB'),(i*390,32))
  process.stdin.write(board.tobytes())
 process.stdin.close()
 if process.wait()!=0:raise RuntimeError('ffmpeg failed')
 global_timeline[theme]={'frames':len(steps)+1,'time_step_seconds':1/60,'max_error_change_8bit':max(steps,default=0),
                         'mean_pixels_changing_error':float(np.mean(pixels)),'max_pixels_changing_error':max(pixels,default=0)}

for i,frame in enumerate(f for f in cases if f['group']!='sequence'):
 r,b,a,_=metrics(frame);records.append(r)
 save_images(frame,r,b,a)
 if i%12==0:print('Analyzed',i+1,'/132',flush=True)
for theme in ('dark','light'):
 print('Sequence',theme,flush=True);make_movie(theme)

for r in records:
 for key in ['max_rgba_8bit','mean_rgba_8bit','bbox_pixels','max_rgba_float16','mean_rgba_float16']:
  if key in r:r[key]=json.dumps(r[key],ensure_ascii=False)
fields=sorted({k for r in records for k in r})
with (output/'frames.csv').open('w',newline='') as f:
 writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader();writer.writerows(records)

summary={}
for group in ('golden','extra','sequence'):
 for theme in ('dark','light'):
  x=[r for r in records if r['group']==group and r['theme']==theme]
  summary[f'{group}_{theme}']={'frames':len(x),'changed_frames':sum(r['pixels_different']>0 for r in x),
   'changed_pixels_total':sum(r['pixels_different'] for r in x),'pixels_total':sum(r['pixels'] for r in x),
   'max_changed_pct':max(r['pixels_different_pct'] for r in x),
   'max_channel_delta_8bit':max(max(json.loads(r['max_rgba_8bit'])) for r in x),
   'mean_rgba_8bit': [sum(json.loads(r['mean_rgba_8bit'])[j]*r['pixels'] for r in x)/sum(r['pixels'] for r in x) for j in range(4)],
   'center_zone_changed':sum(r['changed_in_center_mask_zone'] for r in x),
   'edge_zone_changed':sum(r['changed_near_gradient_edges'] for r in x),
   'top_middle_bottom':[sum(r[k] for r in x) for k in ('changed_upper_third','changed_middle_third','changed_lower_third')],
   'max_channel_delta_float16':max((max(json.loads(r['max_rgba_float16'])) for r in x if 'max_rgba_float16' in r),default=None)}
(summary_path:=output/'summary.json').write_text(json.dumps({'groups':summary,'timeline':global_timeline},ensure_ascii=False,indent=2))

sections=[]
for theme in ('dark','light'):
 parts=[]
 for r in (v for v in selected if v['theme']==theme):
  n=html.escape(r['name']);p=r['progress'];t=r['idle_time'];dist=r['distortion']
  block=f'<details><summary>{n} · {p*100:.0f}% · idle {t:.3f} c · distortion {dist:g} · пикселей отличаются: {r["pixels_different"]} ({r["pixels_different_pct"]:.5f}%)</summary><div class="grid">'
  for k,label in [('original','Исходный'),('optimized','Оптимизированный'),('difference','Разность ×64'),('overlay','Наложение 50/50')]:
   path='images/'+n+'-'+k+'.png';block+=f'<figure><a href="{path}"><img loading="lazy" src="{path}"></a><figcaption>{label}</figcaption></figure>'
  parts.append(block+'</div></details>')
 sections.append(f'<h2>Yellow {theme.title()}</h2><video controls preload="metadata" src="cycles/{theme}-cycle-60fps.mp4"></video>'+''.join(parts))
page='''<!doctype html><html lang="ru"><meta charset="utf-8"><title>V4: сравнение Metal-композиции</title><style>body{font:16px -apple-system,sans-serif;max-width:1500px;margin:24px auto;padding:0 20px;background:#eee;color:#222} .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}figure{margin:8px 0}img{width:100%;height:auto}video{max-width:100%;background:#111}details{background:white;margin:9px 0;padding:10px}summary{cursor:pointer}small{line-height:1.5} code{background:#ddd}</style><h1>GradientsKit V4 — сравнение Metal-композиции</h1><p>Исходная версия и предрасчёт со специализацией. Кадры получены на GPU Mac; включены distortion, Dark-маски и compositor. Надписи и кнопки UIKit не отрисованы.</p><p>Разность ×64 усилена для диагностики. Наложение — среднее 50/50. Цвета в соседних изображениях не усилены. Нажмите на кадр для полного разрешения.</p><p>Видео — рассчитанная последовательность при 60 фазах в секунду, а не запись реального FPS устройства. Кодирование видео может скрывать однобитные отличия.</p><p><a href="frames.csv">Таблица всех кадров (CSV)</a> · <a href="summary.json">Числовая сводка</a></p>'''+''.join(sections)+'</html>'
(output/'index.html').write_text(page)
print('Saved results',output,flush=True)
