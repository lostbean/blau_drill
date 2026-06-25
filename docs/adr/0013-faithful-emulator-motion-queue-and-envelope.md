# 13. The faithful emulator models a motion queue, a tick, and an envelope
<a id="adr-0013"></a>

- **Status:** Accepted
- **Date:** 2026-06-25
- **Builds on:** the faithful-emulator work
  (`control/marlin_emulator.gleam` — line/checksum validation, motor state, `M0`
  block, `M114`) and its design note in `.scratch/marlin-emulator/DESIGN.md`.
  Pairs with [ADR-0012](0012-session-coordinates-stage-wire-screen.md#adr-0012):
  the leveled-up emulator is how the coordination layer is tested.

## Context

The existing `marlin_emulator.gleam` is a faithful **protocol** model — but it
treats every move as **instantaneous**. So two real-hardware, safety-relevant
states have **no representation**, and the thin simulator masks them:

1. **Queued / in-flight motion** — Marlin's planner buffers moves; physical
   motion continues after the host stops sending. "The machine is still moving
   after I hit abort" cannot be expressed if every move completes the instant it
   is fed.
2. **The envelope** — a move past the machine's XYZ limits (or a negative axis)
   should be rejected; an instantaneous, unbounded integrator never refuses one.

Without these, an e2e test cannot prove that **abort actually stops the head**
(the second half of the [ADR-0012](0012-session-coordinates-stage-wire-screen.md#adr-0012)
bug), nor that an out-of-bounds move is caught.

## Decision

Level the emulator up with **physical time** and **an envelope**, keeping it a
**pure core** so the protocol logic stays unit-testable with no browser:

```gleam
pub type EmulatorState {
  EmulatorState(
    last_line: Int, motors_on: Bool, abs: Bool, x: Float, y: Float, z: Float, paused: Bool,
    queue: List(QueuedMove),   // NEW — admitted-but-not-yet-executed moves (the planner buffer)
    bounds: Bounds,            // NEW — injected XYZ envelope
  )
}
pub fn feed(s, line) -> #(EmulatorState, List(String))  // admits a move, acks the ADMISSION
pub fn tick(s, dt) -> EmulatorState                      // drains the queue, advancing the head
pub fn halt(s) -> EmulatorState                          // clears the queue → motion stops
pub fn force(fields…) -> EmulatorState                   // test seam: set ANY state directly
```

The decisions:

- **`feed` admits; `tick` drains** (State). `feed` enqueues a move and acks its
  *admission to the buffer* (like Marlin); a **separate** `tick(state, dt)`
  advances the head over time. Because they are separate, a test can `feed` a long
  move and **not** `tick` — leaving the queue non-empty and the head at its start,
  i.e. the **"still moving"** state — then issue `halt` and assert the queue is
  `[]`. That makes "physical motion continues after abort" a concrete,
  **assertable** regression, not a bench-only hazard.
- **Envelope limits live in the emulator config, test-injected** (Robustness). The
  emulator carries a `Bounds` supplied at construction. A move whose target is
  outside `bounds` (or past a negative min) replies a Marlin-style `error` and is
  **not admitted** — the head does not advance. Bounds are injected by the test,
  so we add **no product default**: motion limits are operator/hardware config,
  never a hardcoded product value ([ADR-0004](0004-ephemeral-no-persistence.md#adr-0004),
  and the project conventions in `CLAUDE.md`).
- **A `force` test seam** (Robustness). Tests can drop the printer into *any*
  `EmulatorState` directly, to exercise edge cases without driving the machine
  there command by command.
- **One core, two drivers** (Composition). The pure `tick` is pumped two ways:
  - **deterministic** — e2e/CI tests call `tick(dt)` by hand, so timing is exact
    and the freeze-mid-move assertion above is possible;
  - **auto-pump** — a thin `emulator_ffi.mjs` shim pumps `tick` on a JS interval
    behind the `Backend` seam, so the **same** core runs as a live in-app virtual
    machine the operator UI can be driven against, hardware-free.

## Consequences

- **The two ADR-0012 bugs become e2e tests** driving `app.update` through
  `transport.emulator()`: a dry-run→confirm test asserts the drill actually starts
  (fails before the coordination fix), and an abort-mid-move test asserts the head
  stops (needs the queue + `halt` this ADR adds).
- **The emulator is now a usable simulator, not just a test fixture.** The
  auto-pump driver makes the flow demonstrable on the live UI without the bench —
  directly addressing the "no in-browser verification" gap.
- **Faithfulness is bounded on purpose.** We model *enough* physics — a queue, a
  tick, an envelope — to make the safety-relevant states observable. We do **not**
  model a cycle-accurate planner (per-move accel/jerk timing); a faithful
  feedrate→duration model is a possible later extension if "speed" tests need it,
  but is out of scope here to avoid over-engineering the emulator beyond what the
  flow tests require.
- **The thin simulator stays.** It remains the fast/forgiving dev backend; the
  faithful emulator is additive and selectable, and all existing tests stay green.
