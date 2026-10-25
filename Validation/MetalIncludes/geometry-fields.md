# Literal geometry/physical-field includes

Base: `e1414c5`; branch: `experiment/metal-geometry-inc`.
This work does not use the previously rejected ContactFields function extraction.

## Blue-only stage

The 1,850 physical lines at e1414c5 ApprovedBlue lines 471, 2655 and 4876
are byte-identical (including comments and whitespace). They occur inside
`qaCurrentAcceptedDarkBlue`, `liquidSpecBackground` and `qaContactDarkReference`.
The full block moves verbatim to `Shared/BlueGeometry.inc` and each occurrence
becomes a literal include, without adding braces, function calls or parameters.
ContactFields and all Yellow files remain unchanged in this stage.

The 1,622-line prefix also occurs verbatim at ContactFields line 32. This is only
analyzed at this stage. Both prefix and 228-line tail independently balance braces,
parentheses and brackets, have no preprocessor directives/location macros, and end
at statement boundaries. All locals remain in their original function scope.
The prefix ends at `float3 preThemeMotionResult = lightResult;`.
Pinned SHA-256 values and original positions are in `geometry-structure.json`.

The composer expands includes literally before compilation. Both V2 and SDK inputs
are byte-identical to e1414c5 (and to the prior stable 75e1800 composition).
The actual Apple Metal preprocessor independently produces the same 86,404 tokens;
only whitespace at native include boundaries differs. Actual Xcode compiler
commands, flags and math modes match the control exactly in Debug and Release.
Each metallib is 521,788 bytes, SHA-256
`99b750649719348c2f9a19667638136f4ccfc84cd84b0f3fc284b98b05f45b3f`.
Both Release executables are byte-identical to the control too.

| Maintained source (generated files excluded) | e1414c5 | Blue stage |
| --- | ---: | ---: |
| Canonical Metal, every .inc included | 10,042 | 6,345 |
| SDK adapter Metal | 42 | 42 |
| SDK Metal total | 10,084 | 6,387 |
| SDK Swift | 1,155 | 1,155 |
| SDK Swift + Metal | 11,239 | 7,542 |

Real removal: 3,697 unique maintained Metal lines. Metal remains 1,387 above 5,000.
Expanded compiler files remain 10,184 (V2) / 10,227 (SDK) lines.

Blue-stage checks: 8 composition tests; 216/216 exact GPU outputs, 33 behavior
checkpoints; 60/60 accepted masks + 108/108 queued masks with zero component/delta
changes. Core equivalence in Debug and Release: each 931 events, 1,385 exact state
checks, 5,540 full frame-argument checks, including idle/release/reset/settings.
Debug and Release Simulator runs each pass 23 component cases plus two native UI
cases covering the four themes, swipes/hold/release/reset and settings changes.
The existing dedicated sanitizer-control case is skipped by its original guard.
No GPU reference, tolerance, Swift runtime code, Yellow palette or animation changes.

Numerical/compiler evidence: `blue-geometry.json`. No captures or HTML are generated.

Blue-stage paired performance check: same iPhone 14 / iOS 18.6 Simulator,
3 s warmup + 20 s trace per theme (idle/swipe/hold/release/idle).
Completion cadence is not physical display FPS. The binaries are identical;
these small differences do not establish a performance change.

| Theme | Control FPS | Blue stage FPS |
| --- | ---: | ---: |
| dark-blue | 59.95 | 59.79 |
| dark-yellow | 59.84 | 59.94 |
| light-blue | 59.00 | 59.02 |
| light-yellow | 59.98 | 60.00 |

Full frame-time p95/p99, CPU/GPU and input-to-completion data are in `blue-geometry.json`.
