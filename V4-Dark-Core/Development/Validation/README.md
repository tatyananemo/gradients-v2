> Исторический материал: относится к указанному ниже этапу/исходникам, а не к новой проверке `1b3c287`.
> Текущий статус V4-Optimized, границы точности масок/кадров, FPS и заполнение 9–10 с — в [RESULTS.md](../../Documentation/RESULTS.md).
> Старые source guards могут намеренно отвергать поздние согласованные изменения; это не инструкция сборки optimized SDK.

# V4 validation — numerical oracles and behavior

These tools never record or replace the accepted oracles. Use a full local Git clone: approved Git objects `542b89b`, `39b50ed`, `12e1b51`, `75e1800`, `db3064b`, `9d4bd08` and `dc7b9da` are test dependencies. A binary/source SDK consumer does not need this history; the SDK build does not read Validation.

## Retained inputs and responsibilities

- `reference.json`: unchanged 216 GPU hashes, original cases/behavior hashes.
- `ReferenceV2/full-screen-baseline.json`: unchanged 88-screen visual baseline metadata, moved out of the retired probe directory; original recording inputs/tooling are recoverable from its pinned Git commit.
- `ReferenceV2/`: seven frozen Swift source fixtures read as text by the behavior, parameter and UI-expression oracle. Not an app target and not a demo dependency.
- `behavior_driver.swift.txt`, `render_reference.swift`: frozen replay and GPU harness. The original renderer remains byte-for-byte unchanged; checks disable PNG encoding only in a temporary copy.
- `metal-dedup.json`, `metal-deletions.json`: unchanged historical proof manifests used by `metal_dedup.py`.
- `v4-cleanup-deletions.json`, `approved_metal.py`: explicit deletion-only proof for two Blue Light-only functions, their declaration and dispatch branch. No retained Yellow expression is rewritten.
- `test_composition.py`: source/include/build-input and immutable-oracle checks.
- `Behavior/`: core and reset-presentation equivalence with SwiftUI V2.
- `Masks/`: 60 exact accepted UIKit masks, 108 reuse/in-flight comparisons, coordinate-system diagnostic.
- `GPU/`: checks the actual maintained SDK fragment/compute adapters, with its fragment reference now kept only in check_adapter.swift (not in shipping metallib).
- `Performance/`: optional V4-only numeric Simulator profile and repeated-launch heartbeat tools.

## GPU coverage after Blue removal

`validate.py` independently renders **108 outputs from the current shipping Yellow library** and compares them with the original Yellow hashes. It also renders the full **216-output historical control**, substituting only the old ApprovedBlue module read from the pinned `dc7b9da` Git object. That old module is not copied into maintained source or included by the SDK build. All other current modules are still used by the control, and source guards verify all remaining expressions.

Previous extraction of ContactFields into a helper/result structure changed GPU rounding and was rejected. Preserve the accepted literal includes, operation order, precision and compiler flags; do not substitute mathematically similar helpers. The historical investigation remains in Git at `dc7b9da`.

Do not describe historical Blue control passes as current SDK Blue support. Public V4 has only Yellow. `GPU/validate_adapters.py` adds 36 current Yellow fragment and 36 current Yellow compute checks against the same unchanged hashes, and can verify the exact Xcode compiler input. The old known one-component Blue Dark adapter discrepancy is outside these public V4 paths; no tolerance was added.

## Run

Write outputs outside this repository, using a new directory per GPU invocation:

```sh
python3 -B Development/Validation/test_composition.py
python3 -B Development/Validation/validate.py --no-images --output /tmp/v4-gpu-check
python3 -B Development/Validation/GPU/validate_adapters.py --reference-run /tmp/v4-gpu-check --output /tmp/v4-adapters
python3 -B Development/Validation/Behavior/validate_session.py
python3 -B Development/Validation/Behavior/validate_presentation.py
python3 -B Development/Validation/Masks/validate_masks.py --accepted-uikit
python3 -B Development/Validation/Masks/validate_mask_reuse.py
```

`--no-images` is accepted for command compatibility; validation now always writes numeric raw outputs/JSON, never PNG/HTML. `--record` was removed: the existing oracle is immutable. Exact GPU hashes require the recorded GPU/toolchain conditions. Test Debug and Release in Xcode as well, including real UI delivery, background, resize, 100% and reset. Full GPU + Thread Sanitizer in Simulator remains an unverified combination; ordinary passes do not prove absence of all races or leaks. Simulator measurements do not establish physical-iPhone FPS/latency/thermal/memory behavior.

Historical reports, images/probe apps and recording/HTML tools are not required to reproduce the checks above; their prior versions remain in Git at `dc7b9da`. No baseline/tolerance has been removed or rerecorded.

## Exact source cleanup after 0de5930

`metal-optimization.json` pins deletion ranges and SHA-256 values against `0de5930`, plus each byte-identical shared block and all original occurrences. The deleted ContactFields readouts do not feed its returned density/contact/counter/grain fields; unused Blue leaves are independently diagnosed by the Metal compiler. Necessary declarations are retained even when an initializer is overwritten. Remaining expressions, floating-point types and evaluation order are unchanged.

The source guard reconstructs the declared delta, rejects other edits and checks that literal sharing reproduces the same compiler input. The original 75e1800 input proof is retained for the pre-cleanup control, and the current control must match precisely the declared delta. GPU hashes, raw-mask comparisons and tolerances remain unchanged. No GPU-mask replacement or CI scheduling experiment is retained.

## Mask source transport experiment after 8f27a47

The experimental IOSurface source keeps accepted CG rasterization, full-frame Gaussian radius/filter/crop, and final orientation. The source uses premultiplied BGRA byte layout and the native IOSurface/CGImage orientation (without the extra flip required by a raw Metal texture view); raw mask tests still require zero changed components. Each worker owns at most two surfaces, reuses one only after its last command completes, and falls back to the original immutable snapshot when busy or unavailable. Cached-context diagnostic mode keeps snapshots. No GPU wait or source completion callback is introduced.

The source composition guard still checks all other Swift/Metal bytes, pins the complete reviewed mask-source revision by SHA-256, and separately compares its geometry, drawing, Gaussian and orientation expressions with the historical source. `testSharedMaskSourcesMatchSnapshotsAfterReuseAndResize` adds Simulator checks for queued frames, fractional resize and multiple scales; existing GPU/mask oracles and tolerances are unchanged.

## Source-only Yellow colors after 615dfe0

`Configuration/YellowColors.json` is consumed at SDK build time. `test_source_colors.py` checks byte-identical default compiler input, exact CGFloat values, strict schema/build dependencies and independent consumption of every Dark/Light role. The existing immutable reference hashes and comparison tolerances are unchanged.

The full source guard now compares the accepted resource-handling implementation at `615dfe0`, undoing only the three explicit CPU color bindings and the private cached UIColor. It checks every other Swift byte, including `GradientRenderSafety`, rather than accepting a new self-recorded hash. `validate.py` and `GPU/validate_adapters.py` consume the configured shipping source; the historical 216-output control stays frozen. Original ShaderSources and Blue are not edited.

Additional checks, all without Simulator or launching an iOS app:

```sh
python3 -B Development/Validation/test_source_colors.py
python3 -B Development/Validation/test_metal_resource_safety.py
python3 -B Development/Validation/GPU/validate_color_isolation.py --reference-run /tmp/v4-gpu-check --output /tmp/v4-color-isolation
python3 -B Development/Validation/Masks/validate_masks.py --accepted-uikit --debug
python3 -B Development/Validation/Masks/validate_mask_reuse.py --debug
```

The isolation check changes all color roles in memory for one theme at a time and checks the opposite theme against its original exact GPU hashes in both fragment and compute. It never edits the configuration or oracles. Source color edits intentionally change their target theme: the unchanged default goldens are not an approval of a new shade. Full UIKit UI/gesture delivery and physical-iPhone performance still require a separately authorized device/Simulator run.
