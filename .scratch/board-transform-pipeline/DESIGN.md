# Design: Board-transform pipeline (single parametrization)

Status: ready-for-implementation
Date: 2026-06-22

## Problem

Drilling the back copper means mounting the board flipped (copper up). The
current "board side" feature mirrors only the **canvas view** (`project`/
`unproject` in `board_canvas.gleam`), while the machine-coordinate path
(click-to-jump `MoveTo`, alignment estimate, g-code) is unaware of the flip.
Result: in Back view, click-to-jump drives the head the **opposite** direction —
the view mirror and the machine mapping disagree. Measured: same screen click →
opposite machine X in Front vs Back.

This is the symptom of a deeper flaw: the flip is a **display hack**, scattered,
not a real geometric transform in one place.

## Goal

A single, sound transformation pipeline. The flip (and, in future, rotation or
any affine) is ONE `Transform2D` applied to the loaded geometry to produce a
**working board**. Everything downstream — display, registration, alignment,
click-to-jump, g-code — operates on the working board with ZERO mirror-awareness.
Flip the board → the working geometry is simply flipped → everything is normal.

## Non-goals

- Not changing the alignment fit math, the g-code generator, or the serial layer.
- Not adding rotation UI now (but the transform must be GENERAL so rotation/other
  affines drop in later without re-architecting).
- Not auto-mirroring g-code from a flag (the flip is a geometry transform, not a
  per-emitter conditional).

## The pipeline (the single parametrization)

```
raw .drl  ──(parse)──►  BoardModel (pristine, front-face, immutable)
                              │
                              │  board_xform : Transform2D   ← the working-board transform
                              ▼
                        Working Board  =  board_xform applied to every point
                        (holes, outline, fiducial candidates, bbox)
                              │
                              │  alignment : Transform2D     ← fitted working-board → machine
                              ▼
                        Machine coords  =  alignment applied to working-board points
```

Two composed transforms, one consistent flow:

- **`board_xform: Transform2D`** — the working-board transform. GENERAL (any
  affine). Today it is parametrized by board side:
    - `Front` → `identity`
    - `Back`  → X-mirror **about the board bbox center**:
      `mirror_x_about(cx) = translate(cx,0) ∘ scale(-1,1) ∘ translate(-cx,0)`,
      i.e. `Transform2D(a:-1, b:0, c:0, d:1, tx: 2*cx, ty:0)` where `cx` is the
      bbox center X. Mirroring about center keeps the flipped board in the same
      footprint (matches flipping the physical board in place).
    - Future: rotation / arbitrary affine — same field, different constructor.
  Applied ONCE to produce the working board. The raw `BoardModel` is never
  mutated (so toggling side re-derives cleanly from raw).

- **`alignment: Transform2D`** — unchanged. Registration captures correspond
  WORKING-board points ↔ machine points; `alignment.fit` solves working→machine.

- **Machine coordinate of a hole** = `alignment ∘ board_xform` applied to the raw
  hole. (`gcode_program.build` already takes an `Alignment` + board; it now
  receives the WORKING board, so it stays mirror-unaware.)

## What changes

1. **The flip leaves the view layer.** `board_canvas.project`/`unproject` DROP all
   `mirror` logic — they render and unproject the working board directly. The
   `Span.mirror` field and the `CanvasData.mirror` field are removed. The canvas
   becomes orientation-agnostic: it just draws the points it's given.

2. **A working board is produced from raw + `board_xform`.** The canvas-facing
   `Board` (holes/outline/candidates/bbox) is built by applying `board_xform` to
   the parsed `BoardModel`. When the side toggles, the working board is rebuilt.

3. **Click-to-jump, estimate, alignment, g-code need NO flip-awareness.** They all
   consume the working board / its correspondences. The bug disappears because the
   flip exists in exactly one place.

## Invariants (must hold; assert in tests)

- **Single source of the flip.** The mirror appears in `board_xform` only. No
  other module (canvas, bridge estimate, gcode) branches on board side. Grep for
  `mirror`/`Back` outside the transform construction must be empty in
  view/estimate/gcode paths.
- **Round-trip:** for any working-board point, screen `project` then `unproject`
  is identity (now trivially, since neither mirrors).
- **Flip is an involution about center:** `board_xform(Back)` applied twice =
  identity; a hole at bbox-center maps to itself; bbox is preserved (same
  footprint) under the Back flip.
- **Composition correctness:** for a known mirrored `alignment`, the machine
  coordinate of a raw hole equals `alignment(board_xform(hole))` — and a
  click on the hole displayed at screen S drives the head to that hole's machine
  point (the direction-consistency the bug violated).
- **Front is a no-op:** `Front` ⇒ `board_xform = identity` ⇒ working board ==
  raw board; all current Front behavior unchanged (regression-safe).

## Interface contracts (pin these)

- `transform2d`:
  - `pub fn mirror_x_about(cx: Float) -> Transform2D` — X-mirror about center cx.
    (Plus existing `identity`, `apply`, `compose`, `invert`.)
- A working-board builder (location: `bridge` or a new `working_board` module):
  - `pub fn board_xform(side: model.BoardSide, bbox: Bbox) -> Transform2D`
  - `pub fn working_board(bm: BoardModel, side: model.BoardSide) -> model.Board`
    (applies `board_xform` to holes/outline/candidates/bbox).
- The machine mapping composes: `board_to_machine` (and gcode build) operate on
  working-board points, so the existing `alignment`/estimate signatures are
  unchanged — they just receive working-board inputs.

## Decisions (resolved 2026-06-22)

- **One working BoardModel is the single source.** G-code is generated from the
  `job`'s `BoardModel` (`gcode_program.build(j.board, …)`), and the canvas board +
  candidates come from `model.board`. So the working transform must produce a
  transformed **BoardModel** that BOTH paths derive from — otherwise g-code would
  drill the un-flipped pattern. Add `working_board_model(bm, side) -> BoardModel`
  (transform holes + outline + bbox of the parsed model); the canvas `Board` is
  then `board_of(working_board_model(bm, side))`, and `job.new` receives the
  working model too. Fiducial candidates are derived from the working model, so
  they're already in working space.
- **Board side locks once registration starts.** Front/Back is only changeable on
  Stage 1 before "Proceed to Align". Once the job leaves `Parsed` (registering or
  beyond), the toggle is disabled — the working geometry is fixed for the session
  (captures/alignment are against that orientation). Selecting a side rebuilds the
  working model + job from raw; this only happens pre-registration so no captures
  are lost.

## Supersedes

Commit `498fcb8` (view-only mirror) — that was the hack. This makes the flip a
real, single, composable transform. CONTEXT.md's "the affine absorbs the mirror"
intent is preserved and made explicit.
