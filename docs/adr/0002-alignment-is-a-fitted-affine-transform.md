# 2. Alignment is a fitted affine transform, not a G92 ritual

- **Status:** Accepted (amended by ADR-0010 — alignment also fits a Z surface
  plane from per-fiducial Z; it is 2.5D. The XY affine + residual gate below are
  unchanged.)
- **Date:** 2026-06-18

## Context

The hand-rolled workflow aligned the board by touching the bit off on a corner
fiducial and issuing a `G92` to zero the machine there, plus a `drill-side=back`
mirror flag and, when the fiducial mapped to a non-zero envelope corner, a baked
`G92 X<minX> Y<minY>`. This conflates three separate geometric facts — offset,
mirror, rotation — into a brittle touch-off ritual, and it has no honesty signal:
nothing tells the operator whether the board is actually square to the bed before
they cut.

## Decision

**Alignment is a solved value, not a procedure.** From 3–4 human
**Correspondence**s (`{board_point, machine_point}` captured by jogging onto each
fiducial and reading `M114`), `Alignment.fit/1` performs a **least-squares affine
fit** yielding a `Transform2D` that carries translation, rotation, mirror, and
skew in one 2×3 matrix. The fit **requires ≥3 non-collinear points** —
`{:error, :too_few}` (caller keeps a `PendingAlignment`) or `{:error,
:degenerate}` (collinear/coincident) otherwise. Every `Alignment` carries its
**Residuals** (`rms` + `max`), which are the trust gate: the **residual gate**
(`residuals.max ≤ tol`) must pass before drilling.

## Consequences

- The back-side X-mirror, a board not square to the bed, and the fiducial offset
  all collapse into the fitted affine — no mirror flag, no baked `G92`. The `G92`
  that streaming may still emit is an implementation detail, not the domain
  alignment.
- The operator gets a real honesty signal: a bad fit (wrong point clicked,
  slipped board) shows a large residual and the drill button is unreachable —
  misalignment is caught before the bit touches copper.
- More than 3 points improves the fit and the residual estimate; collinear
  fiducials are rejected loudly rather than silently producing a bad transform.
- **Reconsider if** a fixed fiducial jig is ever added: a stable `bed → jig`
  transform composes with the per-board `jig → board` transform — the value
  already supports `compose/2`, so this is reachable without reshaping the math.
- **Avoid the term "calibration":** Alignment is fitted fresh per board per
  session, not a stored calibration.
