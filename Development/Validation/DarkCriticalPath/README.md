# Yellow Dark critical-path experiment — 29 October 2026

Branch: `experiment/v4-dark-critical-path`. Main, the maintained SDK, source colors,
shader formulas, numeric oracles and installed iPhone apps are unchanged.
No iPhone/Simulator process was launched for this stage. Data is in
`/private/tmp/v4-dark-critical-path-20261029`; physical traces are the earlier
`/private/tmp/v4-device-comparison-20261029/idle-{reference,precalc}-dark` recordings.

## What actually limits the physical run

The earlier physical run was Release on A15 at 1170×2532, progress .63, Nominal,
brightness .35, low-power mode off, with Metal System Trace + Time Profiler.
Those 12-second instrumented windows are comparable to each other, not to an
unprofiled run or a Mac benchmark.

| Physical metric | Reference | Precalc |
| --- | ---: | ---: |
| Presented FPS | 17.50 | 24.62 |
| Mean presentation interval, ms | 57.14 | 40.62 |
| p95 / p99 interval, ms | 66.75 / 66.76 | 50.06 / 50.09 |
| CPU-frame wall time, ms (includes drawable wait) | 52.34 | 36.53 |
| Drawable acquisition wall time, ms | 39.38 | 26.28 |
| Three-mask preparation wall time, ms | 12.64 | 9.98 |
| Mask 0 / 1 / 2 raster-stage wall time, ms | 9.59 / 6.61 / 2.05 | 7.14 / 4.58 / 1.46 |
| Mask 0 / 1 / 2 CI encoding wall time, ms | 2.82 / 3.02 / 3.41 | 2.61 / 2.92 / 2.71 |
| Background/prep compute interval union per CB, ms | 49.17 | 36.59 |
| Compositor fragment interval per CB, ms | 3.36 | 3.37 |
| Caption compute interval per CB, ms | .161 | .249 |
| GPU completion to handler, ms | .77 | .70 |
| Handler to main, ms | 24.55 | 20.93 |

The three mask workers execute concurrently. Individual raster, encode and GPU
command durations must not be added to the frame latency. GPU channels and
nested intervals overlap too. `gpuStartTime...gpuEndTime` is an elapsed command
interval, not isolated shader ALU time. In particular, a long vertex interval
is not proof that the three-vertex shader is expensive.

Offline union/intersection of the actual saved Precalc GPU and drawable-wait
intervals found: 99.8% of drawable-wait time overlaps app GPU intervals, and
85.8% overlaps background/prep compute. GPU intervals cover almost the whole
11.01-second analysis window (this includes driver dependency stalls).
Running CPU samples show only 60 ms total in drawable acquisition in the
Reference trace, despite many seconds of acquisition wall time. This is
back-pressure/blocking, not equivalent CPU busy time. Main-thread completion
callbacks are then delayed by the blocking render work. No in-flight slot skips
were counted in that physical window; absent display-link ticks and late presents
are the observed lost frames, not an evidence-based claim about slot exhaustion.

The full live path is: CADisplayLink on main → session time/state → reserve one
of three input slots → copy uniforms/history → MTKView draw/currentDrawable →
three parallel CG ellipse/radial raster jobs into the existing IOSurface pool →
CI Gaussian encodings on the shared queue → caption probe on its own queue →
axis/frame prep → background compute → optional distortion → compositor →
present → completion releases slot on main. Resource sizes, tracked lifetimes,
queue ordering, nil-drawable guard and fatal-error handling remain unchanged.

## Why masks cannot just be cached

Even in idle, breath, translations, x/y scales and blur radius change with time.
The full raster/blurred result is animated, so freezing it or refreshing it less
frequently is invalid. Width/height/color stops are constant only while progress
is unchanged. Contexts, output textures and bounded IOSurfaces already persist;
there is no normal per-frame output-texture creation or `waitUntilCompleted()`
in the live SDK. `CGContext.makeImage()` is the busy/unavailable-source fallback,
not the normal IOSurface path. A repeated wait/new bitmap hypothesis is not
established by these traces.

## Three isolated trials

The screening benchmark used 96 post-warmup native-size Dark frames per variant,
rotated variant order, the same inputs, and elapsed wall time from CPU mask start
through completed GPU composition. This is an offscreen latency test, not FPS.

| Trial | Full-frame ms | Relative to Precalc | Decision |
| --- | ---: | ---: | --- |
| Existing Precalc | 12.32 | — | Control |
| Cache unanimated local CG source; transform every frame before original blur | 12.77 | 3.6% slower | Exclude; CPU time drops but resampling/encoding offsets it |
| Cache additional X/Y CONTACT exponentials in existing prep pass | 13.51 | 9.6% slower | Exclude; more loads/compiler cost; no speed benefit |
| Remove transparent full-screen expansion before Gaussian | 9.76 | 20.8% faster | Keep only as explicit experimental build overlay |

The last trial removes exactly one expression from `GradientMaskRenderer.swift`
(line 136 in the maintained source):

```swift
.composited(over: CIImage(color: .clear).cropped(to: fullExtent))
```

The CG raster, mask shape, input pixel scale, Gaussian filter and radius, final
crop/flip, output texture dimensions/format, blending, IOSurface pool, in-flight
count and command ordering are unchanged. Core Image can work from the finite
1170×540 source instead of an artificial transparent 1170×2532 input domain.
This changes Core Image's evaluated graph and its numerical results slightly;
it is NOT described as pixel-exact or as a new custom Gaussian algorithm.

Two further runs sampled all 16 phases of the 3-second idle cycle across six
post-warmup cycles each: 192 samples per variant. No CPU profiling/trace export
or other benchmark ran concurrently with these timed runs. These results are
pooled; p99 remains sensitive to a few host/driver stalls.

| Mac M3 Pro metric, ms | Reference | Precalc | Precalc + finite mask domain |
| --- | ---: | ---: | ---: |
| Full-frame completion mean | 16.24 | 12.60 | 10.09 |
| Full-frame p95 | 21.69 | 16.13 | 13.61 |
| Full-frame p99 | 42.59 | 43.30 | 21.42 |
| Three-mask CPU preparation wall mean | 4.09 | 3.80 | 3.02 |
| Process CPU time per frame mean | 8.96 | 8.15 | 7.96 |
| Composition CB GPU elapsed mean | 10.60 | 7.42 | 5.86 |

The new change reduces end-to-end completion latency by 20.0% over Precalc,
37.9% over Reference, and mask preparation wall time by 20.5% over Precalc.
Process CPU busy-time reduction over Precalc is only 2.3%; this does NOT remove
the expensive CG radial rasterizer. Reduced composition CB elapsed time is not
a background shader rewrite: it also reflects less overlapping/dependent mask work.

A separate existing gesture-input/distortion benchmark (32 post-warmup samples)
measured full-frame mean 10.85 → 10.43 → 8.70 ms, p95 13.31 → 12.39 → 11.08 ms,
p99 13.35 → 12.55 → 11.16 ms. The new change adds 16.5% over Precalc here.
These are fixed replay inputs, not touchscreen-to-present latency measurements.

## Image correctness and limits

494 full offscreen compositor comparisons: 36 unchanged reference inputs, 96
additional native-size states and 362 sequential idle states (181 per theme).
No UIKit labels/buttons, native caption layer, drawable/presentation timing or
physical screen is synthesized by this host.

- Dark: max final RGBA8 difference **1/255** versus approved V4, including the
  existing Precalc difference. Worst changed-pixel fraction **3.3671%**, on the
  maximum-history/distortion frame. Average absolute error **0.001042/255 per
  channel** across tested Dark pixels (see machine summary for exact aggregate).
- Light: the mask-domain change is **exactly identical to Precalc** in all 247
  frames. Its previously reviewed Precalc-vs-approved difference remains ≤1/255.
- 168 raw Float16 mask comparisons: **NOT exact**. Maximum delta .002197265625,
  mean .000008461623; 545,624,346 differing components across the tested masks.
  This is a measured differential, not a pass against old exact mask goldens.
- 180 adjacent-pair comparisons per theme: max change in signed numerical error
  versus approved V4 is 2/255 in Dark and 1/255 in Light. Animation input times,
  geometry expressions and phase are untouched. These are error bounds, not a
  physical-device flicker/pacing test or proof that a 1-LSB difference is invisible.

No goldens or tolerances were updated. Whether these additional CI differences
are acceptable remains a visual approval decision.

## Build/integration checks

- Precalc Debug and Release, generic physical-iOS destination, code signing off:
  SDK and comparison Demo build successfully. No app install/launch.
- Six CPU preparation/resource-contract tests pass, including unchanged SDK
  inputs, single-expression mask overlay, three slots, resize/failure lifetimes,
  unchanged colors, fallback pipeline modes and public declarations.
- Existing source-color tests: 5/5. Behavior: 931 inputs, 1385 exact states,
  5540 exact frame-argument comparisons, Debug and Release.
- Normalized generated Release public Swift interface is identical to previous
  Precalc. Release metallib is byte-identical, SHA-256:
  `c8d5b70f3066c74629d0679c7108b15b150793c9c77c87c145fc063689329141`.
- Original SDK exact GPU and exact mask goldens are unchanged. The new candidate
  is evaluated by the differential tests above, not falsely claimed to pass
  old exact masks. UIKit component/UI runtime tests were not launched because
  devices/Simulator are forbidden in this stage.

## Practical next steps and remaining bottleneck

This is a useful mask-domain experiment, not a demonstrated 60-FPS solution.
The physical Precalc frame interval was 40.62 ms and must reach 16.67 ms. A
20% Mac offscreen improvement cannot be extrapolated to an A15 presentation rate
or a lower iPhone temperature; there is no new physical measurement.

1. Finite mask domain: measured improvement, minimal graph change, numeric visual
   risk quantified above. Next check is the same short A15 idle/gesture comparison
   after approval/cooling, checking CI differences and actual pacing.
2. Background duplicate geometry: the Yellow physical-field projection and Blue
   intensity reference each expand `PhysicalFields.inc` in the source; the Blue
   intensity remains necessary to the accepted Yellow readout. A compact shared
   per-pixel field/readout is a possible larger optimization, but source repetition
   alone does not prove duplicate machine instructions survive compilation. First
   isolate compiled cost/register pressure; then compare final images under the
   existing review protocol. Prior failed helper factoring must not be reapplied
   as an assumed equivalent transform. Expected gain is **unmeasured**, potentially
   limited by compiler CSE and extra live registers; visual risk is higher.
3. Drawable off main: bounded render-worker submission might remove ~26 ms of
   blocking from main in that trace and improve input scheduling, but expected GPU
   work reduction is **zero**. It requires careful snapshots/lifetimes and cannot
   solve GPU throughput/heat by itself. Do not implement casually after the prior
   resource-safety work; verify nil drawable, three-slot bounds, resize and lifecycle.

Heavy GPU/CG work is consistent with heating, but no temperature sensor or power
measurement was obtained and thermal causality is not quantified here.

## Reproduction

`prepare_trials.py --cases <existing 494-case review cases.json> --output <new tmp dir>`
prepares generated trial sources and compiles native macOS hosts only. All source
copies live in that output; the SDK is never changed. Then explicitly run:

```sh
<dir>/compare <dir> <dir>/cases.json <dir>/images validate domain-only
<dir>/compare <dir> <dir>/benchmark.json <dir>/bench benchmark domain-only
<dir>/raw-masks <dir>/raw
```

Read `Results/summary.json`; `summarize.py` aggregates the completed recorded run
folders. `analyze_timeline.py` reads the saved Instruments XML exports offline.
The two rejected trials are available only to the Mac test host, never to the
comparison app/SDK.

The opt-in unsigned iOS build uses the existing comparison project, with
`V4_MASK_DOMAIN=1` and `PrecalcDebug`/`PrecalcRelease`; Reference rejects that flag.
With the flag absent, both Reference and Precalc keep their original mask graph.
No new scheme, installed test app or public API was added. Apple documents that
[Core Image manages intermediate image buffers in its context](https://developer.apple.com/documentation/coreimage/cicontextoption/cacheintermediates);
this experiment changes the explicit image domain, not that cache setting.
