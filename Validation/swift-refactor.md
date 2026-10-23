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

## Stage 2a — proven dead Swift only

- App Swift: 1,531 → 1,029 physical lines (502 removed; 707 since start).
- Canonical Metal: 13,485 unchanged; generated compile file: 13,503 unchanged.
- Removed GradientSwipeTrail and TrailContinuationWave: zero call sites.
- Removed DotPattern: sole call had constant zero opacity (waterSurfaceEnabled=true).
- Removed waterCausticOverlay branch: waterSurfaceVisible=false, plus only its coordinate calculations.
- Removed idleWaveOverlay branch: it excluded both cases of the two-case color enum.
  MAIN's active Metal idle/CONTACT remains unchanged.
- Removed PercentCenterMask's Light branch: sole call is guarded by isDarkTheme.
  Its active Dark body is compared verbatim against the approved source.
- Removed legacy trail samples: written by gesture code but read only by unused Canvas views.
  The live interactionTrail, its limits, timestamps and packing formula remain unchanged.
- Removed textShakeOffset: start time was only initialized/reset to -10; the offset was always zero.
- Reused the same v2History array for shader and caption probe; no second per-frame packing.
- Debug/Release succeeded; 72 frames, 216 GPU outputs, 33 behavior checkpoints exact.
- Main UI block, caption/probe, distortion modifier and mask uniforms are source-checked.
- Interactive isolated Simulator: four themes, settings, swipes (30 → 31 → 33%),
  release/idle visible and reset to 0%; no new visible difference observed.

## Stage 2b — mechanical responsibility split

- App Swift: 1,029 → 1,036 (+7 net lines for file imports/separation).
- Final reduction from the start of this work: 700 physical Swift lines, 40.3%.
- GradientInstallView.swift: 1,717 → 557 lines; state ownership and input/progress
  methods remain in that View. No new animation clock or observable model is introduced.
- Sources/GradientTheme.swift: theme/color enums.
- Sources/GradientInteractionState.swift: existing plain interaction state types.
- Sources/GradientSettings.swift: two selections and the existing tracking-safe UIKit theme control.
- Sources/GradientOverlays.swift: existing Dark counter mask, conditional distortion and caption environment keys.
- Sources/GradientCaption.swift: existing caption backdrop and asynchronous Metal caption probe.
- GradientsV2.xcodeproj/project.pbxproj adds those five files to the existing target.
- Required file-level access changes from private to internal only; algorithm bodies
  were checked mechanically before/after the move. Entry point/bundle ID unchanged.
- Debug and Release succeeded; 72 GPU frames / 216 outputs / 33 checkpoints exact.
- Both configurations' Xcode-generated Metal bytes match the original approved hash.
- Composer checks: 3 passed.
- Interactive isolated Simulator: Yellow Dark at 80%, swipe to 81%; Yellow Light,
  Blue Light and Blue Dark via settings, sheet dismissal and ongoing idle rendering.
- Original V2, V3 and production files match the previously recorded protected hashes.

## Size accounting

Physical editable runtime source lines, including normal comments/spacing.
Validation tools, skills and generated Metal copies are excluded from the total.
No minification or algorithm movement into a generator was performed in this work.

| Checkpoint | Swift | Canonical Metal | Total | Net removed from start |
| --- | ---: | ---: | ---: | ---: |
| Before Swift refactor | 1,736 | 13,485 | 15,221 | 0 |
| Settings simplified | 1,531 | 13,485 | 15,016 | 205 |
| Dead Swift removed | 1,029 | 13,485 | 14,514 | 707 |
| Files separated (final) | 1,036 | 13,485 | 14,521 | 700 |

The generated compiler input remains 13,503 lines before/after, excluded from
editable-source totals to avoid counting the same Metal twice. If counting that
compiler input instead of canonical modules, totals are 15,239 → 14,539, still -700.
The 6,000–8,000 goal is not reached at this Swift-only checkpoint. Metal cleanup
requires a separately approved next stage. No Metal optimization or UIKit migration started.

## Limits and rollback

The 72 fixed GPU cases are exact on Apple M3 Pro with the recorded toolchain;
this does not prove pixel identity for every possible gesture/time or benchmark iPhone FPS.
Simulator interaction is a manual smoke check, not a deterministic UI screenshot diff.
No visual difference was observed in those checks; active overlays and main layout
are additionally compared against the approved Swift source. Existing memcpy
return-value warnings remain unchanged; they are not errors or new runtime behavior.

Settings and dead-code removal are separate local commits, followed by the file
split. Each can be reverted independently. reference.json was never rerecorded.
No GitHub push was performed. Further Metal changes await confirmation.
