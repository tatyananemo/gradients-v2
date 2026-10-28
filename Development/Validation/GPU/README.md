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
