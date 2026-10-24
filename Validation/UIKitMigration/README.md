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
