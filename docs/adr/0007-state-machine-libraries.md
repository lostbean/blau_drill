# 0007 — State-machine approach for `Job` and `PrinterConnection`

- **Status:** Accepted
- **Date:** 2026-06-18

## Context

`blau-drill` has two state machines with fundamentally different shapes, and we
must decide independently for each.

### 1. `Job` — the session lifecycle (a pure domain value)

States: `parsed → registering → aligned → dry_run → drilling → done`, plus
`alignment_rejected` and `faulted`.

```
parsed            → registering          (pick board points)
registering       → registering          (capture another correspondence)
registering       → aligned              (fit ok AND residuals.max ≤ tol)
registering       → alignment_rejected   (residuals > tol)
alignment_rejected→ registering          (recapture)
aligned           → dry_run              (run dry-run)
dry_run           → aligned              (residuals look wrong, redo)
dry_run           → drilling             (confirm registration)
drilling          → done                 (all holes)
drilling          → faulted              (serial loss)
faulted           → aligned              (reconnect & resume)
```

Hard requirements:

- **Illegal sequencing must be unrepresentable.** There is deliberately **no
  `aligned → drilling` edge** — the only path to `drilling` runs through
  `dry_run`. You cannot drill before dry-run; you cannot fit an alignment from
  `< 3` non-collinear points.
- **Transitions guard on data.** The `registering → aligned` edge is gated by
  `residuals.max ≤ tol`; a failing fit lands in `alignment_rejected`, which
  exposes no drill event.
- The architecture (docs/blau-drill-architecture.html, §07) states the `Job`
  FSM **is** the encapsulation, and that the design is built on *immutable
  values held in LiveView assigns*. `Job` is best modelled as a **pure value
  with a `transition/2` function**, not a process.

### 2. `PrinterConnection` — the serial-link mode (a stateful process)

States: `idle → jogging → streaming → faulted`.

```
idle      → jogging    (energize + settle)
jogging   → idle       (release)
jogging   → streaming  (begin program)
idle      → streaming  (begin program)
streaming → idle       (program done)
streaming → faulted    (serial loss / halt)
faulted   → idle       (reconnect)
```

This is a **supervised, GenServer-like process** that owns a `circuits_uart`
serial port and hides the Marlin protocol (line numbering, checksums,
`ok`/`resend` handshake, `M114` polling, flow control) behind four verbs:
`jog/2`, `where/1`, `stream/2`, `halt/1`. Critical invariant: in `:idle` there
is **no jog command** — the 1–2 mm de-energized stepper snap is designed out;
the only path to `:jogging` runs an energize step first. A mid-stream
disconnect must transition to `:faulted`, halt the stream, and surface in the
UI as a local, supervised event.

### Project constraints

- **No Ecto.** There is no database; the session is ephemeral (a crash loses
  the session — accepted per non-goals). Any library whose value depends on
  Ecto persistence is a poor fit.
- Toolchain: **Erlang/OTP 28, Elixir 1.20** (pinned in `flake.nix` / `mix.exs`).
- Add dependencies only when they earn their keep.

## Options considered

Verified June 2026 against hex.pm and GitHub.

| Option | Dep cost | Pure value vs process | Guard / data-on-transition | Illegal transition is… | Maintenance / OTP-28 | Readability |
|---|---|---|---|---|---|---|
| **`:gen_statem`** (OTP built-in) | **None** (stdlib) | **Process** (energize-before-jog, timeouts, faulted) | Yes — guards in callbacks; `state_enter`, state/event/generic **timeouts**, **postpone**, inserted events | **Runtime** (returns/raises), but rich `next_state`/`keep_state` control | **Ships with OTP 28** (current line OTP 29). Maintained by the OTP team | Verbose Erlang-ish callbacks, but battle-tested; ideal for hardware/timeout logic |
| **`Machinery`** v1.1.0 | Low — **0 deps**, no Ecto | Pure (no process); also has an optional supervised wrapper | Guards via `guard_transition/2`; `before/after_transition`; `transition_to/3` → `{:ok, struct} \| {:error, reason}` | **Runtime** — states/transitions are strings/atoms in a DSL | Last commit & Hex release **Apr 2023** (1.1.0). (A stale GitHub *release tag* reads 0.16.1/2018; the Hex package and `master` are 2023.) Soft-maintained | Clean DSL; transitions live in a module attribute |
| **`Fsmx`** v0.5.0 | Low — `ecto`/`ecto_sql` present but **both `optional: true`**; plain-struct path needs neither | Pure value via `Fsmx.Struct` | `before_transition/3` callback to mutate/guard; `transition(struct, new_state, opts)` → `{:ok, struct} \| {:error, reason}` | **Runtime** — transition map is data | Last release **Aug 2023**, last commit **Sep 2023**. Quiet but functional; plain-struct mode is **first-class** | Concise; transition map + a single callback. Ecto is genuinely opt-in |
| **`gen_state_machine`** v3.0.0 | Low — 0 deps | Process (thin `:gen_statem` wrapper) | Same as `:gen_statem` (it just wraps it) | **Runtime** | Last commit **Oct 2020** — effectively dormant. Adds a dep for what OTP 28 gives free | Slightly friendlier than raw `:gen_statem`, but stale |
| **Hand-written pure `transition/2`** | **None** | **Pure value** (perfect for `Job` in assigns) | Yes — plain `case`/guards on `%Job{}` + event; arbitrary data checks (`residuals.max ≤ tol`) | **Typed at the boundary** — `@spec transition(t, event) :: {:ok, t} \| {:error, reason}`; missing clauses are `{:error, :illegal_transition}`; states modelled as an atom union + per-state structs make many illegal combos unrepresentable | N/A — your code | Maximum: the legal graph reads top-to-bottom in one module; no DSL to learn |

Notes on "compile-time vs runtime" honesty: **none** of these libraries make an
illegal transition a *compile error* — they all validate at runtime. The
closest we get to "unrepresentable" is the **data model** (the brief's `Job`
design): model state as a tagged union and attach per-state payload types
(e.g. `PendingAlignment` vs solved `Alignment`) so that functions needing a
transform cannot be handed an unsolved one. That property comes from *our
types*, not from any FSM library — which is an argument for keeping `Job`
hand-rolled where we control the shape.

## Recommendation

### `PrinterConnection` → **`:gen_statem`** (primary)

This validates the coordinator's prior. `PrinterConnection` is already a
supervised process owning hardware, and `:gen_statem` is purpose-built for
exactly this:

- **Zero dependency** — it is OTP stdlib, present on OTP 28.
- **State-enter calls** map cleanly onto "run energize+settle on entering
  `:jogging`," which is precisely how we enforce *no-jog-in-idle* — the energize
  step is the entry action of `:jogging`, not an ad-hoc call the caller could
  skip.
- **Timeouts** (state/generic timeouts) cover the Marlin `ok`/`resend`
  handshake, `M114` poll cadence, and settle delays without a hand-rolled timer.
- **Postpone / inserted events** handle a jog request that arrives before
  energize completes, and a clean `→ :faulted` halt on serial loss.

Use **callback mode `state_functions`** (state is an atom; co-locate each mode's
logic in `idle/3`, `jogging/3`, `streaming/3`, `faulted/3`) with
`[state_functions, state_enter]`. Prefer raw `:gen_statem` over
`gen_state_machine` (dormant since 2020, and an avoidable dep for what OTP 28
ships).

### `Job` → **hand-written pure `transition/2`** (primary)

Also validates the prior. `Job` is a pure value held in LiveView assigns; the
legal graph is small (8 states, ~11 edges) and the guards are domain-specific
(`residuals.max ≤ tol`, `≥ 3` non-collinear points). A library buys us little
and costs us the thing that matters most here — control of the **types** that
make illegal states unrepresentable. The transition graph is more readable as
~11 explicit clauses in one module than as a DSL, and it lets us return precise
typed errors (`{:error, :residuals_over_tol}`, `{:error, :need_three_points}`).

**`Fsmx` (plain-struct mode) is the acceptable fallback** if we later want the
graph declared as data: its Ecto deps are genuinely `optional: true` (verified
on hex.pm — the plain-struct path pulls in *neither* `ecto` nor `ecto_sql`), and
`Fsmx.Struct` + `before_transition/3` is first-class. But it does not improve
the "unrepresentable" property over hand-rolling, so it is a fallback, not the
recommendation.

**Rejected:** `Machinery` (fine library, but no advantage over hand-rolling for
a value this small, and its string-state DSL is weaker than a typed union);
`gen_state_machine` (dormant, needless dep for `Job` which shouldn't be a
process at all).

## Consequences

- **Commits us to:** raw `:gen_statem` callback style for `PrinterConnection`
  (Erlang-flavoured, more verbose than a GenServer — acceptable for the one
  hardware-owning process), and a bespoke `Job` module we own end-to-end.
- **No new runtime dependencies.** Nothing to track for OTP-28/security upkeep
  in this layer.
- **Testing:** `Job.transition/2` is trivially unit-testable (pure, no
  process). `PrinterConnection` can be driven via `:gen_statem` with a fake
  `circuits_uart` port; `state_enter` actions are independently assertable.
- **What we'd reconsider later:** if the `Job` graph grows large or we need to
  render/inspect it as data (e.g. a visualization, or generated docs), move
  `Job` to **`Fsmx` plain-struct** — the migration is mechanical because both
  are pure-value `transition`-returns-`{:ok, t} | {:error, reason}` shapes. If
  the `PrinterConnection` callbacks ever feel too bare, `gen_state_machine`
  could wrap them, but only if it regains maintenance; otherwise stay on
  stdlib.

## If hand-rolled, here's the shape (`Job.transition/2`)

A target for the implementer — spec/signature and one representative clause, not
a full implementation.

```elixir
defmodule BlauDrill.Job do
  @moduledoc "Pure session-lifecycle FSM. A value, never a process."

  @type state ::
          :parsed | :registering | :aligned | :alignment_rejected
          | :dry_run | :drilling | :done | :faulted

  # Events carry the data the guards need (correspondences, tolerance, …).
  @type event ::
          {:capture, correspondence :: map()}
          | {:fit, tol :: float()}
          | :run_dry_run
          | :confirm_registration   # dry_run -> drilling (the ONLY path to drilling)
          | :redo_alignment         # dry_run -> aligned
          | :recapture              # alignment_rejected -> registering
          | :complete               # drilling -> done
          | {:serial_loss, reason :: term()}
          | :reconnect              # faulted -> aligned

  @type reason ::
          :illegal_transition | :need_three_points | :residuals_over_tol | term()

  @type t :: %__MODULE__{state: state(), alignment: term(), residuals: map() | nil}
  defstruct state: :parsed, alignment: nil, residuals: nil

  @spec transition(t(), event()) :: {:ok, t()} | {:error, reason()}

  # Representative clause: the residual-gated alignment fit.
  # Illegal-from-here events simply never match these clauses.
  def transition(%__MODULE__{state: :registering} = job, {:fit, tol}) do
    with {:ok, alignment} <- Alignment.fit(job),          # errors if < 3 non-collinear pts
         %{max: max} = residuals <- Alignment.residuals(alignment) do
      if max <= tol do
        {:ok, %{job | state: :aligned, alignment: alignment, residuals: residuals}}
      else
        {:ok, %{job | state: :alignment_rejected, residuals: residuals}}
      end
    end
  end

  # ... one clause per legal edge; note there is NO :aligned + :confirm clause,
  #     so aligned -> drilling is simply not expressible.

  # Catch-all keeps illegal sequencing a typed error, not a crash.
  def transition(%__MODULE__{}, _event), do: {:error, :illegal_transition}
end
```
