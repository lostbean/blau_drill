# 0007 — State-machine approach for `Job` and the serial control layer

- **Status:** Accepted
- **Date:** 2026-06-18

## Context

`blau-drill` has two state machines with fundamentally different shapes, and we
decide independently for each.

### 1. `Job` — the session lifecycle (a pure domain value)

States: `Parsed → Registering → Aligned → DryRun → Drilling → Done`, plus
`AlignmentRejected` and `Faulted`.

```
Parsed            → Registering          (pick board points)
Registering       → Registering          (capture another correspondence)
Registering       → Aligned              (fit ok AND residuals.max ≤ tol)
Registering       → AlignmentRejected    (residuals > tol)
AlignmentRejected → Registering          (recapture)
Aligned           → DryRun               (run dry-run)
DryRun            → Aligned              (residuals look wrong, redo)
DryRun            → Drilling             (confirm registration)
Drilling          → Done                 (all holes)
Drilling          → Faulted              (serial loss)
Faulted           → Aligned              (reconnect & resume)
```

Hard requirements:

- **Illegal sequencing must be unrepresentable.** There is deliberately **no
  `Aligned → Drilling` edge** — the only path to `Drilling` runs through
  `DryRun`. You cannot drill before dry-run; you cannot fit an alignment from
  `< 3` non-collinear points.
- **Transitions guard on data.** The `Registering → Aligned` edge is gated by
  `residuals.max ≤ tol`; a failing fit lands in `AlignmentRejected`, which
  exposes no drill event.
- `Job` is a pure value, not a process.

### 2. The serial control layer — the link mode

States: `Disconnected → Idle → Jogging → Streaming → Faulted`.

```
Disconnected → Idle       (connect)
Idle         → Jogging    (energize: M17)
Jogging      → Idle       (release: M18)
Jogging      → Streaming  (begin program)
Idle         → Streaming  (begin program)
Streaming    → Idle       (program done)
any active   → Faulted    (serial loss / halt: M112)
Faulted      → Idle       (reconnect)
```

It owns the Web Serial port and hides the Marlin protocol (line numbering,
checksums, `ok`/`resend` handshake, `M114` polling, flow control). Critical
invariant: in `Idle` there is **no jog command** — the 1–2 mm de-energized
stepper snap is designed out; the only path to `Jogging` emits the energize step
(M17) as its entry action. A mid-stream disconnect must transition to `Faulted`,
halt the stream, and surface in the UI.

### Project constraints

- No database; the session is ephemeral (only operator config persists, in
  `localStorage`).
- The whole app is **Gleam → JavaScript** running in the browser. There is no
  BEAM/process runtime; concurrency is the browser event loop + Promises.
- Add dependencies only when they earn their keep.

## Decision

Model **both** state machines as **Gleam sum types with pure transition
functions** — no state-machine library.

Gleam's type system is the whole argument: a state machine is a tagged union
(`type State { ... }`) and a transition is a total function
`fn(State, Event) -> Result(State, Error)` (or, for the serial layer,
`fn(State, Command) -> Step`). This makes the key property structural rather than
runtime-checked:

- **Illegal states are unrepresentable** because each variant carries *only* the
  data that state owns. `PendingAlignment` (a distinct type from solved
  `Alignment`) means a function needing a transform cannot be handed an unsolved
  one. There is no `Aligned, ConfirmRegistration` case clause, so the
  `Aligned → Drilling` shortcut literally does not type-check into existence.
- **Guards are plain code** on the variant + event (`residuals.max <=. tol`,
  `≥ 3` non-collinear points) — no DSL to learn, the legal graph reads
  top-to-bottom in one `case`.
- **Energize-before-jog is structural:** `Jog`/`MoveTo`/`PulseSpindle` only match
  in the `Jogging` variant; every other state returns a refusal and writes
  nothing. The only constructor of `Jogging` emits M17.

The serial layer keeps a **pure core** (`printer.gleam`: transitions return
`Step(state, writes, events)`) with all I/O pushed to a thin effectful shell
(`controller.gleam`) over a `Backend` seam (Web Serial or simulator). This makes
the protocol logic unit-testable with synthetic inbound lines and no browser.

## Consequences

- **No state-machine dependency, no process runtime.** Nothing to track for
  upkeep in this layer; the transition logic is ours end-to-end.
- **Testing is trivial:** both `Job.transition` and the serial `command`/`feed`
  functions are pure — drive them with values, assert the returned state, writes,
  and events. The simulator `Backend` exercises the full streaming handshake
  headlessly.
- **Trade-off:** ordering of side effects is the caller's responsibility — the
  serial shell must perform a transition's `writes` in one effect, never via
  `effect.batch` (which reverses synchronous order and would corrupt an ordered
  `G91`/`G0`/`G90` jog). This is encapsulated in `controller.gleam`.
- **What we'd reconsider later:** if either graph grew large enough to want
  data-driven inspection/visualization, a generated diagram from the sum type
  would be preferable to adopting a library — the typed-union property is the
  thing we are unwilling to give up.
