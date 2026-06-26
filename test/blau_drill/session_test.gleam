//// `Session` coordinator tests (ADR-0012). The Session nests the real `job`
//// and `printer` machines and owns the legal cross-machine moves:
////
////   * `screen/2` is total — every Session × Overlay maps to a `model.Screen`.
////   * `ConfirmRegistration` is the ONLY constructor of `Drilling`, and its
////     `Plan` cancels the in-flight dry-run stream FIRST, then streams the drill
////     program (`[CancelStream, Stream(drill)]`) — so the drill can never be
////     refused `Busy`.
////   * `Abort` from any active Session rolls to `Faulted` with `Plan == [Halt]`.
////   * each transition delegates the STAGE move to `job.transition`, so the job
////     FSM stays the authority on stage legality; an illegal action returns a
////     typed `Rejected` and writes NOTHING.

import blau_drill/control/printer
import blau_drill/domain/board_model.{type BoardModel}
import blau_drill/domain/correspondence.{type Correspondence, Correspondence}
import blau_drill/domain/gcode_program.{
  type RenderedLine, DrillHoleKind, LineOrigin, RenderedLine,
}
import blau_drill/domain/job.{type Job}
import blau_drill/ui/model
import blau_drill/ui/session
import gleam/list
import gleam/option.{None}
import gleeunit/should

const drl = "M48\nMETRIC\nT1C0.600\n%\nT1\nX0.0Y0.0\nM30\n"

// ── RenderedLine test helpers (ADR-0017) ─────────────────────────────────────
// The Stream/StreamJob payloads carry `RenderedLine`s now; the Session threads
// them verbatim. These wrap the bare-string programs the existing tests use.
fn rl(wire: String) -> RenderedLine {
  RenderedLine(
    wire: wire,
    origin: LineOrigin(
      op_index: 0,
      kind: DrillHoleKind,
      tool: None,
      hole_id: None,
      pause: None,
    ),
  )
}

fn prog(lines: List(String)) -> List(RenderedLine) {
  list.map(lines, rl)
}

fn board() -> BoardModel {
  let assert Ok(b) = board_model.parse_drl(drl)
  b
}

fn fresh_job() -> Job {
  job.new_with_tol(board(), 0.1)
}

// Exact identity-fit correspondence set (3 non-collinear → ~0 residual).
fn exact_corrs() -> List(Correspondence) {
  [
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: 0.0),
    Correspondence(board: #(1.0, 0.0), machine: #(1.0, 0.0), machine_z: 0.0),
    Correspondence(board: #(0.0, 1.0), machine: #(0.0, 1.0), machine_z: 0.0),
  ]
}

// ── Job builders (mirror job_test.gleam) ─────────────────────────────────────

fn aligned_job() -> Job {
  let assert Ok(j) = job.transition(fresh_job(), job.StartRegistering)
  let j =
    list.fold(exact_corrs(), j, fn(acc, corr) {
      let assert Ok(acc) = job.transition(acc, job.Capture(corr))
      acc
    })
  let assert Ok(aligned) = job.transition(j, job.Fit(0.1))
  aligned
}

fn dry_run_job() -> Job {
  let assert Ok(dry) = job.transition(aligned_job(), job.RunDryRun)
  dry
}

fn drilling_job() -> Job {
  let assert Ok(d) = job.transition(dry_run_job(), job.ConfirmRegistration)
  d
}

fn done_job() -> Job {
  let assert Ok(d) = job.transition(drilling_job(), job.Complete)
  d
}

// ── Session builders ─────────────────────────────────────────────────────────

fn loading_session() -> session.Session {
  session.Loading(board: model.NoBoard, printer: printer.Disconnected)
}

fn aligning_session() -> session.Session {
  session.Aligning(
    job: aligned_job(),
    printer: printer.Jogging(line_no: 0, pending: printer.PendingNone),
  )
}

fn rehearsing_session() -> session.Session {
  // A Rehearsing session has the dry-run stream in flight on the wire.
  let job_lines = prog(["G0 X0", "G0 X1"])
  let printer.Step(state: streaming, ..) =
    printer.command(
      printer.Jogging(line_no: 0, pending: printer.PendingNone),
      printer.Stream(job_lines),
    )
  session.Rehearsing(job: dry_run_job(), printer: streaming)
}

fn drilling_session() -> session.Session {
  session.Drilling(
    job: drilling_job(),
    printer: printer.Streaming(
      line_no: 1,
      job: printer.StreamJob(rendered: prog(["G0 X1"]), idx: 0, total: 1),
    ),
  )
}

fn completed_session() -> session.Session {
  session.Completed(
    job: done_job(),
    printer: printer.Idle(line_no: 0, pending: printer.PendingNone),
  )
}

fn faulted_session() -> session.Session {
  session.Faulted(job: model.NoJob, printer: printer.Faulted)
}

// ── screen/2 totality ────────────────────────────────────────────────────────
// Every Session variant + every Overlay maps to the expected Screen. Overlay
// OVERRIDES the lifecycle screen; with NoOverlay the lifecycle screen shows.

pub fn screen_loading_is_load_test() {
  session.screen(loading_session(), model.NoOverlay)
  |> should.equal(model.Load)
}

pub fn screen_aligning_is_align_test() {
  session.screen(aligning_session(), model.NoOverlay)
  |> should.equal(model.Align)
}

pub fn screen_rehearsing_is_dryrun_test() {
  session.screen(rehearsing_session(), model.NoOverlay)
  |> should.equal(model.DryRun)
}

pub fn screen_drilling_is_drill_test() {
  session.screen(drilling_session(), model.NoOverlay)
  |> should.equal(model.Drill)
}

pub fn screen_completed_is_done_test() {
  session.screen(completed_session(), model.NoOverlay)
  |> should.equal(model.Done)
}

// Faulted projects to the lifecycle screen the shell renders the fault banner
// OVER. ADR-0012 routes Faulted → Loading on reconnect, so Load is its base.
pub fn screen_faulted_is_load_test() {
  session.screen(faulted_session(), model.NoOverlay)
  |> should.equal(model.Load)
}

// Settings overlay overrides EVERY lifecycle state.
pub fn screen_settings_overlay_overrides_all_test() {
  let sessions = [
    loading_session(),
    aligning_session(),
    rehearsing_session(),
    drilling_session(),
    completed_session(),
    faulted_session(),
  ]
  list.each(sessions, fn(s) {
    session.screen(s, model.SettingsOpen) |> should.equal(model.Settings)
  })
}

// Log overlay overrides EVERY lifecycle state.
pub fn screen_log_overlay_overrides_all_test() {
  let sessions = [
    loading_session(),
    aligning_session(),
    rehearsing_session(),
    drilling_session(),
    completed_session(),
    faulted_session(),
  ]
  list.each(sessions, fn(s) {
    session.screen(s, model.LogOpen) |> should.equal(model.Log)
  })
}

// ── ConfirmRegistration: the ONLY constructor of Drilling ────────────────────

pub fn confirm_registration_from_rehearsing_builds_drilling_test() {
  let drill_lines = prog(["M3", "G0 X10", "M5"])
  let assert Ok(#(next, plan)) =
    session.transition(
      rehearsing_session(),
      session.ConfirmRegistration(drill_lines),
    )
  // The job advanced to Drilling and the Session variant is Drilling.
  case next {
    session.Drilling(job: j, ..) -> j.state |> should.equal(job.Drilling)
    _ -> should.fail()
  }
  // THE cross-machine invariant (ADR-0014): QUICKSTOP (flush the planner) the
  // in-flight dry-run FIRST, THEN stream the drill program — so the dry-run
  // motion is dead before the drill starts and the drill is never refused `Busy`.
  case plan {
    [printer.Quickstop, printer.Stream(lines)] ->
      lines |> should.equal(drill_lines)
    _ -> should.fail()
  }
}

// RedoAlignment (Rehearsing → Aligning) QUICKSTOPS the dry-run stream (ADR-0014):
// going back actually flushes the in-flight dry-run motion rather than letting it
// drain. Motors stay energized (Quickstop → Jogging), alignment stays valid.
pub fn redo_alignment_from_rehearsing_quickstops_test() {
  let assert Ok(#(next, plan)) =
    session.transition(rehearsing_session(), session.RedoAlignment)
  case next {
    session.Aligning(job: j, ..) -> j.state |> should.equal(job.Aligned)
    _ -> should.fail()
  }
  plan |> should.equal([printer.Quickstop])
}

// No OTHER action from any other state yields a Drilling session.
pub fn confirm_registration_from_loading_rejected_test() {
  session.transition(
    loading_session(),
    session.ConfirmRegistration(prog(["G0 X0"])),
  )
  |> is_rejected
  |> should.be_true
}

pub fn confirm_registration_from_aligning_rejected_test() {
  // Aligning is BEFORE the mandatory dry-run — confirm is illegal (no shortcut).
  session.transition(
    aligning_session(),
    session.ConfirmRegistration(prog(["G0 X0"])),
  )
  |> is_rejected
  |> should.be_true
}

pub fn confirm_registration_from_drilling_rejected_test() {
  session.transition(
    drilling_session(),
    session.ConfirmRegistration(prog(["G0 X0"])),
  )
  |> is_rejected
  |> should.be_true
}

// ── Abort: any active Session → Faulted, Plan = [Halt] ───────────────────────

pub fn abort_from_rehearsing_faults_and_halts_test() {
  assert_abort_faults(rehearsing_session())
}

pub fn abort_from_drilling_faults_and_halts_test() {
  assert_abort_faults(drilling_session())
}

pub fn abort_from_aligning_faults_and_halts_test() {
  assert_abort_faults(aligning_session())
}

fn assert_abort_faults(s: session.Session) -> Nil {
  let assert Ok(#(next, plan)) = session.transition(s, session.Abort)
  case next {
    session.Faulted(..) -> Nil
    _ -> should.fail()
  }
  plan |> should.equal([printer.Halt])
}

// ── RunDryRun: Aligned-job Aligning session → Rehearsing, Plan = [Stream(..)] ─

pub fn run_dry_run_from_aligning_rehearses_and_streams_test() {
  let dry_lines = prog(["G0 X0", "G0 Y0"])
  let assert Ok(#(next, plan)) =
    session.transition(aligning_session(), session.RunDryRun(dry_lines))
  case next {
    session.Rehearsing(job: j, ..) -> j.state |> should.equal(job.DryRun)
    _ -> should.fail()
  }
  // The dry-run program is streamed onto the wire in the same step.
  plan |> should.equal([printer.Stream(dry_lines)])
}

// ── illegal actions → Rejected, NO partial transition ────────────────────────

pub fn run_dry_run_from_loading_rejected_test() {
  session.transition(loading_session(), session.RunDryRun(prog(["G0 X0"])))
  |> is_rejected
  |> should.be_true
}

pub fn abort_from_loading_rejected_test() {
  // Loading is not an active wire state — there is nothing to halt.
  session.transition(loading_session(), session.Abort)
  |> is_rejected
  |> should.be_true
}

// ── of/2: derive the Session from (job, board, wire) — ADR-0012 ──────────────
// The app re-runs `of` after every update; it is the single source of truth for
// the lifecycle. These pin the job-state → variant map AND that the REAL wire is
// nested VERBATIM (no copy / no lossy mirror — what the deleted `bridge.printer_state`
// tests used to guard, now guaranteed structurally by nesting).

pub fn of_no_job_is_loading_test() {
  case session.of(model.NoJob, model.NoBoard, printer.Disconnected) {
    session.Loading(..) -> Nil
    _ -> should.fail()
  }
}

pub fn of_aligned_job_is_aligning_test() {
  let wire = printer.Jogging(line_no: 0, pending: printer.PendingNone)
  case session.of(model.HaveJob(aligned_job()), model.NoBoard, wire) {
    session.Aligning(..) -> Nil
    _ -> should.fail()
  }
}

pub fn of_dry_run_job_is_rehearsing_test() {
  let wire = printer.Streaming(line_no: 1, job: streamjob())
  case session.of(model.HaveJob(dry_run_job()), model.NoBoard, wire) {
    session.Rehearsing(..) -> Nil
    _ -> should.fail()
  }
}

pub fn of_drilling_job_is_drilling_test() {
  let wire = printer.Streaming(line_no: 1, job: streamjob())
  case session.of(model.HaveJob(drilling_job()), model.NoBoard, wire) {
    session.Drilling(..) -> Nil
    _ -> should.fail()
  }
}

// The wire is nested VERBATIM — `printer_state` returns exactly what was passed.
pub fn of_nests_the_real_wire_verbatim_test() {
  let wire = printer.Jogging(line_no: 7, pending: printer.PendingWhere)
  session.of(model.HaveJob(aligned_job()), model.NoBoard, wire)
  |> session.printer_state
  |> should.equal(wire)
}

// job_opt/1 recovers the nested job (the app mirrors it back onto model.job).
pub fn job_opt_recovers_the_nested_job_test() {
  let wire = printer.Idle(line_no: 0, pending: printer.PendingNone)
  case
    session.of(model.HaveJob(drilling_job()), model.NoBoard, wire)
    |> session.job_opt
  {
    model.HaveJob(j) -> j.state |> should.equal(job.Drilling)
    model.NoJob -> should.fail()
  }
}

// ── gate predicates read the REAL nested wire (the views/motion gates use these) ─

pub fn is_jogging_true_only_when_energized_test() {
  let jog = printer.Jogging(line_no: 0, pending: printer.PendingNone)
  let idle = printer.Idle(line_no: 0, pending: printer.PendingNone)
  session.is_jogging(session.of(model.NoJob, model.NoBoard, jog))
  |> should.be_true
  session.is_jogging(session.of(model.NoJob, model.NoBoard, idle))
  |> should.be_false
}

// `is_streaming` covers BOTH Streaming and StreamPaused (a paused run is still in
// flight) — the lossy 5-case mirror collapsed StreamPaused; the real gate sees it.
pub fn is_streaming_covers_paused_test() {
  let streaming = printer.Streaming(line_no: 1, job: streamjob())
  let paused = printer.StreamPaused(line_no: 1, job: streamjob())
  session.is_streaming(session.of(model.NoJob, model.NoBoard, streaming))
  |> should.be_true
  session.is_streaming(session.of(model.NoJob, model.NoBoard, paused))
  |> should.be_true
}

fn streamjob() -> printer.StreamJob {
  printer.StreamJob(rendered: prog(["G0 X1"]), idx: 0, total: 1)
}

// ── small test helper ────────────────────────────────────────────────────────

fn is_rejected(
  r: Result(#(session.Session, session.Plan), session.Rejected),
) -> Bool {
  case r {
    Error(_) -> True
    Ok(_) -> False
  }
}
