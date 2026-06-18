# 6. Safety gates are enforced as states, not documented as defaults

- **Status:** Accepted
- **Date:** 2026-06-18

## Context

This machine has dangerous defaults. The **energize-before-jog snap**: a
de-energized stepper that re-engages snaps to the nearest full step and jumps
1–2 mm, ruining alignment. A bad alignment that nobody checks drives the bit into
the wrong place. Drilling for real on the first run, before any rehearsal, risks
cutting a misregistered board. A bare `M3` that never sets the PWM means plunging
with a spindle that isn't actually spinning. In the old workflow every one of
these was a **README sentence** the operator had to remember — "energize the
motors before the final adjustment", "run the dry run first", "do not move X/Y at
bit-change pauses".

## Decision

The dangerous defaults are **enforced as states the machine must pass through**,
not documented. Per principle P5, each gate is a structural transition:

- **Energize-before-jog:** `PrinterConnection` mode `:idle` exposes **no jog
  command**; the only path to `:jogging` runs an energize+settle step first. You
  cannot jog a de-energized axis.
- **Residual gate:** the `Job` transition `:aligned → :drilling` is guarded by
  `residuals.max ≤ tol`; a failing fit lands in `:alignment_rejected`, a state
  with **no drill event**.
- **Dry-run before real:** `Job` has **no edge** from `:aligned` straight to
  `:drilling`; it must route through `:dry_run`, whose completion is the
  precondition for the real-run event.
- **Spindle-on before any plunge:** in `:drill` mode `GcodeProgram` emits
  **M3 S255** before any `plunge`; the spindle is running before the bit goes
  down.

## Consequences

- The wrong order is unrepresentable, not merely discouraged — the `Job` FSM and
  the `PrinterConnection` mode machine make the only legal path the only typed
  path.
- Two of these are codified as **TDD safety invariants** asserted in tests:
  (1) the machine never traverses XY without Z at a safe height (travel only at
  `zsafe` or above); (2) the spindle is running before any plunge in real mode.
  These are non-negotiable test cases for `GcodeProgram` and the streaming path.
- Every motion-enabling path must ship with its gate and an abort/emergency-stop
  affordance (`halt/1`). A new feature that moves the machine without its gate is
  a defect, not a style choice.
- **Trade-off:** gates add transitions an operator cannot skip even when they
  "know what they're doing" — e.g. the dry-run is mandatory. This friction is the
  point; we do not add a bypass.
