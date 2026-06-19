//// Phase-4 entry point: the real blau-drill operator app. This is the
//// integration thread that stitches the three already-built layers together:
////
////   * `domain/*` — the pure board parse, alignment fit, g-code generator, and
////     the session FSM (`job`).
////   * `control/*` — the serial control state machine (`controller` shell +
////     `printer` pure core) over a `transport` backend (simulator or Web Serial).
////   * `ui/*` — the Lustre views, which render a flat `model.Model` and emit a
////     fixed `Msg` vocabulary. The views are UNCHANGED; this module populates the
////     model from real data instead of mocks.
////
//// ## How the controller is bridged into the UI update loop
////
//// The app is a `lustre.application`: `init`/`update` return
//// `#(Model, Effect(Msg))`. A `ControllerEvent(ControllerMsg)` Msg variant wraps
//// every controller message (open/inbound/write-done/loss). The motion verbs
//// (Energize/Jog/...) call `issue/2`, which runs `controller.update(Issue(cmd))`,
//// stores the next controller, maps its `printer.PrinterState` into the UI
//// `PrinterState` (for the gates/badges), folds the emitted `printer.Event`s into
//// the model (Progress → ring + per-hole status, PositionUpdate → live head,
//// StreamComplete → advance, Faulting → fault, Recovered → recover), and maps the
//// controller's `Effect(ControllerMsg)` into `Effect(Msg)` via `effect.map`.
////
//// Safety gates are REAL: motion is gated on the live `printer.PrinterState`
//// (only `Jogging` allows jog/move/spindle — the pure core refuses otherwise and
//// writes nothing), drilling is reachable only via dry-run → confirm (the `job`
//// FSM has no Aligned→Drilling edge), and M112 abort is reachable from every
//// motion stage.

import blau_drill/control/backend
import blau_drill/control/controller
import blau_drill/control/printer
import blau_drill/control/transport
import blau_drill/domain/alignment
import blau_drill/domain/board_model.{Inputs}
import blau_drill/domain/config
import blau_drill/domain/correspondence.{Correspondence}
import blau_drill/domain/gcode_program
import blau_drill/domain/job
import blau_drill/domain/transform2d
import blau_drill/ui/bridge
import blau_drill/ui/mock
import blau_drill/ui/model.{
  type BackendKind, type Head, type Model, type Msg, Align, ApplyConfig,
  BitChange, Capture, Captured, Complete, ConfAligned, ConfEstimate, ConfNone,
  ConfRough, ConfirmRegistration, ConnectDevice, Connection, ControllerEvent,
  DisconnectDevice, Disconnected, Done, Drill, DrillMode, DrlPicked, DryRun,
  DryRunMode, Energize, Faulted, Fiducial, Fit, GoToSession, GoToSettings,
  HaveBitChange, HaveBoard, HaveBoardModel, HaveDiagnostic, HaveHeadPos, HaveJob,
  HaveProgress, HaveSummary, HaveTransform, Head, HoleDone, Jog, Jogging, JumpTo,
  Load, LoadSample, Model, NavStage, NewBoard, NoBitChange, NoBoard,
  NoBoardModel, NoDiagnostic, NoHeadPos, NoJob, NoProgress, NoSummary,
  NoTransform, OutlinePicked, ParseBoard, Progress, RealBackend, Recapture,
  Reconnect, RedoAlignment, Release, ResetDefaults, ResetView, RestartAlignment,
  ResumeDrilling, RunDryRun, SelectBackend, SelectCategory, SelectFile,
  SelectOutline, SetConfigField, SetCurrentTarget, SetJogStep, Settings,
  SimBackend, StageAlign, StageDone, StageDrill, StageDryRun, StageLoad,
  StartRegistering, Summary, TestSpindle, ToggleAutoConnect,
}
import blau_drill/ui/sample
import blau_drill/ui/shell
import blau_drill/ui/stages
import blau_drill/ui/storage
import gleam/dict
import gleam/float
import gleam/int
import gleam/javascript/promise
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre
import lustre/attribute as a
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/event

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

// ── init ─────────────────────────────────────────────────────────────────────

fn init(_flags) -> #(Model, Effect(Msg)) {
  // Restore the persisted operator config + selected backend; default to the
  // simulator so the app works with no hardware.
  let seed = mock.default_config()
  let cfg = storage.load_config(seed)
  let backend_kind = storage.load_backend()
  let backend = backend_for(backend_kind)
  let m =
    Model(
      screen: Load,
      printer: Disconnected,
      board: NoBoard,
      diagnostic: NoDiagnostic,
      file_selected: False,
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
      progress: NoProgress,
      bit_change: NoBitChange,
      summary: NoSummary,
      telemetry_bit: "—",
      telemetry_eta: "—",
      telemetry_spindle: "OFF · 0 RPM",
      zoom: 1.0,
      category: Connection,
      config: cfg,
      config_dirty: False,
      controller: controller.new(backend),
      backend_kind: backend_kind,
      board_model: NoBoardModel,
      job: NoJob,
      pending_drl: "",
      pending_edge_cuts: "",
      captures: [],
      transform: NoTransform,
      applied_config: bridge.gcode_config(cfg, config.DryRun),
      bit_changes_seen: 0,
    )
  #(m, effect.none())
}

fn backend_for(kind: BackendKind) -> backend.Backend {
  case kind {
    SimBackend -> transport.simulator()
    RealBackend -> transport.web_serial()
  }
}

// ── update ───────────────────────────────────────────────────────────────────

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // navigation
    GoToSettings -> noeff(Model(..model, screen: Settings))
    GoToSession -> noeff(Model(..model, screen: resting_screen(model)))
    NavStage(stage) -> noeff(Model(..model, screen: stage_screen(stage)))

    // Stage 1 — load & connect
    SelectFile -> #(model, pick_drl_effect())
    SelectOutline -> #(model, pick_outline_effect())
    LoadSample -> load_sample(model)
    DrlPicked(res) -> drl_picked(model, res)
    OutlinePicked(res) -> outline_picked(model, res)
    ParseBoard -> parse_board(model)
    SelectBackend(kind) -> select_backend(model, kind)
    ConnectDevice -> connect_device(model)
    DisconnectDevice -> disconnect_device(model)
    StartRegistering -> start_registering(model)

    // Stage 2 — alignment
    Energize -> issue(model, printer.Energize)
    Release -> issue(model, printer.Release)
    SetJogStep(step) -> noeff(Model(..model, jog_step: step))
    Jog(axis, sign) -> jog(model, axis, sign)
    TestSpindle -> test_spindle(model)
    SetCurrentTarget(idx) -> noeff(Model(..model, current_target: idx))
    JumpTo(point) -> jump_to(model, point)
    model.CaptureFiducial -> capture(model)
    Fit -> fit(model)
    Recapture -> recapture(model)
    RestartAlignment -> restart_alignment(model)
    RunDryRun -> run_dry_run(model)

    // Stage 3 — dry-run
    RedoAlignment -> redo_alignment(model)
    ConfirmRegistration -> confirm_registration(model)

    // Stage 4 — drilling
    ResumeDrilling -> resume_drilling(model)
    Complete -> complete(model)

    // Stage 5 / fault
    NewBoard -> new_board(model)
    Reconnect -> reconnect(model)

    // global
    model.Abort -> abort(model)

    // canvas zoom
    model.ZoomIn -> noeff(Model(..model, zoom: clamp_zoom(model.zoom *. 1.3)))
    model.ZoomOut -> noeff(Model(..model, zoom: clamp_zoom(model.zoom /. 1.3)))
    ResetView -> noeff(Model(..model, zoom: 1.0))

    // settings
    SelectCategory(cat) -> noeff(Model(..model, category: cat))
    SetConfigField(field, value) -> noeff(set_config_field(model, field, value))
    ToggleAutoConnect ->
      noeff(
        Model(
          ..model,
          config: model.Config(
            ..model.config,
            auto_connect: !model.config.auto_connect,
          ),
          config_dirty: True,
        ),
      )
    ResetDefaults ->
      noeff(Model(..model, config: mock.default_config(), config_dirty: True))
    ApplyConfig -> apply_config(model)

    // controller bridge
    ControllerEvent(cmsg) -> apply_controller(model, cmsg)
  }
}

fn noeff(model: Model) -> #(Model, Effect(Msg)) {
  #(model, effect.none())
}

// ── controller bridge ────────────────────────────────────────────────────────

/// Issue an operator command through the controller, then react to the result.
fn issue(model: Model, cmd: printer.Command) -> #(Model, Effect(Msg)) {
  apply_controller(model, controller.Issue(cmd))
}

/// Route a `ControllerMsg` through `controller.update`, store the next
/// controller, map its printer state into the UI gates, fold its events into the
/// model, and lift its effect into the UI Msg space.
fn apply_controller(
  model: Model,
  cmsg: controller.ControllerMsg,
) -> #(Model, Effect(Msg)) {
  let out = controller.update(model.controller, cmsg)
  let m1 =
    Model(
      ..model,
      controller: out.controller,
      printer: bridge.printer_state(controller.state(out.controller)),
    )
  let #(m2, ev_effects) = fold_events(m1, out.events)
  let ctrl_effect = effect.map(out.effect, ControllerEvent)
  #(m2, effect.batch([ctrl_effect, ev_effects]))
}

/// Fold the pure `printer.Event`s a transition produced into the model. Returns
/// the updated model plus any follow-up effect (e.g. advancing the job on
/// StreamComplete, or re-issuing Where after a fault clear).
fn fold_events(
  model: Model,
  events: List(printer.Event),
) -> #(Model, Effect(Msg)) {
  list.fold(events, #(model, effect.none()), fn(acc, ev) {
    let #(m, eff) = acc
    let #(m2, eff2) = fold_event(m, ev)
    #(m2, effect.batch([eff, eff2]))
  })
}

fn fold_event(model: Model, ev: printer.Event) -> #(Model, Effect(Msg)) {
  case ev {
    // The live position from an M114 reply: update the head readout + crosshair.
    printer.PositionUpdate(pos) -> noeff(apply_head(model, pos.x, pos.y, pos.z))

    // One confirmed stream line: fold into the progress ring + per-hole status.
    printer.Progress(sent, total, _line) ->
      noeff(apply_progress(model, sent, total))

    // The stream finished. In dry-run, leave the operator on the dry-run screen
    // (the confirm gate is theirs); in drill, the run is done streaming but
    // completion stays an explicit operator step (Mark Complete).
    printer.StreamComplete -> noeff(stream_complete(model))

    // The machine faulted (abort or serial loss): fault the job + show banner.
    printer.Faulting(_reason) -> noeff(fault(model))

    // Recovered from a fault: job FSM routes Faulted → Aligned.
    printer.Recovered -> noeff(recovered(model))

    // Accepted/Refused are informational here; the gates already reflect state.
    printer.Accepted(_) -> noeff(model)
    printer.Refused(_, _) -> noeff(model)
  }
}

// ── Stage 1: file load + sample + connect ────────────────────────────────────

@external(javascript, "./ui/file_ffi.mjs", "pickFileText")
fn pick_file_text(accept: String) -> promise.Promise(Result(String, String))

fn pick_drl_effect() -> Effect(Msg) {
  use dispatch <- effect.from
  pick_file_text(".drl,.txt")
  |> promise.map(fn(res) { dispatch(DrlPicked(res)) })
  Nil
}

fn pick_outline_effect() -> Effect(Msg) {
  use dispatch <- effect.from
  pick_file_text(".svg")
  |> promise.map(fn(res) { dispatch(OutlinePicked(res)) })
  Nil
}

fn drl_picked(
  model: Model,
  res: Result(String, String),
) -> #(Model, Effect(Msg)) {
  case res {
    Ok(text) ->
      noeff(
        Model(..model, pending_drl: text, file_selected: True, upload_error: ""),
      )
    // A cancelled picker is silent; a real read error surfaces.
    Error("cancelled") -> noeff(model)
    Error(reason) ->
      noeff(Model(..model, upload_error: "File error: " <> reason))
  }
}

fn outline_picked(
  model: Model,
  res: Result(String, String),
) -> #(Model, Effect(Msg)) {
  case res {
    Ok(text) ->
      noeff(
        Model(..model, pending_edge_cuts: text, outline_file: "Edge.Cuts.svg"),
      )
    Error("cancelled") -> noeff(model)
    Error(reason) ->
      noeff(Model(..model, upload_error: "Outline error: " <> reason))
  }
}

// Load the built-in sample (segby_v1) so the demo runs with no file dialog.
fn load_sample(model: Model) -> #(Model, Effect(Msg)) {
  let m =
    Model(
      ..model,
      pending_drl: sample.drl(),
      pending_edge_cuts: sample.edge_cuts_svg(),
      file_selected: True,
      outline_file: "Edge.Cuts.svg (sample)",
      upload_error: "",
    )
  parse_board(m)
}

fn parse_board(model: Model) -> #(Model, Effect(Msg)) {
  case model.pending_drl {
    "" -> noeff(Model(..model, upload_error: "No drill file selected."))
    drl -> {
      let edge = case model.pending_edge_cuts {
        "" -> None
        s -> Some(s)
      }
      case board_model.parse(Inputs(drl: Some(drl), edge_cuts: edge)) {
        Ok(bm) -> {
          let board = bridge.board_of(bm)
          let diag = bridge.diagnostic_of(bm)
          noeff(
            Model(
              ..model,
              board: HaveBoard(board),
              board_model: HaveBoardModel(bm),
              diagnostic: HaveDiagnostic(diag),
              job: HaveJob(job.new(bm)),
              upload_error: "",
            ),
          )
        }
        Error(err) ->
          noeff(
            Model(
              ..model,
              board: NoBoard,
              board_model: NoBoardModel,
              diagnostic: NoDiagnostic,
              job: NoJob,
              upload_error: bridge.parse_error_message(err),
            ),
          )
      }
    }
  }
}

fn select_backend(model: Model, kind: BackendKind) -> #(Model, Effect(Msg)) {
  // Only meaningful while disconnected (the picker is disabled when connected).
  case controller.is_connected(model.controller) {
    True -> noeff(model)
    False -> {
      let ctrl = controller.set_backend(model.controller, backend_for(kind))
      storage.save_backend(kind)
      noeff(Model(..model, controller: ctrl, backend_kind: kind))
    }
  }
}

fn connect_device(model: Model) -> #(Model, Effect(Msg)) {
  // The real Web Serial open MUST run inside the click (this handler is invoked
  // synchronously from the user gesture). The sim opens instantly the same way.
  let baud = bridge.baud(model.config)
  let eff =
    controller.connect(model.controller, baud) |> effect.map(ControllerEvent)
  #(model, eff)
}

fn disconnect_device(model: Model) -> #(Model, Effect(Msg)) {
  let #(ctrl, eff) = controller.disconnect(model.controller)
  #(
    Model(
      ..model,
      controller: ctrl,
      printer: bridge.printer_state(controller.state(ctrl)),
    ),
    effect.map(eff, ControllerEvent),
  )
}

fn start_registering(model: Model) -> #(Model, Effect(Msg)) {
  // Advance the job FSM Parsed → Registering, snapshot the config for the run,
  // and reset capture state.
  let job2 = job_advance(model.job, job.StartRegistering)
  noeff(
    Model(
      ..model,
      screen: Align,
      job: job2,
      applied_config: bridge.gcode_config(model.config, config.DryRun),
      captured: [],
      captures: [],
      current_target: 0,
      quality: -1,
      alignment_rejected: False,
      transform: NoTransform,
      head_pos: NoHeadPos,
      head_confidence: ConfNone,
    ),
  )
}

// ── Stage 2: alignment ───────────────────────────────────────────────────────

fn jog(model: Model, axis: String, sign: Float) -> #(Model, Effect(Msg)) {
  // Gate off the REAL printer state — the pure core also refuses if not Jogging,
  // writing nothing, but we avoid even issuing when not energized.
  case model.printer == Jogging {
    False -> noeff(model)
    True -> {
      let mm = sign *. model.jog_step
      let pcmd = case axis {
        "X" -> printer.Jog(printer.X, mm)
        "Y" -> printer.Jog(printer.Y, mm)
        "Z" -> printer.Jog(printer.Z, mm)
        _ -> printer.Jog(printer.X, 0.0)
      }
      // Issue the jog now; query position (M114) on the NEXT tick so the jog's
      // ordered writes (G91/G0/G90) reach the wire BEFORE the M114 read — folding
      // both into one `effect.batch` here would let `effect.batch`'s synchronous
      // reversal run M114 first and read a stale position.
      let #(m1, eff1) = issue(model, pcmd)
      #(m1, effect.batch([eff1, request_where_effect()]))
    }
  }
}

// Dispatch a position query (M114) on the next microtask, so it runs after the
// preceding motion effect's writes have been performed.
fn request_where_effect() -> Effect(Msg) {
  use dispatch <- effect.from
  promise.resolve(Nil)
  |> promise.map(fn(_) {
    dispatch(ControllerEvent(controller.Issue(printer.Where)))
  })
  Nil
}

fn test_spindle(model: Model) -> #(Model, Effect(Msg)) {
  case model.printer == Jogging {
    False -> noeff(model)
    True -> {
      let #(on, off) = bridge.spindle_commands(model.config)
      issue(model, printer.PulseSpindle(on, off))
    }
  }
}

// Click-to-jump: move the head to the board point's machine coord using the best
// transform available (solved → estimate → none). Disabled until at least one
// capture (or a fit) exists.
fn jump_to(model: Model, point: #(Float, Float)) -> #(Model, Effect(Msg)) {
  case model.screen == Align && model.printer == Jogging {
    False -> noeff(model)
    True ->
      case bridge.board_to_machine(model.transform, model.captures, point) {
        Error(_) -> noeff(model)
        Ok(#(mx, my)) -> {
          let #(m1, eff1) = issue(model, printer.MoveTo(mx, my))
          #(m1, effect.batch([eff1, request_where_effect()]))
        }
      }
  }
}

// Capture the current target candidate paired with the live head XY. Requires
// motors energized (so a real M114 has been read) and the job in Registering.
fn capture(model: Model) -> #(Model, Effect(Msg)) {
  case model.printer == Jogging, model.job, model.board {
    True, HaveJob(j), HaveBoard(board) ->
      case can_capture(j) {
        False -> noeff(model)
        True -> {
          let idx = model.current_target
          case list_at(board.candidates, idx) {
            Error(_) -> noeff(model)
            Ok(#(bx, by)) -> {
              let already = list.any(model.captured, fn(f) { f.index == idx })
              case already {
                True -> noeff(model)
                False -> {
                  let machine = #(model.head.x, model.head.y)
                  let corr = Correspondence(board: #(bx, by), machine: machine)
                  let j2 = case job.transition(j, job.Capture(corr)) {
                    Ok(jj) -> jj
                    Error(_) -> j
                  }
                  let captured =
                    list.append(model.captured, [
                      Fiducial(bx, by, idx, Captured),
                    ])
                  let captures =
                    list.append(model.captures, [
                      Capture(board: #(bx, by), machine: machine),
                    ])
                  let next = next_uncaptured(board.candidates, captured)
                  noeff(
                    Model(
                      ..model,
                      job: HaveJob(j2),
                      captured: captured,
                      captures: captures,
                      current_target: next,
                    )
                    |> refresh_head_conf(),
                  )
                }
              }
            }
          }
        }
      }
    _, _, _ -> noeff(model)
  }
}

fn can_capture(j: job.Job) -> Bool {
  job.can(j, job.CaptureE)
}

// Fit: drive the job FSM Fit(tol). On Aligned, store the transform + quality; on
// AlignmentRejected, set the recapture path. A failed fit (too few / degenerate)
// leaves the model unchanged (the FSM stays in Registering).
fn fit(model: Model) -> #(Model, Effect(Msg)) {
  case model.job {
    HaveJob(j) ->
      case list.length(model.captures) >= 3 {
        False -> noeff(model)
        True ->
          case job.transition(j, job.Fit(j.tol)) {
            Ok(j2) ->
              case j2.state {
                job.Aligned ->
                  case j2.alignment {
                    Some(al) -> noeff(apply_fit(model, j2, al, False))
                    None -> noeff(Model(..model, job: HaveJob(j2)))
                  }
                job.AlignmentRejected -> {
                  let #(rmax, rrms) = residuals_of(j2)
                  noeff(
                    Model(
                      ..model,
                      job: HaveJob(j2),
                      quality: quality_pct(rmax, j.tol),
                      residual_max: rmax,
                      residual_rms: rrms,
                      alignment_rejected: True,
                    ),
                  )
                }
                _ -> noeff(Model(..model, job: HaveJob(j2)))
              }
            Error(_) -> noeff(model)
          }
      }
    NoJob -> noeff(model)
  }
}

fn apply_fit(
  model: Model,
  j: job.Job,
  al: alignment.Alignment,
  _rejected: Bool,
) -> Model {
  let r = al.residuals
  let pct = quality_pct(r.max, j.tol)
  Model(
    ..model,
    job: HaveJob(j),
    quality: pct,
    residual_max: r.max,
    residual_rms: r.rms,
    alignment_rejected: False,
    transform: HaveTransform(al.transform),
    head_confidence: ConfAligned,
    head_pos: HaveHeadPos(project_head(al.transform, model.head)),
  )
}

fn residuals_of(j: job.Job) -> #(Float, Float) {
  case j.residuals {
    Some(r) -> #(r.max, r.rms)
    None -> #(0.0, 0.0)
  }
}

// Quality 0..100 from residual_max vs the tolerance: residual 0 → 100%, residual
// == tol → ~50% threshold (GOOD above 80, fair, poor), residual >> tol → 0.
// A tolerance-relative quality mapping.
fn quality_pct(residual_max: Float, tol: Float) -> Int {
  let t = float.max(tol, 1.0e-6)
  // 100 at residual 0, falling to 0 at residual 2*tol.
  let frac = 1.0 -. residual_max /. { 2.0 *. t }
  let clamped = float.min(float.max(frac, 0.0), 1.0)
  float.round(clamped *. 100.0)
}

fn recapture(model: Model) -> #(Model, Effect(Msg)) {
  let job2 = job_advance(model.job, job.Recapture)
  noeff(
    Model(
      ..model,
      job: job2,
      captured: [],
      captures: [],
      current_target: 0,
      quality: -1,
      alignment_rejected: False,
      transform: NoTransform,
      head_pos: NoHeadPos,
      head_confidence: ConfNone,
    ),
  )
}

fn restart_alignment(model: Model) -> #(Model, Effect(Msg)) {
  let job2 = job_advance(model.job, job.RestartAlignment)
  noeff(
    Model(
      ..model,
      job: job2,
      captured: [],
      captures: [],
      current_target: 0,
      quality: -1,
      alignment_rejected: False,
      transform: NoTransform,
      head_pos: NoHeadPos,
      head_confidence: ConfNone,
    ),
  )
}

// ── Stage 3/4: dry-run + drilling (streaming) ────────────────────────────────

fn run_dry_run(model: Model) -> #(Model, Effect(Msg)) {
  // Only legal from Aligned with a solved transform; the job FSM gates it.
  case model.job {
    HaveJob(j) ->
      case job.can(j, job.RunDryRunE), j.alignment {
        True, Some(al) -> {
          let j2 = job_advance(model.job, job.RunDryRun)
          let cfg =
            config.GcodeConfig(..model.applied_config, mode: config.DryRun)
          let program = gcode_program.build(j.board, al, cfg)
          let total = list.length(j.board.holes)
          let m =
            Model(
              ..model,
              screen: DryRun,
              job: j2,
              board: reset_hole_status(model.board),
              progress: HaveProgress(Progress(
                drilled: 0,
                total: total,
                mode: DryRunMode,
              )),
            )
          issue(m, printer.Stream(program.lines))
        }
        _, _ -> noeff(model)
      }
    NoJob -> noeff(model)
  }
}

fn redo_alignment(model: Model) -> #(Model, Effect(Msg)) {
  let job2 = job_advance(model.job, job.RedoAlignment)
  noeff(Model(..model, job: job2, screen: Align, progress: NoProgress))
}

fn confirm_registration(model: Model) -> #(Model, Effect(Msg)) {
  case model.job {
    HaveJob(j) ->
      case job.can(j, job.ConfirmRegistrationE), j.alignment {
        True, Some(al) -> {
          let j2 = job_advance(model.job, job.ConfirmRegistration)
          let cfg =
            config.GcodeConfig(..model.applied_config, mode: config.Drill)
          let program = gcode_program.build(j.board, al, cfg)
          let total = list.length(j.board.holes)
          // Bit-change pause: with >1 tool, surface the SECOND tool's diameter as
          // the representative per-tool M0 pause modal (one pause that holds
          // completion until acknowledged).
          let #(bit_change, bit_label, changes) = case program.tool_order {
            [_first, second, ..] -> {
              let dia = tool_diameter(j.board, second)
              #(
                HaveBitChange(BitChange(diameter: dia)),
                fmt_mm(tool_diameter(j.board, first_tool(program.tool_order)))
                  <> "mm",
                int.max(list.length(program.tool_order) - 1, 0),
              )
            }
            _ -> #(NoBitChange, "—", 0)
          }
          let m =
            Model(
              ..model,
              screen: Drill,
              job: j2,
              board: reset_hole_status(model.board),
              progress: HaveProgress(Progress(
                drilled: 0,
                total: total,
                mode: DrillMode,
              )),
              bit_change: bit_change,
              bit_changes_seen: changes,
              telemetry_bit: bit_label,
              telemetry_spindle: spindle_label(model.config),
              telemetry_eta: "—",
            )
          issue(m, printer.Stream(program.lines))
        }
        _, _ -> noeff(model)
      }
    NoJob -> noeff(model)
  }
}

fn resume_drilling(model: Model) -> #(Model, Effect(Msg)) {
  // Clear the bit-change modal; the background stream keeps animating. Completion
  // stays an explicit operator step.
  noeff(Model(..model, bit_change: NoBitChange))
}

fn complete(model: Model) -> #(Model, Effect(Msg)) {
  let job2 = job_advance(model.job, job.Complete)
  let total = case model.board {
    HaveBoard(b) -> list.length(b.holes)
    NoBoard -> 0
  }
  // Total time = the full-run estimate (all holes), same per-hole model as ETA.
  let total_time = fmt_mmss(per_hole_seconds(model) *. int.to_float(total))
  noeff(
    Model(
      ..model,
      screen: Done,
      job: job2,
      summary: HaveSummary(Summary(
        total_holes: total,
        total_time: total_time,
        bit_changes: model.bit_changes_seen,
      )),
    ),
  )
}

// ── fault / recover / new board ──────────────────────────────────────────────

fn abort(model: Model) -> #(Model, Effect(Msg)) {
  // Emergency abort: halt (M112). The controller faults; fold_event handles the
  // job transition + banner.
  issue(model, printer.Halt)
}

fn fault(model: Model) -> Model {
  // The job faults only if it is mid-drill (SerialLoss is legal from Drilling).
  let job2 = case model.job {
    HaveJob(j) ->
      case job.transition(j, job.SerialLoss("abort")) {
        Ok(jj) -> HaveJob(jj)
        Error(_) -> HaveJob(j)
      }
    NoJob -> NoJob
  }
  Model(..model, job: job2, bit_change: NoBitChange)
}

fn reconnect(model: Model) -> #(Model, Effect(Msg)) {
  // Controller Reconnect (Faulted → Idle) emits Recovered, which routes the job
  // Faulted → Aligned. Clear stale progress + modal; land on Align.
  let #(m1, eff1) = issue(model, printer.Reconnect)
  let m2 =
    Model(..m1, screen: Align, progress: NoProgress, bit_change: NoBitChange)
  #(m2, eff1)
}

fn recovered(model: Model) -> Model {
  let job2 = case model.job {
    HaveJob(j) ->
      case job.transition(j, job.Reconnect) {
        Ok(jj) -> HaveJob(jj)
        Error(_) -> HaveJob(j)
      }
    NoJob -> NoJob
  }
  Model(..model, job: job2)
}

fn new_board(model: Model) -> #(Model, Effect(Msg)) {
  // Fresh board (Stage 5 → Stage 1) keeping the connection + applied config.
  let #(fresh, _) = init(Nil)
  noeff(
    Model(
      ..fresh,
      controller: model.controller,
      printer: model.printer,
      backend_kind: model.backend_kind,
      config: model.config,
      applied_config: model.applied_config,
    ),
  )
}

// ── event folding helpers ────────────────────────────────────────────────────

// Update the head readout + projected board crosshair from a live position.
fn apply_head(model: Model, x: Float, y: Float, z: Float) -> Model {
  let head = Head(x: x, y: y, z: z)
  let m = Model(..model, head: head)
  case model.transform {
    HaveTransform(t) ->
      Model(
        ..m,
        head_confidence: ConfAligned,
        head_pos: HaveHeadPos(project_head(t, head)),
      )
    NoTransform -> refresh_head_conf(m)
  }
}

// Fold a confirmed-line stream count into the progress ring + per-hole status.
fn apply_progress(model: Model, sent: Int, _total: Int) -> Model {
  case model.progress, model.job {
    HaveProgress(p), HaveJob(j) -> {
      let program = current_program(model, j)
      let confirmed = list.take(program, sent)
      let holes_done = count_holes(confirmed)
      let board = mark_holes(model.board, holes_done)
      let total_holes = case model.board {
        HaveBoard(b) -> list.length(b.holes)
        NoBoard -> p.total
      }
      Model(
        ..model,
        board: board,
        progress: HaveProgress(
          Progress(..p, drilled: holes_done, total: total_holes),
        ),
        telemetry_eta: eta_label(model, total_holes - holes_done),
      )
    }
    _, _ -> model
  }
}

// The program currently streaming (rebuilt from the job + applied config so the
// confirmed-prefix hole count is exact). Cheap to rebuild; keeps the model flat.
fn current_program(model: Model, j: job.Job) -> List(String) {
  case j.alignment, model.progress {
    Some(al), HaveProgress(p) -> {
      let mode = case p.mode {
        DrillMode -> config.Drill
        DryRunMode -> config.DryRun
      }
      let cfg = config.GcodeConfig(..model.applied_config, mode: mode)
      gcode_program.build(j.board, al, cfg).lines
    }
    _, _ -> []
  }
}

// Every hole emits exactly one `G0 X..` rapid (the per-hole XY rapid format);
// the postamble home is `G00 X..` and the tool lift is `G0 Z..`, so neither is
// miscounted.
fn count_holes(lines: List(String)) -> Int {
  list.count(lines, fn(l) { string.starts_with(l, "G0 X") })
}

fn stream_complete(model: Model) -> Model {
  // Mark the run fully streamed: all holes Done, progress at total. Completion
  // stays an explicit operator step (Mark Complete on Drill; Confirm on DryRun).
  let total = case model.board {
    HaveBoard(b) -> list.length(b.holes)
    NoBoard -> 0
  }
  let board = mark_holes(model.board, total)
  case model.progress {
    HaveProgress(p) ->
      Model(
        ..model,
        board: board,
        progress: HaveProgress(Progress(..p, drilled: total, total: total)),
        telemetry_eta: "0:00",
      )
    NoProgress -> model
  }
}

// ── head confidence (progressive trust) ──────────────────────────────────────

fn refresh_head_conf(model: Model) -> Model {
  case model.head_confidence == ConfAligned {
    True ->
      case model.transform {
        HaveTransform(t) ->
          Model(..model, head_pos: HaveHeadPos(project_head(t, model.head)))
        NoTransform -> model
      }
    False -> {
      let conf = case list.length(model.captures) {
        0 -> ConfNone
        1 -> ConfEstimate
        _ -> ConfRough
      }
      let head_pos = case conf {
        ConfNone -> NoHeadPos
        _ ->
          case bridge.board_to_machine_inverse(model.captures, model.head) {
            Ok(p) -> HaveHeadPos(p)
            Error(_) -> HaveHeadPos(#(model.head.x, model.head.y))
          }
      }
      Model(..model, head_confidence: conf, head_pos: head_pos)
    }
  }
}

// Project the machine head back to a board position via the inverse transform.
fn project_head(t: transform2d.Transform2D, head: Head) -> #(Float, Float) {
  case transform2d.invert(t) {
    Ok(inv) -> transform2d.apply(inv, #(head.x, head.y))
    Error(_) -> #(head.x, head.y)
  }
}

// ── job FSM helper ───────────────────────────────────────────────────────────

fn job_advance(j: model.JobOpt, event: job.Event) -> model.JobOpt {
  case j {
    HaveJob(jj) ->
      case job.transition(jj, event) {
        Ok(next) -> HaveJob(next)
        Error(_) -> HaveJob(jj)
      }
    NoJob -> NoJob
  }
}

// ── telemetry helpers ────────────────────────────────────────────────────────

fn spindle_label(c: model.Config) -> String {
  "ON · " <> c.spindle_speed <> "/" <> c.pwm_max <> " PWM"
}

fn eta_label(model: Model, remaining: Int) -> String {
  let secs = per_hole_seconds(model) *. int.to_float(int.max(remaining, 0))
  fmt_mmss(secs)
}

fn per_hole_seconds(model: Model) -> Float {
  let cfg = model.applied_config
  let feed_per_s = float.max(cfg.drill_feed /. 60.0, 1.0e-6)
  let z_travel = case cfg.mode {
    config.Drill -> 2.0 *. { cfg.zsafe -. cfg.zdrill }
    config.DryRun -> 2.0 *. float.max(cfg.hover, 0.0)
  }
  z_travel /. feed_per_s +. 0.5
}

fn fmt_mmss(seconds: Float) -> String {
  let total = float.round(seconds)
  let mm = total / 60
  let ss = total % 60
  int.to_string(mm) <> ":" <> pad2(ss)
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

// ── board hole status helpers ────────────────────────────────────────────────

fn reset_hole_status(board: model.BoardOpt) -> model.BoardOpt {
  case board {
    HaveBoard(b) -> {
      let holes =
        list.map(b.holes, fn(h) { model.Hole(..h, status: model.Pending) })
      HaveBoard(model.Board(..b, holes: holes))
    }
    NoBoard -> NoBoard
  }
}

fn mark_holes(board: model.BoardOpt, done_count: Int) -> model.BoardOpt {
  case board {
    HaveBoard(b) -> {
      let holes =
        b.holes
        |> list.index_map(fn(hole, i) {
          let status = case i < done_count, i == done_count {
            True, _ -> HoleDone
            False, True -> model.Active
            False, False -> model.Pending
          }
          model.Hole(..hole, status: status)
        })
      HaveBoard(model.Board(..b, holes: holes))
    }
    NoBoard -> NoBoard
  }
}

fn tool_diameter(board: board_model.BoardModel, tool: String) -> Float {
  case list.key_find(dict_to_list(board.tools), tool) {
    Ok(d) -> d
    Error(_) -> 0.0
  }
}

fn dict_to_list(d: board_model.ToolTable) -> List(#(String, Float)) {
  d |> dict.to_list
}

fn first_tool(order: List(String)) -> String {
  case order {
    [t, ..] -> t
    [] -> "T1"
  }
}

fn fmt_mm(d: Float) -> String {
  case d == 10.0 {
    True -> "10"
    False -> float.to_string(d)
  }
}

// ── settings / config ────────────────────────────────────────────────────────

fn apply_config(model: Model) -> #(Model, Effect(Msg)) {
  // Persist the operator config and re-snapshot the generator tunables for the
  // next run. The snapshot is taken when a run starts.
  storage.save_config(model.config)
  noeff(
    Model(
      ..model,
      config_dirty: False,
      applied_config: bridge.gcode_config(model.config, config.DryRun),
    ),
  )
}

fn set_config_field(model: Model, field: String, value: String) -> Model {
  let c = model.config
  let c2 = case field {
    "port" -> model.Config(..c, port: value)
    "baud" -> model.Config(..c, baud: value)
    "max_x" -> model.Config(..c, max_x: value)
    "max_y" -> model.Config(..c, max_y: value)
    "max_z" -> model.Config(..c, max_z: value)
    "spindle_on" -> model.Config(..c, spindle_on: value)
    "spindle_off" -> model.Config(..c, spindle_off: value)
    "pwm_max" -> model.Config(..c, pwm_max: value)
    "spindle_speed" -> model.Config(..c, spindle_speed: value)
    "zdrill" -> model.Config(..c, zdrill: value)
    "zsafe" -> model.Config(..c, zsafe: value)
    "zchange" -> model.Config(..c, zchange: value)
    "drill_feed" -> model.Config(..c, drill_feed: value)
    "hover" -> model.Config(..c, hover: value)
    _ -> c
  }
  Model(..model, config: c2, config_dirty: True)
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn resting_screen(model: Model) -> model.Screen {
  case model.job {
    HaveJob(j) ->
      case j.state {
        job.Parsed -> Load
        job.Registering -> Align
        job.Aligned -> Align
        job.AlignmentRejected -> Align
        job.DryRun -> DryRun
        job.Drilling -> Drill
        job.Done -> Done
        job.Faulted -> Align
      }
    NoJob -> Load
  }
}

fn stage_screen(stage: model.StageId) -> model.Screen {
  case stage {
    StageLoad -> Load
    StageAlign -> Align
    StageDryRun -> DryRun
    StageDrill -> Drill
    StageDone -> Done
  }
}

fn next_uncaptured(
  candidates: List(#(Float, Float)),
  captured: List(model.Fiducial),
) -> Int {
  let done = list.map(captured, fn(f) { f.index })
  let n = list.length(candidates)
  find_first_uncaptured(0, n, done)
}

fn find_first_uncaptured(i: Int, n: Int, done: List(Int)) -> Int {
  case i >= n {
    True -> n - 1
    False ->
      case list.contains(done, i) {
        True -> find_first_uncaptured(i + 1, n, done)
        False -> i
      }
  }
}

fn list_at(items: List(a), idx: Int) -> Result(a, Nil) {
  case list.drop(items, idx) {
    [x, ..] -> Ok(x)
    [] -> Error(Nil)
  }
}

fn clamp_zoom(z: Float) -> Float {
  float.min(float.max(z, 1.0), 12.0)
}

// ── view ─────────────────────────────────────────────────────────────────────

fn view(model: Model) -> Element(Msg) {
  case model.screen {
    Settings -> stages.settings(model)
    _ -> session(model)
  }
}

fn session(model: Model) -> Element(Msg) {
  h.div([a.class("app")], [
    fault_banner(model),
    shell.header(model),
    h.div([a.class("app-body")], [
      shell.sidebar(model),
      h.main([a.class("main")], [stage_main(model)]),
    ]),
    shell.data_bar(model),
  ])
}

fn fault_banner(model: Model) -> Element(Msg) {
  case model.printer == Faulted {
    True -> shell.fault_banner()
    False -> element.none()
  }
}

fn stage_main(model: Model) -> Element(Msg) {
  case model.screen {
    Load -> load_with_sample(model)
    Align -> stages.align(model)
    DryRun -> stages.dry_run(model)
    Drill -> stages.drill(model)
    Done -> stages.done(model)
    Settings -> stages.load(model)
  }
}

// The Stage-1 view, augmented with a "Load sample board" affordance so the demo
// runs with no file dialog. The picker view itself is unchanged.
fn load_with_sample(model: Model) -> Element(Msg) {
  case model.board {
    HaveBoard(_) -> stages.load(model)
    NoBoard ->
      h.div([], [
        stages.load(model),
        h.div([a.class("sample-row")], [
          h.button(
            [
              a.class("btn btn-outline"),
              a.attribute("type", "button"),
              event.on_click(LoadSample),
            ],
            [h.text("Load sample board (segby_v1)")],
          ),
        ]),
      ])
  }
}
