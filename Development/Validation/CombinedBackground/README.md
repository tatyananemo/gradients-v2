# Combined background experiment (Mac only)
- Based on `3adbaf2`; canonical SDK, source colors and goldens stay unchanged.
- Shares the physical projection with the existing Blue intensity readout; reuses the existing scalar MAIN only at progress <= .70. Original readout is retained above .70.
- Combined enables `V4_SHARED_BACKGROUND=1`; Reference/Precalc remain unchanged. No extra pass, buffer, texture, math precision change or public API.
- `result.json`: repeated full-frame Mac tests and background+prep GPU measurements; fixed replay inputs, not phone FPS/power measurements.
- 514 actual-compositor comparisons (including 20 boundary cases): final RGBA8 max delta 1 vs approved and Combined. Caption risk/activation unchanged. No goldens/tolerances updated.
- Debug/Release, 8 CPU contracts and unchanged generated Swift/public interface checked. Release app is built under `/private/tmp/v4-combined-background-20261029/Build`, not installed.
- `check.py --cases <existing review cases.json> --output <new tmp dir> [--run]` reproduces a native Mac check. Complete logs/data: `/private/tmp/v4-combined-background-20261029`.
- Pure Blue-channel projection was screened but not retained: negligible extra full-frame benefit. The 514-frame test retains original RGB/max formulas.
- 60 FPS/heat must be checked on A15 later with permission. CPU CG masks remain expensive; do not infer a phone FPS or energy result from Mac timings.
