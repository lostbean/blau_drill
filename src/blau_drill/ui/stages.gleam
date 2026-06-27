//// The five stage views + the settings screen. Each is a pure function of the
//// model (load / align / dry-run / drill / done, plus settings).
////
//// The right-hand control asides preserve the safety-gate model exactly:
////   * jog / spindle controls are DISABLED unless the printer is `Jogging`
////     (motors energized) — energize-before-jog.
////   * Capture / Fit / Proceed enable only when their preconditions hold.
////   * Confirm-registration (the only path to drilling) is a hazard-striped
////     two-step gate routed through dry-run.

import blau_drill/control/controller
import blau_drill/domain/fit_geometry.{
  type FitGeometry, type SanityFlag, Mirrored, Plausible, ScaleOff, Sheared,
  Suspect, Tilted,
}
import blau_drill/domain/job
import blau_drill/ui/board_canvas.{type CanvasData, CanvasData}
import blau_drill/ui/mock
import blau_drill/ui/model.{
  type Config, type Model, type SettingsCategory, ApplyConfig, CancelRelease,
  CaptureFiducial, ConfirmRegistration, ConfirmReleaseMotors, Connection,
  Defaults, Energize, Fit, Jog, MotionLimits, NewBoard, ParseBoard, Recapture,
  RedoAlignment, Release, RestartAlignment, ResumeDrilling, RunDryRun,
  SelectCategory, SelectFile, SelectOutline, SetConfigField, SetJogStep,
  SpindleControl, StartRegistering, TestSpindle, ToggleAppPause,
  ToggleAutoConnect,
}
import blau_drill/ui/projection
import blau_drill/ui/session
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import lustre/attribute as a
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/element/svg
import lustre/event

// ── Session-derived reads (ADR-0012) ─────────────────────────────────────────
// The screen + wire state are projected from the `Session` (job + the
// controller's REAL `printer.PrinterState`), not stored on the model.

fn sess(model: Model) -> session.Session {
  session.of(model.job, model.board, controller.state(model.controller))
}

fn screen_of(model: Model) -> model.Screen {
  session.screen(sess(model), model.overlay)
}

// ── canvas data assembly (the Phase-4 seam for board/head/fiducials) ─────────

fn canvas_data(model: Model) -> CanvasData {
  // The board's hole STATUS is projected from the run (ADR-0018), not stored.
  let board = case projection.board(model) {
    model.HaveBoard(b) -> b
    model.NoBoard -> mock.board()
  }
  // fiducials = captured (projected from the job's pending captures) + pending
  // candidates not yet captured.
  let captured = projection.captured(model)
  let fiducials = list.append(captured, pending_fiducials(model, captured))
  // Per-fiducial residuals from the last fit (empty / -1 before a fit), so the
  // canvas annotates each captured marker with its error and flags the worst.
  let #(point_residuals, worst_index) = case projection.fit_diag(model) {
    model.HaveFitDiag(d) -> #(d.points, board_canvas.worst_index_of(d.worst))
    model.NoFitDiag -> #([], -1)
  }
  CanvasData(
    holes: board.holes,
    outline: board.outline,
    fiducials: fiducials,
    tools: board.tools,
    bbox: board.bbox,
    head: model.head,
    head_pos: projection.head_pos(model),
    head_confidence: projection.head_confidence(model),
    stage: screen_of(model),
    zoom: model.zoom,
    point_residuals: point_residuals,
    worst_index: worst_index,
    // The downhill tilt arrow's source: the decomposed fit's tilt magnitude +
    // azimuth, or None before a fit. A pure projection (ADR-0018) — the canvas
    // draws it only in the Align stage and only when non-flat.
    tilt: case projection.fit_geometry(model) {
      model.HaveFitGeometry(g) -> option.Some(#(g.tilt_deg, g.tilt_dir_deg))
      model.NoFitGeometry -> option.None
    },
  )
}

fn pending_fiducials(
  model: Model,
  captured: List(model.Fiducial),
) -> List(model.Fiducial) {
  let captured_idx = list.map(captured, fn(f) { f.index })
  let candidates = case model.board {
    model.HaveBoard(b) -> b.candidates
    model.NoBoard -> mock.candidates()
  }
  candidates
  |> list.index_map(fn(pt, i) {
    let #(x, y) = pt
    let state = case i == model.current_target {
      True -> model.Current
      False -> model.FidPending
    }
    model.Fiducial(x, y, i, state)
  })
  |> list.filter(fn(f) { !list.contains(captured_idx, f.index) })
}

// ── Stage 1: Load & Connect ──────────────────────────────────────────────────

pub fn load(model: Model) -> Element(model.Msg) {
  case model.board {
    model.HaveBoard(_) -> load_loaded(model)
    model.NoBoard -> load_picker(model)
  }
}

fn load_loaded(model: Model) -> Element(model.Msg) {
  h.div([a.class("stage")], [
    diagnostic_bar(model),
    board_side_toggle(model),
    h.div([a.class("canvas-frame")], [board_canvas.view(canvas_data(model))]),
    h.div([a.class("stage-actions")], [
      h.button(
        [
          a.class("btn btn-primary btn-lg"),
          a.attribute("type", "button"),
          a.disabled(session.is_disconnected(sess(model))),
          event.on_click(StartRegistering),
        ],
        [h.text("Proceed to Align →")],
      ),
    ]),
  ])
}

// Front/Back selector: which face is up in the printer. Flipping to Back
// X-mirrors the WORKING board geometry once, upstream — the drill pattern, the
// alignment job, and the g-code all derive from that one transformed model, so
// every path (canvas, click-to-jump, g-code) stays consistent. It is a
// Stage-1 / pre-registration choice: once registration starts the working
// geometry is fixed for the session (captures are against that orientation), so
// the toggle LOCKS.
fn board_side_toggle(model: Model) -> Element(model.Msg) {
  let locked = registration_started(model.job)
  let seg = fn(label, this_side, hint) {
    h.button(
      [
        a.class(case model.board_side == this_side {
          True -> "side-seg active"
          False -> "side-seg"
        }),
        a.attribute("type", "button"),
        a.disabled(locked),
        a.attribute("aria-pressed", case model.board_side == this_side {
          True -> "true"
          False -> "false"
        }),
        a.attribute("title", hint),
        event.on_click(model.SetBoardSide(this_side)),
      ],
      [h.text(label)],
    )
  }
  h.div([a.class("side-toggle")], [
    h.span([a.class("side-label")], [h.text("Board side in printer")]),
    h.div([a.class("side-segs")], [
      seg(
        "Front",
        model.Front,
        "Front face up — drill pattern in native orientation",
      ),
      seg(
        "Back (copper up)",
        model.Back,
        "Back/copper up — drill pattern mirrored to match the flipped board",
      ),
    ]),
    case locked, model.board_side {
      True, _ ->
        h.span([a.class("side-note")], [
          h.text("Board side locked once alignment starts."),
        ])
      False, model.Back ->
        h.span([a.class("side-note")], [
          h.text("Board flipped (copper up) — drill pattern mirrored to match."),
        ])
      False, model.Front -> element.none()
    },
  ])
}

// Registration has started once the job has left `Parsed` (Registering or
// beyond): the board side / working geometry is fixed for the session.
fn registration_started(job: model.JobOpt) -> Bool {
  case job {
    model.HaveJob(j) ->
      case j.state {
        job.Parsed -> False
        _ -> True
      }
    model.NoJob -> False
  }
}

// Is `Fit` a legal job event right now? The FSM is the authority (`FitE` is
// legal only in `Registering`), so the Fit button can be hard-disabled where a
// click would be an inert no-op. The view ALSO keeps a captured-count guard (the
// within-`Registering` ≥3 precondition the FSM does not encode) — both must hold.
fn job_can_fit(model: Model) -> Bool {
  case model.job {
    model.HaveJob(j) -> job.can(j, job.FitE)
    model.NoJob -> False
  }
}

// Is `RestartAlignment` a legal job event right now? Legal in Registering /
// Aligned / AlignmentRejected — so the button stays enabled exactly where a
// restart is meaningful and is disabled elsewhere.
fn job_can_restart(model: Model) -> Bool {
  case model.job {
    model.HaveJob(j) -> job.can(j, job.RestartAlignmentE)
    model.NoJob -> False
  }
}

fn load_picker(model: Model) -> Element(model.Msg) {
  h.div([a.class("stage")], [
    h.div(
      [
        a.class("dropzone"),
        a.attribute("role", "button"),
        a.tabindex(0),
        a.attribute("aria-label", "Select PCB drill file"),
        event.on_click(SelectFile),
      ],
      [
        h.span([a.class("dropzone-icon"), a.attribute("aria-hidden", "true")], [
          h.text("⬆"),
        ]),
        h.span([a.class("dropzone-title")], [h.text("Drop PCB files here")]),
        h.span([a.class("dropzone-sub")], [
          h.text("Supports Excellon drill files (.drl)"),
        ]),
        h.span([a.class("browse-pill")], [h.text("Browse Files")]),
      ],
    ),
    h.div(
      [
        a.class("outline-row"),
        a.attribute("role", "button"),
        a.tabindex(0),
        a.attribute("aria-label", "Add board outline file"),
        event.on_click(SelectOutline),
      ],
      [
        h.span([a.attribute("aria-hidden", "true")], [h.text("＋")]),
        h.text(case model.outline_file {
          "" -> "Add board outline — Edge.Cuts (.svg, optional)"
          name -> "Outline: " <> name
        }),
      ],
    ),
    case model.file_selected {
      True ->
        h.div([a.class("file-entry")], [
          h.span([], [h.text("board.drl")]),
          h.button(
            [
              a.class("btn btn-primary"),
              a.attribute("type", "button"),
              event.on_click(ParseBoard),
            ],
            [h.text("Parse & Load")],
          ),
        ])
      False -> element.none()
    },
    case model.upload_error {
      "" -> element.none()
      err -> h.p([a.class("upload-error")], [h.text(err)])
    },
  ])
}

fn diagnostic_bar(model: Model) -> Element(model.Msg) {
  case model.diagnostic {
    model.HaveDiagnostic(d) ->
      h.div([a.class("diagnostic-bar")], [
        h.span([a.class("ok")], [h.text("✓ FILE VALID")]),
        h.span([], [
          h.text("Holes: "),
          h.strong([], [h.text(int.to_string(d.hole_count))]),
        ]),
        h.span([], [
          h.text("Tools: "),
          h.strong([], [h.text(int.to_string(d.tool_count))]),
        ]),
        h.span([], [
          h.text("Dimensions: "),
          h.strong([], [
            h.text(fmt2(d.width) <> " × " <> fmt2(d.height) <> " mm"),
          ]),
        ]),
      ])
    model.NoDiagnostic -> element.none()
  }
}

// ── Stage 2: Physical Alignment ──────────────────────────────────────────────

/// Minimum captured fiducials needed before an alignment can be fit. Shared by
/// the Fit button's `disabled` check and the next-step highlight below.
const min_fit_points = 3

/// Which alignment action is the operator's NEXT step. Derived purely from
/// (captured count, fiducial target) so the Capture / Fit buttons can carry the
/// primary (amber) emphasis in turn — no extra state threaded through the model.
/// Below the 3-point minimum to fit, Capture is next; at/above it, Fit is next
/// (at N/N captured ≥ target ≥ 3, so Fit is correctly next).
pub type NextStep {
  CaptureNext
  FitNext
}

pub fn next_step(captured: Int, _target: Int) -> NextStep {
  case captured >= min_fit_points {
    True -> FitNext
    False -> CaptureNext
  }
}

pub fn align(model: Model) -> Element(model.Msg) {
  let motors_online = session.is_jogging(sess(model))
  let captured_count = list.length(projection.captured(model))
  let quality = projection.quality(model)
  let next = next_step(captured_count, model.fiducial_target)
  // Capture is done once we hit the target — you can't over-capture.
  let capture_done = captured_count >= model.fiducial_target
  // The next action wears the amber primary; the others recede to surface.
  let capture_emphasis = case next == CaptureNext && motors_online {
    True -> "btn-primary"
    False -> "btn-surface"
  }
  let fit_emphasis = case next {
    FitNext -> "btn-primary"
    CaptureNext -> "btn-surface"
  }
  h.div([a.class("stage-cols")], [
    h.div([a.class("canvas-frame")], [board_canvas.view(canvas_data(model))]),
    h.aside([a.class("aside aside-360")], [
      h.div([], [
        h.h3([], [h.text("Alignment Setup")]),
        h.p([a.class("aside-sub")], [
          h.text(
            "Capture "
            <> int.to_string(model.fiducial_target)
            <> " fiducials to align the board.",
          ),
        ]),
      ]),
      release_confirm_panel(model),
      motors_panel(motors_online),
      jog_panel(model, motors_online),
      first_fiducial_hint(model, motors_online),
      h.button(
        [
          a.class("btn " <> capture_emphasis <> " btn-block btn-lg"),
          a.attribute("type", "button"),
          a.disabled(!motors_online || capture_done),
          event.on_click(CaptureFiducial),
        ],
        [
          h.text(
            "Capture Fiducial ("
            <> int.to_string(captured_count)
            <> "/"
            <> int.to_string(model.fiducial_target)
            <> ")",
          ),
        ],
      ),
      h.button(
        [
          a.class("btn " <> fit_emphasis <> " btn-block"),
          a.attribute("type", "button"),
          a.disabled(captured_count < min_fit_points || !job_can_fit(model)),
          event.on_click(Fit),
        ],
        [h.text("Fit Alignment")],
      ),
      // A failed fit (too-few / degenerate) does NOT transition the job (so the
      // rejected-box projection stays empty); its guidance rides `upload_error`,
      // surfaced here in the Align aside.
      align_error(model),
      h.button(
        [
          a.class("btn btn-outline btn-block"),
          a.attribute("type", "button"),
          a.disabled(!job_can_restart(model)),
          event.on_click(RestartAlignment),
        ],
        [h.text("↺ Restart Alignment")],
      ),
      quality_panel(model),
      rejected_box(model),
      h.button(
        [
          a.class("btn btn-primary btn-block btn-lg spacer"),
          a.attribute("type", "button"),
          a.disabled(quality < 0 || projection.alignment_rejected(model)),
          event.on_click(RunDryRun),
        ],
        [h.text("Proceed to Dry-run →")],
      ),
    ]),
  ])
}

// ADR-0011: with motors energized but NOTHING captured yet, click-to-jump is a
// strict no-op — there is no board↔machine relationship to jump on (the estimate
// Errors on zero captures, so a jump would act on a phantom origin). Surface a
// small, non-blocking hint telling the operator to JOG the head onto the first
// fiducial and capture it before clicking other markers to jump. Informational
// only — it blocks no button (Capture stays gated on Jogging, already). Shown
// only while energized AND no captures exist; it disappears after the first
// capture (when click-to-jump starts working).
fn first_fiducial_hint(
  model: Model,
  motors_online: Bool,
) -> Element(model.Msg) {
  case motors_online && projection.captured(model) == [] {
    False -> element.none()
    True ->
      h.p([a.class("panel-hint")], [
        h.text(
          "Jog the head onto fiducial 1 and capture it first — click-to-jump "
          <> "needs at least one capture to know where the board is.",
        ),
      ])
  }
}

// ADR-0011 anti-surprise confirm: a VOLUNTARY "Disable Motors" that would discard
// a non-trivial alignment shows this gate first. De-energizing invalidates the
// alignment (position is valid only while motors stay energized), so the operator
// confirms the destructive reset before it happens — or cancels and keeps the
// alignment. Shown only while `release_confirm` is set.
fn release_confirm_panel(model: Model) -> Element(model.Msg) {
  case model.release_confirm {
    False -> element.none()
    True ->
      h.div([a.class("panel panel-warn")], [
        h.div([a.class("panel-head")], [
          h.span([a.class("panel-head-label")], [
            h.text("Disable motors — resets alignment"),
          ]),
          h.span([a.class("badge offline blink")], [h.text("CONFIRM")]),
        ]),
        h.p([a.class("panel-hint")], [
          h.text(
            "De-energizing the motors resets the alignment — the captured "
            <> "fiducials and fit will be discarded, and you'll re-register. "
            <> "Continue?",
          ),
        ]),
        h.button(
          [
            a.class("btn btn-primary btn-block"),
            a.style("margin-top", "0.75rem"),
            a.attribute("type", "button"),
            event.on_click(ConfirmReleaseMotors),
          ],
          [h.text("Disable & reset")],
        ),
        h.button(
          [
            a.class("btn btn-outline btn-block"),
            a.style("margin-top", "0.5rem"),
            a.attribute("type", "button"),
            event.on_click(CancelRelease),
          ],
          [h.text("Cancel")],
        ),
      ])
  }
}

fn motors_panel(online: Bool) -> Element(model.Msg) {
  let #(badge_cls, badge_txt) = case online {
    True -> #("badge online", "ONLINE")
    False -> #("badge offline blink", "OFFLINE")
  }
  let #(btn_cls, btn_txt, btn_msg) = case online {
    True -> #("btn btn-primary btn-block", "Motors ON — Disable", Release)
    False -> #("btn btn-surface btn-block", "Enable Motors", Energize)
  }
  h.div([a.class("panel")], [
    h.div([a.class("panel-head")], [
      h.span([a.class("panel-head-label")], [h.text("Axis Motors")]),
      h.span([a.class(badge_cls)], [h.text(badge_txt)]),
    ]),
    h.button(
      [
        a.class(btn_cls),
        a.style("margin-top", "0.75rem"),
        a.attribute("type", "button"),
        event.on_click(btn_msg),
      ],
      [h.text(btn_txt)],
    ),
    h.p([a.class("panel-hint")], [
      h.text("Enable motors to unlock jog controls."),
    ]),
  ])
}

fn jog_panel(model: Model, online: Bool) -> Element(model.Msg) {
  let panel_cls = case online {
    True -> "panel jog-panel"
    False -> "panel jog-panel locked"
  }
  h.div([a.class(panel_cls)], [
    h.span([a.class("panel-head-label")], [h.text("Manual Jog")]),
    h.div(
      [a.class("jog-steps")],
      list.map([0.1, 1.0, 10.0], fn(step) { jog_step_btn(model, step, online) }),
    ),
    h.div([a.class("jog-grid")], [
      h.span([], []),
      jog_btn("Y", 1.0, "↑ +Y", online),
      h.span([], []),
      jog_btn("X", -1.0, "← -X", online),
      h.div([a.class("jog-center")], [h.span([a.class("dot")], [])]),
      jog_btn("X", 1.0, "+X →", online),
      h.span([], []),
      jog_btn("Y", -1.0, "↓ -Y", online),
      h.span([], []),
    ]),
    h.div([a.class("jog-z")], [
      jog_btn("Z", 1.0, "+Z", online),
      jog_btn("Z", -1.0, "-Z", online),
    ]),
    h.button(
      [
        a.class("btn btn-outline btn-block"),
        a.style("margin-top", "0.75rem"),
        a.attribute("type", "button"),
        a.disabled(!online),
        event.on_click(TestSpindle),
      ],
      [h.text("⟳ Test Spindle")],
    ),
  ])
}

fn jog_step_btn(model: Model, step: Float, online: Bool) -> Element(model.Msg) {
  let active = model.jog_step == step
  let cls = case active {
    True -> "jog-step active"
    False -> "jog-step"
  }
  h.button(
    [
      a.class(cls),
      a.attribute("type", "button"),
      a.disabled(!online),
      event.on_click(SetJogStep(step)),
    ],
    [h.text(fmt_step(step))],
  )
}

fn jog_btn(
  axis: String,
  sign: Float,
  label: String,
  online: Bool,
) -> Element(model.Msg) {
  h.button(
    [
      a.class("jog-btn"),
      a.attribute("type", "button"),
      a.disabled(!online),
      a.attribute("aria-label", "Jog " <> label),
      event.on_click(Jog(axis, sign)),
    ],
    [h.text(label)],
  )
}

// The Align-aside error line (failed-fit guidance). Empty when there is none.
fn align_error(model: Model) -> Element(model.Msg) {
  case model.upload_error {
    "" -> element.none()
    err -> h.p([a.class("upload-error")], [h.text(err)])
  }
}

fn quality_panel(model: Model) -> Element(model.Msg) {
  let quality = projection.quality(model)
  case quality < 0 {
    True -> element.none()
    False -> {
      let #(cls, label) = quality_class(quality)
      h.div([a.class("panel")], [
        h.div([a.class("panel-head")], [
          h.span([a.class("panel-head-label")], [h.text("Est. Quality")]),
          h.span([a.class("quality-value " <> cls)], [
            h.text(int.to_string(quality) <> "% " <> label),
          ]),
        ]),
        h.div([a.class("quality-track")], [
          h.div(
            [
              a.class("quality-fill " <> cls),
              a.style("width", int.to_string(quality) <> "%"),
            ],
            [],
          ),
        ]),
        h.p([a.class("residuals")], [
          h.text(
            "residual max "
            <> fmt3(projection.residual_max(model))
            <> " mm · rms "
            <> fmt3(projection.residual_rms(model))
            <> " mm",
          ),
        ]),
        // The Z-plane residual line (ADR-0020). An Aligned fit means Z passed the
        // gate too (or, at < 4 captures, Z was unverified — the fit is valid on XY
        // but its depth is unchecked, surfaced as a muted-amber nudge to capture a
        // 4th fiducial). NOT an error here — a Z-FAILING fit lands in
        // AlignmentRejected, whose box shows the over-tolerance Z number instead.
        z_quality_line(model),
        // Advisory fit verdict + numeric breakdown (ADR-0019). DISPLAY ONLY — a
        // Suspect verdict warns the operator but does NOT gate Proceed (the
        // residual stays the sole hard gate). No stored state: both are pure
        // projections of the solved fit (ADR-0018).
        verdict_badge(model),
        fit_breakdown(model),
      ])
    }
  }
}

// The Z-plane residual line for the quality panel (ADR-0020). The quality panel
// co-renders with the rejected box (quality is computed whenever residuals exist),
// so the Z verdict depends on which state we're in:
//   * REJECTED (Z over tolerance, n >= 4): say nothing here — the rejected box
//     below owns the Z message ("Z residual … over tolerance"). A green
//     "Z residual" number here would contradict it.
//   * >= 4 captures AND not rejected (an Aligned fit): Z is meaningful and passed
//     the gate, so show the verified green residual number.
//   * < 4 captures: a plane fits the points exactly, so the Z residual proves
//     nothing — a muted-amber "unverified" nudge to capture a 4th fiducial,
//     WITHOUT implying the fit is wrong (it is valid on XY).
fn z_quality_line(model: Model) -> Element(model.Msg) {
  let rejected = projection.alignment_rejected(model)
  case projection.capture_count(model) >= 4, rejected {
    // Z-rejected: the rejected box carries the Z message; suppress it here.
    True, True -> element.none()
    // Verified Z (Aligned, n >= 4): the gate-passed residual number.
    True, False ->
      h.p([a.class("residuals z-residual")], [
        h.text(
          "Z residual max " <> fmt3(projection.z_residual_max(model)) <> " mm",
        ),
      ])
    // Z unverified (< 4 captures) — a non-error depth nudge.
    False, _ ->
      h.p([a.class("residuals z-unverified")], [
        h.text("Z unverified — capture a 4th fiducial to check depth"),
      ])
  }
}

// The advisory verdict badge from the fit-sanity projection. `Plausible` reads as
// a green confirmation; `Suspect` is an amber warning followed by one
// human-readable line per `SanityFlag`. `NoFitSanity` (unreachable inside the
// quality>=0 branch) renders nothing — kept total.
fn verdict_badge(model: Model) -> Element(model.Msg) {
  case projection.fit_sanity(model) {
    model.HaveFitSanity(Plausible) ->
      h.div([a.class("verdict plausible")], [
        h.span([a.class("verdict-badge")], [h.text("✓ Plausible")]),
      ])
    model.HaveFitSanity(Suspect(reasons)) ->
      h.div(
        [a.class("verdict suspect")],
        [h.span([a.class("verdict-badge")], [h.text("⚠ Suspect")])]
          |> list.append(
            list.map(reasons, fn(flag) {
              h.p([a.class("verdict-reason")], [
                h.text(sanity_reason_text(flag)),
              ])
            }),
          ),
      )
    model.NoFitSanity -> element.none()
  }
}

/// The human-readable advisory line for one `SanityFlag`. Pure (no model) so the
/// exact wording is unit-tested per variant.
pub fn sanity_reason_text(flag: SanityFlag) -> String {
  case flag {
    Mirrored -> "board may be mirrored — check Front/Back"
    ScaleOff("x", v) -> "scale X " <> fmt2(v) <> "×"
    ScaleOff("y", v) -> "scale Y " <> fmt2(v) <> "×"
    ScaleOff(axis, v) -> "scale " <> axis <> " " <> fmt2(v) <> "×"
    Sheared(d) -> "shear " <> fmt3(d) <> "° (check captures)"
    Tilted(d) -> "board tilted " <> fmt3(d) <> "°"
  }
}

// The always-visible numeric breakdown of the eight decomposed quantities
// (ADR-0019). Always-visible (not a toggle): a disclosure toggle would need
// stored Model state, which is forbidden (ADR-0018), and the bench display has
// room. Laid out as labelled `summary-cell` rows inside a compact grid.
fn fit_breakdown(model: Model) -> Element(model.Msg) {
  case projection.fit_geometry(model) {
    model.HaveFitGeometry(g) ->
      h.div([a.class("fit-breakdown")], [
        breakdown_cell("tilt", fmt3(g.tilt_deg) <> "°"),
        breakdown_cell("toward", fmt0(g.tilt_dir_deg) <> "°"),
        breakdown_cell("rotation", fmt3(g.rotation_deg) <> "°"),
        breakdown_cell("shear", fmt3(g.shear_deg) <> "°"),
        breakdown_cell("scale X", fmt2(g.scale_x) <> "×"),
        breakdown_cell("scale Y", fmt2(g.scale_y) <> "×"),
        breakdown_cell("mirror", mirror_label(g)),
      ])
    model.NoFitGeometry -> element.none()
  }
}

fn breakdown_cell(label: String, value: String) -> Element(model.Msg) {
  h.div([a.class("breakdown-cell")], [
    h.span([a.class("label")], [h.text(label)]),
    h.span([a.class("value")], [h.text(value)]),
  ])
}

fn mirror_label(g: FitGeometry) -> String {
  case g.mirrored {
    True -> "yes"
    False -> "no"
  }
}

fn quality_class(pct: Int) -> #(String, String) {
  case pct >= 80, pct >= 50 {
    True, _ -> #("good", "GOOD")
    False, True -> #("fair", "FAIR")
    False, False -> #("poor", "POOR")
  }
}

fn rejected_box(model: Model) -> Element(model.Msg) {
  case projection.alignment_rejected(model) {
    False -> element.none()
    True -> {
      let residual_max = projection.residual_max(model)
      let #(hint, points, can_override) = case projection.fit_diag(model) {
        model.HaveFitDiag(d) -> #(d.hint, fit_point_rows(d), d.can_override)
        model.NoFitDiag -> #(
          "Alignment rejected — residual over tolerance.",
          [],
          False,
        )
      }
      h.div(
        [a.class("rejected-box")],
        list.flatten([
          [
            h.p([a.class("rejected-title")], [h.text("⚠ Alignment rejected")]),
            h.p([a.class("rejected-hint")], [h.text(hint)]),
          ],
          // The Z residual when DEPTH is the failing axis (ADR-0020): an
          // XY-perfect fit can be rejected solely for an inconsistent capture
          // height. Show the over-tolerance Z number so the operator sees the
          // rejection is about depth, not XY. (If both fail, both lines show — the
          // XY one rides the per-point residual list + hint below.)
          rejected_z_line(model),
          points,
          [
            h.button(
              [
                a.class("btn btn-primary btn-block"),
                a.style("margin-top", "0.75rem"),
                a.attribute("type", "button"),
                event.on_click(Recapture),
              ],
              [h.text("Recapture fiducials")],
            ),
          ],
          // The explicit, acknowledged override — only when a transform solved.
          case can_override {
            True -> [
              h.div([a.class("override-box")], [
                h.p([a.class("override-warn")], [
                  h.text(
                    "Override: proceed on this fit despite "
                    <> fmt3(residual_max)
                    <> " mm error. Holes may be off by this much. Only do this if "
                    <> "you understand the risk.",
                  ),
                ]),
                h.button(
                  [
                    a.class("btn btn-danger btn-block"),
                    a.attribute("type", "button"),
                    event.on_click(model.OverrideAlignment),
                  ],
                  [
                    h.text("Proceed anyway (" <> fmt3(residual_max) <> " mm)"),
                  ],
                ),
              ]),
            ]
            False -> []
          },
        ]),
      )
    }
  }
}

// The over-tolerance Z residual line for a Z-rejected fit (ADR-0020), or nothing
// when Z is not the failing axis. Z is the failing residual only when it is
// MEANINGFUL (>= 4 captures) AND over tolerance — exactly the condition that lands
// an XY-passing fit in AlignmentRejected for DEPTH. Returned as a list so it
// flattens into the rejected-box body (empty list = no line, e.g. a pure-XY
// failure where Z passed / is unverified).
fn rejected_z_line(model: Model) -> List(Element(model.Msg)) {
  let z_max = projection.z_residual_max(model)
  let over = z_max >. projection.tolerance(model)
  case projection.capture_count(model) >= 4 && over {
    True -> [
      h.p([a.class("rejected-hint z-rejected")], [
        h.text("Z residual " <> fmt3(z_max) <> " mm (over tolerance)"),
      ]),
    ]
    False -> []
  }
}

// Per-fiducial residual rows; the worst point is flagged.
fn fit_point_rows(d: model.FitDiag) -> List(Element(model.Msg)) {
  let worst_idx = case d.worst {
    model.HaveWorst(w) -> w.index
    model.NoWorst -> -1
  }
  case d.points {
    [] -> []
    points -> [
      h.div(
        [a.class("residual-list")],
        list.map(points, fn(p) {
          let is_worst = p.index == worst_idx
          h.div(
            [
              a.class(case is_worst {
                True -> "residual-row worst"
                False -> "residual-row"
              }),
            ],
            [
              h.span([], [h.text("Point " <> int.to_string(p.index + 1))]),
              h.span([], [
                h.text(
                  fmt3(p.error_mm)
                  <> " mm"
                  <> case is_worst {
                    True -> "  ← worst"
                    False -> ""
                  },
                ),
              ]),
            ],
          )
        }),
      ),
    ]
  }
}

// ── Stage 3: Dry-run ──────────────────────────────────────────────────────────

pub fn dry_run(model: Model) -> Element(model.Msg) {
  h.div([a.class("stage-cols")], [
    h.div([a.class("canvas-frame")], [
      board_canvas.view(canvas_data(model)),
      h.span([a.class("canvas-tag")], [h.text("Dry-run · Spindle OFF")]),
    ]),
    h.aside([a.class("aside aside-360")], [
      h.div([], [
        h.h3([], [h.text("Dry-run Rehearsal")]),
        h.p([a.class("aside-sub")], [
          h.text(
            "The bit hovers over every hole, spindle off. Confirm the digital "
            <> "pattern lines up with the physical board before any real cut.",
          ),
        ]),
      ]),
      progress_note(model),
      // The bit-change pause surfaces HERE in the dry-run aside (a sidebar panel,
      // not a pop-up): the stream halts at each bit-change sentinel and waits for
      // the operator to resume the rehearsal. Without this, the run stopped at the
      // first pause with no way to continue.
      pause_panel(model, "▶ Resume Rehearsal"),
      h.button(
        [
          a.class("btn btn-surface btn-block btn-lg"),
          a.attribute("type", "button"),
          event.on_click(RedoAlignment),
        ],
        [h.text("← Redo Alignment")],
      ),
      h.div([a.class("confirm-box")], [
        h.p([a.class("title")], [h.text("Confirm registration")]),
        h.p([], [
          h.text(
            "Starting the real run plunges the bit with the spindle on. This "
            <> "cannot be undone.",
          ),
        ]),
        h.button(
          [
            a.class("btn btn-danger btn-block btn-lg"),
            a.style("margin-top", "0.75rem"),
            a.attribute("type", "button"),
            event.on_click(ConfirmRegistration),
          ],
          [h.text("Confirm Registration → Start Drilling")],
        ),
      ]),
    ]),
  ])
}

fn progress_note(model: Model) -> Element(model.Msg) {
  case projection.progress(model) {
    model.HaveProgress(p) ->
      h.div([a.class("panel")], [
        h.text(
          "Traced "
          <> int.to_string(p.drilled)
          <> "/"
          <> int.to_string(p.total)
          <> " positions.",
        ),
      ])
    model.NoProgress -> element.none()
  }
}

// ── Stage 4: Active Drilling ──────────────────────────────────────────────────

pub fn drill(model: Model) -> Element(model.Msg) {
  let #(pct, drilled, total) = case projection.progress(model) {
    model.HaveProgress(p) -> #(
      progress_pct(p.drilled, p.total),
      p.drilled,
      p.total,
    )
    model.NoProgress -> #(0, 0, 0)
  }
  h.div([a.class("stage-cols"), a.style("position", "relative")], [
    h.div([a.class("canvas-frame")], [
      board_canvas.view(canvas_data(model)),
      h.div([a.class("drill-overlay")], [
        h.div([a.class("drill-ring")], [
          h.span([a.class("drill-pct")], [h.text(int.to_string(pct) <> "%")]),
          h.span([a.class("drill-count")], [
            h.text(int.to_string(drilled) <> " / " <> int.to_string(total)),
          ]),
          h.span([a.class("drill-status pulse-dot")], [
            h.text("Drilling in progress…"),
          ]),
        ]),
      ]),
    ]),
    h.aside([a.class("aside aside-280")], [
      h.div([a.class("panel panel-high")], [
        h.p([a.class("section-label")], [h.text("Telemetry")]),
        telemetry_row("Current Bit", projection.telemetry_bit(model), "primary"),
        telemetry_row(
          "Est. Time Remaining",
          projection.telemetry_eta(model),
          "secondary",
        ),
        telemetry_row("Spindle", projection.telemetry_spindle(model), ""),
      ]),
      // Bit-change pause as a sidebar panel (consistent with dry-run; no pop-up).
      pause_panel(model, "▶ Resume Drilling"),
      h.button(
        [
          a.class("btn-estop"),
          a.attribute("type", "button"),
          a.attribute("aria-label", "Abort drilling"),
          event.on_click(model.Abort),
        ],
        [h.text("⚠ Abort Drilling")],
      ),
      complete_button(model),
    ]),
  ])
}

fn telemetry_row(
  label: String,
  value: String,
  color: String,
) -> Element(model.Msg) {
  h.div([a.class("telemetry-row")], [
    h.p([a.class("label")], [h.text(label)]),
    h.p([a.class("value " <> color)], [h.text(value)]),
  ])
}

fn complete_button(model: Model) -> Element(model.Msg) {
  let drilled_all = case projection.progress(model) {
    model.HaveProgress(p) -> p.drilled >= p.total && p.total > 0
    model.NoProgress -> False
  }
  let has_modal = case projection.bit_change(model) {
    model.HaveBitChange(_) -> True
    model.NoBitChange -> False
  }
  case drilled_all && !has_modal {
    True ->
      h.button(
        [
          a.class("btn btn-success btn-block btn-lg spacer"),
          a.attribute("type", "button"),
          event.on_click(model.Complete),
        ],
        [h.text("Mark Complete →")],
      )
    False -> element.none()
  }
}

// The in-app pause affordance — a SIDEBAR panel (not a blocking pop-up) shown in
// the dry-run / drill aside while the stream is paused at a bit-change sentinel.
// The stream is genuinely halted (nothing in flight); `ResumeDrilling` issues the
// ResumeStream that sends the next real line. The first pause is "mount the first
// bit" (ADR-0010 removed the touch-off); later ones are per-tool swaps. `resume`
// is the button label so it reads right per stage ("rehearsal" vs "drilling").
fn pause_panel(model: Model, resume: String) -> Element(model.Msg) {
  case projection.bit_change(model) {
    model.HaveBitChange(bc) ->
      h.div([a.class("panel panel-warn")], [
        h.div([a.class("panel-head")], [
          h.span([a.class("panel-head-label")], [h.text("Paused — bit change")]),
          h.span([a.class("badge offline blink")], [h.text("PAUSED")]),
        ]),
        h.p([a.class("panel-hint")], [
          h.text("Mount the "),
          h.strong([], [h.text(fmt_step(bc.diameter) <> "mm")]),
          h.text(
            " bit, then resume. Do NOT move the board — the alignment is locked.",
          ),
        ]),
        h.button(
          [
            a.class("btn btn-primary btn-block btn-lg"),
            a.style("margin-top", "0.75rem"),
            a.attribute("type", "button"),
            event.on_click(ResumeDrilling),
          ],
          [h.text(resume)],
        ),
      ])
    model.NoBitChange -> element.none()
  }
}

// ── Stage 5: Completion ───────────────────────────────────────────────────────

pub fn done(model: Model) -> Element(model.Msg) {
  h.div([a.class("completion")], [
    h.div([a.class("completion-bg")], [board_canvas.view(canvas_data(model))]),
    h.div([a.class("completion-card")], [
      h.span([a.class("completion-check"), a.attribute("aria-hidden", "true")], [
        h.text("✓"),
      ]),
      h.h2([], [h.text("Drilling Complete")]),
      summary_grid(model),
      h.button(
        [
          a.class("btn btn-primary btn-block btn-lg"),
          a.style("margin-top", "1.5rem"),
          a.attribute("type", "button"),
          event.on_click(NewBoard),
        ],
        [h.text("+ Start New Board")],
      ),
    ]),
  ])
}

fn summary_grid(model: Model) -> Element(model.Msg) {
  case projection.summary(model) {
    model.HaveSummary(s) ->
      h.div([a.class("summary-grid")], [
        summary_cell(
          "Total Holes",
          int.to_string(s.total_holes),
          "secondary",
          False,
        ),
        summary_cell("Total Time", s.total_time, "", False),
        summary_cell("Bit Changes", int.to_string(s.bit_changes), "", True),
      ])
    model.NoSummary -> element.none()
  }
}

fn summary_cell(
  label: String,
  value: String,
  color: String,
  span2: Bool,
) -> Element(model.Msg) {
  let cls = case span2 {
    True -> "summary-cell span2"
    False -> "summary-cell"
  }
  h.div([a.class(cls)], [
    h.p([a.class("label")], [h.text(label)]),
    h.p([a.class("value " <> color)], [h.text(value)]),
  ])
}

// ── Settings ──────────────────────────────────────────────────────────────────

pub fn settings(model: Model) -> Element(model.Msg) {
  h.div([a.class("app")], [
    settings_top(),
    h.div([a.class("app-body")], [
      settings_nav(model.category),
      h.div([a.class("settings-main")], [
        h.div([a.class("settings-scroll")], [
          h.div([a.class("settings-inner")], category_panel(model)),
        ]),
        action_bar(model),
      ]),
    ]),
  ])
}

// ── Serial comms log (full screen, like Settings) ────────────────────────────

pub fn comms_log(model: Model) -> Element(model.Msg) {
  h.div([a.class("app")], [
    h.header([a.class("settings-top")], [
      h.div([a.class("settings-top-left")], [
        shell_brand(),
        h.div([a.class("settings-divider")], []),
        h.span([a.class("settings-sys")], [h.text("SERIAL COMMS LOG")]),
      ]),
      h.div([a.class("settings-top-left")], [
        h.span([a.class("log-count")], [
          h.text(int.to_string(list.length(model.comms_log)) <> " lines"),
        ]),
        h.button(
          [
            a.class("config-link"),
            a.attribute("type", "button"),
            event.on_click(model.ClearLog),
          ],
          [h.text("Clear")],
        ),
        h.button(
          [
            a.class("config-link"),
            a.attribute("type", "button"),
            event.on_click(model.GoToSession),
          ],
          [h.text("← Session")],
        ),
      ]),
    ]),
    h.div([a.class("log-scroll")], case model.comms_log {
      [] -> [
        h.p([a.class("log-empty")], [
          h.text(
            "No serial traffic yet. Connect and the TX/RX lines will appear here.",
          ),
        ]),
      ]
      entries -> list.map(entries, log_row)
    }),
  ])
}

fn log_row(e: model.LogEntry) -> Element(model.Msg) {
  let #(cls, arrow) = case e.dir {
    model.Tx -> #("log-tx", "→")
    model.Rx -> #("log-rx", "←")
    model.Note -> #("log-note", "•")
  }
  h.div([a.class("log-row " <> cls)], [
    h.span([a.class("log-time")], [h.text(fmt_log_time(e.at_ms))]),
    h.span([a.class("log-arrow")], [h.text(arrow)]),
    h.span([a.class("log-line")], [h.text(e.line)]),
  ])
}

// Format an epoch-ms stamp as mm:ss.mmm (clock-ish, compact — enough to read
// timing between lines without a full date).
fn fmt_log_time(at_ms: Float) -> String {
  let total_ms = float.round(at_ms)
  let ms = total_ms % 1000
  let total_s = total_ms / 1000
  let s = total_s % 60
  let m = { total_s / 60 } % 60
  pad2(m) <> ":" <> pad2(s) <> "." <> pad3(ms)
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

fn pad3(n: Int) -> String {
  case n < 10 {
    True -> "00" <> int.to_string(n)
    False ->
      case n < 100 {
        True -> "0" <> int.to_string(n)
        False -> int.to_string(n)
      }
  }
}

fn settings_top() -> Element(model.Msg) {
  h.header([a.class("settings-top")], [
    h.div([a.class("settings-top-left")], [
      shell_brand(),
      h.div([a.class("settings-divider")], []),
      h.span([a.class("settings-sys")], [h.text("SYSTEM CONFIGURATION")]),
    ]),
    h.div([a.class("settings-top-left")], [
      h.div([a.class("maintenance")], [
        h.span([a.class("dot pulse-dot")], []),
        h.text("Maintenance Mode"),
      ]),
      h.button(
        [
          a.class("config-link"),
          a.attribute("type", "button"),
          event.on_click(model.GoToSession),
        ],
        [h.text("← Session")],
      ),
    ]),
  ])
}

// brand reused from shell, but shell imports model.Msg too; inline a small copy
// to avoid a cyclic-ish import (shell already depends only on model).
fn shell_brand() -> Element(model.Msg) {
  h.div([a.class("brand")], [
    h.span(
      [
        a.class("brand-mark material-symbols-outlined"),
        a.attribute("aria-hidden", "true"),
      ],
      [h.text("precision_manufacturing")],
    ),
    h.span([a.class("brand-word")], [h.text("blau-drill")]),
  ])
}

fn settings_nav(category: SettingsCategory) -> Element(model.Msg) {
  h.nav([a.class("settings-nav")], [
    h.div([a.class("sidebar-head")], [
      h.h2([a.class("sidebar-title")], [h.text("Printer Configuration")]),
      h.p([a.class("aside-sub")], [h.text("Station Parameters")]),
    ]),
    h.ul([], [
      cat_btn(Connection, "Connection", category),
      cat_btn(MotionLimits, "Motion Limits", category),
      cat_btn(SpindleControl, "Spindle Control", category),
      cat_btn(Defaults, "Defaults", category),
    ]),
  ])
}

fn cat_btn(
  cat: SettingsCategory,
  label: String,
  current: SettingsCategory,
) -> Element(model.Msg) {
  let active = cat == current
  let cls = case active {
    True -> "cat-btn active"
    False -> "cat-btn"
  }
  let base_attrs = [
    a.class(cls),
    a.attribute("type", "button"),
    event.on_click(SelectCategory(cat)),
  ]
  let attrs = case active {
    True -> [a.attribute("aria-current", "page"), ..base_attrs]
    False -> base_attrs
  }
  h.li([], [h.button(attrs, [h.text(label)])])
}

fn category_panel(model: Model) -> List(Element(model.Msg)) {
  case model.category {
    Connection -> connection_panel(model.config)
    MotionLimits -> motion_panel(model.config)
    SpindleControl -> spindle_panel(model.config)
    Defaults -> defaults_panel(model.config)
  }
}

fn connection_panel(c: Config) -> List(Element(model.Msg)) {
  [
    panel_header(
      "Connection Setup",
      "Serial communication parameters for the CNC controller.",
    ),
    card("Serial Port", [
      // The browser's Web Serial picker chooses the physical device — there is
      // no OS device path to type. Only the baud rate is a settable parameter.
      h.p([a.class("field-note")], [
        h.text(
          "The serial device is selected in the browser's port dialog when you "
          <> "click Connect (Chromium only — no device path needed).",
        ),
      ]),
      h.div([a.class("field-grid cols-1")], [
        select_field("baud", "Baud Rate", c.baud, [
          "9600", "19200", "38400", "57600", "115200", "250000",
        ]),
      ]),
      h.div([a.class("toggle-row")], [
        h.button(
          [
            a.class(case c.auto_connect {
              True -> "switch on"
              False -> "switch"
            }),
            a.attribute("type", "button"),
            a.attribute("role", "switch"),
            a.attribute("aria-checked", bool_str(c.auto_connect)),
            a.attribute("aria-label", "Auto-connect on startup"),
            event.on_click(ToggleAutoConnect),
          ],
          [h.span([a.class("knob")], [])],
        ),
        h.div([a.class("toggle-text")], [
          h.span([a.class("title")], [h.text("Auto-connect on startup")]),
          h.span([a.class("sub")], [
            h.text(
              "Reconnect a previously-authorized port automatically on load "
              <> "(no picker needed once you've granted a device).",
            ),
          ]),
        ]),
      ]),
    ]),
  ]
}

fn motion_panel(c: Config) -> List(Element(model.Msg)) {
  [
    panel_header(
      "Motion Limits",
      "Maximum travel per axis (mm). These prevent mechanical crashes — operator/hardware settings.",
    ),
    card("Travel Envelope", [
      h.div([a.class("field-grid cols-3")], [
        number_field("max_x", "X Max (mm)", c.max_x),
        number_field("max_y", "Y Max (mm)", c.max_y),
        number_field("max_z", "Z Max (mm)", c.max_z),
      ]),
    ]),
  ]
}

fn spindle_panel(c: Config) -> List(Element(model.Msg)) {
  [
    panel_header(
      "Spindle Control",
      "G-code commands and PWM range to support varied spindle controllers.",
    ),
    card("Spindle G-code", [
      h.div([a.class("field-grid cols-2")], [
        text_field("spindle_on", "Spindle-on Command", c.spindle_on, "M3 S255"),
        text_field("spindle_off", "Spindle-off Command", c.spindle_off, "M5"),
      ]),
    ]),
    card("PWM Range", [
      h.div([a.class("field-grid cols-2")], [
        select_field("pwm_max", "PWM Full Scale", c.pwm_max, ["255", "1000"]),
        number_field("spindle_speed", "Spindle Speed (duty)", c.spindle_speed),
      ]),
    ]),
  ]
}

fn defaults_panel(c: Config) -> List(Element(model.Msg)) {
  [
    panel_header(
      "Drilling Defaults",
      "Tuned Z heights and feeds the G-code generator uses (operator-tunable).",
    ),
    card("Z Reference Heights (mm)", [
      z_height_diagram(),
      h.div([a.class("field-grid cols-3")], [
        number_field("zdrill", "zdrill (plunge)", c.zdrill),
        number_field("zsafe", "zsafe (travel)", c.zsafe),
        number_field("zchange", "zchange (bit change)", c.zchange),
      ]),
    ]),
    card("Feeds & Speeds (mm/min)", [
      h.h4([], [h.text("Dry-run")]),
      h.div([a.class("field-grid cols-3")], [
        number_field("dry_xy_feed", "XY travel", c.dry_xy_feed),
        number_field("dry_plunge_feed", "Plunge", c.dry_plunge_feed),
        number_field("dry_retract_feed", "Retract", c.dry_retract_feed),
      ]),
      h.h4([], [h.text("Drill")]),
      h.div([a.class("field-grid cols-3")], [
        number_field("drill_xy_feed", "XY travel", c.drill_xy_feed),
        number_field("drill_plunge_feed", "Plunge", c.drill_plunge_feed),
        number_field("drill_retract_feed", "Retract", c.drill_retract_feed),
      ]),
    ]),
    card("Hover", [
      h.div([a.class("field-grid cols-2")], [
        number_field("hover", "Dry-run Hover (mm)", c.hover),
      ]),
    ]),
    card("Pause Behaviour", [
      h.div([a.class("toggle-row")], [
        h.button(
          [
            a.class(case c.app_pause {
              True -> "switch on"
              False -> "switch"
            }),
            a.attribute("type", "button"),
            a.attribute("role", "switch"),
            a.attribute("aria-checked", bool_str(c.app_pause)),
            a.attribute("aria-label", "In-app pause"),
            event.on_click(ToggleAppPause),
          ],
          [h.span([a.class("knob")], [])],
        ),
        h.div([a.class("toggle-text")], [
          h.span([a.class("title")], [
            h.text("In-app pause (omit M0; pause/resume on screen)"),
          ]),
          h.span([a.class("sub")], [
            h.text(
              "Pause the stream in-app at touch-off and each bit change with an "
              <> "on-screen Resume, instead of the printer's M0 panel stop. Off "
              <> "keeps M0 (resume on the printer).",
            ),
          ]),
        ]),
      ]),
    ]),
  ]
}

// A schematic side-view of the drill, board, and the Z reference planes, so the
// abstract `zdrill`/`zsafe`/`zchange`/hover numbers have a visual anchor. Not to
// scale — it is an illustration of what each height means relative to the board
// surface (Z = 0), with +Z up.
fn z_height_diagram() -> Element(model.Msg) {
  // viewBox 0..360 x, 0..220 y. The board surface sits at y=150 (Z=0); higher Z
  // is smaller y. Plane y-positions are chosen to read clearly, not to scale.
  let bit_x = 96.0
  let surface_y = 152.0
  let y_change = 24.0
  let y_safe = 64.0
  let y_hover = 124.0
  let y_drill = 182.0

  h.div([a.class("z-diagram")], [
    svg.svg(
      [
        a.attribute("viewBox", "0 0 470 220"),
        a.attribute("preserveAspectRatio", "xMidYMid meet"),
        a.attribute("role", "img"),
        a.attribute(
          "aria-label",
          "Side-view diagram of drill Z reference heights relative to the board "
            <> "surface: zchange highest, then zsafe travel, the board surface "
            <> "at zero, the dry-run hover just above it, and zdrill plunging "
            <> "into the board.",
        ),
        a.class("z-diagram-svg"),
      ],
      list.flatten([
        // ── board (copper-clad) + sacrificial layer ──
        [
          svg.rect([
            a.attribute("x", "30"),
            a.attribute("y", num(surface_y)),
            a.attribute("width", "300"),
            a.attribute("height", "22"),
            a.attribute("fill", "#1b5e20"),
            a.attribute("stroke", "#2a7a31"),
            a.attribute("stroke-width", "1"),
          ]),
          // thin copper top layer
          svg.rect([
            a.attribute("x", "30"),
            a.attribute("y", num(surface_y)),
            a.attribute("width", "300"),
            a.attribute("height", "3"),
            a.attribute("fill", "#c87b35"),
          ]),
          // sacrificial backing board
          svg.rect([
            a.attribute("x", "30"),
            a.attribute("y", num(surface_y +. 22.0)),
            a.attribute("width", "300"),
            a.attribute("height", "14"),
            a.attribute("fill", "#3a2f1c"),
            a.attribute("stroke", "#514532"),
            a.attribute("stroke-width", "1"),
          ]),
        ],
        // ── drill bit + spindle (a simple tool over the board) ──
        [
          // spindle body
          svg.rect([
            a.attribute("x", num(bit_x -. 12.0)),
            a.attribute("y", "8"),
            a.attribute("width", "24"),
            a.attribute("height", "20"),
            a.attribute("rx", "2"),
            a.attribute("fill", "#353534"),
            a.attribute("stroke", "#9e8e78"),
            a.attribute("stroke-width", "1"),
          ]),
          // collet + shank
          svg.rect([
            a.attribute("x", num(bit_x -. 2.5)),
            a.attribute("y", "28"),
            a.attribute("width", "5"),
            a.attribute("height", num(y_hover -. 28.0)),
            a.attribute("fill", "#cdcdcd"),
          ]),
          // bit tip (triangle pointing down to the hover plane)
          svg.path([
            a.attribute(
              "d",
              "M"
                <> num(bit_x -. 2.5)
                <> " "
                <> num(y_hover)
                <> " L"
                <> num(bit_x +. 2.5)
                <> " "
                <> num(y_hover)
                <> " L"
                <> num(bit_x)
                <> " "
                <> num(y_hover +. 8.0)
                <> " Z",
            ),
            a.attribute("fill", "#ffd79b"),
          ]),
        ],
        // ── reference planes (dashed lines + labels) ──
        z_plane(y_change, "zchange", "bit-change lift", "#ffba38"),
        z_plane(y_safe, "zsafe", "travel / XY moves", "#40e56c"),
        z_plane(surface_y, "Z = 0", "board surface", "#9e8e78"),
        z_plane(y_hover, "hover", "dry-run, spindle off", "#00bcd4"),
        z_plane(y_drill, "zdrill", "plunge (real cut)", "#ff6e6e"),
      ]),
    ),
  ])
}

// One labelled horizontal reference plane in the Z diagram.
fn z_plane(
  y: Float,
  name: String,
  desc: String,
  color: String,
) -> List(Element(model.Msg)) {
  [
    svg.line([
      a.attribute("x1", "30"),
      a.attribute("y1", num(y)),
      a.attribute("x2", "330"),
      a.attribute("y2", num(y)),
      a.attribute("stroke", color),
      a.attribute("stroke-width", "1"),
      a.attribute("stroke-dasharray", "4 3"),
      a.attribute("opacity", "0.85"),
    ]),
    svg.text(
      [
        a.attribute("x", "336"),
        a.attribute("y", num(y -. 3.0)),
        a.attribute("fill", color),
        a.attribute("font-size", "9"),
        a.attribute("font-family", "var(--font-data)"),
      ],
      name,
    ),
    svg.text(
      [
        a.attribute("x", "336"),
        a.attribute("y", num(y +. 7.0)),
        a.attribute("fill", "#9e8e78"),
        a.attribute("font-size", "6.5"),
        a.attribute("font-family", "var(--font-data)"),
      ],
      desc,
    ),
  ]
}

fn num(f: Float) -> String {
  float.to_string(f)
}

fn panel_header(title: String, subtitle: String) -> Element(model.Msg) {
  h.div([a.class("panel-header")], [
    h.h1([], [h.text(title)]),
    h.p([], [h.text(subtitle)]),
  ])
}

fn card(title: String, body: List(Element(model.Msg))) -> Element(model.Msg) {
  h.div([a.class("config-card")], [h.h3([], [h.text(title)]), ..body])
}

fn field_id(name: String) -> String {
  "cfg-" <> name
}

fn text_field(
  name: String,
  label: String,
  value: String,
  placeholder: String,
) -> Element(model.Msg) {
  h.div([a.class("field")], [
    h.label([a.attribute("for", field_id(name))], [h.text(label)]),
    h.input([
      a.id(field_id(name)),
      a.type_("text"),
      a.value(value),
      a.placeholder(placeholder),
      event.on_input(fn(v) { SetConfigField(name, v) }),
    ]),
  ])
}

fn number_field(
  name: String,
  label: String,
  value: String,
) -> Element(model.Msg) {
  h.div([a.class("field")], [
    h.label([a.attribute("for", field_id(name))], [h.text(label)]),
    h.input([
      a.id(field_id(name)),
      a.type_("number"),
      a.value(value),
      event.on_input(fn(v) { SetConfigField(name, v) }),
    ]),
  ])
}

fn select_field(
  name: String,
  label: String,
  value: String,
  options: List(String),
) -> Element(model.Msg) {
  h.div([a.class("field")], [
    h.label([a.attribute("for", field_id(name))], [h.text(label)]),
    h.select(
      [
        a.id(field_id(name)),
        event.on_change(fn(v) { SetConfigField(name, v) }),
      ],
      list.map(options, fn(opt) {
        h.option([a.value(opt), a.selected(opt == value)], opt)
      }),
    ),
  ])
}

fn action_bar(model: Model) -> Element(model.Msg) {
  h.div([a.class("action-bar")], [
    h.button(
      [
        a.class("btn-reset"),
        a.attribute("type", "button"),
        event.on_click(model.ResetDefaults),
      ],
      [h.text("⟲ Reset to Defaults")],
    ),
    h.div([a.class("action-right")], [
      case model.config_dirty {
        True -> h.span([a.class("dirty")], [h.text("Unsaved changes detected")])
        False -> element.none()
      },
      h.button(
        [
          a.class("btn-apply"),
          a.attribute("type", "button"),
          event.on_click(ApplyConfig),
        ],
        [h.text("⤓ Apply Configuration")],
      ),
    ]),
  ])
}

// ── helpers ────────────────────────────────────────────────────────────────

fn progress_pct(drilled: Int, total: Int) -> Int {
  case total {
    0 -> 0
    _ -> drilled * 100 / total
  }
}

fn bool_str(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

fn fmt2(v: Float) -> String {
  let scaled = int.to_float(float.round(v *. 100.0)) /. 100.0
  float.to_string(scaled)
}

fn fmt3(v: Float) -> String {
  let scaled = int.to_float(float.round(v *. 1000.0)) /. 1000.0
  float.to_string(scaled)
}

// Round to a whole number (for the tilt azimuth, where sub-degree precision is
// noise).
fn fmt0(v: Float) -> String {
  int.to_string(float.round(v))
}

// A jog step / diameter as a tidy label: 0.1, 1.0, 10, 1.2 …
fn fmt_step(s: Float) -> String {
  case s == 10.0 {
    True -> "10"
    False -> float.to_string(s)
  }
}
