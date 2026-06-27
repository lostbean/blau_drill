# 20. The Z surface plane has its own residual, and it gates the fit (4+ captures)
<a id="adr-0020"></a>

- **Status:** Accepted
- **Date:** 2026-06-27
- **Amends:** [ADR-0010](0010-alignment-captures-z-surface-plane.md#adr-0010)
  (the 2.5D surface plane — which deliberately left "the residual gate stays the XY
  residual") and [ADR-0011](0011-energize-is-the-trust-boundary.md#adr-0011)
  (the trust boundary). Pairs with [ADR-0019](0019-fit-decomposition-and-sanity.md#adr-0019)
  (the advisory tilt verdict).

## Context

[ADR-0010](0010-alignment-captures-z-surface-plane.md#adr-0010) made alignment 2.5D:
each [Correspondence](../../CONTEXT.md#term-correspondence) carries a `machine_z`
(the height the bit was jogged down to onto the pad), and `Alignment.fit/1` solves a
least-squares tilted surface plane `z = a·bx + b·by + c` so drill depth references the
real per-hole surface. But ADR-0010 explicitly kept the trust gate **XY-only**: the
[Residuals](../../CONTEXT.md#term-residuals) were `point_errors` over `sqrt(dx²+dy²)`
— the `machine_z` was thrown away after the plane solve. The plane had **no honesty
signal at all**.

A least-squares plane is *always* produced, however inconsistent the captured heights.
So a physically impossible Z capture — e.g. two same-side fiducials jogged to Z3 and Z9
(a ~6 mm height discrepancy on points that should be near-coplanar) — fits cleanly: the
plane just tilts to split the difference. The XY residual is ~0 (click-to-move places
the head at the exact board point), so **quality reads 100% GOOD on a garbage Z capture**,
and the operator drills to depths derived from a nonsense plane.

The [ADR-0019](0019-fit-decomposition-and-sanity.md#adr-0019) advisory tilt verdict
*partly* helps (a wild Z capture tilts the plane), but tilt cannot distinguish a *real*
tilted board from *inconsistent* captures, and it is advisory, not a gate. The right
signal is the plane's own residual: does the fitted plane actually pass through the
captured heights?

## Decision

`Residuals` gains a **Z component**, and the fit gate becomes **XY AND Z**.

```gleam
pub type Residuals {
  Residuals(rms: Float, max: Float,        // XY (unchanged)
            z_rms: Float, z_max: Float,    // NEW: plane residual over machine_z
            n: Int)                        // NEW: capture count (the gate needs it)
}
```

The **Z residual** is `machine_z − surface_z(plane, board)` per correspondence (mm). With
exactly **3** captures a plane fits 3 points *exactly* (z_max ≈ 0) — so the Z check is
**not meaningful at 3 points** and must not give false confidence. It becomes meaningful
at **4+** captures, where a wrong-Z point cannot lie on the plane the others define (the
Z3/Z9 case → z_max ≈ 1.5 mm).

### The gate is XY-AND-Z, bounded by capture count

The `Fit` transition (`job.gleam`) accepts → `Aligned` iff:

- the **XY** residual passes: `residuals.max <= tol` (unchanged), **AND**
- the **Z** residual passes *when it is meaningful*: `n < 4` → Z **unverified** (does not
  pass, does not fail — see below); `n >= 4` → `residuals.z_max <= tol`.

Reuse the **same `tol`** as the XY gate (default 0.1 mm — one tolerance, one mental
model). Jog-to-pad Z is coarser than the fitted XY, but 0.1 mm is already an operator
setting and the failure we must catch (≈1.5 mm) is an order of magnitude past it.

### Z-unverified at 3 captures is honest, not a pass

At `n == 3` the Z residual is structurally ~0 and proves nothing. The fit still solves
and the operator may proceed on the XY gate (the prior behavior), BUT the UI must say
**"Z unverified — capture a 4th fiducial to check depth"** rather than imply the Z is
trustworthy. This both closes the false-confidence gap and *nudges* the operator toward
the 4th capture that makes depth trustworthy. (We do not force a 4th capture — 3 remains
a legal fit for the XY registration; we are honest that its Z is unchecked.)

### What rejects

A fit that passes XY but fails Z (≥4 captures, `z_max > tol`) lands in
`AlignmentRejected` exactly like an XY failure — the operator inspects the per-point Z
residuals (the worst-Z point is the bad capture), Recaptures, and re-fits.

### The panel shows two parallel axes; the failing one is the headline

A fit has **two independent quality axes** — **REGISTRATION (XY)** (where holes land) and
**DEPTH (Z)** (how deep they drill) — and either can pass or fail on its own. The earlier
design showed XY as *the* "quality %" and the Z residual as one extra line, so an
XY-perfect-but-Z-failing fit read "99% GOOD" *and* "rejected" at once, with the per-point
list and the override button quoting the **XY** error (0.002 mm) while the real problem was
2.6 mm in Z — internally contradictory and unactionable. The Align quality panel is
redesigned so the two axes are presented in **matched terms**:

- **Two parallel readouts**: REGISTRATION (XY) and DEPTH (Z), each with its own value
  (`max … mm`) and pass/fail color. The overall verdict is GOOD only if **both** pass; if
  one fails it shows red and is the headline. No single "quality %" that hides a Z failure.
- **DEPTH (Z) is framed for the operator**: "DEPTH — how consistent your capture heights
  are", "max 2.6 mm off the surface (tol 0.1 mm)", with the actionable fix "jog the bit to
  the **same contact height** on each pad". (The Z residual = how far the captured heights
  miss a single consistent plane — it is a *capture-consistency* signal, not a board
  property.)
- **The rejected box shows the FAILING axis's detail**: when Z fails, the per-point list,
  the worst-point callout, AND the override button all switch to **Z** values (per-point
  depth errors, "PROCEED ANYWAY — holes may drill ±X mm in DEPTH"). So nothing on screen
  contradicts the reason for rejection. (This needs a per-point Z projection — a
  `z_fit_diag`/extended `fit_diag` over `z_point_errors`, mirroring the XY `fit_diag`.)
- At `n < 4` the DEPTH readout shows **"Z unverified — capture a 4th"** rather than a green
  pass; REGISTRATION still shows its real XY quality.

## Consequences

- The Z3/Z9 garbage capture (and its class) is **caught**: a 1.5 mm Z residual blows past
  the 0.1 mm gate → `AlignmentRejected`, not 100% GOOD.
- `Residuals` grows two fields + the capture count; `point_errors` is unchanged (still XY),
  a new `z_point_errors(plane, correspondences)` computes the Z residual. The XY residual,
  the too-few/degenerate paths, and `RestartAlignment` are unchanged.
- The trust gate is now **XY AND Z** (amending ADR-0010's "XY only"); the Align panel shows
  the two axes as parallel readouts (above), the failing one as the headline, "Z unverified"
  at 3 captures.
- [ADR-0019](0019-fit-decomposition-and-sanity.md#adr-0019)'s tilt verdict stays advisory
  and complementary: tilt says "this board slopes"; the Z residual says "the captures are
  (in)consistent with that slope". They answer different questions.
- Trade-off: at exactly 3 captures the Z is still unchecked — we accept this (3 points
  cannot self-check a plane) and make it *visible* rather than silently trusted. An
  operator who wants depth trust captures a 4th.
