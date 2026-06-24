//// Unit tests for `ui/bridge` — the pure translation layer between the domain /
//// control values and the flat UI model. These guard the wiring that connects a
//// parsed board, the control FSM, and the operator config into what the views
//// render and what a run consumes.

import blau_drill/control/printer
import blau_drill/domain/board_model
import blau_drill/domain/config
import blau_drill/ui/bridge
import blau_drill/ui/mock
import blau_drill/ui/model
import gleam/dict
import gleam/float
import gleam/list
import gleam/string
import gleeunit/should

import blau_drill/fixtures

const eps = 1.0e-9

fn close(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. eps
}

fn point_close(a: #(Float, Float), b: #(Float, Float)) -> Bool {
  close(a.0, b.0) && close(a.1, b.1)
}

// Parse the real segby fixture into a domain BoardModel.
fn board() -> board_model.BoardModel {
  let assert Ok(bm) = board_model.parse_drl(fixtures.segby_drl())
  bm
}

// ── feature_candidates ───────────────────────────────────────────────────────

pub fn feature_candidates_count_in_range_test() {
  let cs = bridge.feature_candidates(board())
  let n = list.length(cs)
  // The 4 bbox-corner-nearest holes, deduped — between 3 and 4 distinct points.
  { n >= 3 && n <= 4 } |> should.be_true
}

pub fn feature_candidates_are_real_holes_test() {
  let bm = board()
  let hole_points = list.map(bm.holes, fn(h) { #(h.x, h.y) })
  let cs = bridge.feature_candidates(bm)
  // Every candidate is an actual hole coordinate on the board.
  list.all(cs, fn(c) { list.any(hole_points, fn(hp) { point_close(hp, c) }) })
  |> should.be_true
}

pub fn feature_candidates_no_duplicates_test() {
  let cs = bridge.feature_candidates(board())
  let deduped =
    list.fold(cs, [], fn(acc, p) {
      case list.any(acc, fn(q) { point_close(q, p) }) {
        True -> acc
        False -> [p, ..acc]
      }
    })
  // Deduping yields the same number of points ⇒ no duplicates already.
  list.length(deduped) |> should.equal(list.length(cs))
}

pub fn feature_candidates_enough_to_fit_test() {
  // The alignment fit needs >= 3 non-collinear correspondences; the candidate
  // set must offer at least 3 distinct points for the operator to capture.
  let cs = bridge.feature_candidates(board())
  { list.length(cs) >= 3 } |> should.be_true
}

// ── printer_state ────────────────────────────────────────────────────────────

pub fn printer_state_disconnected_test() {
  bridge.printer_state(printer.Disconnected) |> should.equal(model.Disconnected)
}

pub fn printer_state_idle_test() {
  bridge.printer_state(printer.Idle(line_no: 0, pending: printer.PendingNone))
  |> should.equal(model.Idle)
}

pub fn printer_state_jogging_test() {
  bridge.printer_state(printer.Jogging(
    line_no: 3,
    pending: printer.PendingWhere,
  ))
  |> should.equal(model.Jogging)
}

pub fn printer_state_streaming_test() {
  let job = printer.StreamJob(lines: ["G0 X1"], idx: 0, total: 1)
  bridge.printer_state(printer.Streaming(line_no: 1, job: job))
  |> should.equal(model.Streaming)
}

pub fn printer_state_faulted_test() {
  bridge.printer_state(printer.Faulted) |> should.equal(model.Faulted)
}

// ── parse_error_message ──────────────────────────────────────────────────────

pub fn parse_error_messages_non_empty_test() {
  let msgs = [
    bridge.parse_error_message(board_model.MissingDrl),
    bridge.parse_error_message(board_model.MissingM48Header),
    bridge.parse_error_message(board_model.NoHoles),
    bridge.parse_error_message(board_model.HoleWithNoTool("X1Y1")),
    bridge.parse_error_message(
      board_model.AbsolutePageCoordinates(
        board_model.CoordinateOverBedSize(threshold_mm: 250.0, sample: []),
      ),
    ),
  ]
  // Each message is non-empty.
  list.all(msgs, fn(m) { m != "" }) |> should.be_true
}

pub fn parse_error_messages_distinct_test() {
  let msgs = [
    bridge.parse_error_message(board_model.MissingDrl),
    bridge.parse_error_message(board_model.MissingM48Header),
    bridge.parse_error_message(board_model.NoHoles),
    bridge.parse_error_message(board_model.HoleWithNoTool("X1Y1")),
    bridge.parse_error_message(
      board_model.AbsolutePageCoordinates(
        board_model.CoordinateOverBedSize(threshold_mm: 250.0, sample: []),
      ),
    ),
  ]
  // All five messages are distinct (dedup keeps all 5).
  let uniq = list.unique(msgs)
  list.length(uniq) |> should.equal(5)
}

pub fn parse_error_hole_with_no_tool_includes_line_test() {
  bridge.parse_error_message(board_model.HoleWithNoTool("X1Y1"))
  |> should.equal("Hole with no selected tool: X1Y1")
}

pub fn parse_error_absolute_page_mentions_origin_test() {
  let msg =
    bridge.parse_error_message(
      board_model.AbsolutePageCoordinates(
        board_model.CoordinateOverBedSize(threshold_mm: 250.0, sample: []),
      ),
    )
  // The guidance is about the drill origin not being set.
  string.contains(msg, "origin") |> should.be_true
  string.contains(msg, "fiducial") |> should.be_true
}

// ── gcode_config ─────────────────────────────────────────────────────────────

pub fn gcode_config_parses_default_config_test() {
  // mock.default_config() carries valid numeric strings; coercion parses them.
  let cfg = bridge.gcode_config(mock.default_config(), config.DryRun)
  cfg.mode |> should.equal(config.DryRun)
  close(cfg.zdrill, -1.5) |> should.be_true
  close(cfg.zsafe, 3.0) |> should.be_true
  close(cfg.zchange, 15.0) |> should.be_true
  close(cfg.drill_feed, 120.0) |> should.be_true
  cfg.spindle_speed |> should.equal(200)
  close(cfg.hover, 1.0) |> should.be_true
}

pub fn gcode_config_carries_drill_mode_test() {
  let cfg = bridge.gcode_config(mock.default_config(), config.Drill)
  cfg.mode |> should.equal(config.Drill)
}

// app_pause defaults True in the model config and coerces through unchanged.
pub fn gcode_config_app_pause_defaults_true_test() {
  let cfg = bridge.gcode_config(mock.default_config(), config.DryRun)
  cfg.app_pause |> should.be_true
}

pub fn gcode_config_coerces_app_pause_true_test() {
  let c = model.Config(..mock.default_config(), app_pause: True)
  bridge.gcode_config(c, config.DryRun).app_pause |> should.be_true
}

pub fn gcode_config_coerces_app_pause_false_test() {
  let c = model.Config(..mock.default_config(), app_pause: False)
  bridge.gcode_config(c, config.Drill).app_pause |> should.be_false
}

pub fn gcode_config_malformed_field_falls_back_to_default_test() {
  // A non-numeric zdrill falls back to the generator default (-2.5), NOT the
  // config's own value — gcode_config uses config.default() for fallbacks.
  let c = model.Config(..mock.default_config(), zdrill: "not-a-number")
  let cfg = bridge.gcode_config(c, config.DryRun)
  close(cfg.zdrill, config.default_zdrill) |> should.be_true
  // The other (valid) fields are unaffected.
  close(cfg.zsafe, 3.0) |> should.be_true
}

pub fn gcode_config_malformed_spindle_speed_falls_back_test() {
  let c = model.Config(..mock.default_config(), spindle_speed: "garbage")
  let cfg = bridge.gcode_config(c, config.DryRun)
  cfg.spindle_speed |> should.equal(config.default_spindle_speed)
}

// ── baud ─────────────────────────────────────────────────────────────────────

pub fn baud_parses_config_test() {
  bridge.baud(mock.default_config()) |> should.equal(115_200)
}

pub fn baud_bad_string_falls_back_test() {
  let c = model.Config(..mock.default_config(), baud: "fast")
  bridge.baud(c) |> should.equal(115_200)
}

// ── spindle_commands ─────────────────────────────────────────────────────────

pub fn spindle_commands_returns_configured_test() {
  let c =
    model.Config(
      ..mock.default_config(),
      spindle_on: "M3 S100",
      spindle_off: "M5",
    )
  bridge.spindle_commands(c) |> should.equal(#("M3 S100", "M5"))
}

// ── board_to_machine / inverse ───────────────────────────────────────────────

// With NoTransform and 0 captures there is nothing to map with.
pub fn board_to_machine_no_captures_errors_test() {
  bridge.board_to_machine(model.NoTransform, [], #(1.0, 2.0))
  |> should.equal(Error(Nil))
}

pub fn board_to_machine_inverse_no_captures_errors_test() {
  bridge.board_to_machine_inverse([], model.Head(1.0, 2.0, 0.0))
  |> should.equal(Error(Nil))
}

// One capture ⇒ pure translation. With board == machine the offset is 0, so a
// board point maps to itself; inverting recovers it.
pub fn board_to_machine_one_capture_identity_test() {
  let caps = [model.Capture(board: #(0.0, 0.0), machine: #(0.0, 0.0))]
  let assert Ok(m) =
    bridge.board_to_machine(model.NoTransform, caps, #(5.0, 7.0))
  point_close(m, #(5.0, 7.0)) |> should.be_true
}

pub fn board_to_machine_one_capture_translation_test() {
  // board₁ = (10, 10), machine₁ = (12, 8) ⇒ offset (board-machine) = (-2, +2).
  // machine = board - (board₁ - machine₁) = board - (-2, +2) = board + (2, -2).
  let caps = [model.Capture(board: #(10.0, 10.0), machine: #(12.0, 8.0))]
  let assert Ok(m) =
    bridge.board_to_machine(model.NoTransform, caps, #(20.0, 20.0))
  point_close(m, #(22.0, 18.0)) |> should.be_true
}

pub fn board_to_machine_forward_then_inverse_identity_test() {
  // Two captures where board == machine ⇒ similarity is the identity. Mapping a
  // board point forward then back recovers it (within epsilon).
  let caps = [
    model.Capture(board: #(0.0, 0.0), machine: #(0.0, 0.0)),
    model.Capture(board: #(10.0, 0.0), machine: #(10.0, 0.0)),
  ]
  let assert Ok(m) =
    bridge.board_to_machine(model.NoTransform, caps, #(3.0, 4.0))
  let assert Ok(b) =
    bridge.board_to_machine_inverse(caps, model.Head(m.0, m.1, 0.0))
  point_close(b, #(3.0, 4.0)) |> should.be_true
}

pub fn board_to_machine_two_captures_pure_translation_test() {
  // A pure (10, -5) translation captured twice: board point + (10, -5) = machine.
  let caps = [
    model.Capture(board: #(0.0, 0.0), machine: #(10.0, -5.0)),
    model.Capture(board: #(4.0, 0.0), machine: #(14.0, -5.0)),
  ]
  let assert Ok(m) =
    bridge.board_to_machine(model.NoTransform, caps, #(2.0, 3.0))
  point_close(m, #(12.0, -2.0)) |> should.be_true
}

pub fn board_to_machine_inverse_one_capture_translation_test() {
  // 1 capture inverse: board ≈ machine + (board₁ − machine₁).
  // board₁=(10,10), machine₁=(12,8) ⇒ (board₁-machine₁)=(-2,+2).
  // head at (22, 18) ⇒ board = (22,18)+(-2,2) = (20, 20).
  let caps = [model.Capture(board: #(10.0, 10.0), machine: #(12.0, 8.0))]
  let assert Ok(b) =
    bridge.board_to_machine_inverse(caps, model.Head(22.0, 18.0, 0.0))
  point_close(b, #(20.0, 20.0)) |> should.be_true
}

// ── board_of / diagnostic_of ─────────────────────────────────────────────────

pub fn board_of_hole_count_matches_model_test() {
  let bm = board()
  let b = bridge.board_of(bm)
  // The translation carries every hole verbatim.
  list.length(b.holes) |> should.equal(list.length(bm.holes))
  // And the fixture has 130 holes.
  list.length(b.holes) |> should.equal(130)
}

pub fn board_of_tool_count_matches_model_test() {
  let bm = board()
  let b = bridge.board_of(bm)
  list.length(b.tools) |> should.equal(dict.size(bm.tools))
  // The fixture defines 5 tools (T1..T5).
  list.length(b.tools) |> should.equal(5)
}

pub fn board_of_bbox_matches_model_test() {
  let bm = board()
  let b = bridge.board_of(bm)
  let #(minx, miny, maxx, maxy) = bm.bbox
  close(b.bbox.minx, minx) |> should.be_true
  close(b.bbox.miny, miny) |> should.be_true
  close(b.bbox.maxx, maxx) |> should.be_true
  close(b.bbox.maxy, maxy) |> should.be_true
}

pub fn board_of_holes_default_pending_test() {
  let b = bridge.board_of(board())
  list.all(b.holes, fn(h) { h.status == model.Pending }) |> should.be_true
}

pub fn diagnostic_of_counts_match_model_test() {
  let bm = board()
  let d = bridge.diagnostic_of(bm)
  d.hole_count |> should.equal(list.length(bm.holes))
  d.tool_count |> should.equal(dict.size(bm.tools))
  d.hole_count |> should.equal(130)
  d.tool_count |> should.equal(5)
}

pub fn diagnostic_of_dimensions_match_bbox_test() {
  let bm = board()
  let d = bridge.diagnostic_of(bm)
  let #(minx, miny, maxx, maxy) = bm.bbox
  // diagnostic rounds to 2dp; assert within a coarse epsilon of the raw span.
  { float.absolute_value(d.width -. { maxx -. minx }) <. 0.01 }
  |> should.be_true
  { float.absolute_value(d.height -. { maxy -. miny }) <. 0.01 }
  |> should.be_true
}
