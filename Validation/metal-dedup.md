# Exact Metal deduplication

Start: 12e1b51, 10,242 canonical Metal lines + 1,036 Swift lines.
Reference GPU outputs/behavior: original 542b89b; reference.json is never rerecorded.
The code guard checks surviving source against the accepted dead-code checkpoint,
allowing only exact shared bodies and their documented bindings. No algebraic
normalization, new precision, shader pass, blending or frame clock is introduced.
ContactFields is frozen byte-for-byte at 12e1b51; its rejected cleanup is untouched.

## Commit 1 — seven exact Yellow helpers

Moved one original body per helper into namespace YellowShared. Matching namespace
copies become explicit using-declarations. All formulas, signatures, types and
operand order match. Their dependencies are shared globals/builtins, not different
local Yellow definitions. No extra function-call wrapper is introduced.

- `yellowReviewDarkPalette`: YellowDarkContact, YellowDarkMAIN
- `yellowReviewTransmission`: YellowDarkContact, YellowDarkMAIN, YellowLightMAIN
- `yellowReviewPrimaryShare`: YellowDarkContact, YellowDarkMAIN, YellowLightMAIN
- `yellowReviewWaveShares`: YellowDarkContact, YellowDarkMAIN, YellowLightMAIN
- `yellowReviewLightSource`: YellowDarkContact, YellowDarkMAIN
- `yellowReviewLightPeak`: YellowDarkContact, YellowDarkMAIN
- `yellowReviewHSV`: YellowDarkContact, YellowDarkMAIN

- Metal: 10,242 → 10,165 (-77 net physical lines, including new shared source).
- Swift: 1,036 unchanged; total editable runtime source: 11,278 → 11,201.
- Debug/Release succeeded. 72 images / 216 GPU hashes / 33 checkpoints exact.
- Four Simulator themes, settings switches, swipe 60→61%, release and idle checked.
- Unlike the three other transmission copies, YellowLightContact's transmission
  formula is not token-identical. It remains separate, even if some operands
  might be mathematically equal for the current palette.

## Rejected candidate — Dark MAIN pose helper

An initial group including yellowReviewDarkMainAtPose built successfully but
changed 19 GPU outputs (including Blue Dark). It was completely restored;
the seven-helper subgroup above then passed all original hashes. Thus the pose
helper remains in its original three namespaces. No tolerance, flag, precision,
coefficient or baseline adjustment was used to accept it. Identical source bodies
do not by themselves guarantee the same optimized floating-point code after sharing.
The exact responsible compiler instruction was not isolated; no unsupported
claim of visually significant differences or a performance improvement is made.

## Rejected candidate — exact Blue geometry prefix

The first 1,850 lines beginning with parameter clamps and ending after the initial
Yellow density readout are byte-identical in qaCurrentAcceptedDarkBlue,
liquidSpecBackground and qaContactDarkReference. An experimental extraction used
one ordinary function, unchanged original formulas/types/order, explicit thread
references for already-mutated scalar parameters and a typed struct for live-out
float values. No new precision, compiler flags or shader passes were introduced.

It built in Debug/Release and would have saved 3,392 net Metal lines. However,
Validation changed 38 GPU outputs. The entire source/plan/proof change was rolled
back before continuing. No rejected library was installed in the Simulator.
This is not accepted as an exact replacement, irrespective of nominal mathematical
or source equality. The original separate Blue bodies remain byte-identical to
12e1b51. No compiler directive or rounding workaround was attempted.

## Rejected candidate — exact Blue RGB/history tail

A smaller, separately tested 84-line block (transmission, boundary states and
history readout) is also byte-identical in those three Blue functions. Extracting
it into one ordinary typed function would have saved 59 lines. Debug/Release
succeeded, but GPU hashes differed again. It was completely restored, including
the experimental plan and validation proof changes. SUBSTRATE FIX and geometry
were not moved in this attempt. No tolerance or alternate baseline was accepted.

## Similar implementations deliberately not merged

- YellowLightMAIN's LightSource/LightPeak have different coefficients/conditions
  from the two Dark-module constant readouts, and remain local.
- YellowLightContact's transmission is not source-identical to the shared helper.
- PrimaryShare and WaveShares have different return types/readouts; their similar
  inner arithmetic was not replaced by a mathematically reformulated helper.
- No other similar palette, mask, field or theme branch was merged.

## Final verified state

Runtime code commit: 57c1ea1. Seven exact Yellow helpers are the only accepted
shader edits. A documentation-only follow-up records the rejected attempts.

| Runtime source | Start | Final | Net removal |
| --- | ---: | ---: | ---: |
| Canonical Metal modules (shared file included) | 10,242 | 10,165 | 77 |
| App Swift | 1,036 | 1,036 | 0 |
| Total editable runtime source | 11,278 | 11,201 | 77 |

Counts are ordinary physical source lines. Nothing was minified or moved into a
build generator. The 79-line shared source and all namespace aliases are included;
Validation Python/JSON/docs and the duplicate generated compiler input are excluded.
The actual generated Metal input is 10,184 lines; it is never counted a second time.
The previous larger reduction estimate was candidate evidence, not an achieved or
safe guarantee; the two Blue experiments did not meet the user's exact-hash criterion.

Final checks after all rollbacks:
- Debug and Release builds succeeded; their generated Metal inputs equal compose().
- Existing Validation ran against the actual Debug build-generated Metal source:
  all original 72 frames, 216 raw GPU outputs and 33 behavior checkpoints exact.
- The four composer/source-sharing checks passed; original reference.json unchanged.
- Debug Simulator: all four themes, both settings selections, swipe 60→61%, idle.
- Final Release Simulator: all four themes, both selections, swipe 30→31%, idle.
- Swift, ContactFields, original Blue source and dispatcher match the accepted
  checkpoints byte-for-byte. Original V2, V3 and production hashes are unchanged.
- No GitHub push, UIKit migration, new app identity or production edit.

Offscreen comparisons cover the existing fixed cases on Apple M3 Pro with the
recorded toolchain. Manual Simulator checks are not deterministic full UI pixel
comparisons, and no physical-device FPS improvement is claimed. Work stops here;
no higher-risk merging is authorized or implemented in this checkpoint.
