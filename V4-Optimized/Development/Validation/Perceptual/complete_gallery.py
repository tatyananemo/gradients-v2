#!/usr/bin/env python3
"""Complete an existing partial gallery using exactly the captured BGRA8 output."""
import csv,html,json,sys
from pathlib import Path
import numpy as np
from PIL import Image
root=Path(sys.argv[1]);out=Path(sys.argv[2]);images=out/'images'
cases=json.loads((root/'cases.json').read_text());raw=root/'frames'
with (out/'frames.csv').open() as f:stats={row['name']:row for row in csv.DictReader(f)}
extra={'dark':[],'light':[]}
for frame in cases:
 if frame['group']=='sequence':continue
 n=frame['name'];target=images/(n+'-original.png')
 if target.exists():continue
 s=frame['scale'];w,h=390*s,844*s
 def read(side):
  x=np.memmap(raw/(n+'-'+side+'.bgra8'),dtype=np.uint8,mode='r',shape=(h,w,4))
  return np.array(x[:,:,[2,1,0,3]])
 b,a=read('before'),read('after');d=np.abs(a.astype(np.int16)-b.astype(np.int16))
 result={'original':b,'optimized':a,'difference':np.dstack([np.minimum(d[:,:,:3]*64,255).astype(np.uint8),np.full((h,w),255,np.uint8)]),'overlay':((b.astype(np.uint16)+a.astype(np.uint16))//2).astype(np.uint8)}
 for k,v in result.items():Image.fromarray(v,'RGBA').save(images/(n+'-'+k+'.png'))
 r=stats[n];progress=float(r['progress'])*100;phase=float(r['idle_time']);escaped=html.escape(n)
 card=f'<details><summary>{escaped} · {progress:.0f}% · idle {phase:.3f} c · изменено пикселей: {r["pixels_different"]} ({float(r["pixels_different_pct"]):.5f}%)</summary><div class="grid">'
 for k,label in [('original','Исходный'),('optimized','Оптимизированный'),('difference','Разность ×64'),('overlay','Наложение 50/50')]:
  path='images/'+escaped+'-'+k+'.png';card+=f'<figure><a href="{path}"><img loading="lazy" src="{path}"></a><figcaption>{label}</figcaption></figure>'
 extra[r['theme']].append(card+'</div></details>')
page=out/'index.html';text=page.read_text()
for theme,cards in extra.items():
 text=text.replace('</html>',f'<h2>Все оставшиеся кадры — Yellow {theme.title()}</h2>'+''.join(cards)+'</html>')
page.write_text(text)
print('Added frames',sum(map(len,extra.values())))
