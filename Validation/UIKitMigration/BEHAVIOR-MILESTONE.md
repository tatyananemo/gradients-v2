# UIKit migration: behavior core connected

Scope: `migration/v2-uikit-feasibility`, based on the accepted feasibility prototype `ebd7dd8`. This milestone stops before complete UI migration, SDK packaging or renderer performance work. No GitHub push.

## What is implemented

- `UIKitComponent/Core/GradientSession.swift`: reusable Foundation/CoreGraphics-only state machine, with injected event time and viewport size. Original continuous swipe calculations, global rate limit, independent 0.48 s progress increments, trail merging and 40-segment cap, release fade (0.30 + 0.82 s), idle delay (0.42 s), reset and settings suppression are retained.
- `UIKitComponent/GradientViewController.swift`: persistent UIKit/MTKView host connected to the session, zero-distance continuous gesture recognizer, display link and one in-flight GPU submission. Input buffers cannot be overwritten while in use. No main-thread GPU wait.
- `UIKitComponent/SessionCaptionProbe.swift`: original asynchronous Metal caption probe and temporal equations without SwiftUI/Combine.
- The demonstration settings, fixture importer, replay clock, screenshot/video capture and XCTest host live separately in `Validation/UIKitMigration`. They are not SDK API.
- The original SwiftUI app, project, all canonical Metal modules and composition script are unchanged. SwiftUI V2 remains independently buildable and the 88 full-screen reference hashes remain frozen.

## Checks

1. **Core Debug/Release:** 931 input events, 1,385 exact state/history/progress checks and **5,540 full frame-argument comparisons**. The oracle is extracted from the original View's callback bodies and frame expressions. All 28 uniforms, history and distortion agree for every theme. Path from 0 to 30/60/80/100%, hold, release, idle, reset and settings suppression pass.
2. **Original Validation:** 72 reference frames, **216/216 exact raw GPU results**, 33 behavior checkpoints against original approved V2 `542b89b`. Reference was not rerecorded.
3. **Isolated UIKit host:** Debug and Release build successfully. Real XCTest continuous swipes, stationary hold and reset are exercised; per-theme results are in `Results/behavior-core/ui-smoke.json`. Pointer-only desktop drag was insufficient to exercise continuous Simulator movement; XCTest confirms actual movement callbacks reach the session.
4. **Static comparison:** 24 full-screen pairs (all themes at 0/30/60/80/100% CONTACT plus active swipe at 60%). Every pair has exactly equal uniforms, history, progress, time, distortion and caption activation. Full PNGs are 1170 × 2532; the HTML preserves direct links and amplified difference images. Small compositor/font/material differences from the accepted prototype remain; full-screen byte equality is not an acceptance gate.
5. **Motion:** eight real Simulator recordings, SwiftUI/UIKit pairs for every theme. Same 60-Hz event trace, 32 seconds at 1× playback; encoded at 30 fps without motion interpolation. Each run checks **1,921 sequential input states**, reaches 30/60/80/100% using V2 swipe credit, then release/reset. Initial video state is 30%; the independent core test starts at 0%. SwiftUI motion uses its original rendering View and callbacks extracted from its unchanged source, not the new core as a reference oracle.
6. **Protected projects:** approved V2 15/15, production 9/9 and V3 15/15 saved file hashes agree.

## Review

Open [before/after comparison](Results/behavior-core/index.html). It includes all four themes, full frames, differences and synchronized side-by-side motion players, with bookmarks for swipe, hold, release, idle, 100% and reset. Raw metadata, captures and original recordings remain local in the Results folder. They are excluded from Git.

## First Release frame — diagnosed

The previous report associated the cold-frame difference with the caption. New cold/warm captures localize all 6,222–6,223 changed pixels to **x=377–793, y=2493–2507** in the 1170 × 2532 screen. This is the system **Home Indicator**, below the caption (whose bounds are y≈2096–2286), not text rasterization or a Metal layer. It can also occur on cold Debug launch.

An additional one-second capture yields complete equality. The comparison host now waits for the cold scene's system overlay to settle before declaring a static capture ready; input clocks and application animations are not delayed. Two cold Release launches × three repeated presentations × two capture times give **12/12 byte-identical frames** against settled Debug. Evidence: `Results/behavior-core/first-frame/results.json`, `settled-results.json` and `home-indicator-comparison.png`.

## Single compute-adapter difference — isolated, retained

The unchanged control is 216/216 exact. The actual scale-aware compute adapter still gives **71/72** exact frames. One Blue Dark 60% CONTACT t=2.1 component, pixel **(223,412), blue**, is 0.092041015625 versus reference 0.09197998046875: **Δ=0.00006103515625**, one half-float step at this magnitude.

- Repeated run: same component and delta, not random behavior.
- Threadgroup 16 × 16 → 8 × 8: same difference; this does not explain it.
- Offline scale=1 control removing only the adapter's runtime coordinate division: **72/72 exact**.

Thus the difference is isolated to the scale-aware entry/coordinate-expression context. Compiler fast-math/inlining reassociation is a likely mechanism; the exact GPU instruction was not disassembled. No shader formula or application adapter was changed to force a byte match, and the rejected scale specialization was not reintroduced. Reproduce using `investigate_adapter.py --reference-run /tmp/<original-validation-run>` with NumPy available. Detailed experiment files are in `Results/behavior-investigation`.

## Remaining work / limits

- **Dark motion performance is not yet equivalent.** In the recorded Simulator trace the native Dark host submitted 497 / 513 frames over approximately 33 wall seconds including pre-roll, with 807 / 848 skipped submission opportunities. Light submitted 1,884 / 1,975 with 94 / 3 skipped. These are submission counters, not a real-device FPS benchmark. The Dark CG/CI mask path correlates with the cost; CPU/GPU profiling is needed before attributing the entire delay to a specific operation. All scheduled input events are replayed and behavior remains exact, but the recordings expose uneven Dark presentation. Do not mark animation smoothness accepted based only on state tests.
- The current UILabel counter updates its target immediately. SwiftUI `numericText` presentation and animated reset's 0.35 s UI transition are not yet migrated. The numerical reset and shader state are equivalent; the moving comparison explicitly exposes the presentation limitation.
- Fullscreen 390 × 844 layout, demo settings presentation, resource packaging/precompiled libraries, component lifecycle/performance hardening and future SDK API remain subsequent stages. The reusable core is independent now; the renderer is an integration prototype, not a shipping SDK.
- This milestone does not authorize modifying canonical shader formulas, CONTACT, SUBSTRATE FIX, original applications or the frozen reference.

Stop here for visual approval before proceeding.
