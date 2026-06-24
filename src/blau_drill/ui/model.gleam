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

// ── Board side (which face is up in the printer) ────────────────────────────

/// Which face of the board is up in the printer.
///
/// This drives the BOARD TRANSFORM applied once, upstream, to produce the WORKING
/// board model (`bridge.working_board_model`): `Front` is the identity, `Back` is
/// an X-mirror about the board centre (copper up — the board is physically
/// flipped). The canvas board, the alignment job, and the G-code all derive from
/// that single transformed model, so every path (display, click-to-jump,
/// generated G-code) stays consistent — the flip lives in exactly one place.
///
/// It is a Stage-1 / pre-registration choice: once registration starts the
/// working geometry is fixed for the session (captures are against that
/// orientation), so the toggle locks. See ADR (board-transform pipeline).
pub type BoardSide {
  /// Front face up — working geometry in the `.drl`'s native orientation.
  Front
  /// Back (copper) up — working geometry X-mirrored to match the flipped board.
  Back
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

// ── Alignment-fit diagnostics ───────────────────────────────────────────────

/// One captured point's residual for the per-fiducial diagnostics list.
/// `index` is 0-based (the UI shows 1-based); `error_mm` is its residual.
pub type PointResidual {
  PointResidual(index: Int, error_mm: Float)
}

/// Actionable read on a fit: per-point residuals, the worst point, a hint, and
/// whether an override is available (a transform was solved). `bridge.diagnose_fit`
/// builds this; the rejected-fit panel renders it.
pub type FitDiag {
  FitDiag(
    points: List(PointResidual),
    worst: WorstOpt,
    hint: String,
    /// True when the fit solved a transform (so override is possible); False for
    /// degenerate/too-few fits (recapture only).
    can_override: Bool,
  )
}

pub type WorstOpt {
  NoWorst
  HaveWorst(PointResidual)
}

pub type FitDiagOpt {
  NoFitDiag
  HaveFitDiag(FitDiag)
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

// ── Stream pause (touch-off / bit change) + completion summary ──────────────

/// What an in-app stream pause is FOR. The touch-off pause (the FIRST pause, at
/// the start of a run) asks the operator to jog the bit to the surface and zero
/// it — there is no bit to swap; a bit-change pause asks them to swap to a given
/// drill size. Both resume via `ResumeDrilling`, but they read very differently.
pub type PauseKind {
  /// Start-of-run touch-off: jog to the fiducial, lower the bit until it touches,
  /// zero, then resume. `diameter` is the FIRST tool's size (informational).
  TouchOff(diameter: Float)
  /// A per-tool bit change: swap to `diameter` mm, then resume.
  BitChangePause(diameter: Float)
}

/// An in-app stream pause (Stage 3/4 modal). `kind` says whether it is the
/// start-of-run touch-off or a per-tool bit change so the modal reads correctly.
pub type BitChange {
  BitChange(diameter: Float, kind: PauseKind)
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
/// strings (as the inputs hold them); coerced + validated into the domain
/// `GcodeConfig` when a run starts. There is no `port` field — the serial device
/// is chosen via the browser's Web Serial picker, not by an OS path.
pub type Config {
  Config(
    baud: String,
    auto_connect: Bool,
    /// In-app pause: when on, the streamed program omits the mandatory machine-
    /// stop `M0` and the app pauses the stream at each bit change / touch-off,
    /// offering an on-screen Resume (control stays on the screen). Off by default
    /// — the streamed program keeps `M0` (operator resumes on the printer panel),
    /// matching any future g-code export. See ADR-0009.
    app_pause: Bool,
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
    /// Actionable diagnosis of the last fit (per-point residuals + worst point +
    /// likely-cause hint), shown on the rejected-fit panel. `NoFitDiag` until a
    /// fit has produced diagnostics.
    fit_diag: FitDiagOpt,
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
    /// Which board face is up in the printer. Drives the board transform applied
    /// once upstream to the WORKING board model (canvas, alignment job, and G-code
    /// all derive from it). Locked once registration starts. See BoardSide.
    board_side: BoardSide,
    /// True when a previously-fitted alignment was RESTORED from localStorage on
    /// reload but is NOT yet trusted: the live serial port is gone after a reload,
    /// so the restored transform must be re-confirmed by the operator. While set,
    /// the Align stage shows a "Board hasn't moved — resume" prompt instead of a
    /// trusted alignment; `ResumeAlignment` (only once reconnected) clears it and
    /// promotes the restored alignment to `ConfAligned`. False in every other
    /// case (a fresh fit, a reset, or no persisted alignment).
    resume_pending: Bool,
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
  /// Choose which board face is up in the printer (rebuilds the working board
  /// geometry pre-registration; locked once aligning).
  SetBoardSide(BoardSide)
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
  /// Explicit, acknowledged override of a rejected (over-tolerance) fit — proceed
  /// on the solved transform despite residuals over tolerance.
  OverrideAlignment
  RestartAlignment
  /// Re-instate an alignment RESTORED from the previous session (reload). Only
  /// meaningful while `resume_pending` is set; the handler refuses unless the
  /// printer is reconnected (the operator must re-open the serial port first).
  /// On success it promotes the restored transform to a trusted `ConfAligned`.
  ResumeAlignment
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
  /// Flip the in-app pause flag (omit M0 + on-screen Resume vs keep M0).
  ToggleAppPause
  ResetDefaults
  ApplyConfig
}
