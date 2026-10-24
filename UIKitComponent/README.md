# UIKit migration — behavior milestone

`Core/GradientSession.swift` is the reusable, Foundation/CoreGraphics-only state machine. The host supplies event time and viewport size; continuous `dragChanged` / `dragEnded` callbacks retain V2's per-gesture history, global progress rate limit, independent increment clocks and release/idle timing. `frame` produces one immutable set of shader arguments and history per display frame. This file does not import SwiftUI, UIKit or Metal.

`GradientViewController.swift` connects the session to the previously visually approved MTKView composition. It owns a persistent view, continuous UIKit gesture recognizer and display link. GPU resources/pipelines persist; shared input buffers are written only after the preceding submission completes. No main-thread GPU waits. `SessionCaptionProbe.swift` retains the original asynchronous probe and temporal equations without SwiftUI/Combine.

The demonstration/comparison controller, fixture importer and scripted inputs live separately in `Validation/UIKitMigration/BehaviorDemo.swift`. They are not SDK API. The original SwiftUI application target is unchanged and remains the reference.

This milestone is not a packaged SDK. The prototype still loads its shader resource from the comparison host and retains the approved 390 × 844 full-screen layout. Resource packaging, flexible host layout, demo/settings migration, exact presentation transitions and profiling are later milestones, subject to approval. CG/CI counter-mask textures are still rebuilt for each submitted Dark frame; further resource optimization requires a separate visual check.

## Local checks

- `python3 Validation/UIKitMigration/validate_session.py`: Debug/Release exact replay comparison against callbacks extracted from the original SwiftUI source.
- `python3 Validation/validate.py --output /tmp/unique-validation-folder`: unchanged original GPU and behavior gates.
- `python3 Validation/UIKitMigration/prepare.py`: isolated host project, sources validated against the frozen manifest before generation.
- Generated project: `Validation/UIKitMigration/Build/MigrationProbe.xcodeproj`, scheme `222`. Build Debug and Release for the dedicated Simulator. Only `com.local.gradients.v2.migrationprobe` is installed there.

For the real gesture smoke test, run `prepare_uitests.py` after `prepare.py`, then build/test scheme `222`. `run_ui_smoke.py` repeats the built test in all four themes. Test products and results are local only.

No original V2, V3 or production application is modified or replaced.
