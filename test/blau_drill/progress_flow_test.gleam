//// The frozen-progress bug repro (ADR-0017), driven end-to-end through
//// `app.update`. The HEADLINE red→green test of Chunk 2.
////
//// THE BUG: dry-run drilled-count froze at 0/N because `app.count_holes` greps
//// the confirmed-line prefix for `"G0 X"`, but ADR-0015 changed the inter-hole
//// travel from a `G0 X..` rapid to a controlled `G1 X.. Y.. F<xy_feed>` move —
//// so the grep counts nothing, `progress.drilled` never advances, and the board
//// never marks a hole, even though the wire streams fine. The fix (ADR-0017)
//// threads the typed `LineOrigin` through the FSM and counts confirmed lines
//// whose `origin.kind == DrillHoleKind` — never the line's text.
////
//// THE GOTCHA (verified): with `app_pause` ON (the default), the dry-run stream
//// PAUSES at the first bit-change sentinel after the preamble + first tool block
//// (~11 lines). The DRILL holes come AFTER that pause, so a naive "feed N oks"
//// STALLS at the pause. This test drives THROUGH the pause via `ResumeDrilling`
//// (which issues `ResumeStream`), exactly as the operator does, to reach the
//// `DrillHole` lines whose confirmation must advance `drilled`.

import blau_drill/app
import blau_drill/control/controller
import blau_drill/control/printer
import blau_drill/control/transport
import blau_drill/domain/board_model.{Inputs}
import blau_drill/domain/config
import blau_drill/domain/job
import blau_drill/ui/bridge
import blau_drill/ui/mock
import blau_drill/ui/model.{
  type Model, Connection, Front, HaveBoard, HaveBoardModel, HaveJob,
  HaveProgress, Head, HoleDone, Model, NoDiagnostic, NoOverlay, NoProgress,
}
import blau_drill/ui/projection
import blau_drill/ui/sample
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// ── fixtures (replicated from session_e2e_test.gleam — helpers are private) ────

fn base_model() -> Model {
  let cfg = mock.default_config()
  let assert Ok(bm) =
    board_model.parse(Inputs(drl: Some(sample.drl()), edge_cuts: None))
  let wm = bridge.working_board_model(bm, Front)
  Model(
    overlay: NoOverlay,
    board: HaveBoard(bridge.board_of(wm)),
    diagnostic: NoDiagnostic,
    file_selected: True,
    outline_file: "",
    upload_error: "",
    head: Head(0.0, 0.0, 0.0),
    jog_step: 1.0,
    current_target: 0,
    fiducial_target: 4,
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
    applied_config: bridge.gcode_config(cfg, config.DryRun),
    board_side: Front,
    release_confirm: False,
    comms_log: [],
  )
}

// Drive the LIVE alignment path to a genuine solved transform (identity fit):
// connect, energize, start registering, capture the first three candidates AT
// their coords with distinct Z, and fit. Returns a connected + Jogging + Aligned
// Model with a real transform.
fn aligned_jogging_model_from(base: Model) -> Model {
  let #(m1, _) =
    app.update(base, model.ControllerEvent(controller.Issue(printer.Connect)))
  let #(m2, _) = app.update(m1, model.Energize)
  let #(m3, _) = app.update(m2, model.StartRegistering)
  let assert HaveBoard(b) = m3.board
  let pts = list.take(b.candidates, 3)
  let zs = [-1.0, -1.2, -1.4]
  let m4 =
    list.zip(pts, zs)
    |> list.index_fold(m3, fn(m, pz, i) {
      let #(#(cx, cy), z) = pz
      let #(ms, _) = app.update(m, model.SetCurrentTarget(i))
      let ms = Model(..ms, head: Head(cx, cy, z))
      let #(mc, _) = app.update(ms, model.CaptureFiducial)
      mc
    })
  let #(m5, _) = app.update(m4, model.Fit)
  m5
}

// Pump simulator `ok` acks through the app, DRIVING THROUGH the app-pause: on
// each step, if the FSM has parked in `StreamPaused`, issue `ResumeDrilling`
// (which issues `ResumeStream`) to send the next real line and re-arm the
// handshake; otherwise feed one `ok`. Stops when at least `until` holes are
// drilled (or `fuel` runs out). Without driving through the pause, the holes —
// which come AFTER the first bit-change sentinel — are never reached.
fn pump_through_pause(m: Model, until: Int, fuel: Int) -> Model {
  case fuel <= 0 {
    True -> m
    False ->
      case drilled_of(m) >= until {
        True -> m
        False -> {
          let wire = controller.state(m.controller)
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
          pump_through_pause(m2, until, fuel - 1)
        }
      }
  }
}

fn drilled_of(m: Model) -> Int {
  case projection.progress(m) {
    HaveProgress(p) -> p.drilled
    NoProgress -> 0
  }
}

fn done_holes(m: Model) -> Int {
  // The per-hole board STATUS is a projection now (ADR-0018) — read the projected
  // board, not the stored (unmarked) `m.board`.
  case projection.board(m) {
    HaveBoard(b) -> list.count(b.holes, fn(h) { h.status == HoleDone })
    model.NoBoard -> 0
  }
}

// ── THE RED→GREEN TEST ────────────────────────────────────────────────────────
//
// RED (before ADR-0017): `app.count_holes` greps `"G0 X"`, but the inter-hole
// travel is `G1 X.. Y.. F..` (ADR-0015), so the confirmed-prefix hole count is 0
// however far the stream runs — `progress.drilled` stays 0 and no `HoleDone` is
// marked. The assertion `drilled > 0` FAILS.
//
// GREEN (after ADR-0017): the FSM threads each line's `LineOrigin` through the
// `Progress` event; `apply_progress` counts confirmed `DrillHoleKind` lines and
// marks holes by `hole_id`. As `DrillHole` lines confirm, `drilled` advances past
// 0 and the matching `HoleDone` holes light up.
pub fn dry_run_progress_advances_past_zero_test() {
  let m_aligned = aligned_jogging_model_from(base_model())

  // RunDryRun: the job is DryRun and the dry-run program is STREAMING.
  let #(m_dryrun, _e1) = app.update(m_aligned, model.RunDryRun)
  controller.state(m_dryrun.controller)
  |> printer.is_streaming
  |> should.be_true

  // Drive the handshake THROUGH the first bit-change pause until at least one
  // hole confirms. (Generous fuel: the preamble + first tool block + pause come
  // before any hole.)
  let m = pump_through_pause(m_dryrun, 1, 400)

  // THE ASSERTION: progress advanced past 0 (RED today — the `"G0 X"` grep counts
  // nothing because travel is `G1 X..`) and the board marks the drilled holes.
  { drilled_of(m) > 0 } |> should.be_true
  { done_holes(m) > 0 } |> should.be_true
  // The two stay in lockstep: every drilled hole is marked Done.
  done_holes(m) |> should.equal(drilled_of(m))
}
