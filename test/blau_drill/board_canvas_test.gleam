//// Board-canvas projection tests.
////
//// The canvas is orientation-agnostic: any board flip (front/back, copper-up)
//// is baked into the WORKING board upstream (`bridge.working_board_model`), so
//// the canvas has NO mirror logic. Click-to-jump correctness still rests on
//// `project` and `unproject` being exact inverses, so these tests pin
//// project∘unproject round-trips to identity.

import blau_drill/ui/board_canvas.{CanvasData}
import blau_drill/ui/model.{BBox, ConfNone, Head, NoHeadPos}
import gleam/float
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import lustre/element

fn approx(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. 0.000001
}

fn bbox() -> model.BBox {
  // An asymmetric board so a sign error would be detectable.
  BBox(minx: 0.0, miny: 0.0, maxx: 81.28, maxy: 83.82)
}

// ── round-trip identity (the click-correctness guarantee) ─────────────────────

pub fn roundtrip_is_identity_test() {
  let #(x, y) = board_canvas.roundtrip_board_point(bbox(), 12.5, 60.0)
  approx(x, 12.5) |> should.be_true
  approx(y, 60.0) |> should.be_true
}

pub fn roundtrip_identity_at_corner_test() {
  let #(x, y) = board_canvas.roundtrip_board_point(bbox(), 0.0, 0.0)
  approx(x, 0.0) |> should.be_true
  approx(y, 0.0) |> should.be_true

  let #(x2, y2) = board_canvas.roundtrip_board_point(bbox(), 81.28, 83.82)
  approx(x2, 81.28) |> should.be_true
  approx(y2, 83.82) |> should.be_true
}

// ── the projection does NOT mirror (the canvas is orientation-agnostic) ───────
// X is a straight shift, not a reflection: distinct board X values round-trip to
// themselves and stay distinct, with no swap about the board centre. Any flip is
// the working board's job, not the canvas's.

pub fn projection_does_not_mirror_x_test() {
  let left = board_canvas.roundtrip_board_point(bbox(), 10.0, 40.0)
  let right = board_canvas.roundtrip_board_point(bbox(), 70.0, 40.0)
  // Each point round-trips to itself (no reflection about the X centre).
  approx(left.0, 10.0) |> should.be_true
  approx(right.0, 70.0) |> should.be_true
  // Distinct points stay distinct (the mapping is a bijection, no collapse).
  { left.0 == right.0 } |> should.be_false
}

// ── downhill tilt arrow render guard (Align + non-flat only) ──────────────────
// A bare CanvasData fixture varied only by stage/tilt; the arrow is rendered iff
// stage == Align AND tilt is Some with a non-flat magnitude. We grep the SVG
// string for the "tilt-arrow" class — see board_canvas.tilt_arrow.

fn base_data(
  stage: model.Screen,
  tilt: option.Option(#(Float, Float)),
) -> board_canvas.CanvasData {
  CanvasData(
    holes: [],
    outline: [],
    fiducials: [],
    tools: [],
    bbox: bbox(),
    head: Head(0.0, 0.0, 0.0),
    head_pos: NoHeadPos,
    head_confidence: ConfNone,
    stage: stage,
    zoom: 1.0,
    point_residuals: [],
    worst_index: -1,
    tilt: tilt,
  )
}

fn renders_arrow(data: board_canvas.CanvasData) -> Bool {
  board_canvas.view(data)
  |> element.to_string
  |> string.contains("tilt-arrow")
}

pub fn tilt_arrow_drawn_in_align_when_tilted_test() {
  renders_arrow(base_data(model.Align, Some(#(5.0, 0.0)))) |> should.be_true
}

pub fn tilt_arrow_absent_without_tilt_test() {
  renders_arrow(base_data(model.Align, None)) |> should.be_false
}

pub fn tilt_arrow_absent_outside_align_test() {
  renders_arrow(base_data(model.DryRun, Some(#(5.0, 0.0)))) |> should.be_false
}

pub fn tilt_arrow_absent_when_flat_test() {
  // A near-zero tilt is below the epsilon — a flat board gets no arrow.
  renders_arrow(base_data(model.Align, Some(#(0.01, 0.0)))) |> should.be_false
}
