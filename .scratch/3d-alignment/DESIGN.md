# Design: 3D alignment (Z-plane) + run-start flow

Status: ready-for-implementation
Date: 2026-06-24

## Problem / motivation

Two coupled real-hardware findings:

1. **Wrong run reference (the offset bug).** The dry-run/drill program emits
   `G92 X0 Y0 Z0` at a start-of-run touch-off, re-zeroing the machine origin at
   the touch-off point. But the fitted affine `Transform2D` already maps board →
   ABSOLUTE machine X/Y (captures are absolute jogged positions + M114). So the
   `G92` double-applies an offset → the run renders referenced from the last
   fiducial and floats over the board.
2. **Z datum is a single global touch-off** — can't represent a board that sits
   tilted / slightly bent in the fixture; one `G92 Z0` height is wrong elsewhere.

## The decided redesign (operator's insight)

During alignment the operator ALREADY jogs the bit DOWN onto each fiducial pad to
align precisely — so **the machine Z at each capture is known**. Use it:

1. **Alignment becomes 3D.** Each capture is `{board_xy, machine_xyz}` (Z read
   from the same M114 the XY comes from). Beyond the existing 2×3 XY affine, fit a
   **tilted plane** `z = a·x + b·y + c` (least-squares over the captured machine
   Z's vs board XY; ≥3 non-collinear — the same gate as the XY fit). The plane
   captures surface height AND tilt/distortion of the XY plane.
2. **No start-of-run touch-off.** Z=0 / surface is established by the alignment
   plane, so the touch-off `M0`/pause at the start of the run is REMOVED. `G92 X0
   Y0 Z0` is dropped entirely — the affine owns X/Y, the plane owns surface Z.
3. **Per-hole plane-relative Z.** For each hole at board (bx,by) → machine
   (mx,my), the surface Z = `plane(mx,my)` (apply the plane in MACHINE space, or
   equivalently board space — see "frame" below). The plunge/hover/retract become
   relative to that local surface:
   - Drill: `G1 Z<surface + zdrill>` (zdrill negative → into the board).
   - Dry-run: `G1 Z<surface + hover>` (hover positive → above the board).
   - Safe/retract: `G0 Z<surface + zsafe>` (and zchange for the big retract).
   So `zdrill`/`hover`/`zsafe`/`zchange` stay config offsets, now added to the
   local surface Z instead of a global G92 Z0.
4. **Dry-run hovers at the alignment click-to-move Z.** The dry-run (no cutting)
   moves the bit at the SAME hover height used by click-to-jump during alignment
   (`hover` above the plane-corrected surface), so the operator visually verifies
   the pattern over the real surface.
5. **Run starts with a bit change, not a touch-off.** The first operation moves
   to the bit-exchange position (board centroid, ADR-0009) and prompts "install
   <size> bit" — the run OPENS with a bit-change pause. (The existing app-pause
   sentinel mechanism already pauses at each tool boundary; with the touch-off
   removed, the FIRST pause is naturally the first tool's bit change.)

## Frame for the Z plane (decide in impl, document)

The plane is fit from `{board_xy → machine_z}`. Two equivalent ways to use it:
- Fit `z = a·bx + b·by + c` over BOARD xy → for a hole at board (bx,by), surface
  Z = a·bx+b·by+c directly. SIMPLEST (hole board coords are exact, no XY transform
  error feeds the Z lookup). PREFERRED.
- Or fit over machine xy and evaluate at transform(hole). Equivalent up to the
  affine; board-frame is cleaner. Use board-frame.

## Data model changes (contracts)

- `correspondence.Correspondence`: add `machine_z: Float` (or change `machine` to
  a 3-tuple). Keep `board: Point` (2D — the .drl is 2D). PREFER adding
  `machine_z: Float` so existing `board`/`machine` (xy) destructures stay valid
  where possible; update call sites.
- `alignment`:
  - Add a Z-plane to `Alignment`, e.g. `Alignment(transform: Transform2D,
    z_plane: ZPlane, residuals: Residuals)` where `ZPlane(a, b, c)` and
    `surface_z(plane, bx, by) -> Float = a*bx + b*by + c`.
  - `fit/1` also solves the Z plane from the same correspondences (now carrying
    machine_z). ≥3 non-collinear (already required). Degenerate XY ⇒ degenerate
    plane (same matrix singularity) ⇒ existing FitError path.
  - Residuals: keep XY residuals as the trust gate (unchanged). OPTIONALLY add a
    Z residual for diagnostics, but the GATE stays XY (don't change the safety
    gate semantics in this chunk).
- `gcode_program.build`: takes the `Alignment` (now with z_plane); each hole's
  Z lines are computed as `surface_z(board_xy) + offset`. Remove the touch-off
  `M0`/G92 from the preamble; preamble keeps only unit/mode setup (G94/G21/G90).
  Postamble's final retract/home unchanged except it must not assume G92 Z0.
- capture handler (`app.gleam`): record `machine_z` from the live head (M114
  `pos.z`) alongside x/y at each capture. The persisted `AlignmentSave` (reload)
  gains Z per capture so a restored alignment re-fits the plane too.
- model `Capture`: gains the captured Z.

## Invariants (assert in tests)

- **No G92, no touch-off pause** in the generated program (neither mode). Grep:
  built program has no `G92` line and no start-of-run touch-off; the first pause
  is the first tool's bit change.
- **Plane fit correctness:** for 3 captures defining a known tilted plane, the
  fitted ZPlane reproduces those Z's exactly (residual ~0); `surface_z` at a 4th
  point matches the plane. A flat set (all same Z) → a,b≈0, c≈that Z.
- **Per-hole Z:** a hole's drill Z = `surface_z(hole) + zdrill`; dry-run Z =
  `surface_z(hole) + hover`; both relative to the LOCAL surface (so a tilted plane
  yields different absolute Z at different holes — assert two holes on a tilted
  plane get different absolute drill Z, differing by the plane slope).
- **XY unchanged / no double offset:** holes drill at absolute transform(hole) XY
  (no G92 reset). Existing XY/affine tests stay green.
- **Degenerate / too-few:** the existing residual gate + too-few/degenerate
  behavior is preserved (the Z plane shares the singularity condition).
- **Reload:** a persisted 3D alignment restores (captures incl. Z) and re-fits the
  same transform + plane.

## ADRs / CONTEXT to update (design layer)

- **ADR-0002** (alignment is a fitted affine): amend — alignment now also fits a
  Z surface plane from per-fiducial Z; it is 2.5D (2×3 affine for XY + a plane for
  Z). The residual gate stays XY.
- **ADR-0009** (real-hardware-correct program): amend — the start-of-run touch-off
  `M0` + `G92` are REMOVED; Z is plane-relative; the run opens with a bit change.
- **CONTEXT.md**: update the Alignment + GcodeProgram terms; remove the "fiducial
  G92 is a streaming detail" framing (G92 is gone) and note the Z plane.

## Gate (every chunk)

`cd /code/edgar/blau_drill && nix develop -c bash -c 'gleam build && gleam test'`
→ clean build (no warnings in touched files), all tests pass (current 356 + new).
Plus: the emulator e2e (faithful Marlin) should drive a run with the new program
shape (no G92/touch-off, first pause = bit change) and reach completion.
