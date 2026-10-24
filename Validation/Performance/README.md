# GradientsKit performance checks

The shipping optimization disables only Core Image **rendered intermediate image caching** for the three continuously changing Dark masks. Compiled kernels, bitmap contexts and output textures remain reusable. Gaussian radius, clipping, premultiplication, color spaces, shader formulas, render resolution and blending are unchanged.

## Evidence and limitations

- Runtime before optimization: `9d4bd08`; instrumented control: `f50aa53`.
- Initial four-theme measurements: `baseline-simulator.json`; repeated Blue Dark control: `baseline-control-simulator.json`; accepted result: `after-simulator.json`.
- Same trace: 3 s warmup, then 20 s of idle, continuous swipe, hold, release and idle, at full 1170 × 2532 resolution. Startup is excluded.
- Repeated Blue Dark control: 50.19 completed frames/s, 19.17 ms mean mask preparation. After: 59.75 frames/s, 7.26 ms mask preparation, 9.68 ms p99 total CPU preparation.
- Time Profiler (8 s, Simulator) located the main cost in `CI::MetalTextureManager::create_intermediate`, `GetSurfaceFromCache`, `IOSurfaceClientSetPurgeable` and synchronous IOSurface XPC calls. Of 7,030 ms of summed sampled thread time, 2,607 ms included intermediate allocation/cache processing. These are overlapping inclusive sample weights, not wall-clock durations.
- GPU work in the repeated control averaged 3.81 ms, versus 19.30 ms CPU preparation. Drawable acquisition was approximately 0.02 ms. The dominant bottleneck was CPU/system preparation of CI intermediates, rather than MAIN or CONTACT shader work.
- Input-to-GPU-completion p95 improved from 32.90 to 30.79 ms in Blue Dark. The p99 tail varied (39.69 ms control, 31.41–42.39 ms optimized runs), so a tail-latency guarantee is not established.
- Simulator completion cadence is **not physical display FPS**. The iOS Simulator SDK lacks `MTLDrawable.presentedTime`. The instrumentation separately records CADisplayLink timing, resource-slot skips, completion shortfall against 60 Hz, and CPU/GPU percentiles. On a physical iPhone it uses drawable presentation callbacks.
- The first baseline's legacy `missedVSyncsEstimate` field counted long completion gaps; do not interpret it as actual dropped display frames. Current reports distinguish these metrics and have a regression test for sustained 50 Hz delivery.
- Accepted 20 s runs still recorded 4/2 missed display-link opportunities in Blue/Yellow Dark and 12 resource-slot skips in Blue Light. Absolutely stable 60 FPS is **not proven** in Simulator. Physical iPhone 14 / iOS 18 Metal System Trace is the next step for attributing the remaining system/driver delivery stalls without reducing quality.

## Preservation checks

- Debug and Release Simulator builds; independent arm64 iOS framework build.
- Original GPU Validation: 72 states, 216 byte-identical raw GPU outputs; original behavioral checkpoints unchanged.
- Session replay: 931 events, 1,385 exact state checks, 5,540 exact uniform/history comparisons; reset presentation unchanged.
- 60 full-resolution raw Float16 mask outputs compare **byte-for-byte** to accepted UIKit `9d4bd08`.
- Additional 108 mask comparisons exercise reuse with three frames queued before synchronization.
- Simulator unit test compares all mask pixels for both Dark palettes at 30/60/80%; UI tests cover all four themes, swipe, hold, release, reset and settings.
- Original V2 (15 files), production (9) and V3 (15) still match their protected source hashes.

## Rejected approaches

- Analytic GPU rasterization with the unchanged CI Gaussian: a sampled state differed by up to 0.0012207031, so it was not shipped.
- Shared source texture/staging: exact masks, no reliable Simulator speed gain; shared-buffer texture views also require a Simulator-specific workaround.
- Batched CI atlas: exact masks, but slower and an extra large texture.
- Queue-backed `CIRenderDestination`: exact masks, no measured speed gain.
- Returning input slots directly in GPU completion: no meaningful FPS gain and variable input tails, so the original resource ownership was restored.

No experimental renderer, new mask layer, resolution reduction or shader approximation remains in the application.

## Commands

Build the `GradientsUIKit` scheme in `UIKitDemo/GradientsUIKit.xcodeproj` first. Profiling is opt-in; ordinary launches do not write timing files.

```sh
GRADIENTS_PROFILE_APP=/path/to/Release-iphonesimulator/GradientsUIKit.app python3 Validation/Performance/profile_simulator.py /tmp/performance.json
python3 Validation/validate.py --no-images --output /tmp/unique-validation-directory
python3 Validation/UIKitMigration/validate_session.py
python3 Validation/UIKitMigration/validate_presentation.py
python3 Validation/UIKitMigration/validate_masks.py --accepted-uikit
python3 Validation/Performance/validate_mask_reuse.py
```

Optional `GRADIENTS_SIMULATOR` selects an already booted device; `GRADIENTS_PROFILE_CASES=dark-blue` narrows the profiling trace. These tools do not create screenshots, videos or HTML reports. Synchronization/readbacks in numerical regression tests are confined to the offline test runners, never the SDK render path.
