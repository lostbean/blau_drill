# Chunk 4 work order — Make `Session` the model spine (the integration refactor)

You are a coding sub-agent doing the FINAL, largest chunk of the session-coordination
build in `blau_drill` (Gleam → JavaScript via Lustre). Work from THIS order alone.
This is a tightly-coupled refactor of `app.gleam` (~1794 lines) + 2 views + the bridge.
Go carefully and lean on the gate after each compile.

## The gate (source of truth)

`cd /code/edgar/blau_drill && nix develop -c bash -c 'gleam build && node scripts/test_gate.mjs'; cat /tmp/blau_gate_report.txt`
- Runs ALL tests, awaits async, writes `/tmp/blau_gate_report.txt` ending `TOTAL: N passed, M failed`, exits non-zero on any failure. (`gleam test` is also reliable now.)
- **Current baseline: 403 passed, 1 failed.** The 1 failure is `session_e2e_test.confirm_registration_starts_the_drill_stream_test` — the INTENTIONAL expected-red bug repro.
- **YOUR SUCCESS CRITERION: after this chunk, that failure FLIPS GREEN → `404 passed, 0 failed`** (or N≥404 / 0 failed if you add tests). Zero failures is the whole point — this chunk makes the dry-run→drill coordination correct. If ANY other test breaks, fix it (the model-shape change will ripple into existing app/view tests — update them to the new shape, preserving their INTENT).
- `gleam format --check src test` must end clean. NO commit / no trailers.

## What exists (built by prior chunks — DO NOT re-create)

`src/blau_drill/ui/session.gleam` — the pure `Session` coordinator (ADR-0012). Public surface:
```gleam
pub type Session {
  Loading(board: model.BoardOpt, printer: printer.PrinterState)
  Aligning(job: job.Job, printer: printer.PrinterState)
  Rehearsing(job: job.Job, printer: printer.PrinterState)
  Drilling(job: job.Job, printer: printer.PrinterState)
  Completed(job: job.Job, printer: printer.PrinterState)
  Faulted(job: model.JobOpt, printer: printer.PrinterState)
}
pub type Overlay { NoOverlay  SettingsOpen  LogOpen }
pub type Plan = List(printer.Command)
pub type Action {
  ConnectAction  StartRegistering  Capture(Correspondence) Fit(Float) RestartAlignment
  RunDryRun(List(String)) RedoAlignment  ConfirmRegistration(List(String))
  MarkComplete  Abort  SerialLost(String) Reconnect  Deenergize  OpenOverlay(Overlay)
}
pub type Rejected { IllegalHere(Action)  JobRefused(job.TransitionError)  WireBusy }
pub fn screen(s: Session, o: Overlay) -> model.Screen      // TOTAL projection
pub fn transition(s: Session, a: Action) -> Result(#(Session, Plan), Rejected)   // pure
```
Read it before starting. Note: `transition` ALSO updates the nested `printer.PrinterState` to match the Plan (via an internal `run_wire`), so the Session's nested wire state stays consistent.

## The design (ADR-0012 — the authority; read it)

`Session` becomes the model's single source of truth for stage + wire + screen:
- **Delete the duplicated/derived state:** `model.screen` (a stored projection), `model.PrinterState` (a lossy mirror of `printer.PrinterState`), and `bridge.printer_state` (the mirror fn). The model holds a `session: Session` (and a small `overlay: Overlay` for Settings/Log) instead.
- **Screen is derived:** views call `session.screen(model.session, model.overlay)` instead of reading `model.screen`.
- **Motion gates read the REAL wire state** off the Session's nested `printer.PrinterState` (NOT the deleted UI mirror). Add helpers as needed (e.g. a `session.printer_state(s) -> printer.PrinterState` accessor if not present, and use `printer.is_streaming`/`is_stream_paused` or pattern-match the real state for `Jogging`/`Idle`/`Disconnected`/`Faulted` gates).
- **Flow Msgs route through `session.transition`:** the handler for a flow action builds the `session.Action`, calls `session.transition`, stores the next Session, and EXECUTES the returned `Plan` (the ordered `List(printer.Command)`) by folding each command through the existing `controller` — in ONE effect, in order (NEVER `effect.batch` for the ordered plan; the existing `issue`/`apply_controller` runs commands through the controller — run the plan's commands sequentially in a single effect).

## Migration map (the concrete surface — verified)

### A. `src/blau_drill/ui/model.gleam`
- DELETE `pub type PrinterState { Disconnected Idle Jogging Streaming Faulted }` (the lossy mirror).
- DELETE the `screen: Screen` field from `Model`. ADD `session: session.Session` and `overlay: session.Overlay` (import `ui/session`). Keep `Screen` the TYPE (still the projection's return + still used by views) — only the stored FIELD goes.
- The `printer: PrinterState` field on Model → DELETE (it was the mirror). Motion gates now read `model.session`'s nested printer.
- Existing model construction in tests (`base_model` in app_test, etc.) will need the new fields — that's expected; update them.

### B. `src/blau_drill/ui/bridge.gleam`
- DELETE `pub fn printer_state(...)` (lines ~219) and its doc bullet (~line 10). Two call sites in app.gleam (lines ~396, ~662) go away (the Session nests the real state instead).

### C. `src/blau_drill/app.gleam` (~1794 lines, the bulk)
- `init`: build the initial `session: session.Loading(NoBoard, printer.Disconnected)` (or appropriate) + `overlay: NoOverlay`.
- `apply_controller` (~386): today it sets `model.printer = bridge.printer_state(...)`. NOW: the controller is still the effectful wire driver, but the Session owns the wire state. Decide the cleanest seam: the Session's nested printer must track the controller's printer state. Simplest correct approach: after the controller processes a command/inbound line, sync the Session's nested `printer.PrinterState` from `controller.state(out.controller)` (the REAL state). I.e. keep ONE printer.PrinterState — the controller's — and have the Session hold/reflect it. You may add a `session.with_printer(s, printer.PrinterState) -> Session` helper to update the nested wire state of the current variant after the controller advances. (This keeps "one printer" — the controller's — and the Session mirrors it, NOT a second copy that drifts.) Document the seam you chose.
- The 16 `screen:`/`printer:` direct writes (e.g. lines 99, 263, 675, 1038, 1064, 1094, 1139, 1187, 1212): these handlers currently set screen + advance job + maybe issue a command. REPLACE each with the session.transition flow where it's a real flow action:
  - `RunDryRun` handler (~1023): build dry-run g-code lines, `session.transition(model.session, session.RunDryRun(lines))`, store session, execute Plan.
  - `ConfirmRegistration` handler (~1066, `confirm_registration`): THE BUG FIX. `session.transition(model.session, session.ConfirmRegistration(drill_lines))` → returns `Drilling` + `Plan[CancelStream, Stream(drill)]`; execute the plan IN ORDER in one effect. This is what flips the expected-red green.
  - `Abort` (~`abort`): `session.transition(.., session.Abort)` → `Plan[Halt]`.
  - `GoToSettings`/`GoToLog`/nav: set `model.overlay` (SettingsOpen/LogOpen/NoOverlay) instead of `screen:`.
  - Alignment actions (StartRegistering/CaptureFiducial/Fit/RestartAlignment/RedoAlignment/Deenergize/Reconnect/MarkComplete via Complete): route through the matching `session.Action`.
- Motion gates `model.printer == Jogging` (lines ~371, 695, 717, 760, 785, 1295, 1756): replace with a read of the Session's nested real printer state (e.g. a helper `is_jogging(model.session)` matching `printer.Jogging(..)`). `model.printer == Disconnected`/`== Faulted` similarly.
- NOTE: some Msgs (jog, capture, settings edits, zoom, file load) are NOT lifecycle transitions — they stay as direct model updates / controller issues. Only the STAGE-FLOW actions route through session.transition. Don't force every Msg through the Session.

### D. Views — `src/blau_drill/ui/shell.gleam` and `src/blau_drill/ui/stages.gleam`
- Replace `model.screen` reads with `session.screen(model.session, model.overlay)` (compute once, pass down).
- Replace `model.printer` reads (`!= Disconnected`, `== Jogging`, `conn_display(model.printer)`, `printer_label`, etc.) with reads off the Session's nested real `printer.PrinterState`. You may need to map the real `printer.PrinterState` to whatever display the view wants (the view previously consumed the 5-case UI mirror; now consume the 6-case real one — `StreamPaused` is now visible, which is an improvement, handle it).

## Safety invariants to PRESERVE (do not regress — ADR-0006/0011)
- Energize-before-jog: motion still gated behind Jogging (the printer core already refuses; keep the UI gate reading the real state).
- No Aligned→Drilling shortcut: the job FSM + Session enforce it; don't add a bypass.
- De-energize discards alignment: the `Deenergize` action routes through the job's reset.
- M112 abort reachable from every motion state: `Abort` → `Plan[Halt]` from any active Session.
- Relative-Z interactive jumps: the jog/jump handlers are unchanged (not lifecycle flow) — leave their G91 logic intact.

## Acceptance criteria
- `model.screen`, `model.PrinterState`, `bridge.printer_state` are GONE. Model holds `session` + `overlay`.
- Views render off `session.screen(...)` and read the real nested printer state.
- Flow Msgs route through `session.transition`; the returned Plan executes in ONE ordered effect.
- **GATE: `node scripts/test_gate.mjs` → `404 passed, 0 failed`** (the `session_e2e confirm` expected-red is now GREEN; no other failures; existing tests updated to the new model shape preserving intent).
- `gleam format --check src test` clean.
- Safety invariants above preserved.

## Escalation rule
Escalate (STOP, report) if: the controller↔Session wire-state sync seam can't be made clean without a design change (e.g. you'd need two printer states that can drift — that defeats the purpose, escalate); OR a view needs lifecycle info the Session doesn't carry; OR making the expected-red green requires changing the session_e2e test's ASSERTION (it shouldn't — the test asserts the drill stream's line count; the fix makes that true). Mechanical migration you drive yourself.

## When done
Report: (1) the controller↔Session wire-sync seam you chose, (2) the list of flow Msgs you routed through session.transition vs left as direct updates, (3) how many existing tests you had to update for the new model shape + that they preserve intent, (4) the FINAL gate numbers (must be 0 failed), (5) confirmation the 5 safety invariants are preserved, (6) any escalation. Leave the tree formatted.
