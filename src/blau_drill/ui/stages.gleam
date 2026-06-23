//// The five stage views + the settings screen. Each is a pure function of the
//// model (load / align / dry-run / drill / done, plus settings).
////
//// The right-hand control asides preserve the safety-gate model exactly:
////   * jog / spindle controls are DISABLED unless the printer is `Jogging`
////     (motors energized) — energize-before-jog.
////   * Capture / Fit / Proceed enable only when their preconditions hold.
////   * Confirm-registration (the only path to drilling) is a hazard-striped
////     two-step gate routed through dry-run.

import blau_drill/domain/job
import blau_drill/ui/board_canvas.{type CanvasData, CanvasData}
import blau_drill/ui/mock
import blau_drill/ui/model.{
  type Config, type Model, type SettingsCategory, ApplyConfig, CaptureFiducial,
  ConfirmRegistration, Connection, Defaults, Energize, Fit, Jog, Jogging,
  MotionLimits, NewBoard, ParseBoard, Recapture, RedoAlignment, Release,
  RestartAlignment, ResumeDrilling, RunDryRun, SelectCategory, SelectFile,
  SelectOutline, SetConfigField, SetJogStep, SpindleControl, StartRegistering,
  TestSpindle, ToggleAutoConnect,
}
import gleam/float
import gleam/int
import gleam/list
import lustre/attribute as a
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/element/svg
import lustre/event

// ── canvas data assembly (the Phase-4 seam for board/head/fiducials) ─────────

fn canvas_data(model: Model) -> CanvasData {
  let board = case model.board {
    model.HaveBoard(b) -> b
    model.NoBoard -> mock.board()
  }
  // fiducials = captured + pending candidates not yet captured.
  let fiducials = list.append(model.captured, pending_fiducials(model))
  // Per-fiducial residuals from the last fit (empty / -1 before a fit), so the
  // canvas annotates each captured marker with its error and flags the worst.
  let #(point_residuals, worst_index) = case model.fit_diag {
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
    head_pos: model.head_pos,
    head_confidence: model.head_confidence,
    stage: model.screen,
    zoom: model.zoom,
    point_residuals: point_residuals,
    worst_index: worst_index,
  )
}

fn pending_fiducials(model: Model) -> List(model.Fiducial) {
  let captured_idx = list.map(model.captured, fn(f) { f.index })
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
          a.disabled(model.printer == model.Disconnected),
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

pub fn align(model: Model) -> Element(model.Msg) {
  let motors_online = model.printer == Jogging
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
      motors_panel(motors_online),
      jog_panel(model, motors_online),
      h.button(
        [
          a.class("btn btn-primary btn-block btn-lg"),
          a.attribute("type", "button"),
          a.disabled(!motors_online),
          event.on_click(CaptureFiducial),
        ],
        [
          h.text(
            "Capture Fiducial ("
            <> int.to_string(list.length(model.captured))
            <> "/"
            <> int.to_string(model.fiducial_target)
            <> ")",
          ),
        ],
      ),
      h.button(
        [
          a.class("btn btn-surface btn-block"),
          a.attribute("type", "button"),
          a.disabled(list.length(model.captured) < 3),
          event.on_click(Fit),
        ],
        [h.text("Fit Alignment")],
      ),
      h.button(
        [
          a.class("btn btn-outline btn-block"),
          a.attribute("type", "button"),
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
          a.disabled(model.quality < 0 || model.alignment_rejected),
          event.on_click(RunDryRun),
        ],
        [h.text("Proceed to Dry-run →")],
      ),
    ]),
  ])
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

fn quality_panel(model: Model) -> Element(model.Msg) {
  case model.quality < 0 {
    True -> element.none()
    False -> {
      let #(cls, label) = quality_class(model.quality)
      h.div([a.class("panel")], [
        h.div([a.class("panel-head")], [
          h.span([a.class("panel-head-label")], [h.text("Est. Quality")]),
          h.span([a.class("quality-value " <> cls)], [
            h.text(int.to_string(model.quality) <> "% " <> label),
          ]),
        ]),
        h.div([a.class("quality-track")], [
          h.div(
            [
              a.class("quality-fill " <> cls),
              a.style("width", int.to_string(model.quality) <> "%"),
            ],
            [],
          ),
        ]),
        h.p([a.class("residuals")], [
          h.text(
            "residual max "
            <> fmt3(model.residual_max)
            <> " mm · rms "
            <> fmt3(model.residual_rms)
            <> " mm",
          ),
        ]),
      ])
    }
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
  case model.alignment_rejected {
    False -> element.none()
    True -> {
      let #(hint, points, can_override) = case model.fit_diag {
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
                    <> fmt3(model.residual_max)
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
                    h.text(
                      "Proceed anyway (" <> fmt3(model.residual_max) <> " mm)",
                    ),
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
  case model.progress {
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
  let #(pct, drilled, total) = case model.progress {
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
        telemetry_row("Current Bit", model.telemetry_bit, "primary"),
        telemetry_row("Est. Time Remaining", model.telemetry_eta, "secondary"),
        telemetry_row("Spindle", model.telemetry_spindle, ""),
      ]),
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
    bit_change_modal(model),
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
  let drilled_all = case model.progress {
    model.HaveProgress(p) -> p.drilled >= p.total && p.total > 0
    model.NoProgress -> False
  }
  let has_modal = case model.bit_change {
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

fn bit_change_modal(model: Model) -> Element(model.Msg) {
  case model.bit_change {
    model.HaveBitChange(bc) ->
      h.div([a.class("modal-scrim")], [
        h.div([a.class("modal")], [
          h.span([a.class("modal-icon"), a.attribute("aria-hidden", "true")], [
            h.text("⚠"),
          ]),
          h.h3([], [h.text("Bit Change Required")]),
          h.p([a.class("modal-paused")], [h.text("System Paused")]),
          h.p([a.class("modal-body")], [
            h.text("Swap to "),
            h.strong([], [h.text(fmt_step(bc.diameter) <> "mm")]),
            h.text(" bit to continue."),
          ]),
          h.p([a.class("modal-warn")], [
            h.text(
              "Warning: do not move the board substrate during the change — "
              <> "alignment will be lost.",
            ),
          ]),
          h.button(
            [
              a.class("btn btn-primary btn-block btn-lg"),
              a.style("margin-top", "1.25rem"),
              a.attribute("type", "button"),
              event.on_click(ResumeDrilling),
            ],
            [h.text("▶ Resume Drilling")],
          ),
        ]),
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
  case model.summary {
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
    card("Feed & Hover", [
      h.div([a.class("field-grid cols-2")], [
        number_field("drill_feed", "Drill Feed (mm/min)", c.drill_feed),
        number_field("hover", "Dry-run Hover (mm)", c.hover),
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

// A jog step / diameter as a tidy label: 0.1, 1.0, 10, 1.2 …
fn fmt_step(s: Float) -> String {
  case s == 10.0 {
    True -> "10"
    False -> float.to_string(s)
  }
}
