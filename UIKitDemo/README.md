# Run Gradients V2 UIKit

1. Open **GradientsUIKit.xcodeproj** in this directory.
2. Select scheme **GradientsUIKit** and Simulator **iPhone 14 (ios 18)** (iOS 18.6, экран 390 × 844).
3. Press **Run** (⌘R). The installed application is **Gradients V2 UIKit**.

This project contains only UIKit demo code and the independent **GradientsKit** framework. It cannot silently launch the reference SwiftUI app. The framework owns its Metal library. Original V2, V3 and production have separate bundle IDs and are not overwritten.

Use the gear button to choose Light/Dark and Blue/Yellow. Swipe continuously to advance progress; use × to reset. The demo keeps the existing instruction text. Settings presentation belongs to the demo, not the SDK.

Select **Product → Test** to run framework and UI tests. Debug and Release configurations are available. To compile only the SDK, select scheme **GradientsKit**. See `../UIKitComponent/README.md` for integration and timing notes.

Optional test-only launch environment: `GRADIENTS_THEME=dark|light`, `GRADIENTS_COLOR=yellow|blue`, `GRADIENTS_PROGRESS=0...1`, `GRADIENTS_DIAGNOSTICS=1`. Ordinary Run uses normal persisted theme/default progress and does not write diagnostics.

Project generation is reproducible using `python3 Scripts/create_uikit_project.py` from the repository root. This never modifies the SwiftUI project or canonical shader modules.
