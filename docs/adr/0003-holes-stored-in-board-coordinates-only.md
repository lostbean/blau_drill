# 3. Holes are stored in board coordinates only

- **Status:** Accepted
- **Date:** 2026-06-18

## Context

A drilling job has two coordinate frames: **board space** (what the KiCad
`.drl` describes) and **machine space** (where the Marlin head actually goes).
The naive model stores both on each `Hole` and updates the machine coordinate
when alignment changes. That creates a desynchronization hazard: a re-fit, a
recapture, or a bug can leave a hole's stored machine coordinate stale relative
to the current `Alignment`, and nothing in the type system catches it.

## Decision

**Holes live only in board space** — `%{x, y, tool}` in board coordinates, never
machine. A hole's machine coordinate is a **derived view**, computed on demand
by `Transform2D.apply(alignment.transform, hole)`. There is **no settable
machine-coordinate field** on `Hole`, `BoardModel`, or anywhere else. Anything
that needs machine coordinates (the G-code generator, the live canvas overlay)
applies the current transform at the point of use.

## Consequences

- The invariant "a hole's machine coordinate is always the transform of its board
  coordinate" is unrepresentable to violate — there is no second field to drift.
- Re-fitting the `Alignment` instantly and consistently moves every derived
  machine coordinate; no cache to invalidate, no batch update to forget.
- `BoardModel` is a pure value produced once at the parsing edge and never
  mutated by alignment — it composes cleanly with any number of trial fits.
- **Trade-off:** machine coordinates are recomputed on each use rather than
  cached. For a few hundred holes this is negligible; **reconsider if** a board
  with very many holes ever makes per-frame recomputation on the live canvas a
  measurable cost — at which point memoize the *view*, never reintroduce a
  settable stored field.
