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
- `GPU/`: checks the actual maintained SDK fragment/compute adapters, without a duplicate prototype adapter.
- `Performance/`: optional V4-only numeric Simulator profile and repeated-launch heartbeat tools.

## GPU coverage after Blue removal

`validate.py` independently renders **108 outputs from the current shipping Yellow library** and compares them with the original Yellow hashes. It also renders the full **216-output historical control**, substituting only the old ApprovedBlue module read from the pinned `dc7b9da` Git object. That old module is not copied into maintained source or included by the SDK build. All other current modules are still used by the control, and source guards verify all remaining expressions.

Previous extraction of ContactFields into a helper/result structure changed GPU rounding and was rejected. Preserve the accepted literal includes, operation order, precision and compiler flags; do not substitute mathematically similar helpers. The historical investigation remains in Git at `dc7b9da`.

Do not describe historical Blue control passes as current SDK Blue support. Public V4 has only Yellow. `GPU/validate_adapters.py` adds 36 current Yellow fragment and 36 current Yellow compute checks against the same unchanged hashes, and can verify the exact Xcode compiler input. The old known one-component Blue Dark adapter discrepancy is outside these public V4 paths; no tolerance was added.

## Run

Write outputs outside this repository, using a new directory per GPU invocation:

```sh
python3 -B Validation/test_composition.py
python3 -B Validation/validate.py --no-images --output /tmp/v4-gpu-check
python3 -B Validation/GPU/validate_adapters.py --reference-run /tmp/v4-gpu-check --output /tmp/v4-adapters
python3 -B Validation/Behavior/validate_session.py
python3 -B Validation/Behavior/validate_presentation.py
python3 -B Validation/Masks/validate_masks.py --accepted-uikit
python3 -B Validation/Masks/validate_mask_reuse.py
```

`--no-images` is accepted for command compatibility; validation now always writes numeric raw outputs/JSON, never PNG/HTML. `--record` was removed: the existing oracle is immutable. Exact GPU hashes require the recorded GPU/toolchain conditions. Test Debug and Release in Xcode as well, including real UI delivery, background, resize, 100% and reset. Full GPU + Thread Sanitizer in Simulator remains an unverified combination; ordinary passes do not prove absence of all races or leaks. Simulator measurements do not establish physical-iPhone FPS/latency/thermal/memory behavior.

Historical reports, images/probe apps and recording/HTML tools are not required to reproduce the checks above; their prior versions remain in Git at `dc7b9da`. No baseline/tolerance has been removed or rerecorded.
