# 19. The solved fit is decomposed into readable geometry + an advisory sanity verdict
<a id="adr-0019"></a>

- **Status:** Accepted
- **Date:** 2026-06-27
- **Builds on / amends:** [ADR-0010](0010-alignment-captures-z-surface-plane.md#adr-0010)
  (the 2.5D surface plane the fit solves), [ADR-0011](0011-energize-is-the-trust-boundary.md#adr-0011)
  (the residual is the trust gate), [ADR-0018](0018-model-is-params-plus-machines.md#adr-0018)
  (derived values are projections, not stored).

## Context

`Alignment.fit/1` already solves a **6-DOF affine** `Transform2D` (rotation,
scale, mirror, skew — "the whole affine") **and** a **3-DOF board surface
`ZPlane`** (`z = a·bx + b·by + c`, i.e. board tilt/bend). But the operator sees
only a scalar quality % and `residuals` (rms + max). None of the fitted *geometry*
is surfaced.

Residuals answer "is the fit **self-consistent**?" — they do not answer "is the
fit **physically plausible**?". A fit can have a tiny residual yet be wrong: a
Front/Back mismatch produces a mirrored solve that still fits its (mirrored)
captures with near-zero error; a wrong-units or mis-scaled board fits consistently
at the wrong scale; a bad capture shows up as shear. A single error number cannot
distinguish these from a good fit. There is a second, orthogonal signal sitting
unused inside the already-solved values.

## Decision

Decompose the solved `Alignment` into **human-readable geometry** and a separate
**advisory sanity verdict**, both as pure projections — no new solver math, no
stored state.

```gleam
// domain/fit_geometry.gleam  (NEW, pure)
pub type FitGeometry {
  FitGeometry(
    rotation_deg: Float,            // in-plane rotation vs the bed
    scale_x: Float, scale_y: Float, // 1.0 == exact
    shear_deg: Float,               // departure from 90° between the X/Y basis
    mirrored: Bool,                 // determinant < 0 (board-side mismatch)
    tilt_deg: Float,                // surface normal vs vertical
    tilt_dir_deg: Float,            // downhill azimuth (0 = +X)
    normal: #(Float, Float, Float), // unit normal of the fitted plane
  )
}
pub type SanityFlag { ScaleOff(axis, value)  Sheared(deg)  Mirrored  Tilted(deg) }
pub type FitSanity { Plausible  Suspect(reasons: List(SanityFlag)) }
pub type Bands { Bands(scale_tol, shear_max_deg, tilt_warn_deg) }  // thresholds = data

pub fn decompose(a: Alignment) -> FitGeometry          // pure
pub fn classify(g: FitGeometry, b: Bands) -> FitSanity  // pure
```

The math is a QR/polar-style decomposition of the 2×2 linear part `[[a,b],[c,d]]`
(columns `(a,c)` and `(b,d)`) plus a normal-vector reduction of the `ZPlane`
slopes — `scale_x = ‖(a,c)‖`, `scale_y = |det|/scale_x`, `rotation = atan2(c,a)`,
`shear = 90° − ∠((a,c),(b,d))`, `mirrored = det < 0`, `normal = normalize((−a,−b,1))`,
`tilt = acos(normal.z)`, `tilt_dir = atan2(b,a)`. Total over any solved
`Alignment` (the fit guarantees a non-singular linear part).

### It is constructible only from a solved Alignment

`FitGeometry` is built only by `decompose(Alignment)`, and `Alignment` is built
only by `Alignment.fit/1`. "Decomposition of an unsolved/pending fit" is therefore
unrepresentable — mirroring how [PendingAlignment](../../CONTEXT.md#term-pendingalignment)
has no transform field. Surfaced as projections `project_fit_geometry`/
`project_fit_sanity` ([ADR-0018](0018-model-is-params-plus-machines.md#adr-0018)),
recomputed each frame, stored nowhere.

### Advisory, not a gate

The verdict changes **display only**. The residual stays the **sole** hard gate
for Proceed-to-Dry-run ([ADR-0011](0011-energize-is-the-trust-boundary.md#adr-0011);
CONTEXT: "the trust gate stays the XY residual"). A `Suspect` verdict warns with
reasons but never disables Proceed — a real board can be legitimately tilted or
rotated, so the decomposition is a hint the operator weighs, not a lock. Even
`Mirrored` (always a setup error) reads as a loud reason without blocking; fixing
Front/Back is the operator's move.

### Mirror is measured against the working board

The Front/Back X-mirror is applied **before** the fit (`bridge.working_board_model`),
so a correctly-set-up board fits near-identity (no mirror). A detected mirror in
the fit therefore means a **board-side mismatch** — a setup error, not a real
board state. This is what makes `mirrored` a high-value sanity flag.

### Thresholds are data

`Bands` (scale tolerance, max shear, tilt-warn) is a value, tunable without
touching the math. `Mirrored` takes no threshold (determinant sign is binary).
Rotation is **not** a sanity flag (square-to-bed is the exception, not the rule);
it is shown as a number only.

## Consequences

- The operator gains a plausibility signal orthogonal to residuals — catching the
  "low residual, physically wrong" class (mirror, wrong scale, bad-capture shear)
  and surfacing board tilt they can act on before drilling.
- Two view touchpoints: a verdict badge + expandable numeric breakdown in the Align
  `quality_panel`, and a downhill tilt arrow on the board canvas (Align stage only).
  The canvas change is in the perf-sensitive hot view, so it requires real-viewport
  verification (CLAUDE.md), not markup inspection.
- New pure module `domain/fit_geometry.gleam`; two new projections; no change to
  `Alignment.fit` or any upstream value. Decomposition math is unit-tested in
  isolation; the sanity bands are tested at their boundaries.
- Trade-off: the verdict is advisory, so a determined operator can still Proceed on
  a `Suspect` fit. We accept this deliberately — the residual remains the safety
  gate, and a hard block would fight legitimately-tilted boards. The verdict's job
  is to make an implausible fit *loud*, not to forbid it.
