# 10. Alignment captures a Z surface plane; no start-of-run touch-off
<a id="adr-0010"></a>

- **Status:** Accepted
- **Date:** 2026-06-24
- **Amends:** ADR-0002 (alignment is a fitted affine), ADR-0009 (real-hardware
  program — removes the touch-off `M0`/`G92`).

## Context

Two real-hardware findings on the operator's printer:

1. **Wrong run reference.** The program emitted `G92 X0 Y0 Z0` at a start-of-run
   touch-off, re-zeroing the machine origin at the touch-off point. But the fitted
   affine `Transform2D` (ADR-0002) already maps board → ABSOLUTE machine X/Y
   (captures are absolute jogged positions read via `M114`). So `G92 X0 Y0`
   double-applied an offset — the run rendered referenced from the last fiducial
   and floated over the board.
2. **Z datum was a single global touch-off.** One `G92 Z0` height cannot represent
   a board that sits slightly tilted / bent in the fixture; the cut depth is wrong
   away from the touch-off point.

Key realization: during alignment the operator ALREADY jogs the bit DOWN onto each
fiducial pad to align precisely — so the machine **Z at each capture is known** for
free, at three or more spread-out points.

## Decision

**Alignment is 2.5D:** the existing 2×3 affine for X/Y, PLUS a fitted **Z surface
plane** for depth.

- Each **Correspondence** carries `machine_z` (read from the same `M114` as X/Y at
  capture). `Alignment.fit` solves, in addition to the affine, a least-squares
  **tilted plane** `z = a·bx + b·by + c` over the captured `{board_xy → machine_z}`
  (board frame). Same ≥3-non-collinear requirement and the same singular-matrix
  degenerate path as the affine; the **residual gate stays the XY residual** (the
  trust gate is unchanged).
- `Alignment` gains `z_plane: ZPlane(a, b, c)` with `surface_z(plane, bx, by) =
  a·bx + b·by + c`.
- **The start-of-run touch-off is removed.** `G92 X0 Y0 Z0` is dropped entirely:
  the affine owns X/Y, the plane owns surface Z. There is no touch-off `M0`/pause.
- **Per-hole, plane-relative Z.** Each hole's Z lines are `surface_z(hole) +
  offset`: drill `+ zdrill` (negative), dry-run `+ hover` (positive), travel/
  retract `+ zsafe`/`+ zchange`. The config Z's stay offsets — now from the LOCAL
  surface, so a tilted board gets the right depth at every hole.
- **Dry-run hovers at the alignment click-to-move height** (`hover` above the
  plane-corrected surface) — the same height click-to-jump uses during alignment —
  so the operator visually verifies the pattern over the real surface, bit safely
  clear.
- **The run opens with a bit change, not a touch-off.** With the touch-off gone,
  the first in-app pause (ADR-0009 app-pause, now the default) is the first tool's
  bit change: move to the exchange position (board centroid) and prompt "install
  <size> bit", then proceed.

## Consequences

- Drill depth references the real per-hole surface (tilt/bend corrected), not one
  global Z. The fiducial-offset / floating-over-board bug is gone (no `G92`).
- `Correspondence`, `Alignment`, `fit`, `gcode_program.build`, the capture handler,
  the persisted `AlignmentSave` (reload), and the model `Capture` all gain Z. The
  XY affine, the residual gate, and the too-few/degenerate behavior are unchanged.
- The touch-off modal / pause kind added in 8578960 becomes moot (no touch-off);
  the bit-change pause + centroid exchange remain.
- Alignment is no longer purely 2D: CONTEXT's "fiducial G92 is a streaming detail"
  framing is removed (G92 is gone), and Alignment is documented as 2.5D.
