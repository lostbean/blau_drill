//// Regression guard for `app.restore_target/2` — the reload safety cap.
////
//// SAFETY PROPERTY ENCODED HERE: a page reload must NEVER resume directly into
//// a stage that depends on a live serial connection or a solved alignment
//// (DryRun / Drill / Done), nor into Align without a parsed board. Connection
//// and alignment are always discarded on reload, so the only safe non-Load
//// resume targets are `Settings` (always) and `Align` (only with a board).
//// Everything else collapses to `Load`. The bug this guards: a reload that
//// resumed straight into a connection/alignment-dependent stage with no live
//// machine state behind it.

import blau_drill/app
import blau_drill/control/controller
import blau_drill/control/printer
import blau_drill/domain/correspondence.{Correspondence}
import blau_drill/domain/job
import blau_drill/test_support.{
  aligned_jogging_model, aligned_jogging_model_from, base_model,
}
import blau_drill/ui/model.{
  type Model, Align, BBox, Board, CancelRelease, ConfNone, ConfirmReleaseMotors,
  Done, Drill, DryRun, HaveBoard, HaveJob, HaveTransform, Head, Load, Model,
  NoBitChange, NoBoard, NoHeadPos, NoTransform, Release, Settings,
}
import blau_drill/ui/projection
import blau_drill/ui/session
import gleam/float
import gleam/list
import gleam/string
import gleeunit/should

// ── Session-derived reads (ADR-0012): the screen + wire are no longer stored ──
// fields. Project them the same way `app`/the views do, so these tests assert
// the genuine derived state.

fn scr(m: Model) -> model.Screen {
  session.screen(
    session.of(m.job, m.board, controller.state(m.controller)),
    m.overlay,
  )
}

fn is_jogging(m: Model) -> Bool {
  session.is_jogging(session.of(m.job, m.board, controller.state(m.controller)))
}

fn is_idle(m: Model) -> Bool {
  case controller.state(m.controller) {
    printer.Idle(..) -> True
    _ -> False
  }
}

fn approx(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. 1.0e-9
}

// ── Settings: always safe ────────────────────────────────────────────────────

pub fn restore_settings_with_board_test() {
  app.restore_target(Ok(Settings), True) |> should.equal(Settings)
}

pub fn restore_settings_without_board_test() {
  app.restore_target(Ok(Settings), False) |> should.equal(Settings)
}

// ── Align: only with a board ──────────────────────────────────────────────────

pub fn restore_align_with_board_test() {
  app.restore_target(Ok(Align), True) |> should.equal(Align)
}

pub fn restore_align_without_board_caps_to_load_test() {
  // No board ⇒ nothing to align ⇒ collapse to Load.
  app.restore_target(Ok(Align), False) |> should.equal(Load)
}

// ── DryRun / Drill / Done: always capped to Load ──────────────────────────────
// These require a live connection + a solved alignment that a reload discards.

pub fn restore_dryrun_with_board_caps_to_load_test() {
  app.restore_target(Ok(DryRun), True) |> should.equal(Load)
}

pub fn restore_dryrun_without_board_caps_to_load_test() {
  app.restore_target(Ok(DryRun), False) |> should.equal(Load)
}

pub fn restore_drill_with_board_caps_to_load_test() {
  app.restore_target(Ok(Drill), True) |> should.equal(Load)
}

pub fn restore_drill_without_board_caps_to_load_test() {
  app.restore_target(Ok(Drill), False) |> should.equal(Load)
}

pub fn restore_done_with_board_caps_to_load_test() {
  app.restore_target(Ok(Done), True) |> should.equal(Load)
}

pub fn restore_done_without_board_caps_to_load_test() {
  app.restore_target(Ok(Done), False) |> should.equal(Load)
}

// ── Load: stays Load ──────────────────────────────────────────────────────────

pub fn restore_load_with_board_test() {
  app.restore_target(Ok(Load), True) |> should.equal(Load)
}

pub fn restore_load_without_board_test() {
  app.restore_target(Ok(Load), False) |> should.equal(Load)
}

// ── Error(Nil): no / garbage hash ─────────────────────────────────────────────

pub fn restore_error_with_board_caps_to_load_test() {
  app.restore_target(Error(Nil), True) |> should.equal(Load)
}

pub fn restore_error_without_board_caps_to_load_test() {
  app.restore_target(Error(Nil), False) |> should.equal(Load)
}

// ── target_candidate/2: marker-click → that fiducial's centre ─────────────────
// Clicking a fiducial marker selects it AND jumps the head to its centre. The
// pure half of that — picking `board.candidates[idx]` — is unit-tested here; the
// jog itself is a browser Effect verified in-app.

fn board_with(candidates: List(#(Float, Float))) -> model.BoardOpt {
  HaveBoard(Board(
    holes: [],
    tools: [],
    bbox: BBox(0.0, 0.0, 10.0, 10.0),
    outline: [],
    candidates: candidates,
  ))
}

pub fn target_candidate_picks_indexed_point_test() {
  let b = board_with([#(1.0, 2.0), #(3.0, 4.0), #(5.0, 6.0)])
  app.target_candidate(b, 0) |> should.equal(Ok(#(1.0, 2.0)))
  app.target_candidate(b, 1) |> should.equal(Ok(#(3.0, 4.0)))
  app.target_candidate(b, 2) |> should.equal(Ok(#(5.0, 6.0)))
}

pub fn target_candidate_out_of_range_is_error_test() {
  let b = board_with([#(1.0, 2.0), #(3.0, 4.0)])
  app.target_candidate(b, 2) |> should.equal(Error(Nil))
  app.target_candidate(b, 99) |> should.equal(Error(Nil))
}

pub fn target_candidate_no_board_is_error_test() {
  app.target_candidate(NoBoard, 0) |> should.equal(Error(Nil))
}

// ── ADR-0011: a fresh init / blank-slate construction has NO alignment ─────────
// THE INVARIANT: alignment/position is valid only while motors stay continuously
// energized; a refresh is a new runtime, so a freshly-built base model carries NO
// transform and NO captures. The alignment-persistence subsystem is GONE — storage
// no longer exposes any alignment-load API at all (its absence is a compile-time
// proof), so a reload is a blank slate by construction: nothing to restore.
pub fn base_model_has_no_alignment_test() {
  let m = base_model()
  // The alignment-derived values are PROJECTIONS now (ADR-0018) — a fresh,
  // unregistered job projects to no transform / no captures / ConfNone.
  projection.transform(m) |> should.equal(NoTransform)
  projection.captures(m) |> should.equal([])
  projection.captured(m) |> should.equal([])
  projection.head_confidence(m) |> should.equal(ConfNone)
}

// ── 2.5D: a live capture records the head Z as the correspondence machine_z ────
// The bit-down height the operator jogged to (model.head.z) IS the surface Z. A
// CaptureFiducial driven through the real capture path must carry that Z into the
// model's Capture (and thus the correspondence feeding the plane fit), not 0.0.
pub fn live_capture_records_head_z_test() {
  // Connect + energize (→ Jogging, motors live) then start registering.
  let #(m1, _) =
    app.update(
      base_model(),
      model.ControllerEvent(controller.Issue(printer.Connect)),
    )
  let #(m2, _) = app.update(m1, model.Energize)
  is_jogging(m2) |> should.be_true
  let #(m3, _) = app.update(m2, model.StartRegistering)
  // Jog the head down to a known bit-down height on the pad: head.z = -1.5.
  let m4 = Model(..m3, head: Head(m3.head.x, m3.head.y, -1.5))
  // Capture the current target.
  let #(m5, _) = app.update(m4, model.CaptureFiducial)
  // Exactly one capture (projected from the job's pending correspondences), and
  // its machine_z is the head Z (-1.5), not 0.0.
  case projection.captures(m5) {
    [c] -> approx(c.machine_z, -1.5) |> should.be_true
    _ -> should.fail()
  }
}

// REPRODUCTION: Connect → Energize must land the UI in Jogging (motors live), so
// jog/capture unlock. Pins the "motor enable not working" report at the app+FSM
// layer (the layer the browser MCP can't currently reach).
pub fn connect_then_energize_reaches_jogging_test() {
  let #(m1, _) =
    app.update(
      base_model(),
      model.ControllerEvent(controller.Issue(printer.Connect)),
    )
  is_idle(m1) |> should.be_true
  let #(m2, _) = app.update(m1, model.Energize)
  is_jogging(m2) |> should.be_true
}

// ── app_pause: in-app pause modal + ResumeDrilling resumes the stream ──────────
// SAFETY PROPERTY (ADR-0009): with app_pause on, the drill stream PAUSES at the
// touch-off / each bit change (a sentinel where M0 would be). The app must raise
// the bit-change modal AND, on ResumeDrilling, actually CONTINUE the stream
// (issue ResumeStream) — the app now drives the pause that M0 used to.

// A connected + Jogging + aligned drill-ready Model with app_pause ON. Drives the
// LIVE alignment path (a real solved transform), then runs the dry-run so the job
// sits in DryRun ready for ConfirmRegistration.
fn drill_ready_app_pause_model() -> Model {
  let base = base_model()
  // Flip app_pause on in the editable config; the live path snapshots it into
  // applied_config at start-registering.
  let cfg = model.Config(..base.config, app_pause: True)
  let base = Model(..base, config: cfg)
  let m0 = aligned_jogging_model_from(base)
  let #(m1, _e1) = app.update(m0, model.RunDryRun)
  m1
}

// Pump simulator `ok` acks through the app until the FSM hits its first in-app
// pause (or `fuel` runs out). ADR-0010 removed the touch-off, so the program no
// longer OPENS with a sentinel: streaming first flows through the unit/mode
// preamble and the opening of the first tool block, then pauses at the first
// bit-change sentinel. This drives the stream to that point the way the live read
// loop would.
fn pump_to_pause(m: Model, fuel: Int) -> Model {
  case fuel <= 0 {
    True -> m
    False ->
      case printer.is_stream_paused(controller.state(m.controller)) {
        True -> m
        False -> {
          let #(m2, _e) =
            app.update(m, model.ControllerEvent(controller.Inbound("ok")))
          pump_to_pause(m2, fuel - 1)
        }
      }
  }
}

// With app_pause ON (now the DEFAULT), starting a run streams a program whose
// FIRST pause is the first tool block's bit-change sentinel (ADR-0010 removed the
// touch-off — the fitted surface plane is the Z datum). Driving the handshake
// forward, the FSM pauses there and the app sets `bit_change` so the DRY-RUN aside
// surfaces the bit-change pause PANEL (a sidebar affordance, not a pop-up): the
// operator mounts the first tool's bit and resumes the rehearsal. (This is the
// exact "moves to centre then stops, no pop, no way to resume" regression — the
// pause is real; the dry-run view now renders the resume affordance off this
// field, which it previously did not.)
pub fn app_pause_pauses_at_first_bit_change_and_surfaces_panel_test() {
  let m0 = drill_ready_app_pause_model()
  scr(m0) |> should.equal(DryRun)
  let m = pump_to_pause(m0, 100)
  // The FSM is genuinely paused on the first sentinel (not streaming through).
  controller.state(m.controller) |> printer.is_stream_paused |> should.be_true
  // The bit-change modal is PROJECTED from the FSM's paused state (ADR-0018) — the
  // dry-run aside's `pause_panel` renders off `projection.bit_change`, so the
  // operator gets a Resume affordance on the dry-run screen.
  case projection.bit_change(m) {
    model.HaveBitChange(_) -> True
    model.NoBitChange -> False
  }
  |> should.be_true
}

pub fn resume_drilling_continues_the_paused_stream_test() {
  let m = pump_to_pause(drill_ready_app_pause_model(), 100)
  // Precondition: paused on the first bit-change sentinel.
  controller.state(m.controller) |> printer.is_stream_paused |> should.be_true
  // ResumeDrilling clears the modal AND resumes the stream: the FSM leaves the
  // paused state (back to Streaming — the next real line went out).
  let #(m2, _e2) = app.update(m, model.ResumeDrilling)
  // Leaving the paused state clears the projected modal (no field to reset).
  projection.bit_change(m2) |> should.equal(NoBitChange)
  controller.state(m2.controller) |> printer.is_stream_paused |> should.be_false
  controller.state(m2.controller) |> printer.is_streaming |> should.be_true
}

// DEFAULT (app_pause OFF): the streamed program keeps M0, the FSM never sees a
// sentinel, so the stream does NOT enter the paused state on start — it streams.
// (M0 halts Marlin on real hardware; the FSM streams through it.)
fn drill_ready_default_model() -> Model {
  let base = base_model()
  // app_pause stays False (mock.default_config()); be explicit for clarity.
  let cfg = model.Config(..base.config, app_pause: False)
  let base = Model(..base, config: cfg)
  let m0 = aligned_jogging_model_from(base)
  let #(m1, _e1) = app.update(m0, model.RunDryRun)
  m1
}

pub fn confirm_default_streams_without_pausing_test() {
  let m = drill_ready_default_model()
  let #(m2, _e) = app.update(m, model.ConfirmRegistration)
  // Default path: streaming (M0 in the body), NOT the in-app paused state.
  controller.state(m2.controller) |> printer.is_stream_paused |> should.be_false
  controller.state(m2.controller) |> printer.is_streaming |> should.be_true
}

// ── ADR-0011: click-to-jump needs >=1 capture (no jump on a guessed origin) ───
// SAFETY PROPERTY: with ZERO captures and NoTransform there is no board↔machine
// relationship, so the estimate Errors and a jump is a STRICT no-op — the head
// must NOT move to a phantom origin. The operator has to jog to fiducial 1 and
// capture it first. Encoded at the app layer: a `JumpTo` while energized but with
// no captures returns the model UNCHANGED (no MoveTo issued, no motion). The pure
// seam (`bridge.board_to_machine(NoTransform, [], pt) -> Error`) is asserted in
// bridge_test (board_to_machine_no_captures_errors_test).
fn registering_jogging_model() -> Model {
  let #(m1, _) =
    app.update(
      base_model(),
      model.ControllerEvent(controller.Issue(printer.Connect)),
    )
  let #(m2, _) = app.update(m1, model.Energize)
  let #(m3, _) = app.update(m2, model.StartRegistering)
  m3
}

pub fn jump_with_no_captures_is_noop_test() {
  let m = registering_jogging_model()
  // Preconditions: energized (Jogging), on the Align screen, NOTHING captured and
  // no solved transform — the only state from which a jump must no-op.
  is_jogging(m) |> should.be_true
  scr(m) |> should.equal(Align)
  projection.captures(m) |> should.equal([])
  projection.transform(m) |> should.equal(NoTransform)
  // A click-to-jump to any board point writes nothing and moves nothing: the
  // model is returned UNCHANGED (the estimate Errors → `noeff(model)`).
  let #(m2, _e) = app.update(m, model.JumpTo(#(12.0, 34.0)))
  m2.head |> should.equal(m.head)
  is_jogging(m2) |> should.be_true
  m2.current_target |> should.equal(m.current_target)
  // Nothing was streamed / the controller did not transition out of Jogging.
  controller.state(m2.controller) |> printer.is_streaming |> should.be_false
}

// ── ADR-0011: de-energize structurally resets the alignment ───────────────────
// THE INVARIANT: position/alignment is valid ONLY while motors stay continuously
// energized. ANY de-energize — operator Release, fault, serial loss, disconnect —
// invalidates it, in lockstep across the job FSM and the model.

fn job_state(m: Model) -> job.State {
  let assert HaveJob(j) = m.job
  j.state
}

// An explicit Release while aligned + energized must NOT immediately reset — it
// raises the confirm gate first (anti-surprise: a destructive de-energize is
// confirmed). The alignment is still intact at this point.
pub fn release_while_aligned_sets_confirm_does_not_reset_test() {
  let m = aligned_jogging_model()
  is_jogging(m) |> should.be_true
  job_state(m) |> should.equal(job.Aligned)
  let #(m2, _e) = app.update(m, Release)
  // The confirm gate is up; nothing has been released or reset yet.
  m2.release_confirm |> should.be_true
  is_jogging(m2) |> should.be_true
  job_state(m2) |> should.equal(job.Aligned)
  // The transform is PROJECTED from the still-Aligned job — present (ADR-0018).
  case projection.transform(m2) {
    HaveTransform(_) -> True
    NoTransform -> False
  }
  |> should.be_true
}

// The confirmed release actually de-energizes AND resets the alignment in lockstep:
// the job goes back to Parsed (so every alignment PROJECTION resets), confirm flag
// cleared.
pub fn confirm_release_resets_alignment_test() {
  let m = aligned_jogging_model()
  let #(m1, _e1) = app.update(m, Release)
  m1.release_confirm |> should.be_true
  let #(m2, _e2) = app.update(m1, ConfirmReleaseMotors)
  m2.release_confirm |> should.be_false
  projection.transform(m2) |> should.equal(NoTransform)
  projection.captures(m2) |> should.equal([])
  projection.captured(m2) |> should.equal([])
  projection.head_confidence(m2) |> should.equal(ConfNone)
  projection.head_pos(m2) |> should.equal(NoHeadPos)
  projection.quality(m2) |> should.equal(-1)
  m2.current_target |> should.equal(0)
  job_state(m2) |> should.equal(job.Parsed)
}

// CancelRelease aborts the gate: nothing released, nothing reset.
pub fn cancel_release_keeps_alignment_test() {
  let m = aligned_jogging_model()
  let #(m1, _e1) = app.update(m, Release)
  m1.release_confirm |> should.be_true
  let #(m2, _e2) = app.update(m1, CancelRelease)
  m2.release_confirm |> should.be_false
  job_state(m2) |> should.equal(job.Aligned)
  // The transform is still projected from the kept Aligned job.
  case projection.transform(m2) {
    HaveTransform(_) -> True
    NoTransform -> False
  }
  |> should.be_true
}

// With NOTHING captured (nothing to lose), Release de-energizes DIRECTLY — no
// confirm gate. Connect + energize, no registration: the job is in Parsed.
pub fn release_with_no_alignment_releases_directly_test() {
  let #(m1, _e1) =
    app.update(
      base_model(),
      model.ControllerEvent(controller.Issue(printer.Connect)),
    )
  let #(m2, _e2) = app.update(m1, model.Energize)
  is_jogging(m2) |> should.be_true
  job_state(m2) |> should.equal(job.Parsed)
  let #(m3, _e3) = app.update(m2, Release)
  // No confirm needed; the motors released directly.
  m3.release_confirm |> should.be_false
  is_idle(m3) |> should.be_true
}

// Disconnect is INVOLUNTARY (no confirm) and resets the alignment directly.
pub fn disconnect_resets_alignment_test() {
  let m = aligned_jogging_model()
  job_state(m) |> should.equal(job.Aligned)
  let #(m2, _e) = app.update(m, model.DisconnectDevice)
  projection.transform(m2) |> should.equal(NoTransform)
  projection.captures(m2) |> should.equal([])
  projection.captured(m2) |> should.equal([])
  projection.head_confidence(m2) |> should.equal(ConfNone)
  job_state(m2) |> should.equal(job.Parsed)
}

// ── backend selection (ADR-0013: the faithful emulator is operator-selectable) ─

// `backend_for` maps each operator-selectable `BackendKind` to a concrete
// transport. The faithful Marlin emulator must be reachable from the picker, so
// `EmuBackend` resolves to `transport.emulator()` (identified by its `.name`).
// localStorage is `undefined` headlessly, so we exercise the PURE mapping here
// rather than the storage round-trip (which no-ops in node).
pub fn backend_for_maps_each_kind_test() {
  app.backend_for(model.SimBackend).name |> should.equal("Simulator")
  app.backend_for(model.RealBackend).name |> should.equal("Web Serial")
  app.backend_for(model.EmuBackend).name |> should.equal("Emulator")
}

// ── ADR-0018: a degenerate fit guides via upload_error, never a stored shadow ──
//
// Regression for the behavior Chunk 3 changed: when ADR-0018 deleted the stored
// `alignment_rejected` / `fit_diag` shadow fields, a degenerate fit (3+ collinear
// board points) — which the job FSM REFUSES (`Error(FitDegenerate)`, the job
// stays `Registering`, so there is NO `AlignmentRejected` state to project a
// rejected box from) — surfaces its guidance through `upload_error` instead. This
// path had no test; pin it. Three collinear board points (0,0),(1,1),(2,2) force
// Degenerate (mirrors alignment_test.three_collinear_degenerate_test).
fn degenerate_capture_job(base: Model) -> job.Job {
  let assert HaveJob(j0) = base.job
  let assert Ok(reg) = job.transition(j0, job.StartRegistering)
  // Accumulate three COLLINEAR correspondences (board points on y = x). The
  // machine points are arbitrary; degeneracy is judged on the BOARD points.
  [
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: -1.0),
    Correspondence(board: #(1.0, 1.0), machine: #(3.0, 7.0), machine_z: -1.0),
    Correspondence(board: #(2.0, 2.0), machine: #(6.0, 14.0), machine_z: -1.0),
  ]
  |> list.fold(reg, fn(j, corr) {
    let assert Ok(j2) = job.transition(j, job.Capture(corr))
    j2
  })
}

pub fn degenerate_fit_guides_via_upload_error_test() {
  let base = base_model()
  let j = degenerate_capture_job(base)
  // Sanity: three captures are present (so the handler's >= 3 pre-check passes
  // and we reach the real Fit transition, which is what rejects as Degenerate).
  let m0 = Model(..base, job: HaveJob(j))
  projection.captures(m0) |> list.length |> should.equal(3)

  // Drive the REAL handler path.
  let #(m, _) = app.update(m0, model.Fit)

  // The degenerate-geometry guidance is surfaced (not a generic too-few message).
  m.upload_error
  |> should.equal("Capture at least 3 well-spread (non-collinear) fiducials.")

  // The job did NOT transition: it stays Registering (a degenerate fit is refused
  // by the FSM), so there is no solved/rejected alignment to project.
  job_state(m) |> should.equal(job.Registering)
  projection.alignment_rejected(m) |> should.be_false
  projection.transform(m) |> should.equal(NoTransform)
  projection.quality(m) |> should.equal(-1)
}

// ── app-level Abort (safety-critical: M112 emergency stop) ─────────────────────

fn is_faulted(m: Model) -> Bool {
  session.is_faulted(session.of(m.job, m.board, controller.state(m.controller)))
}

// Whether the comms log recorded an M112 (the emergency-stop write).
fn issued_m112(m: Model) -> Bool {
  list.any(m.comms_log, fn(e) { string.contains(e.line, "M112") })
}

// A Drilling model driven through the REAL app: aligned → RunDryRun (dry-run
// stream in flight) → ConfirmRegistration (quickstop + drill stream). The job is
// Drilling and the drill program is streaming on the wire.
fn drilling_model() -> Model {
  let m_aligned = aligned_jogging_model()
  let #(m_dry, _) = app.update(m_aligned, model.RunDryRun)
  let #(m_drill, _) = app.update(m_dry, model.ConfirmRegistration)
  m_drill
}

// SAFETY: Abort from a live drill issues M112 (the printer faults), the session
// projects `is_faulted`, and the job records the loss (Drilling → Faulted).
pub fn abort_from_drilling_faults_and_halts_test() {
  let m = drilling_model()
  job_state(m) |> should.equal(job.Drilling)
  let #(m2, _e) = app.update(m, model.Abort)
  // The emergency stop went out…
  issued_m112(m2) |> should.be_true
  // …the wire faulted…
  is_faulted(m2) |> should.be_true
  // …and the job recorded the loss.
  job_state(m2) |> should.equal(job.Faulted)
}

// THE "e-stop is never swallowed" guarantee (app.gleam): from a Loading session
// (board parsed, NOT aligned) the Session has no active wire state — yet Abort
// must STILL issue a raw Halt (M112). We connect so the wire is live but the job
// stays Parsed → the Session projects Loading, so `session.transition(_, Abort)`
// is `Error(IllegalHere)` and the handler's fallback issues the raw Halt anyway.
pub fn abort_from_loading_still_issues_halt_test() {
  let #(m, _) =
    app.update(
      base_model(),
      model.ControllerEvent(controller.Issue(printer.Connect)),
    )
  // Precondition: the Session is Loading (job still Parsed, no alignment).
  scr(m) |> should.equal(Load)
  job_state(m) |> should.equal(job.Parsed)
  // Abort is illegal from Loading at the Session level, but the app's fallback
  // issues the raw Halt — the emergency stop is NEVER swallowed.
  let #(m2, _e) = app.update(m, model.Abort)
  issued_m112(m2) |> should.be_true
}

// ── RedoAlignment preserves the alignment (back-nav must not clear it) ─────────
//
// From a Rehearsing model (a streaming dry-run), RedoAlignment cancels the
// in-flight stream (the wire goes back to Jogging, not Streaming), returns the
// screen to Align, AND preserves the solved transform + captures. This is the
// headline "back-nav must not clear alignment" flow (ADR-0014).
pub fn redo_alignment_preserves_alignment_test() {
  let m_aligned = aligned_jogging_model()
  let #(m_dry, _e1) = app.update(m_aligned, model.RunDryRun)
  // Precondition: a dry-run stream is in flight on the Rehearsing wire.
  controller.state(m_dry.controller) |> printer.is_streaming |> should.be_true
  scr(m_dry) |> should.equal(DryRun)

  let #(m2, _e2) = app.update(m_dry, model.RedoAlignment)
  // The in-flight stream is cancelled — the wire is no longer streaming (back to
  // Jogging, motors still energized).
  controller.state(m2.controller) |> printer.is_streaming |> should.be_false
  is_jogging(m2) |> should.be_true
  // The screen returned to Align.
  scr(m2) |> should.equal(Align)
  // The alignment SURVIVED: transform still present and captures non-empty.
  case projection.transform(m2) {
    HaveTransform(_) -> True
    NoTransform -> False
  }
  |> should.be_true
  { projection.captures(m2) != [] } |> should.be_true
  job_state(m2) |> should.equal(job.Aligned)
}

// ── end-to-end completion: the run reaches the Done screen ─────────────────────
//
// Drive a full run through `app.update`: aligned → RunDryRun → ConfirmRegistration
// (the genuine sim handshake builds Drilling with the drill stream in flight) →
// drive the drill stream through every bit-change pause to StreamComplete (the
// wire settles to Idle) → the explicit operator Complete step closes the run. The
// screen reaches Done and `projection.summary` reports the right totals. (Complete
// is the genuine lifecycle edge: `StreamComplete` alone does not advance to Done.)
fn pump_drill_to_idle(m: Model, fuel: Int) -> Model {
  case fuel <= 0 {
    True -> m
    False -> {
      let wire = controller.state(m.controller)
      case printer.is_streaming(wire) || printer.is_stream_paused(wire) {
        False -> m
        True -> {
          let m2 = case printer.is_stream_paused(wire) {
            True -> {
              let #(mm, _) = app.update(m, model.ResumeDrilling)
              mm
            }
            False -> {
              let #(mm, _) =
                app.update(m, model.ControllerEvent(controller.Inbound("ok")))
              mm
            }
          }
          pump_drill_to_idle(m2, fuel - 1)
        }
      }
    }
  }
}

pub fn full_run_reaches_done_screen_test() {
  let m_drilling = drilling_model()
  job_state(m_drilling) |> should.equal(job.Drilling)
  // Drive the drill stream all the way to Idle (every hole + the postamble).
  let m_streamed = pump_drill_to_idle(m_drilling, 8000)
  controller.state(m_streamed.controller)
  |> printer.is_streaming
  |> should.be_false
  // The explicit operator Complete closes the run → Done.
  let #(m_done, _e) = app.update(m_streamed, model.Complete)
  job_state(m_done) |> should.equal(job.Done)
  scr(m_done) |> should.equal(Done)
  // The completion summary projects with the right hole + bit-change counts.
  case projection.summary(m_done) {
    model.HaveSummary(model.Summary(total_holes: holes, bit_changes: bits, ..)) -> {
      holes |> should.equal(130)
      // Multi-tool board → at least one bit change.
      { bits > 0 } |> should.be_true
    }
    model.NoSummary -> should.fail()
  }
}

// ── inert double-Fit: an illegal Fit is a no-op AT THE HANDLER (Stream B) ──────
//
// From an Aligned model, firing Fit again is illegal at the job FSM (Fit is only
// legal in Registering). The handler drives `job.transition(j, Fit(tol))`, gets
// `IllegalTransition`, lands in the `Error(_)` arm → sets the guidance string and
// leaves the job UNCHANGED. This pins the "illegal Fit is inert at the handler"
// contract that Stream B's button-gating (Fit disabled unless Registering∧≥3)
// relies on — the handler is the second line of defence.
pub fn double_fit_from_aligned_is_inert_test() {
  let m = aligned_jogging_model()
  job_state(m) |> should.equal(job.Aligned)
  // Capture the transform before the inert Fit.
  let before = projection.transform(m)
  case before {
    HaveTransform(_) -> True
    NoTransform -> False
  }
  |> should.be_true

  let #(m2, _e) = app.update(m, model.Fit)
  // The job state is unchanged (still Aligned) — the illegal Fit no-ops.
  job_state(m2) |> should.equal(job.Aligned)
  // The guidance string is set (the `Error(_)` arm's count guidance).
  m2.upload_error
  |> should.equal("Capture at least 3 well-spread fiducials.")
  // The transform is preserved (the projection is unchanged).
  projection.transform(m2) |> should.equal(before)
}
