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
  HaveBitChange, HaveBoard, HaveBoardModel, HaveDiagnostic, HaveFitDiag,
  HaveHeadPos, HaveJob, HaveProgress, HaveSummary, HaveTransform, Head, HoleDone,
  Jog, Jogging, JumpTo, Load, LoadSample, Model, NavStage, NewBoard, NoBitChange,
  NoBoard, NoBoardModel, NoDiagnostic, NoFitDiag, NoHeadPos, NoJob, NoProgress,
  NoSummary, NoTransform, OutlinePicked, ParseBoard, Progress, RealBackend,
  Recapture, Reconnect, RedoAlignment, Release, ResetDefaults, ResetView,
  RestartAlignment, ResumeAlignment, ResumeDrilling, RunDryRun, SelectBackend,
  SelectCategory, SelectFile, SelectOutline, SetConfigField, SetCurrentTarget,
  SetJogStep, Settings, SimBackend, StageAlign, StageDone, StageDrill,
  StageDryRun, StageLoad, StartRegistering, Streaming, Summary, TestSpindle,
  ToggleAppPause, ToggleAutoConnect,
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
import gleam/result
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
  // Restore the reload-survivable session slice (board source + UI prefs).
  let session = storage.load_session(1.0, 1.0)
  let m =
    Model(
      screen: Load,
      printer: Disconnected,
      board: NoBoard,
      diagnostic: NoDiagnostic,
      file_selected: session.drl != "",
      outline_file: session.outline_file,
      upload_error: "",
      head: Head(0.0, 0.0, 0.0),
      head_pos: NoHeadPos,
      head_confidence: ConfNone,
      jog_step: session.jog_step,
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
      telemetry_spindle: "OFF · 0 RPM",
      zoom: session.zoom,
      category: Connection,
      config: cfg,
      config_dirty: False,
      controller: controller.new(backend),
      backend_kind: backend_kind,
      board_model: NoBoardModel,
      job: NoJob,
      pending_drl: session.drl,
      pending_edge_cuts: session.edge_cuts,
      captures: [],
      transform: NoTransform,
      applied_config: bridge.gcode_config(cfg, config.DryRun),
      bit_changes_seen: 0,
      board_side: model.Front,
      resume_pending: False,
    )
  // Re-parse the restored board (deterministic; no hardware). If the stored DRL
  // is empty or fails to parse, `parse_board` leaves the model board-less.
  let #(m, _) = case session.drl {
    "" -> #(m, effect.none())
    _ -> parse_board(m)
  }
  // Apply the URL-hash stage, CAPPED to a safe restore target: never restore
  // into a connection/alignment-dependent stage (DryRun/Drill/Done), and never
  // into Align without a board. Anything else collapses to Load.
  let m = case restore_screen(m) {
    // Restoring into Align: if a fitted alignment was persisted AND restores
    // cleanly, re-instate it into a NOT-YET-TRUSTED state (resume_pending) so the
    // operator can resume without re-capturing — but only after reconnecting and
    // confirming the board hasn't moved. Otherwise fall back to a fresh
    // Registering (the job FSM Parsed → Registering, exactly as "Proceed to
    // Align" does — else the job stays in Parsed and Capture silently no-ops).
    Align ->
      case storage.load_alignment() {
        Ok(saved) ->
          case restore_alignment(m, saved) {
            Ok(m2) -> m2
            // A persisted slice that can't be replayed into Aligned (e.g. the
            // captures no longer fit) is discarded: fall back to fresh register.
            Error(_) -> {
              storage.clear_alignment()
              let #(m2, _) = start_registering(m)
              m2
            }
          }
        Error(_) -> {
          let #(m2, _) = start_registering(m)
          m2
        }
      }
    screen -> Model(..m, screen: screen)
  }
  // Auto-reconnect: if enabled and the real Web Serial backend is selected, try
  // to re-open a previously-authorized port WITHOUT a picker. A benign "no
  // granted port" leaves the app disconnected with no prompt.
  let connect_eff = case cfg.auto_connect, backend_kind {
    True, RealBackend ->
      controller.connect_existing(m.controller, bridge.baud(cfg))
      |> effect.map(ControllerEvent)
    _, _ -> effect.none()
  }
  // Persist the (capped) restored screen + session so storage/URL agree with the
  // model from the first frame.
  #(m, effect.batch([connect_eff, persist_effect(m)]))
}

/// Decide the screen to restore from the URL hash (reads the hash, then caps).
fn restore_screen(model: Model) -> model.Screen {
  let has_board = case model.board {
    HaveBoard(_) -> True
    NoBoard -> False
  }
  restore_target(storage.screen_from_hash(), has_board)
}

/// PURE restore-cap decision (separated from the URL read so it is unit-testable):
/// given the screen the URL hash requested and whether a board re-parsed, return
/// the SAFE screen to resume after a reload — connection + alignment are always
/// reset, so:
///   * `Settings` — always fine.
///   * `Align` — only if a board is present (else there's nothing to align).
///   * everything else, incl. DryRun/Drill/Done — collapse to `Load`, because
///     they require a live connection and a valid alignment we just discarded.
/// Restoring into `Align` also requires advancing the job to Registering — see
/// `init` (the bug this guards against: a restored Align with the job left in
/// Parsed makes Capture silently no-op).
pub fn restore_target(
  requested: Result(model.Screen, Nil),
  has_board: Bool,
) -> model.Screen {
  case requested {
    Ok(Settings) -> Settings
    Ok(Align) ->
      case has_board {
        True -> Align
        False -> Load
      }
    _ -> Load
  }
}

fn backend_for(kind: BackendKind) -> backend.Backend {
  case kind {
    SimBackend -> transport.simulator()
    RealBackend -> transport.web_serial()
  }
}

// ── update ───────────────────────────────────────────────────────────────────

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  let #(next, eff) = update_inner(model, msg)
  // Reflect the reload-survivable slice (board + UI prefs) to localStorage and
  // the current screen to the URL hash after every update — cheap, idempotent,
  // and keeps a single source of truth instead of threading saves through every
  // handler. NO connection/alignment/run state is persisted (safety model).
  #(next, effect.batch([eff, persist_effect(next)]))
}

fn persist_effect(model: Model) -> Effect(Msg) {
  use _dispatch <- effect.from
  let #(drl, edge, outline) = case model.board {
    HaveBoard(_) -> #(
      model.pending_drl,
      model.pending_edge_cuts,
      model.outline_file,
    )
    NoBoard -> #("", "", "")
  }
  storage.save_session(storage.Session(
    drl: drl,
    edge_cuts: edge,
    outline_file: outline,
    jog_step: model.jog_step,
    zoom: model.zoom,
  ))
  // Persist the SOLVED alignment so a reload can resume it (restored unconfirmed,
  // re-instated only after reconnect — see init/ResumeAlignment). A reset / new
  // board / restart sets `transform: NoTransform`, which clears the slice here.
  case model.transform {
    HaveTransform(t) ->
      storage.save_alignment(storage.AlignmentSave(
        transform: t,
        captures: list.map(model.captures, fn(c) {
          #(c.board, c.machine, c.machine_z)
        }),
        side: model.board_side,
        quality: model.quality,
        residual_max: model.residual_max,
        residual_rms: model.residual_rms,
      ))
    NoTransform -> storage.clear_alignment()
  }
  storage.save_screen(model.screen)
  Nil
}

fn update_inner(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // navigation. Going back/forward must NEVER disconnect or clear the
    // alignment (transform/captures/job are left untouched below) — the machine
    // hasn't physically moved. The one hazard is leaving a dry-run stream
    // mid-flight, so any nav that changes the session screen first cancels an
    // in-flight stream GRACEFULLY (→ Idle, still connected), never via Halt.
    GoToSettings -> noeff(Model(..model, screen: Settings))
    GoToSession -> nav_to(model, resting_screen(model))
    NavStage(stage) -> nav_to(model, stage_screen(stage))

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
    model.SetBoardSide(side) -> noeff(set_board_side(model, side))

    // Stage 2 — alignment
    Energize -> issue(model, printer.Energize)
    Release -> issue(model, printer.Release)
    SetJogStep(step) -> noeff(Model(..model, jog_step: step))
    Jog(axis, sign) -> jog(model, axis, sign)
    TestSpindle -> test_spindle(model)
    SetCurrentTarget(idx) -> set_current_target(model, idx)
    JumpTo(point) -> jump_to(model, point)
    model.CaptureFiducial -> capture(model)
    Fit -> fit(model)
    Recapture -> recapture(model)
    model.OverrideAlignment -> override_alignment(model)
    RestartAlignment -> restart_alignment(model)
    ResumeAlignment -> resume_alignment(model)
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
    ToggleAppPause ->
      noeff(
        Model(
          ..model,
          config: model.Config(
            ..model.config,
            app_pause: !model.config.app_pause,
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

// Navigate to `screen`, but first cancel any in-flight dry-run stream GRACEFULLY
// (CancelStream → Idle, still connected) so we never leave a zombie stream on the
// controller. Crucially this does NOT touch transform/captures/job, so the
// alignment survives the navigation — only the screen changes (and the stream,
// if any, stops cleanly without faulting/disconnecting).
fn nav_to(model: Model, screen: model.Screen) -> #(Model, Effect(Msg)) {
  let #(model, eff) = cancel_active_stream(model)
  #(Model(..model, screen: screen), eff)
}

// If a stream is currently in flight, issue a benign CancelStream (→ Idle, stays
// connected, no M112, no fault). Otherwise a no-op. This is the single place
// "leaving an active stream via navigation" is handled gracefully.
fn cancel_active_stream(model: Model) -> #(Model, Effect(Msg)) {
  case model.printer {
    Streaming -> issue(model, printer.CancelStream)
    _ -> noeff(model)
  }
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

    // The stream halted at an in-app pause point (app_pause on; a swapped-in
    // sentinel where an M0 would be). Show the bit-change / resume modal so the
    // operator swaps the bit and presses Resume (which issues ResumeStream).
    printer.StreamPausedAt(pending, _total) ->
      noeff(stream_paused(model, pending))

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
        Ok(bm) -> noeff(install_board(model, bm))
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

// Install a freshly-parsed `BoardModel` for the current `board_side`: build the
// single WORKING model (the flip lives in exactly one place) and derive the
// canvas board, the diagnostic, and the job (hence the g-code) all from it. The
// raw `bm` is not retained — the source text in `pending_drl` / `pending_edge_cuts`
// lets us re-derive for a different side pre-registration (see `set_board_side`).
fn install_board(model: Model, bm: board_model.BoardModel) -> Model {
  let wm = bridge.working_board_model(bm, model.board_side)
  Model(
    ..model,
    board: HaveBoard(bridge.board_of(wm)),
    board_model: HaveBoardModel(wm),
    diagnostic: HaveDiagnostic(bridge.diagnostic_of(wm)),
    job: HaveJob(job.new(wm)),
    upload_error: "",
  )
}

// Set the board side. Pre-registration (job still in `Parsed`, or no board yet)
// the working geometry depends on the side, so re-parse the retained source text
// and rebuild the working model + job for the new side. Once registration has
// started the side is locked (the UI disables the toggle), so this path only ever
// runs with a fresh, unregistered job; if a registered job somehow gets here we
// leave the geometry untouched and only record the side.
fn set_board_side(model: Model, side: model.BoardSide) -> Model {
  let m = Model(..model, board_side: side)
  case registration_started(model.job), model.pending_drl {
    // Locked after registration: only record the side, keep the working model.
    True, _ -> m
    // No source to rebuild from (no board loaded yet): just record the side.
    False, "" -> m
    False, drl -> {
      let edge = case model.pending_edge_cuts {
        "" -> None
        s -> Some(s)
      }
      case board_model.parse(Inputs(drl: Some(drl), edge_cuts: edge)) {
        Ok(bm) -> install_board(m, bm)
        // The source already parsed once to load the board; a re-parse failure is
        // not expected. Fall back to just recording the side.
        Error(_) -> m
      }
    }
  }
}

// Registration has started once the job has left `Parsed` (Registering or
// beyond): the working geometry is fixed for the session.
fn registration_started(job: model.JobOpt) -> Bool {
  case job {
    HaveJob(j) ->
      case j.state {
        job.Parsed -> False
        _ -> True
      }
    NoJob -> False
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
      resume_pending: False,
    ),
  )
}

// Restore a previously-fitted alignment (loaded from localStorage on reload)
// into a NOT-YET-TRUSTED resume state. The live serial port is gone after a
// reload, so the restored transform is held UNCONFIRMED: `resume_pending` is set,
// confidence stays at `ConfRough` (not `ConfAligned`), and the operator must
// reconnect + confirm "board hasn't moved" (ResumeAlignment) before it is
// trusted. The job FSM is driven Parsed → Registering → (replay captures) →
// Aligned by re-fitting the SAVED captures (the same machinery a live fit uses),
// so the alignment is genuinely solved (alignment: Some(_)), not fabricated.
// Returns `Error(Nil)` if the saved captures can't be replayed into Aligned.
pub fn restore_alignment(
  model: Model,
  saved: storage.AlignmentSave,
) -> Result(Model, Nil) {
  // Rebuild the working board for the SAVED side first (the captures are against
  // that orientation). Pre-registration the side rebuild is a no-op or a re-parse
  // (set_board_side handles Parsed → rebuild).
  let m = set_board_side(model, saved.side)
  case m.job {
    HaveJob(j0) -> {
      // Parsed → Registering, then replay each saved capture, then Fit.
      use j1 <- result.try(transition_ok(j0, job.StartRegistering))
      let j2 =
        list.fold(saved.captures, j1, fn(j, triple) {
          let #(board, machine, machine_z) = triple
          // Restore the persisted machine Z so the re-fit reconstructs the same
          // board surface plane (2.5D alignment).
          let corr =
            Correspondence(board: board, machine: machine, machine_z: machine_z)
          case job.transition(j, job.Capture(corr)) {
            Ok(jj) -> jj
            Error(_) -> j
          }
        })
      use j3 <- result.try(transition_ok(j2, job.Fit(j2.tol)))
      // The fit may land Aligned (within tol) or AlignmentRejected (the saved
      // alignment had been overridden over tolerance): in the latter case promote
      // it with the same explicit OverrideAlignment edge a live override uses.
      use j4 <- result.try(case j3.state {
        job.Aligned -> Ok(j3)
        job.AlignmentRejected -> transition_ok(j3, job.OverrideAlignment)
        _ -> Error(Nil)
      })
      case j4.alignment {
        Some(al) -> {
          let r = al.residuals
          // Rebuild the captured-fiducial overlay (green rings) by mapping each
          // saved board point back to its candidate index in the working board.
          let captured = restore_fiducials(m.board, saved.captures)
          let captures =
            list.map(saved.captures, fn(p) {
              let #(b, mc, mz) = p
              Capture(board: b, machine: mc, machine_z: mz)
            })
          Ok(
            Model(
              ..m,
              screen: Align,
              job: HaveJob(j4),
              applied_config: bridge.gcode_config(m.config, config.DryRun),
              captured: captured,
              captures: captures,
              current_target: 0,
              transform: HaveTransform(al.transform),
              quality: quality_pct(r.max, j4.tol),
              residual_max: r.max,
              residual_rms: r.rms,
              alignment_rejected: False,
              fit_diag: NoFitDiag,
              // NOT trusted yet: the port is gone, nothing confirmed.
              head_confidence: ConfRough,
              head_pos: NoHeadPos,
              resume_pending: True,
            ),
          )
        }
        None -> Error(Nil)
      }
    }
    NoJob -> Error(Nil)
  }
}

fn transition_ok(j: job.Job, event: job.Event) -> Result(job.Job, Nil) {
  case job.transition(j, event) {
    Ok(jj) -> Ok(jj)
    Error(_) -> Error(Nil)
  }
}

// Rebuild the captured-fiducial overlay from saved captures: each capture's board
// point is matched to the nearest candidate index in the working board so the
// canvas draws the restored captures as completed (green) markers.
fn restore_fiducials(
  board: model.BoardOpt,
  captures: List(#(transform2d.Point, transform2d.Point, Float)),
) -> List(model.Fiducial) {
  case board {
    HaveBoard(b) ->
      list.map(captures, fn(triple) {
        let #(#(bx, by), _machine, _machine_z) = triple
        let idx = nearest_candidate_index(b.candidates, bx, by)
        Fiducial(bx, by, idx, Captured)
      })
    NoBoard -> []
  }
}

fn nearest_candidate_index(
  candidates: List(#(Float, Float)),
  bx: Float,
  by: Float,
) -> Int {
  candidates
  |> list.index_map(fn(pt, i) {
    let #(cx, cy) = pt
    let dx = cx -. bx
    let dy = cy -. by
    #(i, dx *. dx +. dy *. dy)
  })
  |> list.fold(#(-1, 0.0), fn(best, cand) {
    let #(best_i, best_d) = best
    let #(i, d) = cand
    case best_i < 0 || d <. best_d {
      True -> #(i, d)
      False -> best
    }
  })
  |> fn(best) { best.0 }
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
      // The jog burst now ends with M114 (in the same serialized write
      // sequence), so the position reply reflects the settled head — no separate,
      // racing query needed.
      issue(model, pcmd)
    }
  }
}

// Dispatch a position query (M114) on the next microtask, so it runs after the
// preceding motion effect's writes have been performed.

fn test_spindle(model: Model) -> #(Model, Effect(Msg)) {
  case model.printer == Jogging {
    False -> noeff(model)
    True -> {
      let #(on, off) = bridge.spindle_commands(model.config)
      issue(model, printer.PulseSpindle(on, off))
    }
  }
}

// Select a fiducial target by index and, when motion is allowed, jump the head to
// that fiducial's CENTRE (its candidate board point). Clicking a marker selects it
// (so `current_target` always updates for the UI), but only jogs when the same
// safe-jump guard as `jump_to` holds (Align + Jogging). The destination is the
// fiducial's exact candidate point, routed through the identical safe-jump path
// (`jump_to` → `bridge.board_to_machine` → `printer.MoveTo`). This does NOT touch
// the board-elsewhere `JumpTo(exact)` path, which still jumps to the exact click.
fn set_current_target(model: Model, idx: Int) -> #(Model, Effect(Msg)) {
  let selected = Model(..model, current_target: idx)
  case target_candidate(model.board, idx) {
    // Marker click → jump to its centre via the shared safe-jump path (which
    // applies the Align + Jogging guard itself; selection still took effect).
    Ok(point) -> jump_to(selected, point)
    // No board / index out of range: just record the selection.
    Error(_) -> noeff(selected)
  }
}

// PURE: the candidate board point for a fiducial index, if a board is loaded and
// the index is in range. The fiducial's centre is `board.candidates[idx]`.
pub fn target_candidate(
  board: model.BoardOpt,
  idx: Int,
) -> Result(#(Float, Float), Nil) {
  case board {
    HaveBoard(b) -> list_at(b.candidates, idx)
    NoBoard -> Error(Nil)
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
          // Safe jump: retract to zsafe, travel, descend to hover (config values).
          // The burst ends with M114, so the settled position is read with no race.
          let cfg = model.applied_config
          issue(model, printer.MoveTo(mx, my, cfg.zsafe, cfg.hover))
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
                  // The live M114 head Z is the bit-down height the operator
                  // jogged to on the pad — exactly the surface Z the plane fit
                  // wants. Carry it into both the correspondence and the model
                  // capture (2.5D alignment).
                  let machine_z = model.head.z
                  let corr =
                    Correspondence(
                      board: #(bx, by),
                      machine: machine,
                      machine_z: machine_z,
                    )
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
                      Capture(
                        board: #(bx, by),
                        machine: machine,
                        machine_z: machine_z,
                      ),
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
// AlignmentRejected, build actionable diagnostics (per-point residuals + worst
// point + likely-cause hint) and offer the explicit override. A degenerate /
// too-few fit no longer silently no-ops — it surfaces guidance.
fn fit(model: Model) -> #(Model, Effect(Msg)) {
  case model.job {
    HaveJob(j) ->
      case list.length(model.captures) >= 3 {
        False ->
          noeff(
            Model(
              ..model,
              upload_error: "Capture at least 3 fiducials before fitting.",
            ),
          )
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
                  // Per-point residuals from the (kept) solved transform.
                  let diag = case j2.alignment {
                    Some(al) -> {
                      let errs =
                        alignment.point_errors(
                          al.transform,
                          j2.pending.captured,
                        )
                      HaveFitDiag(bridge.diagnose_fit(errs, j.tol))
                    }
                    None -> NoFitDiag
                  }
                  noeff(
                    Model(
                      ..model,
                      job: HaveJob(j2),
                      quality: quality_pct(rmax, j.tol),
                      residual_max: rmax,
                      residual_rms: rrms,
                      alignment_rejected: True,
                      fit_diag: diag,
                      upload_error: "",
                    ),
                  )
                }
                _ -> noeff(Model(..model, job: HaveJob(j2)))
              }
            // A failed fit no longer silently does nothing: degenerate → geometry
            // guidance; too-few → count guidance.
            Error(job.FitDegenerate) ->
              noeff(
                Model(
                  ..model,
                  alignment_rejected: True,
                  fit_diag: HaveFitDiag(bridge.degenerate_diagnosis()),
                ),
              )
            Error(_) ->
              noeff(
                Model(
                  ..model,
                  upload_error: "Capture at least 3 well-spread fiducials.",
                ),
              )
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
    // A live fit (or override) is trusted immediately — no resume prompt.
    resume_pending: False,
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
      fit_diag: NoFitDiag,
      transform: NoTransform,
      head_pos: NoHeadPos,
      head_confidence: ConfNone,
      resume_pending: False,
    ),
  )
}

// Explicit acknowledged override: promote the rejected (over-tolerance) fit to
// Aligned on its solved transform, then apply it like a normal fit. The UI gates
// this behind a deliberate confirm, so reaching here IS the acknowledgement.
fn override_alignment(model: Model) -> #(Model, Effect(Msg)) {
  case model.job {
    HaveJob(j) ->
      case job.transition(j, job.OverrideAlignment) {
        Ok(j2) ->
          case j2.alignment {
            Some(al) -> noeff(apply_fit(model, j2, al, True))
            None -> noeff(model)
          }
        Error(_) -> noeff(model)
      }
    NoJob -> noeff(model)
  }
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
      fit_diag: NoFitDiag,
      transform: NoTransform,
      head_pos: NoHeadPos,
      head_confidence: ConfNone,
      // A restart discards the restored alignment too — clear the resume prompt.
      resume_pending: False,
    ),
  )
}

// Re-instate a restored (unconfirmed) alignment: the operator has reconnected the
// serial port and confirmed the board has NOT moved. Only legal while
// `resume_pending` is set AND the printer is reconnected (not Disconnected) — the
// restored transform must not be trusted until a live port is back. On success
// the head confidence is promoted to `ConfAligned` (trusted), the resume prompt
// clears, and the crosshair re-projects through the restored transform.
fn resume_alignment(model: Model) -> #(Model, Effect(Msg)) {
  case model.resume_pending && can_resume(model.printer) {
    False -> noeff(model)
    True ->
      case model.transform {
        HaveTransform(t) ->
          noeff(
            Model(
              ..model,
              resume_pending: False,
              head_confidence: ConfAligned,
              head_pos: HaveHeadPos(project_head(t, model.head)),
            ),
          )
        NoTransform -> noeff(Model(..model, resume_pending: False))
      }
  }
}

/// PURE guard for `ResumeAlignment`: a restored alignment may only be re-instated
/// once a live serial port is back — i.e. the printer is anything but
/// `Disconnected`. (Energizing/jogging is a separate, later gate.)
pub fn can_resume(printer: model.PrinterState) -> Bool {
  printer != Disconnected
}

/// PURE: the head confidence after a `ResumeAlignment` attempt with a restored
/// (unconfirmed) alignment. Resuming flips the restored transform to TRUSTED
/// (`ConfAligned`) ONLY when the printer is reconnected; while still
/// `Disconnected` it stays at the unconfirmed `ConfRough`. This is the heart of
/// the "never silently trust a restored transform" rule, unit-tested directly.
pub fn resume_confidence(printer: model.PrinterState) -> model.HeadConfidence {
  case can_resume(printer) {
    True -> ConfAligned
    False -> ConfRough
  }
}

// ── Stage 3/4: dry-run + drilling (streaming) ────────────────────────────────

fn run_dry_run(model: Model) -> #(Model, Effect(Msg)) {
  // A RESTORED alignment is UNCONFIRMED until the operator explicitly resumes
  // (board-hasn't-moved): refuse to dry-run it while `resume_pending` is set, so
  // an unconfirmed restored transform is never trusted into a run. This mirrors
  // the disabled "Proceed to Dry-run" button — belt-and-braces (the handler must
  // not depend on the view's gate alone).
  case model.resume_pending {
    True -> noeff(model)
    False -> run_dry_run_unguarded(model)
  }
}

fn run_dry_run_unguarded(model: Model) -> #(Model, Effect(Msg)) {
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
          issue(m, printer.Stream(gcode_program.stream_lines(program)))
        }
        _, _ -> noeff(model)
      }
    NoJob -> noeff(model)
  }
}

fn redo_alignment(model: Model) -> #(Model, Effect(Msg)) {
  // Going BACK from the dry-run: if a dry-run stream is still in flight, stop it
  // GRACEFULLY (CancelStream → Idle, stay connected) — NOT an emergency Halt
  // (M112, which would fault/disconnect). The machine hasn't moved, so the
  // captured fiducials + fitted transform stay valid; we only roll the job back
  // DryRun → Aligned and return to the Align screen. transform/captures are
  // untouched here, so the operator can re-proceed without re-aligning.
  let #(model, eff) = cancel_active_stream(model)
  let job2 = job_advance(model.job, job.RedoAlignment)
  #(Model(..model, job: job2, screen: Align, progress: NoProgress), eff)
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
          // No pre-set modal: the in-app pause is now DRIVEN by the stream FSM,
          // which raises the touch-off pause (StreamPausedAt pending=0) the moment
          // the run starts and a bit-change pause at each tool boundary. Starting
          // with a bit-change modal already up would be wrong (it precedes the
          // touch-off). `bit_label` is the first tool for the telemetry readout.
          let #(bit_change, bit_label, changes) = case program.tool_order {
            [_first, ..] -> #(
              NoBitChange,
              fmt_mm(tool_diameter(j.board, first_tool(program.tool_order)))
                <> "mm",
              int.max(list.length(program.tool_order) - 1, 0),
            )
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
          issue(m, printer.Stream(gcode_program.stream_lines(program)))
        }
        _, _ -> noeff(model)
      }
    NoJob -> noeff(model)
  }
}

fn resume_drilling(model: Model) -> #(Model, Effect(Msg)) {
  // Clear the bit-change modal and RESUME the stream. With app_pause on, the FSM
  // is genuinely paused at the bit-change sentinel (nothing in flight), so the
  // app drives the continuation: ResumeStream sends the next real line and
  // re-arms the handshake. When the printer is NOT paused (the default M0 path,
  // where the modal is informational and the stream never stops), ResumeStream is
  // a benign no-op in the pure core — so this is safe in both modes. Completion
  // stays an explicit operator step.
  let m = Model(..model, bit_change: NoBitChange)
  issue(m, printer.ResumeStream)
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
  // Fresh board (Stage 5 → Stage 1): clear all board + run state but KEEP the
  // live connection, backend, and config. Forget the persisted board so a
  // subsequent reload also starts clean (the central persist on this update will
  // then write the now-empty board slice anyway, but clearing here is explicit).
  storage.clear_session_board()
  noeff(
    Model(
      ..model,
      screen: Load,
      board: NoBoard,
      board_model: NoBoardModel,
      diagnostic: NoDiagnostic,
      job: NoJob,
      file_selected: False,
      outline_file: "",
      upload_error: "",
      pending_drl: "",
      pending_edge_cuts: "",
      head_pos: NoHeadPos,
      head_confidence: ConfNone,
      captured: [],
      captures: [],
      current_target: 0,
      transform: NoTransform,
      quality: -1,
      residual_max: 0.0,
      residual_rms: 0.0,
      alignment_rejected: False,
      fit_diag: NoFitDiag,
      progress: NoProgress,
      bit_change: NoBitChange,
      summary: NoSummary,
      bit_changes_seen: 0,
      board_side: model.Front,
      resume_pending: False,
    ),
  )
}

// ── event folding helpers ────────────────────────────────────────────────────

// Update the head readout + projected board crosshair from a live position.
fn apply_head(model: Model, x: Float, y: Float, z: Float) -> Model {
  let head = Head(x: x, y: y, z: z)
  let m = Model(..model, head: head)
  case model.transform, model.resume_pending {
    // A RESTORED-but-unconfirmed alignment must NOT be silently promoted to
    // trusted by an incoming M114 after reconnect: keep it at the lower
    // confidence (the crosshair still projects through the restored transform so
    // the operator has a visual, but it stays explicitly UNCONFIRMED until they
    // resume).
    HaveTransform(t), True ->
      Model(..m, head_pos: HaveHeadPos(project_head(t, head)))
    HaveTransform(t), False ->
      Model(
        ..m,
        head_confidence: ConfAligned,
        head_pos: HaveHeadPos(project_head(t, head)),
      )
    NoTransform, _ -> refresh_head_conf(m)
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
// MUST mirror exactly what was fed to `printer.Stream` — the sanitized
// `stream_lines`, not the rich `.lines` — so `Progress.sent` indexes the same
// list (`apply_progress` does `list.take(program, sent)`); otherwise the
// confirmed-prefix hole count would desync from the handshake on real hardware.
fn current_program(model: Model, j: job.Job) -> List(String) {
  case j.alignment, model.progress {
    Some(al), HaveProgress(p) -> {
      let mode = case p.mode {
        DrillMode -> config.Drill
        DryRunMode -> config.DryRun
      }
      let cfg = config.GcodeConfig(..model.applied_config, mode: mode)
      gcode_program.stream_lines(gcode_program.build(j.board, al, cfg))
    }
    _, _ -> []
  }
}

// Every hole emits exactly one `G0 X..` rapid (the per-hole XY rapid format);
// the postamble home is `G00 X..` and the tool lift is `G0 Z..`, so neither is
// miscounted. The per-tool bit-exchange move is ALSO a `G0 X..` rapid, but it
// carries the exchange comment, so it's excluded — it isn't a drilled hole.
fn count_holes(lines: List(String)) -> Int {
  list.count(lines, fn(l) {
    string.starts_with(l, "G0 X")
    && !string.contains(l, "bit-exchange position")
  })
}

// Fold an in-app pause into the model: raise the bit-change / resume modal so the
// operator swaps the bit before continuing. `pending` is the count of confirmed
// lines at the pause point; the upcoming tool is the LAST `T<n>` token in that
// confirmed prefix (the touch-off pause at pending 0 has none yet → the first
// tool). The streamed program is rebuilt the same way `apply_progress` does, so
// the prefix indexes the same list the handshake confirmed.
fn stream_paused(model: Model, pending: Int) -> Model {
  let diameter = case model.job {
    HaveJob(j) -> {
      let program = current_program(model, j)
      let confirmed = list.take(program, pending)
      let tool = upcoming_tool(confirmed, program, pending)
      tool_diameter(j.board, tool)
    }
    NoJob -> 0.0
  }
  // `pending == 0` is the START-OF-RUN touch-off (nothing confirmed yet): the
  // operator jogs to the fiducial and zeroes the bit — no bit to swap. Every
  // later pause is a per-tool bit change.
  let kind = case pending {
    0 -> model.TouchOff(diameter: diameter)
    _ -> model.BitChangePause(diameter: diameter)
  }
  Model(..model, bit_change: HaveBitChange(BitChange(diameter:, kind:)))
}

// The tool whose bit the operator should mount at this pause point: the most
// recent `T<n>` token in the confirmed prefix. The touch-off pause (nothing
// confirmed, or no tool token yet) reports the FIRST tool token of the whole
// program — that's the bit to load before the first block runs.
fn upcoming_tool(
  confirmed: List(String),
  program: List(String),
  pending: Int,
) -> String {
  case last_tool_token(confirmed) {
    Ok(t) -> t
    Error(_) ->
      case pending == 0 {
        True ->
          case first_tool_token(program) {
            Ok(t) -> t
            Error(_) -> "T1"
          }
        False -> "T1"
      }
  }
}

// A bare `T<n>` tool token line (the change block emits the tool id on its own
// line, e.g. "T1"). Distinct from `M6`/`G0` lines: it is exactly `T` followed by
// an integer with nothing else, so `int.parse` of the suffix succeeds.
fn is_tool_token(line: String) -> Bool {
  let t = string.trim(line)
  case string.starts_with(t, "T") {
    True ->
      case int.parse(string.drop_start(t, 1)) {
        Ok(_) -> True
        Error(_) -> False
      }
    False -> False
  }
}

fn first_tool_token(lines: List(String)) -> Result(String, Nil) {
  case list.filter(lines, is_tool_token) {
    [t, ..] -> Ok(string.trim(t))
    [] -> Error(Nil)
  }
}

fn last_tool_token(lines: List(String)) -> Result(String, Nil) {
  case list.filter(lines, is_tool_token) |> list.reverse {
    [t, ..] -> Ok(string.trim(t))
    [] -> Error(Nil)
  }
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
