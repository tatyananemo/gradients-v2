> Исторический материал: относится к указанному ниже этапу/исходникам, а не к новой проверке `1b3c287`.
> Текущий статус V4-Optimized, границы точности масок/кадров, FPS и заполнение 9–10 с — в [RESULTS.md](../../../Documentation/RESULTS.md).
> Старые source guards могут намеренно отвергать поздние согласованные изменения; это не инструкция сборки optimized SDK.

# Bounded background-kernel experiments on Mac

Run `validate_background_experiments.py --reference-run <existing-passed-validation-folder> --output <new-temporary-folder>`.
The reference folder must contain unchanged `cases.json` and `result.json` from `Development/Validation/validate.py`.
`--prepare-only` generates independent test inputs without any GPU submission.

The host compares the 36 approved Yellow RGBA16F hashes at 390×844 and 96 inputs
at 1170×2532 against the unmodified baseline: MAIN, CONTACT, history/release,
0/30/60/80/100% progress, and cycle seams. No image files are generated.
Uniform `dispatchThreadgroups` retains the SDK's bounds guard.

Each source variant is compiled independently with the existing fast-math flag.
Zero specialization is enabled in the tested pipeline itself, not just in source.
Five paired, rotated-order rounds time four background dispatches per command
buffer to a reused private texture after warm-up; reported GPU milliseconds are divided by four. They exclude
CPU readback/hashing, Dark masks, UI/compositor and physical presentation.
The host reuses resources and aborts on the first Metal command error.

2026-10-28, Apple M3 Pro, five paired rounds per run, private output:
deferred Light evaluation in `qaMainAtPose` and 8×8 dispatch were retained.
The final combination reduced Dark background time from 8.677 to 8.255 ms
(4.9%) and Light from 3.315 to 3.277 ms (1.1%; small and near measurement noise).
8×8 added about 0.7% in Dark over lazy evaluation alone; 32×4 had no reliable benefit.
An earlier shared-output timing pass did not show the same small group-size gain;
only the private-output measurements match the SDK target's storage mode.
Fixed-zero specialization was much faster but
failed 35/36 approved hashes and 90/96 native-size comparisons, so it is not in
SDK sources or pipeline creation. These are Mac kernel measurements, not iPhone FPS.

The source-preservation checker normalizes only the explicit lazy-evaluation
diff before comparing against its old checkpoint; historical sources, numeric
goldens, compiler flags and comparison tolerances remain unchanged.

## Rejected GPU axis/frame precomputation experiment

Run `validate_axis_precalculation.py --reference-run <passed-validation-folder> --output <new-temporary-folder>`.
`--controls` checks transport-only and independently generated axis/frame bodies.
`--prepare-only` creates trial inputs without GPU execution. These trials never
rewrite SDK source files or participate in Xcode builds.

The trial caches 10 X-only and 8 Y-only raw sin results, 12 frame-only raw sin
results and five six-float LayerStates. Mixed-axis/warped-coordinate expressions
are excluded. Scratch storage at 1170×2532 is 128,968 bytes. All values are GPU
float32; no interpolation, CPU trigonometry or resolution changes are used.
The prep kernel runs before EVERY background dispatch in the timed CB, including
history-prefix copy. The same tracked private buffer is reused by the sequential
native test host, and no waits/resources are added to the live SDK.

Apple M3 Pro, five paired rounds, private output, Nominal thermal state:

| Trial | Dark ms | Light ms | Changed approved / native-size frames |
| --- | ---: | ---: | --- |
| 54863da | 9.060 | 3.508 | 0/36; 0/96 |
| 9368500 | 8.681 | 3.485 | 0/36; 0/96 |
| X/Y precompute | 4.843 | 2.963 | 35/36; 90/96 |
| Frame precompute | 4.979 | 3.045 | 35/36; 90/96 |
| Both | 4.364 | 2.621 | 35/36; 90/96 |

All three candidates are REJECTED. Runtime SDK remains exactly at 9368500.
The follow-up transport-only control is exact (36/36 and 96/96), while the
independent axis/frame source controls still differ. On the first approved Dark
frame, the latter change respectively 14/12 half components, maximum absolute
delta 0.0000019669533. This is one diagnostic frame, not a global error bound.
The precise first divergent operation is not established; do not present FMA or
rounding as a proven cause. No flags, oracles or tolerances were changed to pass.
Retained SDK separately passes Yellow 108, historical control 216 and exact masks 168.
