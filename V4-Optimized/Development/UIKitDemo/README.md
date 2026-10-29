> Актуальная оптимизированная V4 `1b3c287`: см. [корневой README](../../README.md) и схему V4 Optimized
> в соседнем DeviceComparison. Ниже — инструкция сохранённого базового Demo, не финальной сборки.

# GradientsKit V4 UIKit Demo

Open `GradientsUIKitV4.xcodeproj`, select scheme **GradientsUIKitV4**, and Run on an iPhone Simulator. Display name: **GradientsKit V4**. Bundle ID: `com.local.gradients.v4.uikit`. First launch defaults to Yellow Dark; existing settings switch only Light/Dark.

Use scheme **GradientsKit** to build the independent UIKit + Metal framework. Product → Test runs the component and native interaction checks. Release tests use a separate test build with testability enabled; the ordinary Release product does not use that override.

Opt-in test environment: `GRADIENTS_THEME=dark|light`, `GRADIENTS_PROGRESS=0...1`, `GRADIENTS_DIAGNOSTICS=1`. There is no color-selection environment or UI. Ordinary launches write no diagnostic files.

Regenerate only this project with `python3 -I -B Development/Scripts/create_demo_project.py` from the V4 root. No external V2/V3/refactor project is referenced.

SDK target берётся из `../../GradientsKit-V4/GradientsKit.xcodeproj`. Исходники SDK не включаются в target Demo или тестов.
