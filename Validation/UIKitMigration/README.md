# UIKit migration feasibility, stages 1–2

Application checkpoint: dd5bb02, approved SwiftUI V2. Work branch:
`migration/v2-uikit-feasibility`. No app target, canonical Metal module, or gesture
algorithm is edited. No original V2/V3/production installation is overwritten.

## Stage 1: full-screen reference

`prepare.py` generates an isolated build from the real application files. It
injects state/time only, isolates AppStorage, records geometry/uniforms, and
suppresses appearance/task resets while loading fixtures. The validated extractor
from `Validation/validate.py` reuses the actual swipe/progress/history/reset
methods. Nothing is redrawn as an illustration.

The actual V2CaptionProbe kernel and CPU equations are reused with an injected
1/60 s timestep. Each fixed state is settled with 90 samples; the measured
activation is then frozen for both renderers. These captures document settled
fixed-state composition, not real-time adaptive-probe latency or reset's numeric
text transition. Reset's resulting state and original behavior replay are covered.

88 fixtures: four themes × (five progress values × MAIN/CONTACT + six additional
CONTACT phases + six swipe/hold/release/reset states). MAIN fixtures suppress the
idle CONTACT wave through the existing active-touch condition without a trail.
CONTACT fixtures use the existing idle-wave route, not a new animation.

Screenshots are captured by `simctl io screenshot` from the actual Simulator
compositor at 1170×2532 (390×844 points, 3×, iOS 18.6). The reference includes
SwiftUI masks, blur, blend modes, caption support, text and controls. It is not an
ImageRenderer/drawHierarchy/offscreen-Metal substitute.

`Results/swiftui` holds PNGs and exact state/geometry metadata; `baseline.json`
locks their hashes and source provenance. Results and generated copies are local
artifacts, excluded from Git. The lock is not regenerated for a UIKit candidate.

## Reproduce

Requires the isolated Simulator named Gradients V2 Refactor Validation, Xcode
26.3/Metal Toolchain and Python. The current scripts name its UUID explicitly.

```sh
python3 Validation/UIKitMigration/prepare.py
xcodebuild -project Validation/UIKitMigration/Build/MigrationProbe.xcodeproj \
  -scheme 222 -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=468B8589-9260-4F1B-8958-63737D5D8BB6' \
  -derivedDataPath /tmp/gradients-uikit-probe-build CODE_SIGNING_ALLOWED=NO build
xcrun simctl install 468B8589-9260-4F1B-8958-63737D5D8BB6 \
  /tmp/gradients-uikit-probe-build/Build/Products/Debug-iphonesimulator/MigrationProbe.app
xcrun simctl launch 468B8589-9260-4F1B-8958-63737D5D8BB6 com.local.gradients.v2.migrationprobe
python3 Validation/UIKitMigration/capture.py
```

Do not run two capture processes concurrently. Request IDs are unique; the host
waits for fixture loading, the actual GPU probe, and onscreen presentation before
signalling readiness. Source-derived replay is not an OS-touch injection test.

## Stage 2: isolated native renderer

`PrototypeRenderer.swift` contains a fixed-state UIKit/MTKView experiment, not a
replacement for the application. Geometry is measured from the reference before
the native controller is installed. No SwiftUI view is retained in the native
controller. There is no SDK API, responsive layout, native gesture migration or
UI interaction implementation in this prototype.

`PrototypeAdapters.metal` calls the unchanged composed V2 source. The baseline's
default.metallib is compiled separately, without these adapters. A separate runtime
library is used only by the prototype, with the same fast-math setting as V2.
The fragment alternative is retained for the failed numerical comparison; the
onscreen prototype uses the closer compute-first alternative.

Native composition:

1. Original V2 background into RGBA16Float, in point coordinates at 3×.
2. Original distortion function and linear texture sampling when strength > .002.
3. Dark's original permanent lower-30% black backing, before the counter masks.
4. Three original ellipses/radial gradients drawn via CG, Gaussian blur via CI,
   original Yellow readability exclusion, then normal/multiply/screen composition.
5. Light's original 17-stop caption backing through CAGradientLayer, where there
   are no counter masks. Text and controls through UIKit.

Mask input images are flipped once when crossing CI/Metal coordinates. The small
`check_mask_coordinates.swift` test demonstrates the otherwise incorrect mapping
of a 200-point top-origin center to 644 on an 844-point texture. CG source masks
use 8-bit premultiplied pixels; intermediate textures use RGBA16Float. Equivalence
of this blur/rasterization path to SwiftUI is not assumed.

`prepare.py` enables the prototype only when its source exists. It verifies all
frozen application files before generating anything. Build Debug/Release as above.
Then capture sequentially (never two capture clients at the same time):

```sh
python3 Validation/UIKitMigration/capture.py --mode uikit
python3 Validation/UIKitMigration/capture.py --mode swiftui-background --set diagnostic
python3 Validation/UIKitMigration/capture.py --mode uikit-background --set diagnostic
python3 Validation/UIKitMigration/capture.py --mode swiftui-caption --set diagnostic
python3 Validation/UIKitMigration/capture.py --mode uikit-caption --set diagnostic
```

A frozen `swiftui` destination is protected against accidental recapture; use a
new `--suffix` for reference repeats. `--filter` selects a fixture-name substring.
After installing a Release build, capture `--mode uikit --suffix=-release` to keep
it separate from Debug. The application bundle ID is always the isolated probe.

Use Python with NumPy and Pillow for these commands (the existing bundled Codex
Python environment was used; no dependencies were installed in the project):

```sh
python Validation/UIKitMigration/gpu_check.py --reference-run /tmp/your-validation-run
python Validation/UIKitMigration/analyze.py
python3 Validation/UIKitMigration/lock_reference.py
```

`gpu_check.py` accepts the output of the original Validation runner and verifies
its raw hashes against the original reference.json before comparing. It creates
a new GPU result directory; `--suffix` preserves separate experiments.
`analyze.py` verifies all frozen PNG hashes and exact input/geometry equality
before creating decoded RGB differences. No tolerance is used. Difference images
are amplified ×8 solely for viewing; numeric metrics use original pixels.

See FINDINGS.md, gpu-results.json and verification.json for outcomes and limits.
