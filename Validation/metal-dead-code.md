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
