#!/usr/bin/env python3
"""Build all-frame navigation and max-pooled difference previews."""
import csv,html,json,sys
from pathlib import Path
import numpy as np
from PIL import Image
root=Path(sys.argv[1]);out=Path(sys.argv[2]);images=out/'images'
cases=json.loads((root/'cases.json').read_text());byname={c['name']:c for c in cases}
with (out/'frames.csv').open() as f:rows=[x for x in csv.DictReader(f) if x['group']!='sequence']
for r in rows:
 n=r['name'];scale=byname[n]['scale'];difference=np.array(Image.open(images/(n+'-difference.png')).convert('RGBA'))
 if scale==3:difference=difference.reshape(844,3,390,3,4).max(axis=(1,3))
 Image.fromarray(difference,'RGBA').save(images/(n+'-overview.png'))

def card(r):
 n=html.escape(r['name']);p=float(r['progress'])*100;t=float(r['idle_time']);dist=float(r['distortion'])
 title=f'{n} · {p:.0f}% · idle {t:.3f} с · distortion {dist:g} · пикселей отличаются: {r["pixels_different"]} ({float(r["pixels_different_pct"]):.5f}%)'
 c=f'<details><summary>{title}</summary><div class="grid">'
 for k,label in [('original','Исходный'),('optimized','Оптимизированный'),('difference','Разность ×64'),('overlay','Наложение 50/50'),('overview','Карта расхождений')]:
  path='images/'+n+'-'+k+'.png';c+=f'<figure><a href="{path}"><img loading="lazy" src="{path}"></a><figcaption>{label}</figcaption></figure>'
 return c+'</div></details>'
head='''<!doctype html><html lang="ru"><meta charset="utf-8"><title>V4 — сравнение Metal-композиции</title><style>body{font:16px -apple-system,sans-serif;max-width:1600px;margin:24px auto;padding:0 20px;background:#eee;color:#222}.grid{display:grid;grid-template-columns:repeat(5,1fr);gap:8px}figure{margin:8px 0}img{width:100%;height:auto}video{max-width:100%;background:#111}details{background:white;margin:9px 0;padding:10px}summary{cursor:pointer}p{line-height:1.45}</style><h1>GradientsKit V4 — сравнение Metal-композиции</h1><p>Исходная версия 9368500 и вариант предрасчёта. На кадрах — реальный Metal-рендер Mac с distortion, Dark-масками и compositor. Надписи и кнопки UIKit не отображены.</p><p>«Разность ×64» искусственно усилена. Для «Карты расхождений» объединены блоки по 3×3 пикселя — так отдельные изменённые пиксели легче найти. Наложение: 50/50. Нажмите на изображение для просмотра в исходном разрешении.</p><p>Видео — рассчитанные фазы с шагом 1/60 секунды, не запись кадрового времени iPhone. Сжатие видео может скрывать отдельные отличия.</p><p><a href="frames.csv">Таблица всех 494 кадров</a> · <a href="summary.json">Сводка</a></p>'''
sections=[]
for theme in ('dark','light'):
 items=[r for r in rows if r['theme']==theme]
 curated=[r for r in items if r['name'].startswith('extra-') and r['name'].endswith('-t3')]
 others=[r for r in items if r not in curated]
 sections.append(f'<h2>Yellow {theme.title()}</h2><video controls preload="metadata" src="cycles/{theme}-cycle-60fps.mp4"></video><h3>0%, 33%, 63%, 80%, 100%</h3>'+''.join(card(r) for r in curated)+'<details><summary>Все остальные эталонные и дополнительные кадры</summary>'+''.join(card(r) for r in others)+'</details>')
(out/'index.html').write_text(head+''.join(sections)+'</html>')
print('Navigation and maps ready for',len(rows),'frames')
