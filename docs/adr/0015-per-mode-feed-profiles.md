# 15. Per-mode feed profiles (XY travel, plunge, retract — separate dry-run vs drill)
<a id="adr-0015"></a>

- **Status:** Accepted
- **Date:** 2026-06-25
- **Relates to:** [ADR-0001](0001-native-gcode-generation.md#adr-0001) (native
  G-code) and `GcodeConfig` (the tuned, operator-settable run parameters).

## Context

Two motion-speed problems on real hardware:

1. **XY travel is uncontrolled.** The generator emits XY moves as `G0` (rapid),
   so their speed is whatever the firmware's rapid feed happens to be — not
   operator-settable, and in practice slow. Only the Z moves carry a feed
   (`G1 F<drill_feed>`).
2. **Dry-run is needlessly slow.** Dry-run and drill share the one `drill_feed`,
   but a dry-run (spindle off, just tracing the pattern to verify registration)
   could safely run its XY travel much faster than a real cut.

The operator asked to configure the feed for plunge (Z down/up) and XY
displacement, and to have **separate dry-run vs drill profiles** — with dry-run
XY faster by default.

## Decision

Replace the single `drill_feed` with a **feed profile** carried per mode. A
profile has three feeds (mm/min):

- `xy_feed` — XY travel between holes (was an uncontrolled `G0`; now a controlled
  `G1 F<xy_feed>`).
- `plunge_feed` — the downward Z move into the work.
- `retract_feed` — the upward Z move back to safe.

`GcodeConfig` carries **two** profiles — `dry_run_feeds` and `drill_feeds` — and
`GcodeProgram.build` selects by `cfg.mode`. The emitter formats each move with the
selected profile's feed:

- XY travel → `G1 X.. Y.. F<xy_feed>` (was `G0`).
- plunge → `G1 Z.. F<plunge_feed>`.
- retract → `G1 Z.. F<retract_feed>`.

### Defaults

- **drill**: `xy_feed` and `plunge_feed` from the existing tuned value
  (`drill_feed` = 200), `retract_feed` a touch faster (retract is free travel).
- **dry-run**: `xy_feed` **≈ 2× the drill `xy_feed`** by default (the headline ask
  — dry-run traces faster); plunge/retract match drill (the hover move is small).

All values stay operator config (persisted per-operator in `localStorage`, never
hardcoded as a product/hardware truth — ADR-0004), exposed in **Settings** under a
"Feeds & Speeds" group with dry-run and drill columns.

### Invariant preserved

The XY-only-at-safe-Z invariant is untouched: making XY a `G1` changes only the
*speed* of the travel move, not its Z (still emitted at the program-wide safe
height). The spindle-before-plunge invariant is likewise unaffected.

## Consequences

- XY travel speed is now operator-tunable and, by default, dry-run traces ~2×
  faster — directly addressing the "moving pretty slowly, dry-run could be
  faster" report.
- `GcodeConfig` grows a `FeedProfile` type and two fields; the old scalar
  `drill_feed` is removed. Settings, the config persistence (`storage`), and the
  defaults move in lockstep. Existing g-code tests that pinned `G0` XY travel or
  the single `drill_feed` are updated to the per-mode `G1 F..` form (intent —
  "travel at the configured feed" — preserved).
- Backwards-compatible behavior is a non-goal: this is a single-operator,
  ephemeral-config app (ADR-0004); there is no stored profile to migrate, only
  the in-browser defaults, which the new shape supplies.
- A future "rapid" override (emit `G0` for travel when an operator wants firmware
  rapids) is possible but out of scope; the default is controlled `G1` travel so
  the speed is predictable and settable.
