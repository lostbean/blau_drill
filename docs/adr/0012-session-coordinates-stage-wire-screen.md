# 12. A `Session` coordinates stage + wire + screen — nest the machines, project the UI
<a id="adr-0012"></a>

- **Status:** Accepted
- **Date:** 2026-06-25
- **Builds on:** [ADR-0007](0007-state-machine-libraries.md#adr-0007) (pure-sum-type
  state machines, no library) and [ADR-0011](0011-energize-is-the-trust-boundary.md#adr-0011)
  (de-energize discards alignment). Does **not** supersede them — it adds a
  coordinator one level above the two machines they describe.

## Context

`blau-drill` had **three** authorities that each claimed to know "where the
session is," kept in sync by hand in `app.gleam` (1794 lines):

1. the **`job`** FSM — the stage (`Parsed → Registering → Aligned → DryRun →
   Drilling → Done`, + `AlignmentRejected`/`Faulted`);
2. the **`printer`** FSM — the wire (`Disconnected → Idle → Jogging → Streaming →
   StreamPaused → Faulted`);
3. **`model.screen`** plus a *second*, lossy `model.PrinterState` — the UI, set
   independently in each handler.

Two concrete drift sources, both confirmed in code:

- **Duplicated type.** `model.PrinterState` (`ui/model.gleam:117`, five cases, no
  payloads) is a hand-maintained, lossy mirror of `printer.PrinterState`
  (`control/printer.gleam:56`, six cases with payloads), bridged at
  `bridge.printer_state`. Two definitions of one concept — the UI one literally
  cannot see `StreamPaused`.
- **Stored projection.** `screen` is a stored copy of `f(job, printer)` that every
  handler writes by hand, so a handler can assert a screen the FSMs contradict.

The bug this produced: `confirm_registration` (DryRun → Drilling) does **three
un-atomic writes** — advance the job, set `screen: Drill` + 0 % progress, and
issue `printer.Stream(drill)`. But the dry-run stream is still in flight, so the
`printer` FSM **refuses** `Stream` with `Busy` (`printer.gleam:295`). The drill
never starts, yet the UI already shows **Drill / 0 %**. Then **Abort** issues
`Halt` (M112), which faults the controller while queued physical motion keeps
running. Three machines, no coordinator enforcing legal cross-machine transitions.

## Decision

Introduce **one** pure value, `Session` (`domain/session.gleam`), that **owns the
cross-machine state** by *nesting the real machines* — not by copying their state
tags into its own variants:

```gleam
pub type Session {
  Loading(board: BoardOpt, printer: printer.PrinterState)
  Aligning(job: job.Job, printer: printer.PrinterState)
  Rehearsing(job: job.Job, printer: printer.PrinterState)   // DryRun — stream REQUIRED
  Drilling(job: job.Job, printer: printer.PrinterState)     // constructed ONLY with a drill plan
  Completed(job: job.Job, printer: printer.PrinterState)
  Faulted(job: JobOpt, printer: printer.PrinterState)
}
pub type Overlay { NoOverlay  SettingsOpen  LogOpen }     // side routes, orthogonal to lifecycle
pub type Plan = List(printer.Command)                      // ordered; run in ONE effect
```

Three load-bearing moves, each tagged with the lens it serves:

- **Nest, don't copy** (State). A `Session` variant *holds* the actual `job.Job`
  and/or `printer.PrinterState`. There is exactly **one** `job` and **one**
  `printer` in the whole app. `model.screen`, `model.PrinterState`, and
  `bridge.printer_state` are **deleted** — there is nothing left to keep in sync,
  so nothing can drift.
- **Project, don't store** (Invariants). The screen is a pure function
  `session.screen(session, overlay) -> Screen`. With no stored screen field, a
  handler *cannot* assert a screen the FSMs contradict — the "UI says Drill but
  nothing is streaming" class of bug is **deleted, not fixed**. Side routes
  (Settings, Log) are an `Overlay` the projection consults, so they never become
  lifecycle states that clobber the job.
- **One coordinator owns ordered cross-machine moves** (Depth + Robustness). The
  pure transition `session.transition(session, action) -> Result(#(Session,
  Plan), Rejected)` mirrors `printer.gleam`'s `Step(state, writes, events)` one
  level up: it returns a **`Plan`** (an ordered `List(printer.Command)`) that
  `app.update` executes **in one effect, in order** (never `effect.batch`, the
  same rule that governs G-code writes). So `ConfirmRegistration` *is* the single
  transition `Rehearsing → Drilling` returning `Plan[CancelStream, Stream(drill)]`
  — the cancel precedes the drill in the same effect, so the drill can never be
  refused `Busy`. The `Drilling` variant is **constructible only** by that
  transition, so "Drilling without its own in-flight stream" has no
  representation. Abort is one transition whose `Plan` is `[Halt]`; the session
  rolls to `Faulted` and the wire halts in the same step. An illegal action
  returns a typed `Rejected(reason)` and writes nothing — never a half-applied
  cross-machine move.

This is **ADR-0007's discipline, one level up**: the same "make the illegal
combination fail to type-check" trick that distinguishes `PendingAlignment` from
`Alignment` is applied to the cross-machine seam. We considered (and rejected) a
`Session` that *copies* stage/wire info into its own tags — that would
re-introduce a third authority that can drift, the very thing we are removing.
Nesting the real values is what makes the coordinator drift-proof.

## Consequences

- **No new state-machine library, no new stored state.** `Session` is a plain sum
  type with a pure transition function, ephemeral in the Lustre model
  ([ADR-0004](0004-ephemeral-no-persistence.md#adr-0004)).
- **`app.gleam` shrinks to an orchestrator.** Each flow `Msg` becomes one
  `Session` action; the handler that set three things by hand is gone. The views
  read `screen(session, overlay)` and the real `printer.PrinterState` off the
  session for motion gates.
- **The dry-run→drill bug and the abort-mid-move bug become e2e tests** that drive
  `app.update` end to end through the faithful emulator
  ([ADR-0013](0013-faithful-emulator-motion-queue-and-envelope.md#adr-0013)):
  they fail before this change and pass after.
- **Faulted recovery follows ADR-0011.** A fault discards trusted position; the
  `Session` routes `Faulted → Loading` on reconnect, and the operator
  re-registers. There is no "resume where we were" across a motors-off gap.
- **Trade-off:** the refactor is large (it deletes `model.screen` /
  `model.PrinterState` / `bridge.printer_state` and touches every view that
  matched on them). We accept the blast radius because caching around the
  duplicated types would leave them able to re-drift; the goal is to remove the
  drift *sources*, not paper over them. The change is delivered in gated,
  test-backed chunks.
