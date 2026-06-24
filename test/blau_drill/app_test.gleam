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
import blau_drill/control/transport
import blau_drill/domain/board_model.{Inputs}
import blau_drill/domain/config
import blau_drill/domain/job
import blau_drill/domain/transform2d.{Transform2D}
import blau_drill/ui/bridge
import blau_drill/ui/mock
import blau_drill/ui/model.{
  type Model, Align, BBox, Board, ConfAligned, ConfNone, ConfRough, Connection,
  Disconnected, Done, Drill, DryRun, Faulted, Front, HaveBoard, HaveBoardModel,
  HaveJob, HaveTransform, Head, Idle, Jogging, Load, Model, NoBitChange, NoBoard,
  NoDiagnostic, NoFitDiag, NoHeadPos, NoProgress, NoSummary, NoTransform,
  ResumeAlignment, Settings, Streaming,
}
import blau_drill/ui/sample
import blau_drill/ui/storage.{type AlignmentSave, AlignmentSave}
import gleam/float
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

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

// ── resume gate: a restored alignment is re-instated only once reconnected ─────
// SAFETY PROPERTY: a transform restored from the previous session must NEVER be
// silently trusted. It is re-instated to `ConfAligned` only after the operator
// has reconnected the serial port (printer != Disconnected) and confirmed the
// board hasn't moved. While Disconnected, resume is refused and confidence stays
// at the unconfirmed `ConfRough`.

pub fn can_resume_disconnected_is_false_test() {
  app.can_resume(Disconnected) |> should.be_false
}

pub fn can_resume_idle_is_true_test() {
  app.can_resume(Idle) |> should.be_true
}

pub fn can_resume_jogging_is_true_test() {
  app.can_resume(Jogging) |> should.be_true
}

pub fn can_resume_streaming_is_true_test() {
  app.can_resume(Streaming) |> should.be_true
}

pub fn can_resume_faulted_is_true_test() {
  // Faulted is still a live (if halted) port — reconnect/recover handles it.
  app.can_resume(Faulted) |> should.be_true
}

pub fn resume_confidence_disconnected_stays_unconfirmed_test() {
  app.resume_confidence(Disconnected) |> should.equal(ConfRough)
}

pub fn resume_confidence_connected_is_trusted_test() {
  app.resume_confidence(Idle) |> should.equal(ConfAligned)
  app.resume_confidence(Jogging) |> should.equal(ConfAligned)
}

// ── reload-restore → resume-pending Model (the C2 bounce) ─────────────────────
// SAFETY PROPERTY: restoring a persisted alignment on reload must reinstate it
// HELD-UNCONFIRMED — `resume_pending: True`, `head_confidence` NOT `ConfAligned`
// — and it must stay that way through a (re)connect, until the operator EXPLICITLY
// resumes. These pin the bounce: unit-level proof that `restore_alignment` builds
// the unconfirmed Model, that the connect-fold doesn't silently trust it, and
// that `ResumeAlignment` flips it ONLY once reconnected. (Build/Fit replay is the
// same machinery a live fit uses, so a real solved transform is restored.)

// A base, board-parsed Model (job in `Parsed`) for the sample board, Front side
// and DISCONNECTED — the state `init` lands in just before the restore branch.
fn base_model() -> Model {
  let cfg = mock.default_config()
  let assert Ok(bm) =
    board_model.parse(Inputs(drl: Some(sample.drl()), edge_cuts: None))
  let wm = bridge.working_board_model(bm, Front)
  Model(
    screen: Load,
    printer: Disconnected,
    board: HaveBoard(bridge.board_of(wm)),
    diagnostic: NoDiagnostic,
    file_selected: True,
    outline_file: "",
    upload_error: "",
    head: Head(0.0, 0.0, 0.0),
    head_pos: NoHeadPos,
    head_confidence: ConfNone,
    jog_step: 1.0,
    captured: [],
    current_target: 0,
    fiducial_target: 4,
    quality: -1,
    residual_max: 0.0,
    residual_rms: 0.0,
    alignment_rejected: False,
    fit_diag: NoFitDiag,
    progress: NoProgress,
    bit_change: NoBitChange,
    summary: NoSummary,
    telemetry_bit: "—",
    telemetry_eta: "—",
    telemetry_spindle: "OFF",
    zoom: 1.0,
    category: Connection,
    config: cfg,
    config_dirty: False,
    controller: controller.new(transport.simulator()),
    backend_kind: model.SimBackend,
    board_model: HaveBoardModel(wm),
    job: HaveJob(job.new(wm)),
    pending_drl: sample.drl(),
    pending_edge_cuts: "",
    captures: [],
    transform: NoTransform,
    applied_config: bridge.gcode_config(cfg, config.DryRun),
    bit_changes_seen: 0,
    board_side: Front,
    resume_pending: False,
  )
}

// Three identity board↔machine captures from the board's first candidates (a
// perfect identity fit — well within the 0.1mm gate), as a persisted slice would
// hold them. The transform field is irrelevant to the replay (the captures are
// re-fitted), so an identity transform is stored. Each capture carries a DISTINCT
// non-flat machine Z so a restore proves the Z survives into the surface plane
// fit (2.5D alignment).
fn saved_alignment() -> AlignmentSave {
  let base = base_model()
  let assert HaveBoard(b) = base.board
  let pts = list.take(b.candidates, 3)
  let zs = [-1.0, -1.2, -1.4]
  let captures =
    list.zip(pts, zs)
    |> list.map(fn(pz) {
      let #(p, z) = pz
      #(p, p, z)
    })
  AlignmentSave(
    transform: Transform2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0),
    captures: captures,
    side: Front,
    quality: 100,
    residual_max: 0.0,
    residual_rms: 0.0,
  )
}

pub fn restore_alignment_holds_unconfirmed_test() {
  let assert Ok(m) = app.restore_alignment(base_model(), saved_alignment())
  // Held UNCONFIRMED: the resume prompt is up and the head is NOT trusted.
  m.resume_pending |> should.be_true
  { m.head_confidence != ConfAligned } |> should.be_true
  // The alignment is genuinely solved (a real transform was restored), and we
  // landed on the Align screen.
  m.screen |> should.equal(Align)
  case m.transform {
    HaveTransform(_) -> True
    NoTransform -> False
  }
  |> should.be_true
}

pub fn restore_then_connect_keeps_resume_pending_test() {
  // The reported bounce: a (re)connect after restore must NOT silently trust the
  // restored alignment. Drive the REAL connect-fold (Issue(Connect) → Idle,
  // emits Accepted(Connect)) through `update` and assert resume_pending survives.
  let assert Ok(m) = app.restore_alignment(base_model(), saved_alignment())
  let #(m2, _eff) =
    app.update(m, model.ControllerEvent(controller.Issue(printer.Connect)))
  // Now connected (machine ready) but the restored alignment is STILL held.
  m2.printer |> should.equal(Idle)
  m2.resume_pending |> should.be_true
  { m2.head_confidence != ConfAligned } |> should.be_true
}

pub fn resume_while_disconnected_is_refused_test() {
  // Resume is refused while the port is gone: the prompt stays up, nothing
  // trusted. (Mirrors `can_resume(Disconnected) == False` at the Model level.)
  let assert Ok(m) = app.restore_alignment(base_model(), saved_alignment())
  let #(m2, _eff) = app.update(m, ResumeAlignment)
  m2.resume_pending |> should.be_true
  { m2.head_confidence != ConfAligned } |> should.be_true
}

pub fn resume_when_connected_trusts_alignment_test() {
  // Once reconnected, the EXPLICIT ResumeAlignment click flips the restored
  // alignment to trusted: ConfAligned + resume prompt cleared.
  let assert Ok(m0) = app.restore_alignment(base_model(), saved_alignment())
  // Reconnect first (Issue(Connect) → Idle), then resume.
  let #(m1, _e1) =
    app.update(m0, model.ControllerEvent(controller.Issue(printer.Connect)))
  let #(m2, _e2) = app.update(m1, ResumeAlignment)
  m2.resume_pending |> should.be_false
  m2.head_confidence |> should.equal(ConfAligned)
}

pub fn dry_run_refused_while_resume_pending_test() {
  // SAFETY: an UNCONFIRMED restored alignment must not be dry-run. Even connected,
  // RunDryRun is a no-op while resume_pending — the operator must resume first.
  let assert Ok(m0) = app.restore_alignment(base_model(), saved_alignment())
  let #(m1, _e1) =
    app.update(m0, model.ControllerEvent(controller.Issue(printer.Connect)))
  let #(m2, _e2) = app.update(m1, model.RunDryRun)
  // Did NOT advance to the dry-run screen; still held on Align, still pending.
  m2.screen |> should.equal(Align)
  m2.resume_pending |> should.be_true
  // After an explicit resume, the dry-run is allowed (screen advances).
  let #(m3, _e3) = app.update(m2, ResumeAlignment)
  let #(m4, _e4) = app.update(m3, model.RunDryRun)
  m4.screen |> should.equal(DryRun)
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
  m2.printer |> should.equal(Jogging)
  let #(m3, _) = app.update(m2, model.StartRegistering)
  // Jog the head down to a known bit-down height on the pad: head.z = -1.5.
  let m4 = Model(..m3, head: Head(m3.head.x, m3.head.y, -1.5))
  // Capture the current target.
  let #(m5, _) = app.update(m4, model.CaptureFiducial)
  // Exactly one capture, and its machine_z is the head Z (-1.5), not 0.0.
  case m5.captures {
    [c] -> approx(c.machine_z, -1.5) |> should.be_true
    _ -> should.fail()
  }
}

// ── 2.5D: a restore threads the persisted Z into the re-fitted captures ────────
// The saved slice carries distinct non-flat Z per capture; restore_alignment
// re-fits them. Prove the Z survives the round trip into the model captures (the
// plane-correctness itself is chunk-1-tested).
pub fn restore_threads_persisted_z_into_captures_test() {
  let assert Ok(m) = app.restore_alignment(base_model(), saved_alignment())
  // The persisted Zs (-1.0, -1.2, -1.4) come back on the restored captures, in
  // order — not all-zero (which would mean the Z was dropped on restore).
  case m.captures {
    [c0, c1, c2] -> {
      approx(c0.machine_z, -1.0) |> should.be_true
      approx(c1.machine_z, -1.2) |> should.be_true
      approx(c2.machine_z, -1.4) |> should.be_true
    }
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
  m1.printer |> should.equal(Idle)
  let #(m2, _) = app.update(m1, model.Energize)
  m2.printer |> should.equal(Jogging)
}

// ── app_pause: in-app pause modal + ResumeDrilling resumes the stream ──────────
// SAFETY PROPERTY (ADR-0009): with app_pause on, the drill stream PAUSES at the
// touch-off / each bit change (a sentinel where M0 would be). The app must raise
// the bit-change modal AND, on ResumeDrilling, actually CONTINUE the stream
// (issue ResumeStream) — the app now drives the pause that M0 used to.

// A connected + trusted-aligned drill-ready Model with app_pause ON. Reuses the
// restore-alignment machinery (a real solved transform), connects + resumes, then
// runs the dry-run so the job sits in DryRun ready for ConfirmRegistration.
fn drill_ready_app_pause_model() -> Model {
  let base = base_model()
  // Flip app_pause on in BOTH the editable config and the run snapshot.
  let cfg = model.Config(..base.config, app_pause: True)
  let base =
    Model(
      ..base,
      config: cfg,
      applied_config: bridge.gcode_config(cfg, config.DryRun),
    )
  let assert Ok(m0) = app.restore_alignment(base, saved_alignment())
  // The restore snapshot re-reads applied_config from the model's config, so it
  // already carries app_pause. Connect, resume (trust), then dry-run.
  let #(m1, _e1) =
    app.update(m0, model.ControllerEvent(controller.Issue(printer.Connect)))
  let #(m2, _e2) = app.update(m1, ResumeAlignment)
  let #(m3, _e3) = app.update(m2, model.RunDryRun)
  m3
}

// With app_pause ON (now the DEFAULT), starting a run streams a program that OPENS
// with the touch-off sentinel, so the FSM pauses IMMEDIATELY on stream start and
// the app raises the touch-off modal — the operator jogs to the surface and
// resumes. `drill_ready_app_pause_model` ends with RunDryRun, so the dry-run is
// already at that first pause: assert it there (this is the exact "stuck at 0
// with no pop" regression, now turned into an explicit on-screen pause).
pub fn app_pause_pauses_at_touch_off_and_shows_modal_test() {
  let m = drill_ready_app_pause_model()
  m.screen |> should.equal(DryRun)
  // The FSM is genuinely paused on the touch-off sentinel (not streaming through).
  controller.state(m.controller) |> printer.is_stream_paused |> should.be_true
  // The touch-off modal is up so the operator can zero the bit and resume.
  case m.bit_change {
    model.HaveBitChange(bc) ->
      case bc.kind {
        // The FIRST pause is the touch-off, not a bit change.
        model.TouchOff(_) -> True
        model.BitChangePause(_) -> False
      }
    model.NoBitChange -> False
  }
  |> should.be_true
}

pub fn resume_drilling_continues_the_paused_stream_test() {
  let m = drill_ready_app_pause_model()
  // Precondition: paused on the touch-off sentinel (from RunDryRun).
  controller.state(m.controller) |> printer.is_stream_paused |> should.be_true
  // ResumeDrilling clears the modal AND resumes the stream: the FSM leaves the
  // paused state (back to Streaming — the next real line went out).
  let #(m2, _e2) = app.update(m, model.ResumeDrilling)
  m2.bit_change |> should.equal(NoBitChange)
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
  let base =
    Model(
      ..base,
      config: cfg,
      applied_config: bridge.gcode_config(cfg, config.DryRun),
    )
  let assert Ok(m0) = app.restore_alignment(base, saved_alignment())
  let #(m1, _e1) =
    app.update(m0, model.ControllerEvent(controller.Issue(printer.Connect)))
  let #(m2, _e2) = app.update(m1, ResumeAlignment)
  let #(m3, _e3) = app.update(m2, model.RunDryRun)
  m3
}

pub fn confirm_default_streams_without_pausing_test() {
  let m = drill_ready_default_model()
  let #(m2, _e) = app.update(m, model.ConfirmRegistration)
  // Default path: streaming (M0 in the body), NOT the in-app paused state.
  controller.state(m2.controller) |> printer.is_stream_paused |> should.be_false
  controller.state(m2.controller) |> printer.is_streaming |> should.be_true
}
