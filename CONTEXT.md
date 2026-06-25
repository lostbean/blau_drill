# blau-drill — Domain Context

The canonical vocabulary and load-bearing decisions for `blau-drill`. Every
implementation agent should share the terms defined here and obey the
invariants. When code names a domain concept — in a module, a type, an issue, a
test name — use the term as defined below and avoid the synonyms each entry
explicitly rejects.

> This is a **single-context** repo: this one `CONTEXT.md` plus `docs/adr/`.
> The promoted **architecture overview** (the durable source of truth for
> structure) lives in [`docs/design/overview.html`](docs/design/overview.html); the
> product brief in
> [`docs/design_reference/blau_drill_project_brief.md`](docs/design_reference/blau_drill_project_brief.md).

## Purpose

blau-drill is a single-operator **pure-browser** instrument (Gleam compiled to
JavaScript via the Lustre framework — no backend server, no install) that drives
a modified Two Trees Bluer (a 3D printer running Marlin) to drill PCBs. It runs
entirely in a Chromium browser and talks to the printer **directly over the Web
Serial API**. It loads a KiCad board, fits an affine **board → machine**
transform from human-located fiducials, and streams Marlin-correct G-code over
the live serial link — dry-run first, real drilling second. It replaces a
hand-rolled chain of re-export, a mirror flag, a fiducial `G92`, pcb2gcode, and a
Python post-processor with one guided flow where the wrong order is
unrepresentable.

> **Source layout:** the domain glossary and invariants below are
> language-independent. They map directly onto the code: a concept `Foo` lives as
> `foo.gleam` in `src/blau_drill/{domain,control,ui}/`, and a `Foo.bar`
> operation as the `bar` function in that module.

## Glossary

The registration → alignment progression is the spine of the domain. Illegal
states ("a drilling job with no transform", "a transform from 2 points") have no
representation — they cannot be constructed.

### BoardModel {#term-boardmodel}

The immutable parse of the KiCad outputs — `holes`, `outline`, `fiducials`,
`tools`, and bounding box — entirely in **board coordinates**. Produced once at
the parsing edge by `BoardModel.parse/1` and consumed by everything downstream;
nothing past the edge ever touches a file again.
_Avoid:_ "drill file" / "the Gerber" as a synonym — those are raw inputs, not
the parsed value. Don't say a BoardModel holds machine coordinates; it never
does.

### Hole

A single drill location in **board space**: `%{x, y, tool}`. A hole's machine
coordinate is never stored — it is a derived view, computed on demand via
`Transform2D.apply/2`. There is no settable machine-coordinate field.
_Avoid:_ "point" (ambiguous with registration points/fiducials) and "drill hit".

### Fiducial

A registration-candidate reference mark on the board (`%{x, y, kind: :cross |
:hole}`), in board coordinates. Fiducials are placed on the copper side drilled
from (back copper); unlike the board edge, they survive etching, so the operator
can still register to them. The set of selectable registration points is
`fiducials ++ holes`.
_Avoid:_ "marker" / "alignment mark" as the canonical noun; the domain term is
**Fiducial**.

### ToolTable

The mapping `tool_id => diameter_mm` parsed from the Excellon file. Drives
per-tool grouping in the G-code and the bit-change pauses during drilling.
_Avoid:_ "bit list" in code; "ToolTable" is the type, "bit" is the physical
object the operator swaps.

### Correspondence {#term-correspondence}

A captured pair `{board_point, machine_point}` — a board feature paired with
where the printer head actually is when the operator locates that feature
physically. The raw material that `Alignment.fit/1` consumes. Correspondences
accumulate as an append-only list while registering.
_Avoid:_ "calibration pair" / "mapping" — it is specifically a board↔machine
pair captured by a human.

### PendingAlignment {#term-pendingalignment}

The in-progress type holding **fewer than 3** correspondences (or 3+ that are
still collinear). It has **no transform field** — it is a structurally different
struct from `Alignment`, so no function that needs a transform can be handed an
unsolved one. Capturing the deciding non-collinear correspondence promotes it,
via `Alignment.fit/1`, to an `Alignment`.
_Avoid:_ treating it as "an Alignment that isn't ready" — it is a distinct type,
not a flag on Alignment.

### Alignment {#term-alignment}

A **solved** value: an affine `Transform2D` for XY, a **Z surface plane** for
depth, plus its `residuals`. It is **2.5D** (ADR-0010): each Correspondence
carries `machine_z` (read from `M114` when the operator jogs the bit onto the pad),
and `Alignment.fit/1` solves both the 2×3 XY affine AND a least-squares tilted
plane `z = a·bx + b·by + c` over the captured Z's — so drill depth references the
real per-hole surface (tilt/bend corrected), not one global touch-off. Constructible
**only** via `Alignment.fit/1`, and only from ≥3 non-collinear correspondences;
otherwise `{:error, :too_few}` (caller keeps the `PendingAlignment`) or
`{:error, :degenerate}`. The trust gate stays the **XY** residual. No public
constructor.
_Avoid:_ the word **"calibration"** — Alignment is a per-board fitted transform,
solved fresh each session, not a stored calibration. There is **no `G92`** in the
run anymore (ADR-0010 removed the touch-off): the affine owns XY and the plane owns
surface Z, so don't describe a "fiducial G92" or origin reset.

### Transform2D

A 2×3 affine matrix mapping **board → machine**. A composable, invertible value:
`Transform2D.apply(t, {bx, by}) -> {mx, my}`, `compose/2`, `invert/1`. Being a
full affine, it absorbs translation, rotation, **mirror**, and skew in one
matrix — the back-side X-mirror, a board not square to the bed, and the fiducial
offset all collapse into it.
_Avoid:_ "offset" or "G92 offset" — those describe only the translation part; a
Transform2D is the whole affine.

### Residuals

The per-point fit error of an `Alignment`, reported as `%{rms, max}` in
millimetres. This is the **honesty/trust signal**: it tells the operator whether
the fit is trustworthy *before* the bit touches copper. `residuals.max` gates the
real run (see **residual gate**).
_Avoid:_ "error score" / "accuracy %"; the UI may show a quality percentage, but
the domain value is `residuals` (rms + max).

### PrinterConnection {#term-printerconnection}

The system's **single stateful identity**: the serial control state machine
owning the link to Marlin for the duration of a drilling session. In the Gleam
app this is `src/blau_drill/control/` — a **pure** transition core
(`printer.gleam`: `command(state, Command)` / `feed(state, line)` →
`Step(state, writes, events)`) wrapped by an effectful `controller.gleam` that
drives a `Backend` seam (`transport.web_serial()` over the browser **Web Serial
API**, or `transport.simulator()` for hardware-free dev). It hides the entire
Marlin protocol — line numbering, checksums, the `ok`/`resend` handshake, `M114`
polling, flow control — behind verbs `Energize`/`Release`/`Jog`/`MoveTo`/
`Where`/`Stream`/`Halt`/`Reconnect`, plus `CancelStream` (benign stop → Jogging,
for navigating away from a dry-run), `ResumeStream` (continue past an in-app
pause), and `Quickstop` (graceful planner flush — see below). Its mode is one of
`Disconnected | Idle | Jogging | Streaming | StreamPaused | Faulted`, where
`StreamPaused` is a stream halted at an in-app pause point (`app_pause`) awaiting
`ResumeStream`; `Halt`, `CancelStream`, and `Quickstop` stay reachable from it so
abort/flush is never gated.
_Avoid:_ "serial driver" / "the port" as the noun, and do **not** model it as
OctoPrint or a general print host — it owns the port only for the session.

### Quickstop {#term-quickstop}

The **graceful planner flush** verb on `PrinterConnection`: it emits `M410`
(quickstop — abort all queued/buffered moves NOW, clearing Marlin's planner) then
`M400` (wait for the now-empty move queue) **raw/unnumbered**, so they are
actioned immediately rather than queued behind the very moves they must cancel.
Valid from `Streaming`/`StreamPaused`/`Jogging`, it lands in `Jogging` — motors
stay energized, so alignment trust is preserved (ADR-0011). It is the missing
piece the bug exposed: `CancelStream` only stops the **host** from sending more
lines (it writes nothing), so the moves already in the firmware's planner keep
executing; `Quickstop` actually flushes them. Used on `ConfirmRegistration`
(dry-run → drill) and `RedoAlignment` (drill rehearsal → align) so a phase change
stops in-flight motion dead before the next phase prepares (ADR-0014).
_Avoid:_ conflating it with `CancelStream` (benign, no write — host stop only) or
`Halt` (M112 emergency → `Faulted`). `Quickstop` is graceful (stays connected,
motors live) but, unlike `CancelStream`, it physically empties the planner.

### MarlinEmulator {#term-marlinemulator}

The **faithful, pure Marlin protocol core** behind the `Backend` seam
(`control/marlin_emulator.gleam`), used in place of the thin `simulator` to
exercise real-hardware behaviour headlessly. Beyond protocol fidelity
(line-number + checksum validation, the resend handshake, motor state, `M0`
block, `M114`), it models enough **physical time** to make the safety-relevant
states observable: a **motion queue** that `feed` admits moves into (acking the
admission, like Marlin's planner buffer) and a separate `tick(state, dt)` that
drains it — so a test can `feed` a long move and *not* `tick` to hold the head
mid-move (the "still moving after abort" state), then `halt` to clear the queue
and assert the head stops. It also carries an injected XYZ **envelope**
(`bounds`): an out-of-range or past-min move replies a Marlin-style `error` and
is *not* admitted (the head does not advance). A `force` seam sets arbitrary
`EmulatorState` directly for edge cases. One pure core, two drivers: tests pump
`tick` by hand (deterministic CI/e2e); an `emulator_ffi.mjs` shim auto-pumps it
on a JS interval so the same core runs as a live in-app virtual machine
(ADR-0013).
It is an **operator-selectable backend**: `EmuBackend` is a third
`model.BackendKind` (with `SimBackend` / `RealBackend`), wired to
`transport.emulator()`, so the operator can drive the live UI against the
faithful virtual machine — the same backend the app-level e2e tests use.
_Avoid:_ confusing it with the **thin `simulator`** (which acks everything and
masks real bugs); the emulator is the faithful one. Bounds are **test-injected**,
never a hardcoded product default (motion limits are operator/hardware config).

### GcodeProgram {#term-gcodeprogram}

The generated Marlin G-code for **one mode** (`:dry_run | :drill`), built by
`GcodeProgram.build(%Alignment{}, opts)`. It requires an `Alignment` by type —
there is no arity that accepts raw, unaligned holes. Dry-run and real are the
*same* generator with one parameter flipped (`plunge: {:hover, 0.2} |
{:drill, -2.5}`), not two code paths.
_Avoid:_ "the gcode file" — it is an in-memory value (`lines`, `mode`,
`bbox_machine`), generated natively, not produced by pcb2gcode or a Python
post-processor.

The **streamed** form and the **export** form differ by design (ADR-0009).
`lines` is the rich, human-readable program (blank lines, `( comments )`, `M0`
stops); a future export uses it verbatim. The app never streams `lines` directly
— it streams `stream_lines(program)`, which is **sanitized**: no blank/comment
lines (real Marlin does not `ok` a blank line, so a streamed blank stalls the
handshake at 0 — the simulator masks this by acking everything). `M0` stops are
governed by `app_pause`: in the in-app workflow `M0` is omitted and the app pauses
the stream in-app at touch-off / each bit change (control stays on the screen);
export keeps `M0`. A streamed program that omits `M0` still **pauses** at each
bit-change boundary — a bit swap opportunity is mandatory. Each tool block also
moves to the board **centroid** (center of mass of the machine-space holes) for
the bit exchange after retracting Z.
_Avoid:_ streaming `lines` verbatim (stalls on blanks); "the gcode" without
distinguishing the sanitized stream from the rich export.

### Job {#term-job}

The session **state machine** that enforces the only legal order: `parsed →
registering → aligned → dry_run → drilling → done`, with `alignment_rejected`
and `faulted` as off-ramps. Each event exists only in the states where it is
legal, so illegal sequencing is unrepresentable (no "drill" in `:parsed`; no
straight edge from `:aligned` to `:drilling`).
_Avoid:_ "workflow" / "wizard" as the type name; the domain value is **Job**.

### Session {#term-session}

The **coordinator** value the Lustre model holds — the single authority for
"where the session is." It **nests** the real `Job` (the stage FSM) and
`PrinterConnection` (the wire FSM) inside its variants — it never *copies* their
state tags — so there is exactly one `job` and one `printer` in the whole app and
nothing to keep in sync. Its variants are `Loading | Aligning | Rehearsing |
Drilling | Completed | Faulted`, each carrying the actual nested machine value(s);
side routes (Settings, Log) are an orthogonal `Overlay`, not lifecycle states.
The UI screen is a **pure projection** of it (`session.screen/2`), never a stored
field, so a handler cannot assert a screen the FSMs contradict. A flow `Action`
is one pure transition `session.transition(session, action) -> Result(#(Session,
Plan), Rejected)` (mirroring the printer core's `Step`), which makes
cross-machine moves atomic and legal-by-construction — e.g. `ConfirmRegistration`
is the single `Rehearsing -> Drilling` edge returning a cancel-then-drill
`Plan`, so "start a drill while a stream is in flight" is unrepresentable
(ADR-0012).
_Avoid:_ treating it as a *third* state machine that duplicates `job`/`printer` —
it is a thin outer type that **holds** them; and do not store the screen
alongside it — the screen is **derived**.

### Plan {#term-plan}

The **ordered** `List(printer.Command)` a `Session` transition returns alongside
the next session value. The effectful `app.update` executes it **in one effect,
in order** — never `effect.batch` (which reverses synchronous order and would
corrupt an order-dependent burst). A `Plan` is what makes a cross-machine action
atomic: `ConfirmRegistration` yields `[CancelStream, Stream(drill)]` (the cancel
precedes the drill in the same effect, so the drill is never refused `Busy`);
`Abort` yields `[Halt]`. The pure `Session` core chooses the commands; the app
performs them — the same pure-core/effect-edge split as the printer FSM.
_Avoid:_ "command list" loosely — a **Plan** is specifically the *ordered*
commands a session transition emits, executed as one effect.

### Registration

The act of **picking board points and capturing their machine coordinates** —
the operator clicks 3–4 fiducials (or distinctive holes), jogs the head onto
each physical feature, and captures, producing `Correspondence`s. Registration
is the *input-gathering* step; **Alignment** is the *solved result* of fitting
those correspondences.
_Avoid:_ conflating Registration with Alignment — registration captures,
alignment solves. Also avoid "calibration".

### Dry-run

A full pass of `GcodeProgram.build(mode: :dry_run)`: **spindle off**, the bit
**hovers** `zsafe`-relative +0.2 mm over every hole instead of plunging. It is a
mandatory rehearsal — the operator confirms the digital pattern lines up with
the physical board before any real cut. The `Job` has no edge from `:aligned`
straight to `:drilling`; it must route through `:dry_run`.
_Avoid:_ "test run" / "simulation" — it physically traces the pattern on the
real board with the spindle off.

### Plunge

The downward Z move that takes the bit into the work: to `zdrill` (-2.5 mm) in
`:drill` mode, or only to the +0.2 mm hover in `:dry_run` mode. The
spindle-on-before-any-plunge rule is a safety invariant.
_Avoid:_ "drill down" / "lower" as the canonical verb; the term is **plunge**.

### Retract

The upward Z move that lifts the bit clear after a hole — to `zsafe` for travel,
or to `zchange` for a bit change. Travel between holes happens only at a safe Z;
the machine never traverses XY with the bit down.
_Avoid:_ "lift" / "raise" as the type-level term; **retract** is the verb.

### zsafe / zdrill / zchange

The three tuned Z reference heights, carried in session config, never
hardcoded:
- **zsafe** = `5` mm — the safe travel height above the surface; XY moves happen
  here.
- **zdrill** = `-2.5` mm — the plunge depth in real drilling, through the board
  into the sacrificial layer.
- **zchange** = `30` mm — the lift height for bit changes, clearing the head so
  the operator can swap bits.
_Avoid:_ inventing new names like "z_travel" / "z_cut" / "z_tool"; use these
three exactly. (Related tuned values: the `FeedProfile` feeds — base ~200 — and
spindle speed = 255.)

### FeedProfile {#term-feedprofile}

The set of three motion **feed rates** (mm/min) for one run mode:
`xy_feed` (XY travel between holes), `plunge_feed` (the downward Z into the work),
and `retract_feed` (the upward Z back to safe). `GcodeConfig` carries **two**
profiles — `dry_run_feeds` and `drill_feeds` — and `GcodeProgram.build` selects by
`cfg.mode`, so dry-run and real drilling run at independently tuned speeds (the
dry-run `xy_feed` defaults to ~2× the drill `xy_feed` — a spindle-off trace can
travel faster). Every motion line is emitted as a **feed-controlled** `G1`
(including XY travel, which was previously an uncontrolled `G0` rapid), so speed is
predictable and operator-settable. Replaces the single scalar `drill-feed`
(ADR-0015). Like all run tunables it is operator config, persisted per-operator in
`localStorage` — never a hardcoded hardware truth (ADR-0004).
_Avoid:_ a single shared feed for both modes, or leaving XY travel as an
uncontrolled `G0` rapid; the feed is per-mode and every move is `G1`-controlled.
Changing a feed changes only the move's **speed**, never its Z — the
XY-only-at-safe-Z invariant is untouched.

### M3 S255

The Marlin spindle-on command, with the PWM duty **on the same line** as the
`M3`. The spindle shares the **laser PWM hardware**, so it is driven directly by
G-code. Marlin requires `S` on the `M3` line — a bare `M3` only toggles the
enable pin and never sets the PWM (MarlinFirmware/Marlin#8379). `255` = full PWM
duty (`CUTTER_POWER_UNIT=PWM255`). This quirk is encoded once, in
`GcodeProgram`.
_Avoid:_ emitting a standalone `G00 S255` line plus a bare `M3` (what pcb2gcode
did, and why the old Python post-processor existed).

### Back-side X-mirror

Because the board is drilled from the **back copper** side, the board's X axis
is mirrored relative to the machine. In blau-drill this is **not a flag** — the
fitted `Transform2D` absorbs the mirror automatically as part of the affine, the
same way it absorbs rotation and offset.
_Avoid:_ a separate "mirror" boolean or a `drill-side=back` setting; the mirror
is a property of the fitted transform, not configuration.

### Energize-before-jog snap

The physical failure mode being designed out: when steppers are **de-energized**
(idle) and then re-engage, they snap to the nearest full step and jump 1–2 mm —
enough to ruin alignment. The fix is to make the final XY nudge with the motors
already holding. In blau-drill this is enforced structurally:
`PrinterConnection` mode `:idle` exposes **no jog command**, and the only path to
`:jogging` runs an energize-and-settle step first.
_Avoid:_ describing it as a "homing offset" or a calibration step — it is a
stepper re-engagement snap, prevented by the energize gate.

### Energize trust boundary

Position/alignment knowledge is valid **only while motors stay continuously
energized** (ADR-0011). ANY de-energize — operator `Release`, fault, serial loss,
disconnect, or a page refresh (a new runtime) — **invalidates** it: the `job` FSM
`Deenergize` event returns to `Parsed` and discards `pending`/`alignment`/
`residuals`, and the model's alignment/position fields reset in lockstep. You
cannot recover trust by querying `M114` (Marlin's own position is unreliable after
a motors-off move); only physically re-registering restores it. Consequently:
alignment/position is **never persisted** (localStorage is config-only — ADR-0004);
a **capture** requires energized (Jogging); **click-to-jump** requires ≥1 capture
(no captures ⇒ no transform ⇒ inert, never a phantom (0,0) origin); and the
interactive jump lifts Z **relatively** (`G91 Z+`), never an absolute retract that
could plunge.
_Avoid:_ treating a re-energize or refresh as "resume where we were" — there is no
trusted position across a motors-off gap; the operator re-registers.

### Residual gate

The guard on the `Job` transition `:aligned → :drilling`: it requires
`residuals.max ≤ tol`. A fit that fails the gate lands in `:alignment_rejected`,
a state that has **no drill event** — the operator must recapture. The gate is
what catches a bad fit (wrong points clicked, slipped board) *before* the bit
touches copper.
_Avoid:_ calling it a "warning" or a "soft check"; it is a hard state guard, not
advisory.

## The five-stage flow

A strictly **linear** five-stage workflow; each arrow is a gate whose
precondition must hold before advancing.

1. **Load & Connect** — open the serial link to Marlin and parse the KiCad
   outputs into a `BoardModel`. → gate: a valid parse and a live connection.
2. **Physical Alignment** — register 3–4 correspondences (energize → jog →
   capture `M114`) and `Alignment.fit/1` the affine `Transform2D`. → gate: the
   **residual gate** (`residuals.max ≤ tol`); failure routes to
   `:alignment_rejected`.
3. **Dry-run** — stream `mode: :dry_run` (spindle off, hover +0.2) and confirm
   the pattern lines up. → gate: operator confirmation that registration looks
   right (no straight edge from aligned to drilling).
4. **Active Drilling** — stream `mode: :drill` (`M3 S255`, plunge `zdrill`),
   pausing per tool for bit changes. → gate: all holes drilled.
5. **Completion** — session summary (holes drilled, elapsed time, bit changes);
   fault-recovery paths for disconnect / CNC fault.

## Invariants

These must always hold. Each is made **unrepresentable** by the data model, not
merely documented (architecture §00). They are load-bearing — preserve them.

| Invariant (must always hold) | Made unrepresentable by… |
| --- | --- |
| An `Alignment` exists only when solvable. | No public constructor. Only `Alignment.fit(corrs)` returns `{:ok, %Alignment{}}`, and only for ≥3 non-collinear points; otherwise `{:error, :degenerate}`. Fewer points are a `PendingAlignment` — a *different struct*. |
| Drilling cannot start without a valid alignment. | `GcodeProgram.build/2` takes an `%Alignment{}` as a required argument — there is no arity that accepts raw holes. The "Drill" event only exists in `Job` state `:aligned`. |
| Residuals over tolerance block the real run. | The `Job` transition `:aligned → :drilling` is guarded by `residuals.max ≤ tol`; a failing fit lands in `:alignment_rejected`, which has no drill event. |
| You never jog a de-energized axis (the 1–2 mm snap). | `PrinterConnection` mode `:idle` exposes no jog command. The only path to `:jogging` runs an energize+settle step first. |
| Real drilling is never the first thing that runs. | `Job` has no edge from `:aligned` straight to `:drilling` — it routes through `:dry_run`, whose completion is the precondition for the real-run event. |
| A hole's machine coordinate is always the transform of its board coordinate. | Holes are stored *only* in board space. Machine coordinates are computed on demand by `Transform2D.apply/2` — there is no settable machine-coordinate field to drift out of sync. |

Two of these are also the **TDD safety invariants** to assert in tests:

1. The machine never traverses XY without Z at a safe height (travel only at
   `zsafe` / above).
2. The spindle is running (`M3 S255`) before any plunge in `:drill` mode.

## Non-goals

These are deliberately out of scope (architecture §00); they shape what the
system is *not*.

- **Not multi-user / multi-machine.** One bench, one printer, one operator.
- **Not a persistent job database.** Each session is a fresh upload; run state is
  ephemeral, held in the Lustre model. Only the operator **config** persists, in
  the browser's `localStorage`. No server, no DB. (See ADR-0004.)
- **Not a CAM suite.** No trace isolation, no laser-ablation pass — drilling
  only, for now.
- **Not an OctoPrint replacement.** It owns the serial port only for the
  duration of a drilling session, not as a general print host. (See ADR-0005.)
