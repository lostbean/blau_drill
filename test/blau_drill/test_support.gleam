//// Shared test fixtures + helpers (Stream A, Task 1).
////
//// `base_model()` and `aligned_jogging_model_from(_)` were copy-pasted verbatim
//// into `app_test.gleam`, `session_e2e_test.gleam` AND `progress_flow_test.gleam`
//// (each file admitted "replicated … its helpers are private"). They are
//// behavior-identical, so they live here ONCE and the three test files import
//// them. The small projection-reading helpers the flow tests share
//// (`drilled_of` / `done_holes` / `pump_through_pause`) live here too.

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

// A base, board-parsed Model (job in `Parsed`) for the sample board, Front side
// and DISCONNECTED — the state `init` lands in just after parsing a board.
pub fn base_model() -> Model {
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

// Drive the LIVE alignment path from `base` to a genuine solved transform:
// connect, energize (→ Jogging), start registering, then capture the first three
// board candidates with the head parked AT each candidate's coords (machine ==
// board → an identity fit, well within the 0.1mm gate) carrying a DISTINCT machine
// Z, and fit. Returns a connected + Jogging + Aligned Model with a real
// transform/captures. The run snapshot (`applied_config`) is taken from `base`'s
// config at start-registering, so flip any config flag (e.g. app_pause) on `base`
// FIRST.
pub fn aligned_jogging_model_from(base: Model) -> Model {
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
      // Select the candidate, park the head at it (identity machine == board),
      // then capture through the real path.
      let #(ms, _) = app.update(m, model.SetCurrentTarget(i))
      let ms = Model(..ms, head: Head(cx, cy, z))
      let #(mc, _) = app.update(ms, model.CaptureFiducial)
      mc
    })
  let #(m5, _) = app.update(m4, model.Fit)
  m5
}

/// `aligned_jogging_model_from(base_model())`.
pub fn aligned_jogging_model() -> Model {
  aligned_jogging_model_from(base_model())
}

/// The projected drilled-hole count (0 outside a run).
pub fn drilled_of(m: Model) -> Int {
  case projection.progress(m) {
    HaveProgress(p) -> p.drilled
    NoProgress -> 0
  }
}

/// The number of holes the PROJECTED board marks `HoleDone` (ADR-0018 — the
/// per-hole status is a projection now, so read the projected board, not the
/// stored, unmarked `m.board`).
pub fn done_holes(m: Model) -> Int {
  case projection.board(m) {
    HaveBoard(b) -> list.count(b.holes, fn(h) { h.status == HoleDone })
    model.NoBoard -> 0
  }
}

/// Pump simulator `ok` acks through the app, DRIVING THROUGH the app-pause: on
/// each step, if the FSM has parked in `StreamPaused`, issue `ResumeDrilling`
/// (which issues `ResumeStream`) to send the next real line and re-arm the
/// handshake; otherwise feed one `ok`. Stops when at least `until` holes are
/// drilled (or `fuel` runs out). Without driving through the pause, the holes —
/// which come AFTER the first bit-change sentinel — are never reached.
pub fn pump_through_pause(m: Model, until: Int, fuel: Int) -> Model {
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
