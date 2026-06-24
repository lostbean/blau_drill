//// Tests for the alignment-fit diagnostics (bridge.diagnose_fit) — the
//// actionable feedback shown when a fit is over tolerance: per-point residuals,
//// the worst point, and a likely-cause hint. Plus alignment.point_errors, the
//// per-correspondence residual the diagnosis is built from.

import blau_drill/domain/alignment
import blau_drill/domain/correspondence.{Correspondence}
import blau_drill/ui/bridge
import blau_drill/ui/model
import gleam/float
import gleam/list
import gleam/string
import gleeunit/should

fn approx(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. 0.0001
}

// ── alignment.point_errors ────────────────────────────────────────────────────

pub fn point_errors_zero_for_exact_fit_test() {
  // Identity-recoverable correspondences (board == machine) → ~0 error each.
  let cs = [
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: 0.0),
    Correspondence(board: #(10.0, 0.0), machine: #(10.0, 0.0), machine_z: 0.0),
    Correspondence(board: #(0.0, 10.0), machine: #(0.0, 10.0), machine_z: 0.0),
  ]
  let assert Ok(al) = alignment.fit(cs)
  let errs = alignment.point_errors(al.transform, cs)
  list.length(errs) |> should.equal(3)
  list.all(errs, fn(e) { e <. 0.0001 }) |> should.be_true
}

pub fn point_errors_in_capture_order_test() {
  // Four points where one (index 2) is deliberately displaced so the fit can't
  // satisfy it: its residual should be the largest, and the list stays ordered.
  let cs = [
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: 0.0),
    Correspondence(board: #(10.0, 0.0), machine: #(10.0, 0.0), machine_z: 0.0),
    Correspondence(board: #(0.0, 10.0), machine: #(5.0, 13.0), machine_z: 0.0),
    // displaced
    Correspondence(board: #(10.0, 10.0), machine: #(10.0, 10.0), machine_z: 0.0),
  ]
  let assert Ok(al) = alignment.fit(cs)
  let errs = alignment.point_errors(al.transform, cs)
  list.length(errs) |> should.equal(4)
  // index 2 has the largest residual
  let assert [_, _, e2, _] = errs
  let max = list.fold(errs, 0.0, float.max)
  approx(e2, max) |> should.be_true
}

// ── diagnose_fit: per-point + worst + hint ────────────────────────────────────

pub fn diagnose_reports_all_points_and_worst_test() {
  // errors: point index 2 is the clear outlier.
  let diag = bridge.diagnose_fit([0.02, 0.03, 1.5, 0.01], 0.1)
  list.length(diag.points) |> should.equal(4)
  case diag.worst {
    model.HaveWorst(w) -> {
      w.index |> should.equal(2)
      approx(w.error_mm, 1.5) |> should.be_true
    }
    model.NoWorst -> should.fail()
  }
}

pub fn diagnose_outlier_hint_names_the_point_test() {
  // One point way off, the rest within tol → hint should point at THAT point and
  // suggest recapturing just it.
  let diag = bridge.diagnose_fit([0.02, 0.03, 1.5, 0.01], 0.1)
  // "Point 3" (1-based display of index 2)
  string.contains(diag.hint, "Point 3") |> should.be_true
  string.contains(diag.hint, "mis-captured") |> should.be_true
}

pub fn diagnose_systematic_hint_when_all_over_tol_test() {
  // All points over tolerance → systematic-error guidance (origin / shift).
  let diag = bridge.diagnose_fit([0.5, 0.6, 0.55, 0.7], 0.1)
  string.contains(diag.hint, "All points are over tolerance")
  |> should.be_true
  string.contains(diag.hint, "origin") |> should.be_true
}

pub fn degenerate_diagnosis_gives_geometry_guidance_test() {
  let diag = bridge.degenerate_diagnosis()
  diag.points |> should.equal([])
  diag.worst |> should.equal(model.NoWorst)
  diag.can_override |> should.be_false
  string.contains(diag.hint, "line") |> should.be_true
}
