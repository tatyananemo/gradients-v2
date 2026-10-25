# Isolated Metal source-include experiment

Base: `75e1800`. Branch: `experiment/metal-history-inc`. No large-prefix extraction.

Three exact 63-line history blocks in `qaCurrentAcceptedDarkBlue`, `liquidSpecBackground`,
and `qaContactDarkReference` now include `ShaderSources/Shared/InteractionHistory.inc`.
The block, identifiers, types, expression order and original scopes remain unchanged.
No MSL function, parameter, result structure, precision or shader pass was added.

## Build integration and proof

`compose_metal.py` literally expands the registered flat `.inc` before emitting the
compiler input. It performs no arithmetic substitutions or formula generation.
This keeps the existing SwiftUI/GPU Validation string-compilation route working.
Both the SwiftUI input file list and UIKit build inputs track the `.inc`; the
project creation script discovers it too. Nested/unregistered blocks are rejected.

The original source-sharing proof remains active. The extra allowed edit pins the
block SHA-256 and exactly three substitutions. ContactFields and Yellow are unchanged.
Seven composition tests also check byte identity against the Git object `75e1800`,
three-site dependency propagation, build inputs, and invalid block rejection.

Expanded V2 and UIKit compiler inputs are **byte-identical** to the control.
The actual Metal preprocessor was independently run on unexpanded candidate input,
using the toolchain from the Xcode build log and the original target/math flags.
Its 86,404 tokens match in Debug/Release. Its text differs only by three blank
lines introduced at include boundaries. All non-whitespace bytes match.
Actual Xcode Metal compile commands match the control in both configurations.
`MTL_FAST_MATH=YES` and all math/precision settings are unchanged.

## Size

| Source | Before | After |
| --- | ---: | ---: |
| ApprovedBlue alone | 7,047 | 6,861 |
| New common .inc | 0 | 63 |
| Canonical Metal including .inc | 10,165 | 10,042 |
| SDK Metal including adapter and .inc | 10,207 | 10,084 |
| SDK Swift | 1,155 | 1,155 |
| SDK Swift + Metal | 11,362 | 11,239 |
| Expanded SDK compiler input | 10,227 | 10,227 |

Net unique Metal removal: **123 physical lines**, including the common block.
The Python/build/test plumbing is not claimed as a runtime-source reduction.
Both Debug and Release default.metallib are byte-identical: **521,788 bytes**,
SHA-256 `99b750649719348c2f9a19667638136f4ccfc84cd84b0f3fc284b98b05f45b3f`.
The Release app and framework executable bytes are identical too.

## Checks

- Fresh Debug and Release builds passed, with actual Metal compiler invocations.
- Original GPU Validation: 72 states, all 216 raw output hashes exact, 33 behavior checkpoints.
- Accepted masks: 60/60; queued reuse: 108/108; zero changed components and delta.
- UIKit behavioral core vs frozen SwiftUI: Debug/Release each 931 events,
  1,385 exact state comparisons, 5,540 frame-argument comparisons.
- Each Simulator configuration: 23 component cases passed, one dedicated GPU-control
  case skipped by the existing plan, plus the native four-theme swipe/hold/release/reset test passed.
- No Main Thread Checker diagnostics or crash restarts. No GPU references/tolerances changed.
- Automatic XCTest media attachments discarded (`keepNever`); no capture/report scripts used.

## Timing

Same iPhone 14 / iOS 18.6 Simulator; existing four-theme trace, 3 s warmup + 20 s.
These are GPU-completion cadence measurements, **not physical display FPS**.

| Theme | Control FPS | Candidate FPS |
| --- | ---: | ---: |
| dark-blue | 59.90 | 59.19 |
| dark-yellow | 59.93 | 59.73 |
| light-blue | 58.84 | 59.09 |
| light-yellow | 59.98 | 59.99 |

Because the first Blue Dark comparison varied, one more identical control/candidate
pair was measured: **59.96 / 59.90 FPS**. No performance improvement or regression
is established: the executable binaries are identical and the measurements vary.
This change deduplicates maintained source; it does not remove GPU arithmetic.
Full p95/p99, CPU/GPU and input-to-completion summaries are in `history-inc.json`.

Logs/raw numeric comparisons: `/tmp/gradients-inc-*.log`, `/tmp/gradients-inc-evidence/`.
No videos, PNG screenshots or HTML reports were created in the project.
No original V2/V3/production edits and no GitHub push. Stop before any large-block work.
