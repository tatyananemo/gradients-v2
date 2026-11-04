#!/usr/bin/env python3
"""Attach benchmark and caption-probe data to a generated comparison."""
import csv,hashlib,json,math,statistics,sys
from pathlib import Path
r=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(exist_ok=True)
results={}
for run in ['bench-final','bench-distortion']:
 samples=json.loads((r/run/'timings.json').read_text())
 groups={}
 for theme in ['dark','light']:
  for variant in ['reference','precalc']:
   xs=[a for a in samples if a['theme']==theme and a['variant']==variant and not a['name'].endswith('round0')]
   gpu=sorted(a['gpuMS'] for a in xs);masks=[a['maskGPUms'] for a in xs if 'maskGPUms' in a]
   groups[theme+'_'+variant]={'samples':len(xs),'composition_gpu_mean_ms':statistics.mean(gpu),
     'composition_gpu_p95_ms':gpu[math.ceil(.95*len(gpu))-1],
     'mask_gpu_mean_sum_ms':statistics.mean(masks) if masks else None,
     'mask_samples':len(masks)}
 results[run]=groups
 with (out/(run+'-samples.csv')).open('w',newline='') as f:
  w=csv.DictWriter(f,fieldnames=['name','theme','scale','variant','gpuMS','maskGPUms']);w.writeheader();w.writerows(samples)
caption=json.loads((r/'caption-final.json').read_text());sequences=[x for x in caption if x['group']=='sequence']
results['caption']={'frames':len(caption),'frames_different_probe_components':sum(x['differentComponents']>0 for x in caption),
 'max_probe_component_difference':max(x['maxDifference'] for x in caption),
 'max_risk_difference':max(abs(x['riskBefore']-x['riskAfter']) for x in caption),
 'sequence_frames':len(sequences),'max_modeled_activation_difference':max(abs(x['activationBefore']-x['activationAfter']) for x in sequences),
 'sequence_hysteresis_decision_differences':sum(x['neededBefore']!=x['neededAfter'] for x in sequences)}
trial=Path('/private/tmp/v4-axis-precalculation-20261028/trial')
results['inputs']={'reference_source_sha256':hashlib.sha256((trial/'candidate936.metal').read_bytes()).hexdigest(),
 'candidate_source_sha256':hashlib.sha256((trial/'precalculated.metal').read_bytes()).hexdigest(),
 'comparison': '9368500 background vs precalculation with function constant 3; candidate compositor and caption use function constant 0',
 'device':'Apple M3 Pro; native macOS Metal', 'scope':'Metal compositor only; no UIKit overlay or device display'}
(out/'performance.json').write_text(json.dumps(results,indent=2,ensure_ascii=False))
(out/'caption-probe.json').write_text(json.dumps(caption,ensure_ascii=False,indent=2))
(out/'cases.json').write_text((r/'cases.json').read_text())
summary=json.loads((out/'summary.json').read_text())
rows=''
for group,label in [('golden','Эталонные'),('extra','Дополнительные'),('sequence','Последовательность')]:
 for theme in ['dark','light']:
  g=summary['groups'][group+'_'+theme]
  rows+=f'<tr><td>{label}</td><td>{theme.title()}</td><td>{g["changed_frames"]}/{g["frames"]}</td><td>{g["max_changed_pct"]:.4f}%</td><td>{g["max_channel_delta_8bit"]}/255</td></tr>'
bench=results['bench-final'];perf=''
for theme in ['dark','light']:
 a=bench[theme+'_reference']['composition_gpu_mean_ms'];b=bench[theme+'_precalc']['composition_gpu_mean_ms']
 perf+=f'<tr><td>{theme.title()}</td><td>{a:.2f} мс</td><td>{b:.2f} мс</td><td>{(1-b/a)*100:.1f}%</td></tr>'
page=out/'index.html';s=page.read_text();link=f'''<p><a href="performance.json">GPU: числовые замеры и условия</a> · <a href="caption-probe.json">Проверка анализатора подписи</a> · <a href="cases.json">Входные состояния</a></p>
<h2>Результаты числового сравнения</h2><p>Изменения измерены после Metal-композиции в BGRA8. Доля — максимальная для одного кадра в группе; максимальное отличие — по одному из каналов RGBA.</p>
<table border="1" cellpadding="6"><tr><th>Набор</th><th>Тема</th><th>Кадры с отличиями</th><th>Макс. доля пикселей</th><th>Макс. отличие канала</th></tr>{rows}</table>
<p>Полные значения по каждому каналу, координаты, центр масок и зоны локальных границ находятся в CSV. Границы — приближённая оценка по соседним пикселям; вертикальная зона масок также приблизительная. RGBA16F — отдельный диагностический вариант целевой текстуры.</p>
<h2>GPU Mac M3 Pro</h2><p>Среднее после прогрева: фоновый расчёт, дополнительный предрасчёт кандидата и compositor. Три Dark-маски измерялись отдельно; анализатор подписи и отображение кадра здесь не включены.</p><table border="1" cellpadding="6"><tr><th>Тема</th><th>Исходный</th><th>Предрасчёт</th><th>Разница</th></tr>{perf}</table>
<p>Dark-маски: {bench['dark_reference']['mask_gpu_mean_sum_ms']:.2f} / {bench['dark_precalc']['mask_gpu_mean_sum_ms']:.2f} мс — сумма трёх GPU-команд; код масок одинаков, разницу нельзя приписывать оптимизации. Эти показатели не являются FPS на iPhone.</p>'''
s=s.replace('<h2>Yellow Dark</h2>',link+'<h2>Yellow Dark</h2>',1);page.write_text(s)
print('Saved performance, caption and provenance')
