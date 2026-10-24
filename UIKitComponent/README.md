# GradientsKit — UIKit + Metal

Reusable iOS 17+ framework. Runtime dependencies: UIKit, Metal/MetalKit, CoreImage, CoreGraphics and Foundation. No SwiftUI or hosting controller. The separate demo application is in `UIKitDemo`; approved SwiftUI V2 remains in the original `GradientsV2.xcodeproj`.

## Build and integrate

Open `UIKitDemo/GradientsUIKit.xcodeproj`:

- **GradientsUIKit** scheme builds/runs the ordinary UIKit application (`Gradients V2 UIKit`, bundle ID `com.local.gradients.v2.uikit`).
- **GradientsKit** scheme builds the independent framework. Embed `GradientsKit.framework` in the SDK host with **Embed & Sign**. Device and Simulator framework binaries are different products; an XCFramework can be assembled from separately archived slices for distribution.

The framework owns its precompiled `default.metallib`, loaded using its own bundle. It does not load shaders or preferences from the host application's `Bundle.main`, and it does not compile Metal at runtime. `Scripts/compose_uikit_metal.py` combines the approved canonical modules and pipeline adapters into a derived build file; formulas are not rewritten. Generated Metal/build products are not committed.

```swift
import UIKit
import GradientsKit

let gradient = try GradientViewController(theme: .yellowDark)
parent.addChild(gradient)
gradient.view.frame = parent.view.bounds
gradient.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
parent.view.addSubview(gradient.view)
gradient.didMove(toParent: parent)

gradient.theme = .blueLight
gradient.onSettings = { /* present the host's settings */ }
gradient.onFrame = { frame in /* frame.progress is the behavioral target */ }
gradient.reset(animated: true)
```

Create/access the controller on the main thread. The controller owns the continuous UIKit gesture recognizer and display link; the host can `pauseRendering()` / `resumeRendering()` on scene lifecycle changes. Pausing never resets session or animation clocks. Rendering stops when the controller disappears. The component renders in its own bounds and updates drawable resources when size/scale changes; the approved 390 × 844 full-screen layout retains its original measurements. Font sizes, button insets and caption bottom inset remain fixed; the host should provide a phone-sized surface, not a small toolbar-sized container.

For an externally owned behavioral session, use `init(session:dark:yellow:size:)`. Supply event times in the same Date reference-time domain as the controller. `GradientSession` is Foundation/CoreGraphics-only, serially owned; public `dragChanged`, `dragEnded`, `setSettingsVisible`, `reset` and `frame` retain the approved V2 calculations. Do not feed the same gesture twice through both host callbacks and the controller's recognizer.

## Presentation and rendering

- Four separate accepted theme paths; CONTACT and SUBSTRATE FIX remain canonical.
- Ordinary progress writes remain unanimated as in the reference transaction. Changed digits roll during animated reset, using 0.35 s easeInOut. Presentation interpolation is separate from logical progress: resetting immediately clears progress/history and preserves release/idle behavior. This matches the reference use of [numericText](https://developer.apple.com/documentation/swiftui/contenttransition/numerictext(countsdown:)) inside an explicit animation transaction; no SwiftUI code is used at runtime.
- Three shared input-buffer slots; a slot is reused only after its GPU command completes. No main-thread GPU wait.
- Dark mask preparation uses bounded, pixel-aligned CG surfaces and three independent CI workers. The original full-domain Gaussian and normal/multiply/screen composition remain. CoreImage rounding differs by at most 0.000061 in the tested raw mask textures, well below an 8-bit screen color level.
- `renderStatistics` exposes submission/preparation counters for opt-in measurement. The component never writes diagnostics to disk. Only the demo does so when launched explicitly with `GRADIENTS_DIAGNOSTICS=1`.

## Verification and limits

`Validation/validate.py` retains the original 216 raw GPU / 33 behavior checks. `validate_session.py` checks the extracted V2 oracle against the maintained core in Debug/Release; `validate_presentation.py` checks reset timing and separation from shader progress; `validate_masks.py` compares 60 raw mask textures without screenshots. The independent project includes framework unit tests and real UIKit interaction tests for all themes.

The existing scale-aware compute adapter retains its known single half-float-step difference at Blue Dark 60% CONTACT t=2.1 (delta 0.000061); canonical formulas are unchanged. Simulator timing is not a guarantee of physical-device performance. Final visual review and device profiling remain required before shipping an integrated SDK.
