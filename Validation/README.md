# Approved V2 baseline

Base: `542b89b54b9299b48d4121de7f6ee182f3e3f340` (`Save Gradients V2`).
This validation code is outside the app target. It does not install apps, alter
preferences, change UI, or introduce an alternate interaction implementation.

## Coverage and limits

- Four approved themes, MAIN and CONTACT at 30/60/80%, three fixed CONTACT times,
  endpoints, swipe history, release and the maximum 40-segment history.
- Real GPU output in RGBA16Float, unquantized comparison; PNGs are viewing copies.
- The actual caption-probe kernel and the distortion function are also checked.
- The application's actual gesture handlers and progress/history methods are
  extracted into an offline Swift executable. Only event time and the reset
  closure's explicit reference capture are adapted for this test host.
- Replay covers touch, long/repeated swipes, hold, release/fade boundaries,
  30/60/80/100% progress, the segment cap and reset.
- During Metal dead-code cleanup, Swift is byte-identical to accepted checkpoint 39b50ed.
- Metal changes are restricted to documented deletions by metal_deletions.py;
  the original GPU and behavior reference.json is never rerecorded.
- Swift refactoring is checked against the original shader argument expressions,
  all 14 fixed Default parameters and the original behavior replay hashes.

These are offscreen shader images, **not Simulator UI screenshots**. SwiftUI
layout/material/numeric-text transitions and actual OS event delivery are not
exercised by the offline host; inspect those in the isolated Simulator. This is
not a performance benchmark, and Simulator builds do not establish iPhone FPS.

## Run

Requires Xcode, its Metal Toolchain, a real Metal-capable Mac and Python 3.
Run on the same GPU/toolchain as the recorded reference for exact GPU hashes.

```sh
python3 Validation/validate.py --output /tmp/v2-reference-check
```

After switching to generated sources, pass the generated Metal file:

```sh
python3 Validation/validate.py --metal /path/to/DerivedSources/LiquidSpecBackground.metal \
  --output /tmp/v2-generated-check
```

The output directory must be new. It holds binaries, raw frames, probe results,
PNGs, a viewing index and `result.json`; these artifacts are not committed.
`reference.json` records the original source and output hashes. Baseline recording
uses `--record`, refuses an existing reference, and requires protected application
sources to satisfy the current phase guards. Do not use --record for candidates.

Each later behavior-changing validation capability requires its own reviewed
baseline extension. A passing source/hash check must not be described as a full
interactive UI test.
