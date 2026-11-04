> Исторический материал: относится к указанному ниже этапу/исходникам, а не к новой проверке `1b3c287`.
> Текущий статус V4-Optimized, границы точности масок/кадров, FPS и заполнение 9–10 с — в [RESULTS.md](../../../Documentation/RESULTS.md).
> Старые source guards могут намеренно отвергать поздние согласованные изменения; это не инструкция сборки optimized SDK.

# Mac-only visual comparison of V4 axis/frame precalculation

This validation folder is separate from SDK, Demo and the immutable oracles.
It renders V4's background, optional distortion, existing Dark CG/CI masks,
Dark backing and Metal compositor. BGRA8 is the production target format; the
RGBA16F target is an additional diagnostic pipeline, not the actual display
format. UIKit text, buttons, Light's UIKit caption layer, drawable presentation
and a physical iPhone are not reproduced. This is not an iPhone FPS test.

A 36-frame input set comes from unchanged Yellow validation cases. `prepare_cases.py`
adds 96 inputs at native 3x pixel size, including progress 0/33/63/80/100,
8 idle phases and 16 varied interaction states. Those interaction cases use a
specified 0.65 distortion strength for testing, not a recording of a real gesture.
The 362 additional sequence frames are two 3-second cycles at 60 timestamps/s.
Videos encode these static renders; temporal metrics are numerical rather than
an observation of vsync or device pacing.

The candidate uses the existing function-constant value 3 for its precalculation
and background compute; compositor and caption probe are individually
specialized with value 0 so they compute their original path without an input
cache. It cannot be dropped into existing SDK pipeline creation unmodified.
The candidate incurs a prep dispatch and an output buffer in addition to the
original pipeline. It was not installed or integrated into the application.

`RenderComparison.swift` runs the unchanged SDK `GradientMaskRenderer` once
per paired frame, uses the corresponding compiled Metal functions for each
variant, writes full compositor BGRA8 and diagnostic RGBA16F readbacks, and
fails on Metal errors. Benchmark mode re-renders masks separately for each
variant, alternates order, and records GPU command durations with the candidate's
extra prep pass. The mask samples are callback-reported sum of three individual
GPU command durations, not end-to-end GPU envelope or display interval. Caption
probe and UIKit are outside that benchmark. A separate distortion benchmark uses
synthetic gesture inputs. First round is warm-up.

`CaptionComparison.swift` evaluates the two caption probe pipelines and
replays the original risk/hysteresis calculation for the 60 Hz sequence at a
fixed dt; this is not a UIKit presentation test. `analyze.py` computes every
pixel's four-channel absolute error and bounding box, spatial counts, changes
of error between adjacent timestamps, original/after/64x-difference/50-50-overlay
PNGs, and labeled video comparisons. CSV retains per-frame channel maxima and
means. The `gradient edge` proxy means adjacent RGB difference >= 2/255; the
mask-zone counter is the approximate 236–553pt vertical band and is not a strict
boundary of Gaussian blur. Video is H.264 and may obscure 8-bit differences;
the raw-difference PNG and CSV are authoritative for numeric comparison.

To reproduce, first run `GPU/validate_axis_precalculation.py --prepare-only` in a
new temporary folder from unchanged SDK 9368500, and provide its trial path and
previous passing `cases.json` to `prepare_cases.py`. Generate `colors.swift` with
`source_colors.swift_source(load(sdkRoot))`. Compile `RenderComparison.swift`
as `main.swift` with `GradientRenderSafety.swift`, `GradientMaskRenderer.swift`,
`GradientPerformanceMetrics.swift` and generated colors using native `swiftc -O`;
compile `CaptionComparison.swift` separately as `main.swift`. Pass trial path,
cases.json and an output directory to each executable. Then call `analyze.py`
with the directory containing cases and readbacks, and a new output directory.
GPU access is required. Never copy the trial sources into the shipping SDK.

After `analyze.py`, run `build_index.py <capture-dir> <output-dir>` and then
`finalize.py <capture-dir> <output-dir>` to add navigation, benchmark samples,
caption results and source provenance. `complete_gallery.py` can recover
missing PNGs from an earlier partial analysis without changing pixel values.

One initial native test attempted to create the candidate caption pipeline
without supplying its function constant; Metal API Validation correctly
stopped that test process before submission. The subsequent run explicitly
specialized the caption and compositor fallback with value 0 and completed.
This is a prototype integration requirement, not evidence of a GPU hang.
