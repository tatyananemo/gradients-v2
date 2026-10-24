#!/usr/bin/env python3
"""Build review page from real compositor captures and recordings, never synthesize app frames."""
from pathlib import Path
import json,html
import numpy as np
from PIL import Image,ImageDraw
H=Path(__file__).resolve().parent;R=H/'Results';O=R/'behavior-core';O.mkdir(exist_ok=True)
themes=['blue-dark','blue-light','yellow-dark','yellow-light'];titles=['Blue Dark','Blue Light','Yellow Dark','Yellow Light']
rows=[];cards=[]
for theme,title in zip(themes,titles):
 for p in [0,30,60,80,100]:
  for kind in ['contact','swipe'] if p==60 else ['contact']:
   n=f'{theme}-{p:03}-{kind}'+('-0' if kind=='swipe' else '')
   before=R/'behavior-swiftui'/(n+'.png');after=R/'behavior-uikit'/(n+'.png')
   ma=json.loads(before.with_suffix('.json').read_text());mb=json.loads(after.with_suffix('.json').read_text())
   equal={k:ma[k]==mb[k] for k in ['uniforms','history','progress','time','distortion','activation']}
   if not all(equal.values()):raise RuntimeError((n,equal))
   a=np.array(Image.open(before).convert('RGB'),dtype=np.int16);b=np.array(Image.open(after).convert('RGB'),dtype=np.int16);delta=np.abs(a-b)
   diff=O/'diff';diff.mkdir(exist_ok=True)
   Image.fromarray(np.minimum(delta*8,255).astype(np.uint8)).save(diff/(n+'.png'))
   rows.append(dict(name=n,inputs_equal=equal,mae=float(delta.mean()),max_delta=int(delta.max()),changed_pixels=int(np.count_nonzero(np.any(delta,axis=2)))))
   cards.append(f'<article class="still" data-theme="{theme}" data-progress="{p}"><h3>{title} · {p}% · {kind}</h3><div class="pair"><figure><figcaption>ДО — SwiftUI V2</figcaption><a href="../behavior-swiftui/{n}.png"><img loading="lazy" src="../behavior-swiftui/{n}.png"></a></figure><figure><figcaption>ПОСЛЕ — UIKit + новое ядро</figcaption><a href="../behavior-uikit/{n}.png"><img loading="lazy" src="../behavior-uikit/{n}.png"></a></figure><figure class="difference"><figcaption>Разность ×8</figcaption><img loading="lazy" src="diff/{n}.png"></figure></div></article>')
for p in [30,60,80]:
 board=Image.new('RGB',(390*8,886),'#16191d');d=ImageDraw.Draw(board)
 for i,(t,title) in enumerate(zip(themes,titles)):
  for j,(folder,label) in enumerate([('behavior-swiftui','ДО SwiftUI'),('behavior-uikit','ПОСЛЕ UIKit')]):
   im=Image.open(R/folder/f'{t}-{p:03}-contact.png').convert('RGB').resize((390,844))
   x=(i*2+j)*390;board.paste(im,(x,42));d.text((x+8,12),title+' / '+label,fill='white')
 board.save(O/f'all-themes-{p}.png')
motion=[];motion_report={}
for t,title in zip(themes,titles):
 for mode in ['swiftui','uikit']:
  path=O/'motion'/f'{t}-{mode}.json'
  if path.exists():motion_report[t+'-'+mode]=json.loads(path.read_text())
 motion.append(f'''<article class="motion" data-theme="{t}"><h3>{title} · непрерывная запись</h3><div class="pair"><figure><figcaption>ДО — SwiftUI V2</figcaption><video muted playsinline preload="metadata" src="motion/{t}-swiftui.mp4"></video></figure><figure><figcaption>ПОСЛЕ — UIKit + новое ядро</figcaption><video muted playsinline preload="metadata" src="motion/{t}-uikit.mp4"></video></figure></div><p><button class="play">▶ Синхронно</button> <button class="pause">Пауза</button> <input class="seek" type="range" min="0" max="31.9" step="0.05" value="0"> <output>0.00 с</output></p><p class="markers">'''+''.join(f'<button data-time="{time}">{label}</button>' for time,label in [(0,'CONTACT / idle'),(2,'Свайп'),(5,'Удержание'),(6,'Отпускание'),(7.5,'Idle'),(15,'Накопление прогресса'),(28,'100%'),(30,'Reset')])+'''</p></article>''')
summary=dict(static_comparisons=rows,motion=motion_report,reference_preserved=True)
(O/'comparison.json').write_text(json.dumps(summary,indent=2))
page='''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Gradients V2 — поведенческое ядро UIKit</title><style>body{margin:24px;background:#16191d;color:#eee;font:16px system-ui}header{max-width:1100px}a{color:#91d9ff}button,select,input{font:inherit}button,select{padding:7px 10px;background:#303641;color:white;border:1px solid #687481;border-radius:5px;margin:3px}article{border-top:1px solid #505967;padding:18px 0}.pair{display:flex;gap:16px;align-items:flex-start}figure{margin:0;width:390px;max-width:45vw}img,video{width:100%;display:block}figcaption{padding:8px 0}.difference{display:none}body.diff .difference{display:block}.seek{width:40%;vertical-align:middle}p{line-height:1.5}.notice{background:#242b35;padding:14px;border-radius:8px}summary{cursor:pointer}pre{white-space:pre-wrap}</style><header><h1>Gradients V2: SwiftUI → UIKit + Metal</h1><p>Этап: перенос поведенческого ядра и его подключение к UIKit. Исходная SwiftUI V2 сохранена. Все изображения и записи ниже получены из настоящего рендера iOS Simulator, размер экрана 390 × 844 pt / 1170 × 2532 px.</p><p><a href="all-themes-30.png">Все темы, 30%</a> · <a href="all-themes-60.png">Все темы, 60%</a> · <a href="all-themes-80.png">Все темы, 80%</a> · <a href="comparison.json">Метаданные сравнения</a> · <a href="../../BEHAVIOR-MILESTONE.md">Результат и ограничения</a> · <a href="first-frame/home-indicator-comparison.png">Причина первого кадра</a> · <a href="../index.html">Предыдущий визуальный эталон</a></p><p class="notice">Статика: одинаковые 28 uniform-параметров, история, время, прогресс, distortion и activation. Видео: один и тот же сценарий событий с шагом 1/60 с, скорость воспроизведения 1×. Запись и экспорт 30 fps; это не заявление о стабильных 60 fps рендера. Кадры не интерполированы и не дорисованы. Для Motion начальное состояние — 30%; переход к 100% происходит только через исходную формулу свайпов. Отдельный тест ядра проверяет путь от 0 до 100%.</p><p>0–2 с CONTACT/idle · 2–5 свайп · 5–6 удержание · 6 отпускание · 6–9 idle · 9–29 свайпы до 100% · 29 отпускание · 30 reset · 30–32 idle.</p><p class="notice">Это промежуточный этап. Цифровой переход SwiftUI numericText и его анимированная презентация reset пока не воспроизведены UIKit-аналогом; численные состояния reset совпадают. У Dark-прототипа в Simulator есть пропуски кадров при обновлении CG/CI-масок; они отражены в записи и метаданных. Финальная упаковка SDK, гибкий layout и полный перенос демонстрационного UI ещё не выполнены.</p><label>Тема <select id="theme"><option value="all">Все четыре</option>'''+''.join(f'<option value="{t}">{name}</option>' for t,name in zip(themes,titles))+'''</select></label> <label><input id="diff" type="checkbox"> Показать разность ×8</label></header><h2>В движении</h2>'''+''.join(motion)+'''<h2>Полные кадры</h2>'''+''.join(cards)+'''<script>document.querySelector('#theme').onchange=e=>document.querySelectorAll('article').forEach(a=>a.hidden=e.target.value!=='all'&&a.dataset.theme!==e.target.value);document.querySelector('#diff').onchange=e=>document.body.classList.toggle('diff',e.target.checked);document.querySelectorAll('.motion').forEach(a=>{let v=[...a.querySelectorAll('video')],seek=a.querySelector('.seek'),o=a.querySelector('output');a.querySelector('.play').onclick=()=>{let t=+seek.value;v.forEach(x=>{x.currentTime=t;x.play()})};a.querySelector('.pause').onclick=()=>v.forEach(x=>x.pause());function go(t){v.forEach(x=>{x.pause();x.currentTime=t});seek.value=t;o.value=t.toFixed(2)+' с'}seek.oninput=()=>go(+seek.value);a.querySelectorAll('[data-time]').forEach(b=>b.onclick=()=>go(+b.dataset.time));v[0].ontimeupdate=()=>{seek.value=v[0].currentTime;o.value=v[0].currentTime.toFixed(2)+' с';if(!v[0].paused&&Math.abs(v[1].currentTime-v[0].currentTime)>.10)v[1].currentTime=v[0].currentTime}})</script>'''
(O/'index.html').write_text(page)
print('Static:',len(rows),'Motion:',len(motion_report));print(O/'index.html')
