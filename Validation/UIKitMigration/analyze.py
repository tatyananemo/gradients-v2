#!/usr/bin/env python3
"""Exact decoded-pixel differences. Never alters the frozen reference."""
import hashlib,html,json
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
HERE=Path(__file__).resolve().parent
RESULTS=HERE/'Results'
FONT_PATH='/System/Library/Fonts/Supplemental/Arial.ttf'
def metrics(a,b):
    d=np.abs(a.astype(np.int16)-b.astype(np.int16))
    return dict(max_channel_delta=int(d.max()),mean_absolute_delta=float(d.mean()),changed_pixels=int(np.count_nonzero(d.max(axis=2))),pixels=int(d.shape[0]*d.shape[1]),exact=bool(not np.any(d)))
def analyze(label,left,right,names):
    rows=[]
    out=RESULTS/'diff'/label;out.mkdir(parents=True,exist_ok=True)
    for name in names:
        pa,pb=RESULTS/left/(name+'.png'),RESULTS/right/(name+'.png')
        if not pb.exists():raise FileNotFoundError(pb)
        ia,ib=Image.open(pa),Image.open(pb)
        assert ia.info.get('icc_profile')==ib.info.get('icc_profile'),(label,name,'ICC profile differs')
        a=np.asarray(ia.convert('RGB'));b=np.asarray(ib.convert('RGB'))
        ma=json.loads((RESULTS/left/(name+'.json')).read_text());mb=json.loads((RESULTS/right/(name+'.json')).read_text())
        for key in ['uniforms','history','caption','counter','activation','distortion','progress','time','size','scale']:
            if ma[key]!=mb[key]:raise AssertionError((label,name,key,ma[key],mb[key]))
        d=np.abs(a.astype(np.int16)-b.astype(np.int16))
        Image.fromarray(np.minimum(d*8,255).astype('uint8')).save(out/(name+'.png'))
        m=metrics(a,b)
        regions={}
        for key,box in [('counter',(45,260,345,540)),('caption',(0,591,390,844)),('controls',(0,40,390,110))]:
            x0,y0,x1,y1=[int(v*3) for v in box]
            regions[key]=metrics(a[y0:y1,x0:x1],b[y0:y1,x0:x1])
        rows.append(dict(name=name,left=f'{left}/{name}.png',right=f'{right}/{name}.png',diff=f'diff/{label}/{name}.png',metrics=m,regions=regions))
    return rows

def board(rows,path):
    width=260;height=round(2532/1170*width);gap=12;header=36
    out=Image.new('RGB',(3*width+4*gap,len(rows)*(height+header)+gap),(24,24,24));draw=ImageDraw.Draw(out)
    font=ImageFont.truetype(FONT_PATH,15)
    for i,row in enumerate(rows):
        for j,(key,title) in enumerate([('left','SwiftUI'),('right','UIKit + MTKView'),('diff','Difference ×8')]):
            x=gap+j*(width+gap);y=gap+i*(height+header)
            draw.text((x,y),title,fill='white',font=font)
            im=Image.open(RESULTS/row[key]).convert('RGB').resize((width,height),Image.Resampling.LANCZOS)
            out.paste(im,(x,y+header))
    out.save(path)
if __name__=='__main__':
    lock=json.loads((HERE/'baseline.json').read_text())
    for name,entry in lock['images'].items():
        assert hashlib.sha256((RESULTS/'swiftui'/(name+'.png')).read_bytes()).hexdigest()==entry['png_sha256'],name
    groups={'full':analyze('full','swiftui','uikit',sorted(lock['images']))}
    for label in ['background','caption']:
        names=sorted(p.stem for p in (RESULTS/('swiftui-'+label)).glob('*.png'))
        groups[label]=analyze(label,'swiftui-'+label,'uikit-'+label,names)
    for label in ['repeat','postprototype']:
        names=sorted(p.stem for p in (RESULTS/('swiftui-'+label)).glob('*.png'))
        groups[label]=analyze(label,'swiftui','swiftui-'+label,names)
    if (RESULTS/'uikit-release/manifest.json').exists():
        names=sorted(p.stem for p in (RESULTS/'uikit-release').glob('*.png'))
        groups['release']=analyze('release','uikit','uikit-release',names)
    if (RESULTS/'uikit-release-repeat/manifest.json').exists():
        names=sorted(p.stem for p in (RESULTS/'uikit-release-repeat').glob('*.png'))
        groups['release-repeat']=analyze('release-repeat','uikit','uikit-release-repeat',names)
    summary={name:{'cases':len(rows),'exact_cases':sum(r['metrics']['exact'] for r in rows),'max_delta':max((r['metrics']['max_channel_delta'] for r in rows),default=0),'mean_case_absolute_delta':sum(r['metrics']['mean_absolute_delta'] for r in rows)/max(len(rows),1)} for name,rows in groups.items()}
    report={'summary':summary,'groups':groups,'comparison':'decoded 8-bit RGB, exact comparison; no tolerance or reference replacement','gpu_comparison':'See gpu-results.json; screen metrics do not establish raw-GPU equality'}
    (RESULTS/'comparison.json').write_text(json.dumps(report,indent=2))
    blue=[next(r for r in groups['full'] if r['name']==f'{theme}-060-contact') for theme in ['blue-dark','blue-light']]
    board(blue,RESULTS/'comparison-blue-60.png')
    for p in [30,60,80]:
        selected=[next(r for r in groups['full'] if r['name']==f'{theme}-{p:03}-contact') for theme in ['yellow-dark','yellow-light']]
        board(selected,RESULTS/f'comparison-yellow-{p}.png')
    cards=[]
    for group,rows in groups.items():
        for row in rows:
            m=row['metrics'];cards.append(f'''<article data-group="{group}" data-name="{row['name']}"><h3>{html.escape(row['name'])} · {group}</h3><p>max Δ {m['max_channel_delta']}/255 · MAE {m['mean_absolute_delta']:.6f} · changed {m['changed_pixels']:,}/{m['pixels']:,}</p><div class="pair">'''+''.join(f'<figure><figcaption>{title}</figcaption><a href="{row[key]}"><img loading="lazy" src="{row[key]}"></a></figure>' for key,title in [('left','SwiftUI'),('right','UIKit / repeat'),('diff','|difference| ×8')])+'</div></article>')
    page='''<!doctype html><meta charset="utf-8"><title>Gradients V2 — UIKit feasibility</title><style>body{background:#17191c;color:#eee;font:15px system-ui;margin:24px}header{max-width:1100px}select,input{font:inherit;padding:8px;background:#30343a;color:white;border:1px solid #666}article{border-top:1px solid #555;margin-top:24px}.pair{display:flex;gap:16px}figure{margin:0;width:30%;max-width:390px}img{width:100%}figcaption{padding:8px}pre{white-space:pre-wrap}a{color:#8fd7ff}</style><header><h1>Gradients V2: SwiftUI → UIKit / MTKView</h1><p>Фиксированные состояния. Эталон dd5bb02 сохранён без замены. Все кадры — реальные Simulator screenshots 1170×2532, iOS 18.6. Разность усилена ×8; числа рассчитаны без допуска.</p><p>MAIN/CONTACT и поведение исходного приложения не изменены. Прототип не является завершённой миграцией. Адаптивная подложка зафиксирована после 90 исходных проб; динамика её включения и анимированный reset здесь не проверяются.</p><p><a href="comparison.json">Все метрики</a> · <a href="../gpu-results.json">GPU</a> · <a href="../FINDINGS.md">Выводы</a></p><pre>'''+html.escape(json.dumps(summary,indent=2))+'''</pre><label>Серия <select id="group"><option value="full">Полный экран</option><option value="background">Фон + distortion</option><option value="caption">Фон + подложка</option><option value="repeat">Повтор эталона</option><option value="postprototype">Эталон после добавления прототипа</option><option value="release">Debug / Release UIKit</option><option value="release-repeat">Повтор Release</option></select></label> <input id="name" placeholder="yellow-dark / 060 / swipe"></header>'''+''.join(cards)+'''<script>function filter(){document.querySelectorAll('article').forEach(x=>x.hidden=x.dataset.group!==document.querySelector('#group').value||!x.dataset.name.includes(document.querySelector('#name').value))}document.querySelectorAll('input,select').forEach(x=>x.addEventListener('input',filter));filter()</script>'''
    (RESULTS/'index.html').write_text(page)
    print(json.dumps(summary,indent=2),flush=True)
