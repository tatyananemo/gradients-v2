> Исторический материал: относится к указанному ниже этапу/исходникам, а не к новой проверке `1b3c287`.
> Текущий статус V4-Optimized, границы точности масок/кадров, FPS и заполнение 9–10 с — в [RESULTS.md](../../../Documentation/RESULTS.md).
> Старые source guards могут намеренно отвергать поздние согласованные изменения; это не инструкция сборки optimized SDK.

# Axis/frame precalculation: bounded numerical diagnosis (2026-10-28)

Decision: reject the render change; keep SDK 9368500 unchanged. Only native-macOS
Development diagnostics are retained. No iPhone/Simulator was launched.

## Evidence and localization

Control: `yellow-dark-p30-main`, 390 x 844. Original RGBA16F SHA-256:
`2ad08e3928788dae25595336db4b2b3417b00a8fed478b706b5e6e942302d228`.

There are two separable discrepancies:

1. An inactive `if(functionConstant == 99) return` branch, specialized with 0,
   changes 13 components without ANY precomputation or changed numerical
   expression. The same branch with an ordinary compile-time constant 0 is
   pixel-exact. Thus the specialized compilation context itself changes the
   output. This does not identify a specific backend instruction or prove a
   Metal compiler bug; fast math permits different numerical lowering.
2. Replacing the precalc function constants with ordinary true constants reduces
   this frame's discrepancy from 12 to 2 components. First output mismatch:
   pixel (323,578), B, half bits 3568 -> 3569. The residual is separate from
   specialization.

Limited Float32 probes at position (323.5,578.5) preserved the COMPLETE final
control-image SHA of both uninstrumented variants. p.x, p.y, uv, rise, and the
in-main reconstructed sine arguments match. The first cached sine site in
PhysicalFields.inc:195 does not match its in-main reconstruction:

| Value | Original/recomputed in main | Loaded prepass value |
|---|---:|---:|
| sin(p.x * .018 + time * .50 + rise * 2.0) | 0.9175887107849121 (bits 1063970584) | 0.9175885319709778 (1063970581) |
| sin(p.x * .041 - time * .36 + rise * 4.0) | -0.19942115247249603 (3192665359) | -0.19942209124565125 (3192665422) |
| clearWave | 13.089303970336914 | 13.089286804199219 |

This localizes the earliest measured disagreement to evaluation of the first
cached sine, before its multiplication/clearWave accumulation. It does NOT
uniquely identify a producer argument reassociation vs intrinsic lowering.
Additional producer/hash/all-local probes changed the producer intermediates
or the original final image themselves and were discarded as causal evidence.
Do not present their trace as the uninstrumented kernel's instruction trace.

## Separate controls (no changed reference or global compiler option)

- GPU Float32 input -> private float buffer -> output: 65,536 finite bit patterns,
  **0 changed bits**, including the four sine values above. No half conversion
  exists in the cache. Storage precision loss is not supported by this test.
- Source expression order and Float32 types are unchanged; crossing a kernel
  boundary still changes the compiler's optimization context/materialization.
- Materializing only producer p/uv/rise with volatile: same 2 component errors.
- Producer-only `contract(off)`: 2 errors, at different pixels; not exact.
- Producer-only `reassociate(off)`: same 2 errors as ordinary static precalc.
- Both pragmas: 3 errors; not exact. No global fast-math change was attempted.

FMA/contraction can affect the result, but it is NOT established as the sole
cause and disabling it is NOT a valid fix. No replacement formula was retained.

## Paired GPU measurements

Apple M3 Pro, full native pixel size 1170 x 2532, private output, fastMathEnabled
true for every library. Three rotated-order rounds of the same 22 CONTACT/idle
cases; four dispatches per sample. Prepass/history copy/cache reads included.
No probes/readback inside timed work. These are GPU background timings, not app
FPS or iPhone results. Thermal state reported Nominal.

| Variant | Dark mean ms | Light mean ms | 390x844 exact | Native/extra exact |
|---|---:|---:|---:|---:|
| 9368500 | 8.9863 | 3.5644 | 36/36 | 96/96 |
| Specialized precalc | 4.5484 | 2.7704 | 1/36 | 6/96 |
| Static precalc, no specialization | 8.6846 | 2.7700 | 23/36 | 56/96 |
| Specialized inactive branch, no precalc | 5.2382 | 3.3114 | 1/36 | 6/96 |

Static precalc Dark relative round differences: -7.3%, -4.0%, +2.0% time.
Its aggregate 3.4% improvement is small/nonuniform; do not claim a robust large
Dark acceleration. Light aggregate improvement is 22.3%, but pixels fail.
The inactive specialized branch alone accounts for ~41.7% Dark improvement,
while also failing exactness. The prior ~50% cannot be attributed entirely to
hoisting arithmetic out of pixels.

## Stop condition and checks

Removing specialization eliminates most of the Dark gain before exactness is
restored. Minimal producer rounding controls also fail the control-frame gate.
Stop rather than rewriting formulas, adding tolerances, changing the global
compiler mode, or pursuing more speculative trials. There is no acceptable
render candidate from this investigation.

The 36 compute goldens and 96 original/extra native-size states were checked for
the timed controls. Full 216 historical/108 Yellow/72 adapter/168 mask suites
were not rerun for a candidate already failing one-frame exactness. Shipping
SDK, masks, config, public API and oracles remain byte-identical to 9368500;
existing local Xcode signing edits are untouched. CPU source-color and resource
safety tests passed separately (5 + 2 tests, including Debug/Release CPU
executables), without an iOS process.

## Reproduce, explicitly on the Mac GPU only

1. Prepare trial sources with validate_axis_precalculation.py --prepare-only.
2. Run diagnose_axis_precalculation.py --trial <trial> --output <new-temp-dir>.
3. Compile compare_background_variants.swift with swiftc -O and a temporary
   module cache; invoke it on control/trace/fix/fp/timed-manifest.json explicitly.
4. Trace validity requires smallBase SHA == baseline936 SHA and smallStatic SHA
   == precalcStatic SHA before interpreting captured values. Bench manifests
   contain no probes. check_float32_transport.swift is the isolated bit test.

Numeric outputs and discarded diagnostic inputs from this run are preserved at
/private/tmp/v4-precalc-numeric-20261028 (JSON/log/Metal/Swift only).
