# Swift refactor — fixed approved parameters

Only the refactor checkout is changed. Baseline: 542b89b. Metal is unchanged.
The settings sheet retains only theme and color selection. All removed controls
are frozen at the initial Default values used by the approved render baseline.
Airy/Deep selection is intentionally removed; those optional presets are not the baseline.

| Removed control | Internal parameter | Fixed value |
| --- | --- | --- |
| Заполнение за 1/4 экрана | progressSpeed | 0.150 |
| Множитель заполнения | fillGain | 1.00 |
| Жест волны | waveStrength | 1.0 |
| Разлёт волн | waveSpread | 1.0 |
| Верхний bloom | topBloom | 1.0 |
| Белое ядро | whiteCore | 1.0 |
| Глубина синего | blueDepth | 1.0 |
| Амплитуда волн | shockStrength | 0.62 |
| Частота волн | shockInteraction | 1.0 |
| Длина волн | shockTrail | 0.74 |
| Количество волн | waveCount | 2 |
| Вода | waterIntensity | 0.94 |
| Масштаб воды | waterScale | 0.84 |
| Скорость воды | waterSpeed | 0.72 |

The three water parameters belonged to a disabled overlay; retaining their values
records the requested freeze. They do not alter the active Metal pipeline.
The main screen layout, caption styling and gesture algorithms are preserved.

Validation is extended without rerecording reference.json: original shader-call
expressions and fixed parameter values are checked, and the actual refactored
input handlers are replayed against the original behavior digest. GPU hashes
remain exact comparisons, not an image tolerance or a new candidate baseline.

## Stage 1 validation

- App Swift: 1,736 → 1,531 physical lines (205 removed).
- Canonical Metal: 13,485 → 13,485; generated compile file: 13,503 unchanged.
- Debug and Release Simulator builds succeeded.
- 72 GPU frames / 216 raw outputs and 33 behavior checkpoints match 542b89b exactly.
- Interactive isolated iPhone 14 / iOS 18.6: both settings, all four themes,
  dismiss sheet, continuous swipe (60 → 61%), caption preserved.
- Intentional UI difference: settings sheet only; height reduced from 620 to 300.
- No shader or runtime algorithm changes; no measured performance claim.
