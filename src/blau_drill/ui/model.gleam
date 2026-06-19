//// The UI model + messages for the blau-drill operator shell, rendered by a
//// Lustre app. This is PHASE 3: every value here is MOCK data wired in by
//// `app.gleam`.
////
//// ## Phase 4 seams (where mocks get replaced by real domain/control)
////
//// The model is deliberately a flat record of plain data so the wiring is a
//// drop-in. The seams, by field:
////
////   * `board: BoardOpt` — the parsed `.drl` (+ optional Edge.Cuts outline).
////     Phase 4 builds this from `blau_drill/domain` (BoardModel parse) instead
////     of `mock.board()`. Holes carry board coords + a tool id; the canvas fits
////     them to view from `bbox`.
////   * `head: Head` + `head_confidence` — the live machine-head XYZ and how much
////     to trust its projected board position. Phase 4 reads this from the
////     `control` layer (M114 over Web Serial) and the alignment solver; here it
////     is a static mock that the demo nudges with the jog buttons.
////   * `printer: PrinterState` — the connection FSM (Disconnected/Idle/Jogging/
////     Streaming/Faulted) mirrored from `control/transport`. The motion gates
////     (jog/spindle enabled only in `Jogging`) read off this. Phase 4 swaps the
////     mock transitions for real `control` effects.
////   * `progress: ProgressOpt` — live stream progress (sent/total holes, current
////     tool). Phase 4 folds real per-`ok` events from `control` here.
////   * `captured` / `current_target` / `quality` — alignment capture state.
////     Phase 4 feeds these from `domain/pending_alignment` + the fit solver.
////
//// The `Msg` type is the event vocabulary (the operator-facing verbs:
//// energize/jog/capture/jump_to/fit/run_dry_run/confirm/abort/...). `app.gleam`
//// owns the `update` that maps these onto the mock state; Phase 4 reroutes the
//// motion verbs through `control` effects.

import blau_drill/control/controller
import blau_drill/domain/board_model
import blau_drill/domain/config
import blau_drill/domain/job
import blau_drill/domain/transform2d.{type Point}

// ── Stage (the linear 5-stage flow) ─────────────────────────────────────────

/// The current screen. The five operator stages are linear; `Settings` is a
/// side route reachable from the header gear. `Fault` is an overlay state the
/// shell renders the fault banner over (Stage 5 fault path).
pub type Screen {
  /// Stage 1 — Load & Connect.
  Load
  /// Stage 2 — Physical Alignment.
  Align
  /// Stage 3 — Dry-run rehearsal.
  DryRun
  /// Stage 4 — Active Drilling.
  Drill
  /// Stage 5 — Completion.
  Done
  /// The printer-configuration screen.
  Settings
}

/// The stage ids for the 5-node stepper / sidebar nav, in order.
pub type StageId {
  StageLoad
  StageAlign
  StageDryRun
  StageDrill
  StageDone
}

// ── Connection / motion state machine (mirrors control/transport) ───────────

/// The printer connection mode. Motion (jog / move / spindle) is structurally
/// gated behind `Jogging` (motors energized) — the energize-before-jog
/// invariant enforced by the control state machine.
pub type PrinterState {
  Disconnected
  /// Connected, motors NOT energized. Jog/move/spindle refused here.
  Idle
  /// Motors energized (M17). Motion allowed.
  Jogging
  /// A G-code program is streaming (dry-run or drill).
  Streaming
  /// Halted / serial-loss. Loud, reachable from any motion stage.
  Faulted
}

// ── Board / holes / fiducials ───────────────────────────────────────────────

/// One drill hole, in BOARD coordinates, tagged with its tool id and run status.
pub type Hole {
  Hole(x: Float, y: Float, tool: String, status: HoleStatus)
}

/// A hole's status across a run. `Pending` = not yet drilled (drawn as a ring),
/// `Active` = the bit is on it now, `Done` = drilled (filled green).
pub type HoleStatus {
  Pending
  Active
  HoleDone
}

/// A tool: its id (e.g. "T1") and diameter in mm. The legend + true-size hole
/// radius read off this.
pub type Tool {
  Tool(id: String, diameter: Float)
}

/// A fiducial / registration marker, in BOARD coords, with its capture state.
/// `index` ties it back to the candidate list so a click can select it.
pub type Fiducial {
  Fiducial(x: Float, y: Float, index: Int, state: FiducialState)
}

/// A fiducial's three states (matching the canvas styling):
///   * `Captured` — solid green ring + check.
///   * `Current`  — the one being aligned: bright amber, blinks.
///   * `FidPending` — the rest: faded amber, click to select.
pub type FiducialState {
  Captured
  Current
  FidPending
}

/// A parsed board: holes, tools, bounding box, and an optional outline path.
pub type Board {
  Board(
    holes: List(Hole),
    tools: List(Tool),
    bbox: BBox,
    outline: List(Point),
    /// The registration candidate points (board coords), in capture order — the
    /// fiducial targets the operator aligns to.
    candidates: List(Point),
  )
}

/// `minx, miny, maxx, maxy` in board coordinates.
pub type BBox {
  BBox(minx: Float, miny: Float, maxx: Float, maxy: Float)
}

/// Option-shaped wrapper kept local so the model stays a flat record (the spike
/// idiom). No board loaded yet = `NoBoard`.
pub type BoardOpt {
  NoBoard
  HaveBoard(Board)
}

/// The board diagnostic summary shown after a parse (Stage 1).
pub type Diagnostic {
  Diagnostic(hole_count: Int, tool_count: Int, width: Float, height: Float)
}

pub type DiagnosticOpt {
  NoDiagnostic
  HaveDiagnostic(Diagnostic)
}

// ── Live head ───────────────────────────────────────────────────────────────

/// The live machine-head position (machine coords) for the bottom-bar readout,
/// plus its projected board position for the canvas crosshair.
pub type Head {
  Head(x: Float, y: Float, z: Float)
}

/// How much to trust the head's projected board position. Drives the crosshair
/// styling + caption: `ConfNone` hides the in-board marker entirely.
pub type HeadConfidence {
  ConfNone
  ConfEstimate
  ConfRough
  ConfAligned
}

/// The head's projected BOARD position (for the crosshair), or `NoHeadPos` when
/// confidence is `ConfNone` (we never fabricate a board position).
pub type HeadPosOpt {
  NoHeadPos
  HaveHeadPos(Point)
}

// ── Stream progress ─────────────────────────────────────────────────────────

/// Live stream progress for dry-run / drilling.
pub type Progress {
  Progress(drilled: Int, total: Int, mode: ProgressMode)
}

pub type ProgressMode {
  DryRunMode
  DrillMode
}

pub type ProgressOpt {
  NoProgress
  HaveProgress(Progress)
}

// ── Bit-change pause + completion summary ───────────────────────────────────

/// A per-tool M0 bit-change pause (Stage 4 modal).
pub type BitChange {
  BitChange(diameter: Float)
}

pub type BitChangeOpt {
  NoBitChange
  HaveBitChange(BitChange)
}

/// The completion summary (Stage 5).
pub type Summary {
  Summary(total_holes: Int, total_time: String, bit_changes: Int)
}

pub type SummaryOpt {
  NoSummary
  HaveSummary(Summary)
}

// ── Settings (config) ───────────────────────────────────────────────────────

/// The settings screen category nav.
pub type SettingsCategory {
  Connection
  MotionLimits
  SpindleControl
  Defaults
}

/// The working printer configuration edited on the settings screen. Plain
/// strings (as the inputs hold them); Phase 4 coerces + validates via
/// `domain`/`Config`.
pub type Config {
  Config(
    port: String,
    baud: String,
    auto_connect: Bool,
    max_x: String,
    max_y: String,
    max_z: String,
    spindle_on: String,
    spindle_off: String,
    pwm_max: String,
    spindle_speed: String,
    zdrill: String,
    zsafe: String,
    zchange: String,
    drill_feed: String,
    hover: String,
  )
}

// ── Phase 4 backing values (real control + domain) ──────────────────────────

/// Which transport the operator picked. `SimBackend` works with no hardware;
/// `RealBackend` is the Web Serial port (Chromium-only, user-gesture connect).
pub type BackendKind {
  SimBackend
  RealBackend
}

/// The captured board <-> machine pairs accumulated during registration, in
/// capture order. Phase 4 feeds these to `alignment.fit`. Each entry pairs the
/// board candidate point with the machine head XY recorded when it was captured.
pub type Capture {
  Capture(board: Point, machine: Point)
}

/// The solved transform once an alignment is fitted (board -> machine), or
/// `NoTransform` before a fit. The inverse projects the live head back to a
/// board position for the crosshair.
pub type TransformOpt {
  NoTransform
  HaveTransform(transform2d.Transform2D)
}

// ── The model ───────────────────────────────────────────────────────────────

pub type Model {
  Model(
    screen: Screen,
    printer: PrinterState,
    board: BoardOpt,
    diagnostic: DiagnosticOpt,
    /// Whether a .drl file has been "selected" in the picker (Stage 1, pre-parse).
    file_selected: Bool,
    /// Optional Edge.Cuts outline file name, "" when none selected.
    outline_file: String,
    upload_error: String,
    head: Head,
    head_pos: HeadPosOpt,
    head_confidence: HeadConfidence,
    jog_step: Float,
    captured: List(Fiducial),
    current_target: Int,
    fiducial_target: Int,
    /// Alignment quality 0..100, or -1 when not yet fitted.
    quality: Int,
    residual_max: Float,
    residual_rms: Float,
    /// True when a fit produced residuals over tolerance (recapture path).
    alignment_rejected: Bool,
    progress: ProgressOpt,
    bit_change: BitChangeOpt,
    summary: SummaryOpt,
    /// Stage-4 telemetry (current bit / eta / spindle), as display strings.
    telemetry_bit: String,
    telemetry_eta: String,
    telemetry_spindle: String,
    // canvas zoom (1.0 = whole board fits; up to 12). Pan is kept centred for
    // the mock; Phase 4 can add drag-pan as a pair of fractions.
    zoom: Float,
    // settings
    category: SettingsCategory,
    config: Config,
    config_dirty: Bool,
    // ── Phase 4: real backing state ─────────────────────────────────────────
    /// The serial control machine (pure core + chosen transport + live conn).
    controller: controller.Controller,
    /// Which transport is selected (drives the connect effect).
    backend_kind: BackendKind,
    /// The parsed board (domain), carried for gcode generation. `NoBoardModel`
    /// until a `.drl` parses.
    board_model: BoardModelOpt,
    /// The session FSM, once a board is parsed. Keeps illegal stage jumps
    /// unrepresentable in lockstep with the UI screen.
    job: JobOpt,
    /// The raw `.drl` text awaiting a parse (Stage 1, post-pick).
    pending_drl: String,
    /// The raw Edge.Cuts SVG text awaiting a parse (optional).
    pending_edge_cuts: String,
    /// The captured correspondences (board <-> machine), in capture order.
    captures: List(Capture),
    /// The solved alignment transform, once fitted.
    transform: TransformOpt,
    /// The config snapshot applied for the current run (immutable per run),
    /// taken when the run starts.
    applied_config: config.GcodeConfig,
    /// Count of bit changes seen so far in the active run (for the summary).
    bit_changes_seen: Int,
  )
}

/// Option-shaped wrapper for the parsed domain board model (carried for gcode
/// generation; distinct from the canvas-facing `Board`).
pub type BoardModelOpt {
  NoBoardModel
  HaveBoardModel(board_model.BoardModel)
}

/// Option-shaped wrapper for the session FSM.
pub type JobOpt {
  NoJob
  HaveJob(job.Job)
}

// ── Messages (the event vocabulary) ─────────────────────────────────────────

pub type Msg {
  // navigation
  GoToSettings
  GoToSession
  NavStage(StageId)

  // Stage 1 — load & connect
  SelectFile
  SelectOutline
  ParseBoard
  ConnectDevice
  DisconnectDevice
  StartRegistering
  /// Load the built-in sample board (segby_v1) so the demo runs with no file
  /// dialog. Picks the .drl + outline from the bundled fixture text.
  LoadSample
  /// Choose the transport backend (Simulator vs real Web Serial).
  SelectBackend(BackendKind)

  // Phase-4 async results (folded back into the model from effects)
  /// A picked `.drl` file's text arrived from the browser file picker.
  DrlPicked(Result(String, String))
  /// A picked Edge.Cuts `.svg` file's text arrived.
  OutlinePicked(Result(String, String))
  /// A `ControllerMsg` bridged back into the UI loop (open/inbound/write/lost).
  ControllerEvent(controller.ControllerMsg)

  // Stage 2 — alignment
  Energize
  Release
  SetJogStep(Float)
  Jog(axis: String, sign: Float)
  TestSpindle
  /// Canvas: select a registration candidate as the current target.
  SetCurrentTarget(Int)
  /// Canvas: rapid the head to a board point (click-to-jump).
  JumpTo(Point)
  CaptureFiducial
  Fit
  Recapture
  RestartAlignment
  RunDryRun

  // Stage 3 — dry-run
  RedoAlignment
  ConfirmRegistration

  // Stage 4 — drilling
  ResumeDrilling
  Complete

  // Stage 5 / fault
  NewBoard
  Reconnect

  // global
  Abort

  // canvas zoom/pan (kept in the model so the canvas stays a pure view)
  ZoomIn
  ZoomOut
  ResetView

  // settings
  SelectCategory(SettingsCategory)
  SetConfigField(field: String, value: String)
  ToggleAutoConnect
  ResetDefaults
  ApplyConfig
}
