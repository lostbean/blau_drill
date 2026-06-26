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
import blau_drill/ui/bridge
import blau_drill/ui/mock
import blau_drill/ui/model.{
  type BackendKind, type Model, type Msg, Align, ApplyConfig, CancelRelease,
  Complete, ConfirmRegistration, ConfirmReleaseMotors, ConnectDevice, Connection,
  ControllerEvent, DisconnectDevice, Done, Drill, DrlPicked, DryRun, EmuBackend,
  Energize, Fit, GoToSession, GoToSettings, HaveBoard, HaveBoardModel,
  HaveDiagnostic, HaveJob, Head, Jog, JumpTo, Load, LoadSample, Model, NavStage,
  NewBoard, NoBoard, NoBoardModel, NoDiagnostic, NoJob, NoOverlay, OutlinePicked,
  ParseBoard, RealBackend, Recapture, Reconnect, RedoAlignment, Release,
  ResetDefaults, ResetView, RestartAlignment, ResumeDrilling, RunDryRun,
  SelectBackend, SelectCategory, SelectFile, SelectOutline, SetConfigField,
  SetCurrentTarget, SetJogStep, Settings, SimBackend, StartRegistering,
  TestSpindle, ToggleAppPause, ToggleAutoConnect,
}
import blau_drill/ui/projection
import blau_drill/ui/sample
import blau_drill/ui/session
import blau_drill/ui/shell
import blau_drill/ui/stages
import blau_drill/ui/storage
import gleam/float
import gleam/javascript/promise
import gleam/list
import gleam/option.{None, Some}
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
      overlay: NoOverlay,
      board: NoBoard,
      diagnostic: NoDiagnostic,
      file_selected: session.drl != "",
      outline_file: session.outline_file,
      upload_error: "",
      head: Head(0.0, 0.0, 0.0),
      jog_step: session.jog_step,
      current_target: 0,
      fiducial_target: 4,
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
      applied_config: bridge.gcode_config(cfg, config.DryRun),
      board_side: model.Front,
      release_confirm: False,
      comms_log: [],
    )
  // Re-parse the restored board (deterministic; no hardware). If the stored DRL
  // is empty or fails to parse, `parse_board` leaves the model board-less.
  let #(m, _) = case session.drl {
    "" -> #(m, effect.none())
    _ -> parse_board(m)
  }
  // Apply the URL-hash stage, CAPPED to a safe restore target: never restore
  // into a connection/alignment-dependent stage (DryRun/Drill/Done), and never
  // into Align without a board. Anything else collapses to Load. The screen is
  // DERIVED from the job (ADR-0012), so restoring a stage = putting the real
  // machine into the matching state, not setting a screen field:
  //   * Align    → advance the job Parsed → Registering (re-register, blank slate)
  //   * Settings → open the Settings overlay
  //   * anything else (incl. Load) → leave the job in Parsed → derives to Load
  let m = case restore_screen(m) {
    // Restoring into Align is a BLANK SLATE (ADR-0011): alignment/position is
    // valid only while the motors stay continuously energized, and a page refresh
    // is a new runtime, so nothing is ever restored. We only advance the job FSM
    // Parsed → Registering (exactly as "Proceed to Align" does — else the job
    // stays in Parsed and Capture silently no-ops); the operator re-captures from
    // scratch. There is no persisted alignment to load.
    Align -> {
      let #(m2, _) = start_registering(m)
      m2
    }
    Settings -> Model(..m, overlay: model.SettingsOpen)
    _ -> m
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

pub fn backend_for(kind: BackendKind) -> backend.Backend {
  case kind {
    SimBackend -> transport.simulator()
    RealBackend -> transport.web_serial()
    EmuBackend -> transport.emulator()
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
  // ADR-0011: alignment/position is NEVER persisted — it is valid only while the
  // motors stay continuously energized, and a refresh is a new runtime that
  // invalidates it. localStorage holds CONFIG + board-source + UI prefs only.
  // The screen is DERIVED (ADR-0012), so persist the projection, not a field.
  storage.save_screen(current_screen(model))
  Nil
}

// ── the Session: the single source of truth for stage + wire + screen ─────────

/// The current `Session` (ADR-0012), DERIVED from the app's real machines: the
/// `job` FSM (stage), the controller's REAL `printer.PrinterState` (wire), and
/// the parsed board. Recomputed on demand rather than stored, so it can never be
/// a second authority that drifts — it is a pure projection of the machines the
/// handlers already own. The wire is the controller's state (the ONE printer),
/// so the Session always reflects the genuine wire after the controller advances.
fn current_session(model: Model) -> session.Session {
  session.of(model.job, model.board, controller.state(model.controller))
}

/// The current screen, PROJECTED from the Session + overlay. There is no stored
/// screen field a handler could set to contradict the machines (ADR-0012).
fn current_screen(model: Model) -> model.Screen {
  session.screen(current_session(model), model.overlay)
}

fn update_inner(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    // navigation. The lifecycle SCREEN is derived from the job (ADR-0012), so
    // nav only opens/closes a side-route OVERLAY — it never moves the lifecycle
    // (the job is the authority) and never disconnects or clears the alignment
    // (the machine hasn't physically moved). Returning to the session (closing an
    // overlay) cancels any in-flight dry-run stream GRACEFULLY (→ Jogging, still
    // connected), never via Halt.
    GoToSettings -> noeff(Model(..model, overlay: model.SettingsOpen))
    GoToSession -> close_overlay(model)
    model.GoToLog -> noeff(Model(..model, overlay: model.LogOpen))
    model.ClearLog -> noeff(Model(..model, comms_log: []))
    // The stepper nav is not interactive (no clickable nodes); keep the Msg
    // compiling by closing any overlay (the lifecycle stays job-driven).
    NavStage(_) -> close_overlay(model)

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
    Release -> release(model)
    ConfirmReleaseMotors -> confirm_release(model)
    CancelRelease -> noeff(Model(..model, release_confirm: False))
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

// Close any side-route overlay (return to the lifecycle screen), first cancelling
// an in-flight dry-run stream GRACEFULLY (CancelStream → Jogging, still connected)
// so we never leave a zombie stream on the controller. Crucially this does NOT
// touch transform/captures/job, so the alignment survives — only the overlay
// closes (and the stream, if any, stops cleanly without faulting/disconnecting).
fn close_overlay(model: Model) -> #(Model, Effect(Msg)) {
  let #(model, eff) = cancel_active_stream(model)
  #(Model(..model, overlay: NoOverlay), eff)
}

// If a stream is currently in flight, issue a benign CancelStream (→ Jogging,
// stays connected, no M112, no fault). Otherwise a no-op. This is the single
// place "leaving an active stream via navigation" is handled gracefully. Reads
// the REAL wire state off the Session (ADR-0012).
fn cancel_active_stream(model: Model) -> #(Model, Effect(Msg)) {
  case session.is_streaming(current_session(model)) {
    True -> issue(model, printer.CancelStream)
    False -> noeff(model)
  }
}

// ── controller bridge ────────────────────────────────────────────────────────

/// Issue an operator command through the controller, then react to the result.
fn issue(model: Model, cmd: printer.Command) -> #(Model, Effect(Msg)) {
  apply_controller(model, controller.Issue(cmd))
}

/// Run a STAGE-FLOW action (ADR-0012): build the current `Session`, apply
/// `action` via `session.transition`, and on success store the next job
/// (`model.job` stays in lockstep with the Session's nested job — ONE job) plus
/// any `extra` model updates, then execute the returned `Plan` (the ordered
/// `List(printer.Command)`) through the controller IN ORDER. A `Rejected`
/// transition writes NOTHING — the model is returned unchanged (the safety
/// invariant: never a half-applied cross-machine move).
fn flow(
  model: Model,
  action: session.Action,
  extra: fn(Model) -> Model,
) -> #(Model, Effect(Msg)) {
  case session.transition(current_session(model), action) {
    Ok(#(next, plan)) -> {
      // The Session's nested job is the advanced stage; mirror it onto model.job.
      let m = extra(Model(..model, job: session.job_opt(next)))
      run_plan(m, plan)
    }
    // Refused: nothing is written, nothing is issued.
    Error(_) -> noeff(model)
  }
}

/// Execute a `Plan` — the ordered `List(printer.Command)` a Session transition
/// returned — through the controller, IN ORDER. Each command is applied
/// sequentially (the model from one feeds the next), so the STATE ordering that
/// matters (e.g. CancelStream BEFORE Stream, so the drill is not refused `Busy`)
/// is guaranteed. Each command's own framed writes already go out in a single
/// ordered controller effect; the per-command effects are combined without
/// reordering any order-dependent write burst.
fn run_plan(
  model: Model,
  plan: List(printer.Command),
) -> #(Model, Effect(Msg)) {
  list.fold(plan, #(model, effect.none()), fn(acc, cmd) {
    let #(m, eff) = acc
    let #(m2, eff2) = issue(m, cmd)
    #(m2, effect.batch([eff, eff2]))
  })
}

/// Route a `ControllerMsg` through `controller.update`, store the next
/// controller, map its printer state into the UI gates, fold its events into the
/// model, and lift its effect into the UI Msg space.
fn apply_controller(
  model: Model,
  cmsg: controller.ControllerMsg,
) -> #(Model, Effect(Msg)) {
  let out = controller.update(model.controller, cmsg)
  // The controller owns the ONE real `printer.PrinterState`; storing it here is
  // gone (ADR-0012). The Session reads it back via `controller.state` on demand,
  // so the wire is reflected with no second copy that could drift.
  let m1 =
    Model(
      ..model,
      controller: out.controller,
      comms_log: append_log(model.comms_log, out.log),
    )
  let #(m2, ev_effects) = fold_events(m1, out.events)
  let ctrl_effect = effect.map(out.effect, ControllerEvent)
  #(m2, effect.batch([ctrl_effect, ev_effects]))
}

/// Max serial-log entries kept (a ring — oldest dropped). Bounds memory + render.
const log_cap = 500

/// Stamp each control-layer `LogLine` with a wall-clock time, map it to a
/// `model.LogEntry`, append (newest LAST), and keep only the most recent
/// `log_cap`. The timestamp is read at this effect edge — the pure core never
/// reads the clock.
fn append_log(
  existing: List(model.LogEntry),
  lines: List(controller.LogLine),
) -> List(model.LogEntry) {
  case lines {
    [] -> existing
    _ -> {
      let stamped =
        list.map(lines, fn(l) {
          let #(dir, text) = case l {
            controller.LogTx(s) -> #(model.Tx, s)
            controller.LogRx(s) -> #(model.Rx, s)
            controller.LogNote(s) -> #(model.Note, s)
          }
          model.LogEntry(at_ms: storage.now_ms(), dir: dir, line: text)
        })
      let combined = list.append(existing, stamped)
      // Keep the most recent `log_cap` (drop from the front when over).
      let over = list.length(combined) - log_cap
      case over > 0 {
        True -> list.drop(combined, over)
        False -> combined
      }
    }
  }
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
    // The live position from an M114 reply: update the head readout (the crosshair
    // + confidence are projections of it now, ADR-0018).
    printer.PositionUpdate(pos) -> noeff(apply_head(model, pos.x, pos.y, pos.z))

    // One confirmed stream line. The progress ring + per-hole board status + ETA
    // are now PROJECTIONS of the FSM's `StreamJob` (ADR-0018): `projection.progress`
    // / `projection.board` read the confirmed prefix's typed `DrillHoleKind` origins
    // off `printer.stream_rendered`/`stream_progress` (ADR-0017). The FSM has
    // already advanced its `idx` by the time this event folds, so there is nothing
    // to hand-sync — the next render reads the new position straight from the FSM.
    printer.Progress(_sent, _total, _line, _origin) -> noeff(model)

    // The stream finished. The FSM has dropped to Idle (the standing "fully
    // streamed" signal the progress/board projections read); completion stays an
    // explicit operator step (Mark Complete on Drill; Confirm on DryRun). Nothing
    // to fold.
    printer.StreamComplete -> noeff(model)

    // The stream halted at an in-app pause point (app_pause on; a swapped-in
    // sentinel where an M0 would be). The bit-change / resume modal is a PROJECTION
    // of the FSM's standing `StreamPaused` state (ADR-0018) — `projection.bit_change`
    // reads the paused line's typed `origin.pause` (ADR-0017) — so there is no
    // event-driven field to set here.
    printer.StreamPausedAt(_pending, _total, _reason) -> noeff(model)

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
  // ADR-0011: a disconnect de-energizes the motors, so it invalidates the
  // alignment (involuntary → no confirm). Reset it in lockstep with the job FSM.
  // The wire state lives on the controller now (ADR-0012), so just store it.
  let m = deenergize_reset(Model(..model, controller: ctrl))
  #(m, effect.map(eff, ControllerEvent))
}

fn start_registering(model: Model) -> #(Model, Effect(Msg)) {
  // Advance the job FSM Parsed → Registering and snapshot the config for the run.
  // The alignment-derived values (captures, transform, quality, head pose, …) are
  // PROJECTIONS of the job (ADR-0018), so the `StartRegistering` transition — which
  // lands in a fresh `Registering` with an empty `pending` and no `alignment` —
  // resets them by construction. No hand-sync needed. Only the operator's selected
  // target (a parameter) is reset.
  let job2 = job_advance(model.job, job.StartRegistering)
  noeff(
    Model(
      ..model,
      job: job2,
      applied_config: bridge.gcode_config(model.config, config.DryRun),
      current_target: 0,
    ),
  )
}

// ── Stage 2: alignment ───────────────────────────────────────────────────────

fn jog(model: Model, axis: String, sign: Float) -> #(Model, Effect(Msg)) {
  // Gate off the REAL printer state (the Session's nested wire) — the pure core
  // also refuses if not Jogging, writing nothing, but we avoid even issuing when
  // not energized.
  case session.is_jogging(current_session(model)) {
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
  case session.is_jogging(current_session(model)) {
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
  case
    current_screen(model) == Align && session.is_jogging(current_session(model))
  {
    False -> noeff(model)
    True ->
      // The best transform + the captures are PROJECTIONS of the job now
      // (ADR-0018) — compute them for the estimate.
      case
        bridge.board_to_machine(
          projection.transform(model),
          projection.captures(model),
          point,
        )
      {
        // ADR-0011: with NO captures and NoTransform the estimate Errors, so a
        // jump is a strict no-op (no phantom origin) — the operator must jog to
        // fiducial 1 and capture it first to establish the board↔machine relation.
        Error(_) -> noeff(model)
        Ok(#(mx, my)) -> {
          // SAFE pre-fit jump (ADR-0011): lift Z by a RELATIVE amount (the
          // configured z-safe rise), travel XY high, then STOP — no absolute
          // descend (pre-fit there is no surface datum, so an absolute Z could
          // plunge; a relative up-lift can't). The operator jogs down onto the
          // target. The burst ends with M114, so the settled position reads
          // without a race.
          let cfg = model.applied_config
          issue(model, printer.MoveTo(mx, my, cfg.zsafe))
        }
      }
  }
}

// Capture the current target candidate paired with the live head XY. Requires
// motors energized (so a real M114 has been read) and the job in Registering.
fn capture(model: Model) -> #(Model, Effect(Msg)) {
  case session.is_jogging(current_session(model)), model.job, model.board {
    True, HaveJob(j), HaveBoard(board) ->
      case can_capture(j) {
        False -> noeff(model)
        True -> {
          let idx = model.current_target
          case list_at(board.candidates, idx) {
            Error(_) -> noeff(model)
            Ok(#(bx, by)) -> {
              // Already captured? The captured set is PROJECTED from the job's
              // pending correspondences (ADR-0018), so check those, not a shadow.
              let already =
                list.any(projection.captured(model), fn(f) { f.index == idx })
              case already {
                True -> noeff(model)
                False -> {
                  let machine = #(model.head.x, model.head.y)
                  // The live M114 head Z is the bit-down height the operator
                  // jogged to on the pad — exactly the surface Z the plane fit
                  // wants. Carry it into the correspondence (2.5D alignment); the
                  // job's `pending.captured` is now the SOLE home for captures.
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
                  // Advance the operator's selected target to the next uncaptured
                  // candidate (projected from the job's pending captures).
                  let m2 = Model(..model, job: HaveJob(j2))
                  let next =
                    next_uncaptured(board.candidates, projection.captured(m2))
                  noeff(Model(..m2, current_target: next))
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

// Fit: drive the job FSM Fit(tol). The job FSM stores the solved alignment +
// residuals + the resulting state (Aligned / AlignmentRejected) ITSELF, so this
// handler just advances the job — quality, residuals, the rejected flag, the
// fit diagnosis, the transform, and the head pose are all PROJECTIONS of the
// job (ADR-0018), read by the views via `ui/projection`. A degenerate / too-few
// fit does NOT transition the job; we surface guidance via `upload_error`.
fn fit(model: Model) -> #(Model, Effect(Msg)) {
  case model.job {
    HaveJob(j) ->
      // The ≥3-captures rule has a SINGLE runtime authority: `alignment.fit`
      // (via `job.transition`, which maps a too-few fit to `FitTooFew`). We drive
      // the transition directly and let the result arms carry guidance — no
      // redundant pre-check here.
      case job.transition(j, job.Fit(j.tol)) {
        // Aligned or AlignmentRejected: store the advanced job; the rejected
        // box + quality panel project off `job.state` / `job.alignment` /
        // `job.residuals`.
        Ok(j2) -> noeff(Model(..model, job: HaveJob(j2), upload_error: ""))
        // A failed fit no longer silently does nothing: degenerate → geometry
        // guidance; too-few (and any other) → count guidance. (The job stays
        // Registering, so the rejected-box projection is empty — the guidance
        // rides the upload-error path.)
        Error(job.FitDegenerate) ->
          noeff(
            Model(
              ..model,
              upload_error: "Capture at least 3 well-spread (non-collinear) fiducials.",
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
    NoJob -> noeff(model)
  }
}

fn recapture(model: Model) -> #(Model, Effect(Msg)) {
  // AlignmentRejected → Registering (a clean slate on the job: pending/alignment/
  // residuals wiped by the FSM). The alignment-derived projections follow; only
  // the operator's selected target is reset here.
  let job2 = job_advance(model.job, job.Recapture)
  noeff(Model(..model, job: job2, current_target: 0, upload_error: ""))
}

// Explicit acknowledged override: promote the rejected (over-tolerance) fit to
// Aligned on its already-solved transform. The UI gates this behind a deliberate
// confirm, so reaching here IS the acknowledgement. The job FSM carries the solved
// alignment forward; quality/transform/head-pose are projections of the now-Aligned
// job (ADR-0018), so this handler just stores the advanced job.
fn override_alignment(model: Model) -> #(Model, Effect(Msg)) {
  case model.job {
    HaveJob(j) ->
      case job.transition(j, job.OverrideAlignment) {
        Ok(j2) -> noeff(Model(..model, job: HaveJob(j2)))
        Error(_) -> noeff(model)
      }
    NoJob -> noeff(model)
  }
}

fn restart_alignment(model: Model) -> #(Model, Effect(Msg)) {
  // Start the whole alignment over. The FSM's `RestartAlignment` lands in a fresh
  // `Registering` (pending/alignment/residuals wiped), so every alignment-derived
  // projection (captures, transform, quality, head pose, …) resets by
  // construction (ADR-0018). Only the operator's selected target is reset here.
  let job2 = job_advance(model.job, job.RestartAlignment)
  noeff(Model(..model, job: job2, current_target: 0, upload_error: ""))
}

// ── Stage 3/4: dry-run + drilling (streaming) ────────────────────────────────

fn run_dry_run(model: Model) -> #(Model, Effect(Msg)) {
  // Only legal from Aligned with a solved transform; the Session (delegating to
  // the job FSM) gates it. Build the dry-run program, route the move through
  // `session.transition(RunDryRun(lines))`, and execute the returned Plan
  // (`[Stream(dry_run)]`) in ONE ordered effect (ADR-0012).
  case model.job {
    HaveJob(j) ->
      case job.can(j, job.RunDryRunE), j.alignment {
        True, Some(al) -> {
          let cfg =
            config.GcodeConfig(..model.applied_config, mode: config.DryRun)
          // Build the typed op list + render to Wire `RenderedLine`s (ADR-0017):
          // each line carries its framed wire text + the typed origin the FSM
          // pauses on and the app reads progress/tool from. NEVER a bare
          // `List(String)` the consumers would have to re-parse.
          let rendered = render_wire(j.board, al, cfg)
          // The progress ring + per-hole board status are PROJECTIONS of the
          // streaming FSM (ADR-0018): once the Session transition puts the FSM
          // into Streaming, `projection.progress`/`projection.board` read 0/N and
          // all-Pending off the StreamJob — no hand-reset of the board or progress.
          flow(model, session.RunDryRun(rendered), fn(m) { m })
        }
        _, _ -> noeff(model)
      }
    NoJob -> noeff(model)
  }
}

fn redo_alignment(model: Model) -> #(Model, Effect(Msg)) {
  // Going BACK from the dry-run (Rehearsing → Aligning). The Session transition
  // returns `Plan[CancelStream]`, which stops the in-flight dry-run stream
  // GRACEFULLY (→ Jogging, stay connected) — NOT an emergency Halt. The machine
  // hasn't moved, so the captured fiducials + fitted transform stay valid; the
  // job rolls DryRun → Aligned and the screen derives back to Align. Progress is
  // a projection — `Aligned` is not a streaming stage, so it reads `NoProgress`.
  flow(model, session.RedoAlignment, fn(m) { m })
}

fn confirm_registration(model: Model) -> #(Model, Effect(Msg)) {
  // THE BUG FIX (ADR-0012). DryRun → Drilling is ONE Session transition that
  // returns `Plan[CancelStream, Stream(drill)]` — the cancel of the IN-FLIGHT
  // dry-run stream precedes the drill stream IN THE SAME ORDERED EFFECT, so the
  // drill can never be refused `Busy` (the old three un-atomic writes did, leaving
  // the UI on Drill / 0% with the dry-run still running). `Drilling` is
  // constructible ONLY by this transition.
  case model.job {
    HaveJob(j) ->
      case job.can(j, job.ConfirmRegistrationE), j.alignment {
        True, Some(al) -> {
          let cfg =
            config.GcodeConfig(..model.applied_config, mode: config.Drill)
          // Build the typed op list + render to Wire `RenderedLine`s (ADR-0017).
          let rendered = render_wire(j.board, al, cfg)
          // The progress ring, per-hole board status, the bit-change modal, the
          // bit-change count, and the telemetry strings are all PROJECTIONS now
          // (ADR-0018): once the Session transition puts the FSM into Streaming,
          // `projection.*` read them off the StreamJob + the run's `applied_config`
          // + `tool_order`. No hand-set modal, count, or telemetry here.
          flow(model, session.ConfirmRegistration(rendered), fn(m) { m })
        }
        _, _ -> noeff(model)
      }
    NoJob -> noeff(model)
  }
}

fn resume_drilling(model: Model) -> #(Model, Effect(Msg)) {
  // RESUME the stream. With app_pause on, the FSM is genuinely paused at the
  // bit-change sentinel (nothing in flight), so the app drives the continuation:
  // ResumeStream sends the next real line and re-arms the handshake. When the
  // printer is NOT paused (the default M0 path, where the modal is informational
  // and the stream never stops), ResumeStream is a benign no-op in the pure core
  // — so this is safe in both modes. The bit-change modal is a PROJECTION of the
  // FSM's paused state (ADR-0018): leaving the paused state clears it, with no
  // field to reset. Completion stays an explicit operator step.
  issue(model, printer.ResumeStream)
}

fn complete(model: Model) -> #(Model, Effect(Msg)) {
  // Drilling → Completed (the screen derives to Done). Plan is empty. The
  // completion summary is a PROJECTION of the now-`Done` job + the board hole
  // count + `applied_config` (ADR-0018), so this handler just advances the job —
  // `projection.summary` builds the totals/time/bit-changes off the standing
  // `Done` state.
  flow(model, session.MarkComplete, fn(m) { m })
}

// ── fault / recover / new board ──────────────────────────────────────────────

fn abort(model: Model) -> #(Model, Effect(Msg)) {
  // Emergency abort (ADR-0012): from any ACTIVE Session, `session.Abort` returns
  // `Plan[Halt]` and rolls to Faulted. `run_plan` issues the M112 Halt through the
  // controller, whose `Faulting` event the fold then handles (job reset + fault
  // banner). M112 stays reachable from every motion stage. From a non-active
  // Session (Loading) there is nothing on the wire to halt → a benign no-op.
  case session.transition(current_session(model), session.Abort) {
    Ok(#(_next, plan)) -> run_plan(model, plan)
    // Not an active wire state (nothing to halt) — but keep the hard guarantee:
    // a raw Halt is still issued so an emergency stop is NEVER swallowed.
    Error(_) -> issue(model, printer.Halt)
  }
}

fn fault(model: Model) -> Model {
  // A fault is an involuntary de-energize / trust loss (ADR-0011): the alignment
  // can no longer be trusted from ANY state, so clear it in lockstep with the job.
  //   * mid-drill: SerialLoss is legal from Drilling → job goes Faulted (the
  //     fault BANNER, driven off the controller's `printer == Faulted`, is
  //     preserved either way), and we also clear the alignment slate.
  //   * any alignment state (Registering/Aligned/AlignmentRejected/DryRun): route
  //     the job reset through `Deenergize` (→ Parsed, alignment discarded).
  // Either path also clears the model alignment/position fields via
  // `deenergize_reset` below, so a later move can't act on a stale transform.
  // The alignment-derived projections (transform/captures/quality/head pose/…)
  // and the bit-change / progress projections all follow the job + FSM state, so
  // routing the job to Faulted (mid-drill) or Parsed (de-energize from an
  // alignment state) is the WHOLE reset — no fields to clear (ADR-0018). Only the
  // confirm-gate parameter is dropped (a fault overrides any pending release).
  let job2 = case model.job {
    HaveJob(j) ->
      case job.transition(j, job.SerialLoss("abort")) {
        // Mid-drill fault: keep the Faulted job (Reconnect re-registers).
        Ok(jj) -> HaveJob(jj)
        // Not mid-drill: de-energize-reset the job (alignment states → Parsed;
        // benign no-op elsewhere) so the alignment never survives the fault.
        Error(_) -> job_advance(model.job, job.Deenergize)
      }
    NoJob -> NoJob
  }
  Model(..model, job: job2, release_confirm: False)
}

fn reconnect(model: Model) -> #(Model, Effect(Msg)) {
  // Controller Reconnect (Faulted → Idle) emits Recovered, which routes the job
  // Faulted → Parsed (ADR-0011: no trusted transform survives a fault; re-register
  // from a clean slate). The screen then DERIVES back to Load (ADR-0012: Faulted →
  // Loading on reconnect). Progress + the bit-change modal are projections of the
  // FSM/job, so reconnecting clears them by construction — nothing to hand-reset.
  issue(model, printer.Reconnect)
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
  // Clearing the board + the job (→ NoJob) resets every alignment/run PROJECTION
  // by construction (ADR-0018) — captures, transform, quality, progress, the
  // bit-change modal, the summary, telemetry all read NoJob/NoBoard. Only the
  // genuine PARAMETERS are reset here.
  noeff(
    Model(
      ..model,
      board: NoBoard,
      board_model: NoBoardModel,
      diagnostic: NoDiagnostic,
      job: NoJob,
      file_selected: False,
      outline_file: "",
      upload_error: "",
      pending_drl: "",
      pending_edge_cuts: "",
      current_target: 0,
      board_side: model.Front,
    ),
  )
}

// ── de-energize trust boundary (ADR-0011) ────────────────────────────────────

// Operator-initiated "Disable Motors". THE INVARIANT (ADR-0011): position /
// alignment is valid ONLY while the motors stay continuously energized, so a
// de-energize invalidates the alignment. A VOLUNTARY release that would discard a
// non-trivial alignment is anti-surprise: raise a confirm gate first instead of
// silently throwing the alignment away. With nothing to lose, release directly.
fn release(model: Model) -> #(Model, Effect(Msg)) {
  case is_energized(model) && has_alignment(model) {
    True -> noeff(Model(..model, release_confirm: True))
    False -> release_now(model)
  }
}

// Confirm a destructive release: actually de-energize AND reset the alignment.
fn confirm_release(model: Model) -> #(Model, Effect(Msg)) {
  release_now(Model(..model, release_confirm: False))
}

// Issue the real motor release, then reset the alignment in lockstep (the
// de-energize trust boundary). Used by both the direct path and the confirmed one.
fn release_now(model: Model) -> #(Model, Effect(Msg)) {
  let #(m, eff) = issue(model, printer.Release)
  #(deenergize_reset(m), eff)
}

// PURE: whether there is a non-trivial alignment that a de-energize would discard
// (so a voluntary Release must confirm first). True once registration has started
// (the job left `Parsed`) OR captures exist — both PROJECTED from the job now
// (ADR-0018), not read off a shadow.
fn has_alignment(model: Model) -> Bool {
  let job_has = case model.job {
    HaveJob(j) ->
      case j.state {
        // Parsed: not registering yet. Registering and beyond: captures exist.
        job.Parsed -> False
        _ -> True
      }
    NoJob -> False
  }
  job_has || projection.captures(model) != []
}

fn is_energized(model: Model) -> Bool {
  session.is_jogging(current_session(model))
}

// Drive a de-energize through the job FSM and clear the release-confirm gate. The
// FSM's `Deenergize` lands the job in `Parsed` (alignment states) — a clean slate
// — so every alignment/position PROJECTION resets by construction (ADR-0018);
// `release_confirm` is the only parameter to reset (current_target is reset on the
// next StartRegistering). No fields to hand-clear.
fn deenergize_reset(model: Model) -> Model {
  Model(
    ..model,
    job: job_advance(model.job, job.Deenergize),
    current_target: 0,
    release_confirm: False,
  )
}

// ── event folding helpers ────────────────────────────────────────────────────

// Update the live head readout from an M114 reply. The head's PROJECTED board
// crosshair + confidence are projections of `(transform, captures, head)` now
// (ADR-0018, `ui/projection.head_pos`/`head_confidence`), recomputed each frame
// — so this just stores the new live machine XYZ; nothing else to hand-sync.
fn apply_head(model: Model, x: Float, y: Float, z: Float) -> Model {
  Model(..model, head: Head(x: x, y: y, z: z))
}

// Render the typed op list to Wire `RenderedLine`s — the exact program fed to
// `printer.Stream` (ADR-0017). The producers (`run_dry_run`,
// `confirm_registration`) build the streamed program through this.
fn render_wire(
  board: board_model.BoardModel,
  al: alignment.Alignment,
  cfg: config.GcodeConfig,
) -> List(gcode_program.RenderedLine) {
  let ops = gcode_program.build_ops(board, al, cfg)
  let ctx = gcode_program.render_context(board, al, cfg)
  gcode_program.render(ops, ctx, gcode_program.Wire)
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
    "drill_plunge_feed" -> model.Config(..c, drill_plunge_feed: value)
    "drill_xy_feed" -> model.Config(..c, drill_xy_feed: value)
    "drill_retract_feed" -> model.Config(..c, drill_retract_feed: value)
    "hover" -> model.Config(..c, hover: value)
    _ -> c
  }
  Model(..model, config: c2, config_dirty: True)
}

// ── helpers ──────────────────────────────────────────────────────────────────

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
  // The screen is DERIVED from the Session + overlay (ADR-0012) — there is no
  // stored screen field. Settings / Log are full-screen overlays; everything else
  // renders the operator shell.
  case current_screen(model) {
    Settings -> stages.settings(model)
    model.Log -> stages.comms_log(model)
    _ -> session_view(model)
  }
}

fn session_view(model: Model) -> Element(Msg) {
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
  // The loud fault banner shows whenever the REAL wire is Faulted (ADR-0012).
  case session.is_faulted(current_session(model)) {
    True -> shell.fault_banner()
    False -> element.none()
  }
}

fn stage_main(model: Model) -> Element(Msg) {
  case current_screen(model) {
    Load -> load_with_sample(model)
    Align -> stages.align(model)
    DryRun -> stages.dry_run(model)
    Drill -> stages.drill(model)
    Done -> stages.done(model)
    Settings -> stages.load(model)
    // Log is intercepted by `view` (full screen, like Settings); unreachable here.
    model.Log -> stages.load(model)
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
