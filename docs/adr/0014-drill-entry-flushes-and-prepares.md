# 14. Entering Drill flushes the planner and prepares; phase transitions set up initial conditions
<a id="adr-0014"></a>

- **Status:** Accepted
- **Date:** 2026-06-25
- **Builds on / amends:** [ADR-0012](0012-session-coordinates-stage-wire-screen.md#adr-0012)
  (the `Session` coordinator). ADR-0012 made `ConfirmRegistration` a single
  transition emitting `Plan[CancelStream, Stream(drill)]`; this ADR fixes what
  that plan does **physically** and generalizes the lesson to every phase edge.

## Context

ADR-0012 fixed the *software* coordination of dry-run → drill: one Session
transition, `Drilling` constructible only via `ConfirmRegistration`, the dry-run
cancel ordered before the drill stream. The app-level e2e test passed. **But on
real hardware the bug persisted**, and the user reported it precisely: mid-dry-run
you press Proceed, the UI flips to Drill and shows drill progress — yet the
machine keeps tracing the **dry-run** pattern (spindle off, hovering), not
drilling.

Root cause (confirmed in `printer.gleam`): **`CancelStream` writes nothing to the
wire** (`Streaming(_, _), CancelStream -> accepted(Jogging(0, …), [], cmd)`). It
stops the *host* from sending more lines and returns the FSM to `Jogging`, but it
does **not** flush Marlin's **planner buffer** — the dozens of dry-run moves
already sent are still queued in the firmware and keep executing. The subsequent
`Stream(drill)` then interleaves drill lines with the still-draining dry-run
motion. The e2e test missed this because the emulator drained its queue
synchronously and the test asserted streamed **line counts**, not the physical
interleaving of two programs.

The deeper lesson the user named: a phase transition must not merely **re-point
the stream** — it must **reset and prepare the machine** so the next phase starts
from a known, safe initial condition (planner empty, Z retracted, head at a
defined setup position). The `Session` FSM was reviewed end-to-end against this.

## Decision

### 1. A `Quickstop` wire command (raw M410 + M400)

Add `Quickstop` to `printer.Command`. It emits, **raw/unnumbered** (like `M112` /
`M114`, so it is actioned immediately rather than queued behind the very moves it
must flush):

```
M410   ; quickstop — abort all queued/buffered moves NOW (clears the planner)
M400   ; wait for the (now-empty) move queue to finish, so the next line is on a settled machine
```

`Quickstop` is valid from `Streaming` / `StreamPaused` / `Jogging` and lands in
`Jogging` (motors stay energized — alignment trust is preserved, ADR-0011). It is
distinct from `CancelStream` (benign host-side stop, no write) and from `Halt`
(M112 emergency → `Faulted`). It is the *graceful planner flush* that
`CancelStream` was wrongly assumed to be.

### 2. `ConfirmRegistration` flushes, prepares, then drills

The Session `Rehearsing → Drilling` plan becomes:

```
Plan = [ Quickstop, Stream(drill_program) ]
```

and the **drill program's preamble** (its first streamed lines) is a **prepare
sequence**: retract Z to the program-wide safe height, then travel (at safe Z) to
the **board-centroid setup position** — the same well-defined spot used for bit
changes — before the first tool block. So entering Drill always: (a) flushes the
dry-run motion dead (M410+M400), then (b) re-establishes a known safe pose, then
(c) drills. No interleaving, no surprise pose. The `M410`+`M400` cannot sit in the
stream (they would queue behind the moves they must cancel), which is exactly why
`Quickstop` is a raw command in the Plan, ahead of `Stream`.

### 3. Phase transitions set up initial conditions (the FSM review)

Reviewed every `Session` edge for "does the destination start from a defined
state?" The governing rules, now explicit:

- **Entering a streamed phase** (`RunDryRun`, `ConfirmRegistration`) flushes any
  in-flight motion first (`Quickstop`) when a stream could be live, and the
  streamed program's preamble re-establishes safe Z + setup pose. (Dry-run is
  entered from `Aligning` where nothing streams, so its flush is a benign no-op;
  drill is entered from `Rehearsing` where the dry-run *is* live, so the flush is
  load-bearing.)
- **Leaving a streamed phase backwards** (`RedoAlignment`: `Rehearsing →
  Aligning`) also `Quickstop`s (not bare `CancelStream`), so going back actually
  stops the dry-run motion rather than letting it drain. Motors stay energized,
  alignment stays valid, the operator re-aligns from a settled machine.
- **`Abort`** stays `Halt` (M112 → `Faulted`) from any active phase — the loud
  emergency path, unchanged.
- **`Deenergize` / `SerialLost` / `Reconnect`** are unchanged (ADR-0011): they
  discard trust and route to a clean slate; there is no "resume mid-phase".
- **Legal back/forth is preserved and guarded**: the only backward edge that
  keeps alignment is `Rehearsing → Aligning` (`RedoAlignment`); there is still no
  `Aligned → Drilling` shortcut (drill routes through dry-run), and `Drilling`
  has no backward edge to dry-run (re-entering drill is a fresh
  `ConfirmRegistration` after a `RedoAlignment`, which re-flushes and re-prepares
  — exactly the reset the user asked for).

## Consequences

- The dry-run → drill transition now **physically** resets the machine: the
  dry-run motion is flushed, Z retracted, the head parked at the setup centroid,
  then drilling begins. The reported bug is fixed at the wire level, not just the
  FSM level.
- **The emulator must model the flush to test it** (it currently auto-drains, so
  it can't observe "moves still queued were cancelled"). The faithful emulator
  ([ADR-0013](0013-faithful-emulator-motion-queue-and-envelope.md#adr-0013))
  gains an `M410` handler that empties its motion queue; an app-level e2e asserts
  that after `ConfirmRegistration` the dry-run moves are **gone** (queue flushed)
  and the streamed program is the drill program — the assertion the old test
  lacked.
- `Quickstop` is a new gate-bearing command; the printer FSM's transition tests
  cover it (valid in Streaming/StreamPaused/Jogging → Jogging with the raw
  M410+M400 writes; refused while Disconnected/Faulted).
- Trade-off: `M410` (quickstop) can lose steps on some configurations. We accept
  it because alignment is re-validated by the prepare pose (safe Z + known
  centroid) and, more importantly, because the alternative — letting the dry-run
  drain while drilling — is the actual hazard. Operators who prefer drain-first
  can be offered an `M400`-only variant later; not in scope here.
