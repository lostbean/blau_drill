# 18. The Model holds only parameters + machines; everything derived is projected
<a id="adr-0018"></a>

- **Status:** Accepted
- **Date:** 2026-06-25
- **Builds on / amends:** [ADR-0004](0004-ephemeral-no-persistence.md#adr-0004)
  (ephemeral run state), [ADR-0011](0011-energize-is-the-trust-boundary.md#adr-0011)
  (alignment trust / nothing persisted), [ADR-0012](0012-session-coordinates-stage-wire-screen.md#adr-0012)
  (the Session is a projection, screen is not stored). Completes the program-pipeline
  pair [ADR-0016](0016-typed-operation-algebra.md#adr-0016) / [ADR-0017](0017-typed-rendered-line-through-fsm.md#adr-0017).

## Context

[ADR-0012](0012-session-coordinates-stage-wire-screen.md#adr-0012) removed the
stored `screen` and the `model.printer` mirror by making them projections of the
nested machines. But the same disease persists across the rest of the `Model`:
~20 fields are **stored copies of state that already lives in the `job` FSM, the
`printer` FSM, or the streamed program** — `quality` / `residual_max` /
`residual_rms` / `alignment_rejected` / `fit_diag` shadow `job.alignment`;
`captured` / `captures` / `transform` shadow `job.pending` / `job.alignment`;
`progress` / `telemetry_bit` / `telemetry_eta` / `bit_change` shadow the stream
position; `head_pos` / `head_confidence` shadow `(head, transform, captures)`.

Every handler that advances a machine must then hand-sync the 5–10 fields that
depend on it (e.g. `RestartAlignment` clears `captured`, `captures`,
`current_target`, `quality`, and more, one by one). A missed reset is a drift bug.
This is the stringly-typed bug ([ADR-0016](0016-typed-operation-algebra.md#adr-0016)) one level up: a second
authority kept in sync by hand. `app.current_program` is the same disease in time —
it *rebuilds and re-parses* the entire G-code program on every progress event to
re-derive the hole count.

## Decision

The `Model` holds **only parameters and the nested machines**; every derived value
is a **pure projection**, computed each frame and stored nowhere.

- **Parameters** (the only things that persist, [ADR-0004](0004-ephemeral-no-persistence.md#adr-0004)):
  board source, machine config, `board_side`, `jog_step`, `zoom`, `backend_kind`,
  settings category, overlay, modal flags.
- **Machines** (the authorities): the one `job`, the one `printer` (in the
  controller), `board_model`, the run-start `applied_config` snapshot, and the
  **single run-state value `stream_index: Int`**.
- **Projections** (deleted as fields, added as functions): `progress`,
  `hole_status`, current `tool`, `eta`, `quality`, `residuals`,
  `alignment_rejected`, `fit_diag`, `captured` fiducials, `head_pose`,
  `head_confidence`, `summary`, `screen` — each `f(session, …)` recomputed per
  frame.

```gleam
fn project_progress(rendered, stream_index)        -> Progress
fn project_hole_status(rendered, stream_index, id) -> HoleStatus
fn project_tool(rendered, stream_index)            -> ToolId          // origin.tool, not a T<n> grep
fn project_quality(job)                            -> Int             // job.alignment.residuals
fn project_captured(job, current_target)           -> List(Fiducial)  // job.pending.captured, not a shadow
```

### The command program is projected, not stored as strings

There is no `current_program` rebuild. The program is rendered **once** into the
FSM's `StreamJob` at run start ([ADR-0017](0017-typed-rendered-line-through-fsm.md#adr-0017)); progress reads that
already-rendered list by `stream_index`. The only run-state is the index. "Which
program is streaming" has one answer (the FSM's `StreamJob.rendered`), so it cannot
disagree with the wire.

### Ephemeral runtime is structural

The persisted slice (`storage.gleam`) is typed to hold **only parameters** —
runtime fields are not members of that type, so "persist the progress to resume a
run" is unrepresentable, not merely discouraged. On `init`: load params from
`localStorage`, construct fresh machines, project everything else from empty. A
page refresh restores params only and restarts the run — the [ADR-0004](0004-ephemeral-no-persistence.md#adr-0004)
/ [ADR-0011](0011-energize-is-the-trust-boundary.md#adr-0011) invariant, now
enforced by the Model's shape rather than by `init` zeroing two dozen fields.

## Consequences

- The drift class is removed, not patched: there is no stored value that can fall
  out of sync with a machine, because the value isn't stored. Handlers stop
  hand-syncing shadow fields; an alignment reset is just a `job` transition.
- Views call projection functions instead of reading `model.<derived>`. Projections
  are pure and cheap; if any proves hot, it is memoized at the call site, never
  promoted back to a stored field.
- This is the highest-blast change of the three: ~20 `Model` fields are deleted and
  the handlers that wrote them are simplified. The test suite shifts from asserting
  stored fields to asserting projections — which is what the UI actually shows.
- Trade-off: a projection recomputes each frame instead of caching. For a
  single-operator bench app this is free; the correctness win (one authority, no
  drift) is the whole point of the redesign.
