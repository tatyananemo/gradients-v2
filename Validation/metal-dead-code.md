# Metal stage 1 — dead code only

Frozen Swift checkpoint: 39b50ed. Approved GPU/behavior baseline remains 542b89b.
No Swift, shader ABI, precision, live formulas or dispatcher changes are allowed.
Only deletions are made in the source modules; no code is moved into a generator.
`metal-deletions.json` records original module line ranges and reasons. The guard
checks every surviving source byte against 39b50ed after only these deletions.
It is test infrastructure, never an Xcode source generation step.

## 1a: unreachable functions / historical fallback

Route proof:
- App calls only gradientsV2Background, gradientTrailDistortion, v2ReadabilityMask,
  and v2CaptionProbe. No dynamic or indirect function selection exists.
- v2ComposeBackground sends color=3 to four distinct Yellow namespaces and color=0
  to liquidSpecBackground. Theme is exactly 0 or 1.
- Blue Light returns into qaCurrentAcceptedDarkBlue with literal theme=1/color=0.
  Blue Dark proceeds with theme=1/color=0. Yellow's Blue profile calls explicitly
  use theme=1/color=0. Therefore neither old correctedThemesBackground guard can fire.
- The remaining removed functions have no path from those four entry points.
  Dependencies of each removed overlay were checked separately. Names qa/legacy
  were not deletion criteria. Live qa helpers and the SUBSTRATE FIX stay intact.
- interp4/interp4v were initially misclassified by a limited call parser; compilation
  identified the LayerState dependency. Both were restored before this commit and
  all checks were rerun successfully. No failing candidate is committed.

Metal: 13,485 → 10,614 (-2,871). Swift: 1,036 → 1,036.
Debug + Release succeeded. Original 72 frame / 216 GPU output hashes and 33 replay
checkpoints match exactly. Composer/deletion checks passed. Isolated Simulator:
all four themes, switching theme/color, continuous swipe 60→61%, release/idle.
No observed visual change. No GPU-speed improvement is claimed.

Removed function definitions (28):

- `ApprovedBlue.metal.source::acceptedYellowDarkWave`
- `ApprovedBlue.metal.source::correctedLightIdle`
- `ApprovedBlue.metal.source::correctedThemesBackground`
- `ApprovedBlue.metal.source::idleWaveDistortion`
- `ApprovedBlue.metal.source::idleWaveField`
- `ApprovedBlue.metal.source::idleWaveOverlay`
- `ApprovedBlue.metal.source::lightContactRidgeDensity`
- `ApprovedBlue.metal.source::lightFrontContactReaction`
- `ApprovedBlue.metal.source::lightIdleWaveDensity`
- `ApprovedBlue.metal.source::qaAcceptedMainShapeColumnPeak`
- `ApprovedBlue.metal.source::qaAcceptedShapeSample`
- `ApprovedBlue.metal.source::qaHistoricalYellowDarkContact`
- `ApprovedBlue.metal.source::rectSDF`
- `ApprovedBlue.metal.source::restoredYellowDarkContact`
- `ApprovedBlue.metal.source::restoredYellowDarkTint`
- `ApprovedBlue.metal.source::shockwaveRippleOverlay`
- `ApprovedBlue.metal.source::shockwaveScreenDistortion`
- `ApprovedBlue.metal.source::waterCausticOverlay`
- `ApprovedBlue.metal.source::waterCausticThread`
- `ApprovedBlue.metal.source::waterSurfaceDistortion`
- `ApprovedBlue.metal.source::waterSurfaceField`
- `ApprovedBlue.metal.source::whiteRectField`
- `ApprovedBlue.metal.source::whiteTrapField`
- `ApprovedBlue.metal.source::yellowHeatColor`
- `YellowDarkContact.metal.source::yellowReviewDarkContact`
- `YellowDarkContact.metal.source::yellowReviewSubstratePalette`
- `YellowDarkMAIN.metal.source::yellowReviewSubstratePalette`
- `YellowLightContact.metal.source::yellowReviewDarkPalette`

## 1b: overwritten stores and inactive preprocessor branches

- In qaCurrentAcceptedDarkBlue, liquidSpecBackground and qaContactDarkReference,
  removed only local values and RGB stores that are unread before the unconditional
  travellingDarkResult replacement. Each function lost 100 lines; their surviving
  formula bytes, live CONTACT composition and SUBSTRATE FIX are unchanged.
- In yellowReferenceContactFields, removed 20 lines of initial darkResult stores
  (including their two local accent densities) plus 26 lines of now-unused local
  palette/intensity values. The initial declaration and all travelling-band,
  counter, grain and returned field expressions remain unchanged.
- Removed 26 lines of disabled QA_CONFIG_PALETTE alternatives/markers from Yellow
  modules. This macro is absent from the project/build settings and composer.
  Active preprocessor bodies are retained verbatim.
- No other functions were removed in 1b; the complete list above remains 28.

Metal: 10,614 → 10,242 (-372); Swift remains 1,036.
Debug/Release succeeded. Existing Validation: 72 frames / 216 raw output hashes /
33 behavior checkpoints exact. All 4 composition/deletion tests passed. Both
Xcode-generated libraries equal the current canonical composition. Isolated
Simulator: four themes, both selections, swipe 80→81%, release and ongoing idle.
Original V2, V3 and production hashes remain unchanged. No push was performed.

## Rejected experiment (not committed)

A broader backward-liveness cleanup of ContactFields removed 890 lines but changed
8 Yellow Dark image hashes. In the first checked differing frame, one half-float
component changed by 2.384185791015625e-07. No tolerance was introduced. That entire
candidate was restored before the smaller, passing change above. The exact
compiler instruction/CSE responsible was not established; do not describe that
broader deletion as pixel-identical or apply it later without new exact checks.
Original reference.json, comparison inputs, GPU precision, fast-math flags and
validation renderer were never changed or rerecorded to make a candidate pass.

## Final accounting

| Runtime source | Before stage 1 | After 1a | After 1b (final) |
| --- | ---: | ---: | ---: |
| Swift | 1,036 | 1,036 | 1,036 |
| Canonical Metal | 13,485 | 10,614 | 10,242 |
| Total editable runtime source | 14,521 | 11,650 | 11,278 |

Net real source removal: 3,243 Metal lines (24.0%), excluding generated copies,
Validation Python/JSON/docs and skills. Physical line counts include normal
comments and blank lines; surviving formatting was not compacted. The generated
Metal compiler input is 10,260 lines (+18 composition wrappers); it is not counted
again as a second copy. Swift is byte-identical to 39b50ed, including text/settings.

| Module | Before | After |
| --- | ---: | ---: |
| ApprovedBlue.metal.source | 10,148 | 7,047 |
| ContactFields.metal.source | 1,978 | 1,932 |
| V2EntryPoints.metal.source | 91 | 91 |
| YellowDarkContact.metal.source | 360 | 314 |
| YellowDarkMAIN.metal.source | 331 | 294 |
| YellowLightContact.metal.source | 277 | 269 |
| YellowLightMAIN.metal.source | 300 | 295 |

## Remaining potential — analysis only, no implementation

After cleanup, qaCurrentAcceptedDarkBlue, liquidSpecBackground and
qaContactDarkReference still have 2,072 / 2,116 / 2,078 lines respectively.
Pairwise exact contiguous matches (blocks of at least 8 lines) cover 1,972 lines
of current-vs-reference and 2,043 of main-vs-reference. This is candidate evidence,
not a guaranteed removal count: function outputs, display corrections and
half-rounding boundaries differ. Sharing these computations could plausibly save
roughly 2,500–3,500 net lines after extraction overhead, pending exact GPU tests.
This could bring editable Swift+Metal to roughly 7,800–8,800 lines. It does not
prove that the full 6,000–8,000 goal is safe or achievable.

No additional reduction is certified without those tests. The broader rejected
ContactFields cleanup is excluded from the safe estimate. No duplicate/helper
merging, algebraic rewrite, precision conversion or UIKit work was performed.
Manual Simulator inspection is a smoke check, not a deterministic pixel diff of
SwiftUI compositing; exact GPU comparisons cover the existing fixed cases on
Apple M3 Pro, not every possible future gesture/time or a physical-device FPS test.
