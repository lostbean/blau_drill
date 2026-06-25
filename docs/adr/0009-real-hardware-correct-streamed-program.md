# 9. Real-hardware-correct streamed program (sanitize, app-pause, centroid exchange)
<a id="adr-0009"></a>

- **Status:** Accepted (app-pause is now the DEFAULT, commit 8578960; amended by
  ADR-0010 — the start-of-run touch-off `M0`/`G92` is REMOVED and Z is
  plane-relative. Sanitize, app-pause, and the centroid exchange below stand.)
- **Date:** 2026-06-23

## Context

`GcodeProgram.build` emits a human-readable Marlin program: blank lines for
visual grouping, full-line `( comments )`, `M0` mandatory stops at touch-off and
each bit change, and per-tool retracts. The app streams `program.lines`
**verbatim** through the numbered `ok`/`resend` handshake (see ADR-0001, the
control state machine).

On the **simulator** this works — the sim synthesizes an `ok` for every written
line. On **real Marlin** the dry-run/drill hangs at 0/130 with no error: Marlin
does **not** reliably emit an `ok` for a blank line, so the handshake stalls on
the first blank line and never advances. Comments and `M0` add two further
mismatches with a screen-driven workflow: `M0` blocks until the operator presses
resume **on the printer's panel**, freezing the app's progress while it waits on
hardware the operator isn't looking at.

Separately, a bit change only retracts Z (to `zchange`) — the operator swaps the
bit directly over the board, with no clear exchange position.

## Decision

Make the **streamed** program real-hardware-correct while keeping the rich
program for human-readable export. Three coupled changes, all in `GcodeProgram`
(plus config plumbing):

1. **Sanitize before streaming.** A pure `stream_lines(program)` returns the
   program with blank/whitespace-only lines and full-line comments removed; the
   app streams **this**, never `program.lines`. Every real command survives in
   order. `program.lines` stays the rich form for a future g-code export.

2. **Configurable `M0` (app-pause vs export).** A `GcodeConfig.app_pause` flag
   governs `M0`: when set (the in-app streaming workflow), `M0` is **omitted** and
   the app pauses the stream in-app at touch-off / each bit change with a resume
   affordance (building on the existing bit-change UI) — control stays on the
   screen. Default is **`M0` present** (conservative); a future standalone g-code
   **export always keeps `M0`** (a file has no app to drive it). A stream that
   omits `M0` must still **pause** at each bit-change boundary — a bit change
   without a swap opportunity is never allowed.

3. **Bit-exchange at the board centroid.** Each tool block, after retracting Z to
   `zchange`, moves XY to the board **centroid** (center of mass = mean of the
   machine-space hole positions, via the alignment transform), then pauses for the
   swap, then returns to the work. Applies to dry-run, drill, and export.

## Consequences

- The real-hardware streaming stall is fixed: the handshake only ever sees lines
  Marlin acks. This is a streaming **invariant** — no blank line is ever streamed.
- The simulator could not have caught this (it acks everything); the regression is
  pinned by a unit test on `stream_lines` (no blanks/comments) rather than by the
  sim. Real-hardware behavior is the operator's bench check.
- The generated program now depends on `app_pause`; the human-readable export and
  the streamed form diverge by design (export = rich + `M0`; stream = sanitized,
  `M0` omitted when `app_pause`).
- The exchange centroid is derived from the board (no new operator config); it
  changes the tool-block g-code, so existing `GcodeProgram` tests that pin the
  tool-block / preamble shape are updated.

## Related

- ADR-0001 (native g-code generation) — this refines what that generator emits and
  how it is streamed.
- ADR-0006 (safety-gate model) — the app-pause path keeps the bit-change pause; a
  swap opportunity is mandatory, never skipped.
