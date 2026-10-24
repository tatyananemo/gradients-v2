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
changed 19 GPU image outputs (including Blue Dark). It was completely restored;
the seven-helper subgroup above then passed all original hashes. Thus the pose
helper remains in its original three namespaces. No tolerance, flag, precision,
coefficient or baseline adjustment was used to accept it. Identical source bodies
do not by themselves guarantee the same optimized floating-point code after sharing.
The exact responsible compiler instruction was not isolated; no unsupported
claim of visually significant differences or a performance improvement is made.
