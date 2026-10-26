# GradientsKit V4 — Yellow

Standalone iOS 17+ UIKit + Metal component. Public themes are **Yellow Dark** and **Yellow Light**; the demo starts in Yellow Dark. Continuous swipes, progress, idle, release, reset, typography and approved visual effects are preserved.

## Build and run

Open `UIKitDemo/GradientsUIKitV4.xcodeproj` in Xcode:

- **GradientsUIKitV4** builds/runs the demo (`com.local.gradients.v4.uikit`).
- **GradientsKit** builds the reusable framework (`com.local.gradients.v4.kit`).

Xcode and Python 3 are required for a source build. The composer expands the canonical modules and literal `.inc` blocks into DerivedData. No generated Metal or build products belong in the source tree. Regenerate the project, if needed, with `python3 -I -B Scripts/create_uikit_project.py`.

## Structure

- `UIKitComponent/`: SDK only; no SwiftUI or demo dependency. See its README for host integration and limitations.
- `ShaderSources/`: approved Yellow shaders plus required common geometry, physical fields and color/profile helpers. Blue-named common modules remain necessary for Yellow; obsolete Blue Light-only functions are removed.
- `UIKitDemo/`: the demo and component/UI tests.
- `Scripts/`: reproducible build tools.
- `Validation/`: immutable oracles, source guards and numerical/behavior checks. See its README for commands and coverage.

The SDK does not require V2, V3, original production or the Validation fixtures at build/runtime. Historical migration probes, capture/report tools and old measurements are no longer in the working tree; they remain recoverable from local Git history at `dc7b9da`. No remotes are configured.
