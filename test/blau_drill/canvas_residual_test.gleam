//// Canvas residual-annotation tests.
////
//// After a fit, the board canvas annotates each CAPTURED fiducial with its
//// per-point residual (mm) and highlights the WORST one. The SVG rendering
//// itself isn't unit-tested, but the data-selection logic that drives it is:
//// looking a fiducial's residual up by its index, and resolving / flagging the
//// worst point. These pin "fiducial index N shows residual E, worst is W".

import blau_drill/ui/board_canvas
import blau_drill/ui/model.{HaveWorst, NoWorst, PointResidual}
import gleam/float
import gleam/option.{None, Some}
import gleeunit/should

fn approx(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. 0.000001
}

// ── residual_for: look a fiducial's residual up by index ──────────────────────

pub fn residual_for_finds_point_by_index_test() {
  let residuals = [
    PointResidual(index: 0, error_mm: 0.08),
    PointResidual(index: 1, error_mm: 0.21),
    PointResidual(index: 2, error_mm: 1.43),
  ]
  // Fiducial at index 2 shows its residual 1.43 mm.
  let assert Some(e) = board_canvas.residual_for(residuals, 2)
  approx(e, 1.43) |> should.be_true

  let assert Some(e0) = board_canvas.residual_for(residuals, 0)
  approx(e0, 0.08) |> should.be_true
}

pub fn residual_for_missing_index_is_none_test() {
  let residuals = [PointResidual(index: 0, error_mm: 0.08)]
  // An index without a residual (e.g. an uncaptured/pending fiducial) → no label.
  board_canvas.residual_for(residuals, 3) |> should.equal(None)
}

pub fn residual_for_empty_is_none_test() {
  // No fit yet → no residuals → nothing is annotated.
  board_canvas.residual_for([], 0) |> should.equal(None)
}

// ── worst_index_of: resolve the worst fiducial index from WorstOpt ────────────

pub fn worst_index_of_have_worst_test() {
  // Worst is the index-2 point (error 1.43); that fiducial is the flagged one.
  let worst = HaveWorst(PointResidual(index: 2, error_mm: 1.43))
  board_canvas.worst_index_of(worst) |> should.equal(2)
}

pub fn worst_index_of_no_worst_is_negative_test() {
  // No worst (degenerate / no fit) → -1 so no fiducial is ever flagged.
  board_canvas.worst_index_of(NoWorst) |> should.equal(-1)
}

// ── is_worst_index: only flag the matching index, never pre-fit ───────────────

pub fn is_worst_index_flags_only_matching_test() {
  board_canvas.is_worst_index(2, 2) |> should.be_true
  board_canvas.is_worst_index(2, 0) |> should.be_false
  board_canvas.is_worst_index(2, 1) |> should.be_false
}

pub fn is_worst_index_never_flags_when_no_fit_test() {
  // worst_index -1 (no fit): no index, not even -1-ish noise, is flagged.
  board_canvas.is_worst_index(-1, 0) |> should.be_false
  board_canvas.is_worst_index(-1, -1) |> should.be_false
}

// ── end-to-end data selection (the contract the canvas renders) ───────────────
// Fiducial index N shows residual E, and the worst (index W) is flagged.

pub fn fiducial_annotation_selection_test() {
  let residuals = [
    PointResidual(index: 0, error_mm: 0.08),
    PointResidual(index: 1, error_mm: 0.21),
    PointResidual(index: 2, error_mm: 1.43),
  ]
  let worst_index =
    board_canvas.worst_index_of(HaveWorst(PointResidual(2, 1.43)))

  // Each captured fiducial's label value is its own residual.
  let assert Some(e0) = board_canvas.residual_for(residuals, 0)
  let assert Some(e1) = board_canvas.residual_for(residuals, 1)
  let assert Some(e2) = board_canvas.residual_for(residuals, 2)
  approx(e0, 0.08) |> should.be_true
  approx(e1, 0.21) |> should.be_true
  approx(e2, 1.43) |> should.be_true

  // Only fiducial 2 is the worst.
  board_canvas.is_worst_index(worst_index, 0) |> should.be_false
  board_canvas.is_worst_index(worst_index, 1) |> should.be_false
  board_canvas.is_worst_index(worst_index, 2) |> should.be_true
}
