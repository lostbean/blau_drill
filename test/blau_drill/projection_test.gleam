//// Tests for the pure PROJECTIONS of the `Model`'s machines (ADR-0018).
////
//// `ui/projection.gleam` recomputes every alignment / streaming / telemetry /
//// summary value off its authority (the `job` FSM, the `printer`/`controller`
//// FSM, the board, `applied_config`) each frame. This suite pins the 13
//// projections that had no test file: the alignment group (`quality`,
//// `residuals`/`residual_max`/`residual_rms`, `fit_diag`, `project_head`), the
//// streaming/Done group (`drilled_count`, `confirmed_hole_ids`,
//// `bit_changes_seen`, `summary`) and the telemetry group (`telemetry_bit`,
//// `telemetry_eta`, `telemetry_spindle`).
////
//// Each projection is asserted against a constructed AUTHORITY: a `Model` built
//// via `test_support`, its `job`/`controller` advanced to the right state, then
//// the projection compared to an independently-derived expectation.

import blau_drill/app
import blau_drill/control/controller
import blau_drill/control/printer
import blau_drill/domain/config
import blau_drill/domain/correspondence.{Correspondence}
import blau_drill/domain/fit_geometry.{Mirrored, Plausible, Suspect}
import blau_drill/domain/gcode_program.{
  type RenderedLine, DrillHoleKind, LineOrigin, PauseKind, RenderedLine,
  ToolBlockKind,
}
import blau_drill/domain/job
import blau_drill/domain/transform2d
import blau_drill/test_support.{
  aligned_jogging_model, base_model, pump_through_pause,
}
import blau_drill/ui/model.{
  type Model, ConfAligned, HaveBoard, HaveFitDiag, HaveFitGeometry,
  HaveFitSanity, HaveJob, HaveSummary, HaveTransform, NoBoard, NoFitDiag,
  NoFitGeometry, NoFitSanity, NoSummary, Summary,
}
import blau_drill/ui/projection
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn approx(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. 1.0e-9
}

// ── authorities ───────────────────────────────────────────────────────────────

/// A rejected (over-tolerance) fit on a real job, placed on a base model. Four
/// near-identity correspondences with a +0.4mm Y nudge produce residuals.max ~
/// 0.1 > the 0.05 gate, so the job lands in `AlignmentRejected` carrying the
/// solved (over-tol) alignment + residuals — exactly the standing state the
/// rejected-box / fit-diag projections read.
fn rejected_model() -> Model {
  let base = base_model()
  let assert HaveJob(j0) = base.job
  let assert Ok(reg) = job.transition(j0, job.StartRegistering)
  let j =
    [
      Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: -1.0),
      Correspondence(board: #(1.0, 0.0), machine: #(1.0, 0.0), machine_z: -1.0),
      Correspondence(board: #(0.0, 1.0), machine: #(0.0, 1.0), machine_z: -1.0),
      Correspondence(board: #(1.0, 1.0), machine: #(1.0, 1.4), machine_z: -1.0),
    ]
    |> list.fold(reg, fn(acc, corr) {
      let assert Ok(acc) = job.transition(acc, job.Capture(corr))
      acc
    })
  let assert Ok(rejected) = job.transition(j, job.Fit(0.05))
  model.Model(..base, job: HaveJob(rejected))
}

/// A MIRRORED-but-exact fit on a real job, in the `Aligned` state. The board ->
/// machine map mirrors X (`(bx, by) -> (-bx, by)`), so the solved transform has
/// `det < 0` (mirrored) yet projects every captured point EXACTLY — residual 0,
/// so a generous tolerance lands the job in `Aligned` (not `AlignmentRejected`).
/// This is the seam for putting a KNOWN non-identity Alignment on a SOLVED-
/// alignment model so the sanity projection has to flag `Mirrored`. (Scale,
/// shear, tilt are all clean here, so the only flag is the mirror.)
fn suspect_aligned_model() -> Model {
  let base = base_model()
  let assert HaveJob(j0) = base.job
  let assert Ok(reg) = job.transition(j0, job.StartRegistering)
  let j =
    [
      Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: -1.0),
      Correspondence(board: #(2.0, 0.0), machine: #(-2.0, 0.0), machine_z: -1.0),
      Correspondence(board: #(0.0, 2.0), machine: #(0.0, 2.0), machine_z: -1.0),
      Correspondence(board: #(2.0, 2.0), machine: #(-2.0, 2.0), machine_z: -1.0),
    ]
    |> list.fold(reg, fn(acc, corr) {
      let assert Ok(acc) = job.transition(acc, job.Capture(corr))
      acc
    })
  // The fit is exact (residual 0), so a generous tolerance keeps it `Aligned`.
  let assert Ok(aligned) = job.transition(j, job.Fit(1.0))
  aligned.state |> should.equal(job.Aligned)
  model.Model(..base, job: HaveJob(aligned))
}

/// Drive a model to `Drilling` through the REAL app: aligned → RunDryRun (dry-run
/// stream in flight) → ConfirmRegistration (quickstop + drill stream). The job is
/// `Drilling` and the drill program is on the wire.
fn drilling_model() -> Model {
  let m_aligned = aligned_jogging_model()
  let #(m_dry, _) = app.update(m_aligned, model.RunDryRun)
  let #(m_drill, _) = app.update(m_dry, model.ConfirmRegistration)
  m_drill
}

/// Drive a model to `Done` through the REAL app, e2e through the genuine sim
/// handshake: the Drilling model, drive the drill stream THROUGH every bit-change
/// pause until the wire drains to `Idle` (the whole program streamed), then the
/// explicit operator Complete step (Drilling → Completed; the screen derives to
/// Done). `Complete` is the genuine app lifecycle edge — `StreamComplete` alone
/// does NOT advance to Done by design (app.gleam: `StreamComplete -> noeff`), so
/// the operator confirm is what closes the run. Driving the stream to Idle first
/// is what makes `drilled_count`/`telemetry_eta` read a fully-streamed run.
fn done_model() -> Model {
  let m_drilling = drilling_model()
  // Pump the drill stream through every bit-change pause until all holes drill
  // and the wire settles back to Idle (a naturally-completed stream returns to
  // Idle; a cancel would land in Jogging).
  let m_streamed = pump_to_idle(m_drilling, 8000)
  let #(m_done, _) = app.update(m_streamed, model.Complete)
  m_done
}

/// Pump simulator acks (resuming through bit-change pauses, exactly as the
/// operator does) until the wire leaves the streaming/paused lifecycle — i.e. the
/// program ran to `StreamComplete` and the FSM settled back to `Idle`.
fn pump_to_idle(m: Model, fuel: Int) -> Model {
  case fuel <= 0 {
    True -> m
    False -> {
      let wire = controller.state(m.controller)
      case printer.is_streaming(wire) || printer.is_stream_paused(wire) {
        False -> m
        True -> {
          let m2 = case printer.is_stream_paused(wire) {
            True -> {
              let #(mm, _) = app.update(m, model.ResumeDrilling)
              mm
            }
            False -> {
              let #(mm, _) =
                app.update(m, model.ControllerEvent(controller.Inbound("ok")))
              mm
            }
          }
          pump_to_idle(m2, fuel - 1)
        }
      }
    }
  }
}

/// The job carried by a model.
fn job_of(m: Model) -> job.Job {
  let assert HaveJob(j) = m.job
  j
}

/// The board hole count, independently of the projection.
fn board_holes(m: Model) -> Int {
  case m.board {
    HaveBoard(b) -> list.length(b.holes)
    NoBoard -> 0
  }
}

// ── alignment group ───────────────────────────────────────────────────────────

// quality is -1 before a fit (Parsed / no residuals), 0..100 once fitted.
pub fn quality_is_minus_one_before_fit_test() {
  projection.quality(base_model()) |> should.equal(-1)
}

pub fn quality_is_high_for_exact_fit_test() {
  let m = aligned_jogging_model()
  // An identity fit has ~0 residual → quality 100 (residual 0 → 100).
  projection.quality(m) |> should.equal(100)
}

pub fn quality_is_in_range_for_rejected_fit_test() {
  let q = projection.quality(rejected_model())
  { q >= 0 && q <= 100 } |> should.be_true
}

// quality_pct pinned to EXACT intermediate values so the residual term cannot be
// silently dropped (a `quality_pct` mutated to always-100 would slip past the
// exact-fit→100 / rejected→in-range tests above; these INTERMEDIATE points fail
// it). Formula: `round(clamp(1 - residual/(2*tol)) * 100)` → residual 0 → 100,
// residual == tol → 50, residual == 2*tol → 0.
pub fn quality_pct_pins_residual_term_test() {
  // No residual → full quality.
  projection.quality_pct(0.0, 0.1) |> should.equal(100)
  // Residual exactly at tolerance → the half-way point (NOT 100; this is the
  // mutation-killing pin — an always-100 quality_pct fails here).
  projection.quality_pct(0.1, 0.1) |> should.equal(50)
  // Residual at twice tolerance → fully degraded.
  projection.quality_pct(0.2, 0.1) |> should.equal(0)
  // Quarter / three-quarter points pin the linear residual response.
  projection.quality_pct(0.05, 0.1) |> should.equal(75)
  projection.quality_pct(0.15, 0.1) |> should.equal(25)
}

// quality_pct is strictly monotone decreasing in the residual (a bigger residual
// is never better quality) — pins the SIGN of the residual term too.
pub fn quality_pct_decreases_with_residual_test() {
  { projection.quality_pct(0.05, 0.1) > projection.quality_pct(0.15, 0.1) }
  |> should.be_true
  // … and clamps below 0 / above 100 rather than running negative or past full.
  projection.quality_pct(1.0, 0.1) |> should.equal(0)
  projection.quality_pct(-1.0, 0.1) |> should.equal(100)
}

// residuals / residual_max / residual_rms mirror job.alignment.residuals.
pub fn residuals_match_the_job_residuals_test() {
  let m = rejected_model()
  let assert Some(r) = job_of(m).residuals
  projection.residuals(m) |> should.equal(#(r.max, r.rms))
  projection.residual_max(m) |> should.equal(r.max)
  projection.residual_rms(m) |> should.equal(r.rms)
  // The rejected fit really is over the 0.05 gate it was judged against.
  { r.max >. 0.05 } |> should.be_true
}

pub fn residuals_are_zero_before_fit_test() {
  projection.residuals(base_model()) |> should.equal(#(0.0, 0.0))
  projection.residual_max(base_model()) |> should.equal(0.0)
  projection.residual_rms(base_model()) |> should.equal(0.0)
}

// fit_diag is HaveFitDiag (per-point residuals + worst + hint) only in
// AlignmentRejected; NoFitDiag for a clean Aligned model.
pub fn fit_diag_present_and_names_worst_for_rejected_test() {
  case projection.fit_diag(rejected_model()) {
    HaveFitDiag(diag) -> {
      // Per-point residuals for every captured point (4 here).
      list.length(diag.points) |> should.equal(4)
      // The named worst point is pinned to its ACTUAL value, not a wildcard: for
      // this +0.4mm-Y-nudge fixture the least-squares fit spreads the residual so
      // every point sits ~0.1mm off, and `worst_point` (first strict-max wins,
      // scanning capture order) deterministically selects index 2. Pinning the
      // index AND its error kills a "worst is always index 0 / always present"
      // mutation that the old `HaveWorst(_)` wildcard let through.
      case diag.worst {
        model.HaveWorst(w) -> {
          w.index |> should.equal(2)
          approx(w.error_mm, 0.1) |> should.be_true
          // The named worst really is the max over all points.
          let max_err =
            diag.points
            |> list.map(fn(p) { p.error_mm })
            |> list.fold(0.0, float.max)
          approx(w.error_mm, max_err) |> should.be_true
        }
        model.NoWorst -> should.fail()
      }
      // The fit solved a transform → override is offered.
      diag.can_override |> should.be_true
    }
    NoFitDiag -> should.fail()
  }
}

pub fn fit_diag_absent_for_clean_aligned_test() {
  projection.fit_diag(aligned_jogging_model()) |> should.equal(NoFitDiag)
}

pub fn fit_diag_absent_before_fit_test() {
  projection.fit_diag(base_model()) |> should.equal(NoFitDiag)
}

// project_head inverse-projects the machine head XY through the transform.
pub fn project_head_inverse_projects_through_transform_test() {
  // A pure translation by (+10, +20): board → machine adds (10, 20), so the
  // inverse takes a machine head back to (head - (10, 20)).
  let t =
    transform2d.Transform2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 10.0, ty: 20.0)
  let head = model.Head(15.0, 25.0, -1.0)
  let #(bx, by) = projection.project_head(t, head)
  approx(bx, 5.0) |> should.be_true
  approx(by, 5.0) |> should.be_true
}

pub fn project_head_identity_is_head_xy_test() {
  let id =
    transform2d.Transform2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0)
  let head = model.Head(3.5, -7.25, 0.0)
  projection.project_head(id, head) |> should.equal(#(3.5, -7.25))
}

// On an aligned model, head_pos uses project_head off the solved transform, so a
// head parked at machine origin projects to the board origin (identity fit here).
pub fn aligned_head_pos_uses_transform_test() {
  let m = aligned_jogging_model()
  projection.head_confidence(m) |> should.equal(ConfAligned)
  case projection.transform(m) {
    HaveTransform(_) -> Nil
    model.NoTransform -> should.fail()
  }
}

// ── fit decomposition & sanity group (ADR-0019) ───────────────────────────────
//
// These pin the WIRING of the F1 decomposition into the projection layer: the
// right Alignment in → the right Opt out, with the SAME on/off gating as
// `transform/1`. The decomposition math itself is F1's `fit_geometry_test`; here
// we only spot-check a field or two to prove the projection passed the right
// Alignment through.

// Before a fit (a fresh/Parsed model has no solved alignment), both projections
// are the No* variant — exactly when `transform/1` is `NoTransform`.
pub fn fit_geometry_is_none_before_fit_test() {
  projection.fit_geometry(base_model()) |> should.equal(NoFitGeometry)
}

pub fn fit_sanity_is_none_before_fit_test() {
  projection.fit_sanity(base_model()) |> should.equal(NoFitSanity)
}

// After a clean identity fit (the aligned-jogging model is an identity fit), the
// geometry is present and passes through unchanged: rotation ~0, scale ~1, not
// mirrored. The deep math is F1-tested — this just proves the projection handed
// the right Alignment to `decompose`.
pub fn fit_geometry_present_for_identity_fit_test() {
  case projection.fit_geometry(aligned_jogging_model()) {
    HaveFitGeometry(g) -> {
      approx(g.rotation_deg, 0.0) |> should.be_true
      approx(g.scale_x, 1.0) |> should.be_true
      approx(g.scale_y, 1.0) |> should.be_true
      g.mirrored |> should.be_false
    }
    NoFitGeometry -> should.fail()
  }
}

// A clean identity fit is `Plausible` (no sanity flags).
pub fn fit_sanity_is_plausible_for_identity_fit_test() {
  projection.fit_sanity(aligned_jogging_model())
  |> should.equal(HaveFitSanity(Plausible))
}

// A mirrored (det < 0) but otherwise-clean fit is `Suspect([Mirrored])` — the
// projection classifies the decomposed geometry through `default_bands()`.
pub fn fit_sanity_is_suspect_mirrored_for_mirrored_fit_test() {
  projection.fit_sanity(suspect_aligned_model())
  |> should.equal(HaveFitSanity(Suspect([Mirrored])))
}

// The mirrored fixture is genuinely mirrored at the geometry layer too (so the
// Suspect verdict above is driven by the real decomposition, not a coincidence).
pub fn fit_geometry_is_mirrored_for_mirrored_fit_test() {
  case projection.fit_geometry(suspect_aligned_model()) {
    HaveFitGeometry(g) -> g.mirrored |> should.be_true
    NoFitGeometry -> should.fail()
  }
}

// Gating matches `transform/1` exactly: where `transform` is NoTransform, both
// fit projections are None; where it is HaveTransform, both are present. Checked
// across the lifecycle states the other projections exercise (before-fit,
// rejected, aligned, drilling, done).
pub fn fit_projections_gate_in_lockstep_with_transform_test() {
  [
    base_model(),
    rejected_model(),
    aligned_jogging_model(),
    drilling_model(),
    done_model(),
  ]
  |> list.each(fn(m) {
    case projection.transform(m) {
      HaveTransform(_) -> {
        // transform present → both fit projections present.
        case projection.fit_geometry(m) {
          HaveFitGeometry(_) -> Nil
          NoFitGeometry -> should.fail()
        }
        case projection.fit_sanity(m) {
          HaveFitSanity(_) -> Nil
          NoFitSanity -> should.fail()
        }
      }
      model.NoTransform -> {
        // transform absent → both fit projections absent.
        projection.fit_geometry(m) |> should.equal(NoFitGeometry)
        projection.fit_sanity(m) |> should.equal(NoFitSanity)
      }
    }
  })
}

// ── streaming / Done group ────────────────────────────────────────────────────

// confirmed_hole_ids counts the unique DrillHoleKind hole_ids in a rendered
// prefix (deduped), ignoring non-drill lines.
pub fn confirmed_hole_ids_counts_drill_lines_test() {
  let rendered = [
    rl(ToolBlockKind, None, None),
    rl(DrillHoleKind, None, Some(0)),
    // A second wire line for the same hole 0 (e.g. the plunge) — deduped.
    rl(DrillHoleKind, None, Some(0)),
    rl(DrillHoleKind, None, Some(1)),
    rl(PauseKind, None, None),
    rl(DrillHoleKind, None, Some(2)),
  ]
  projection.confirmed_hole_ids(rendered) |> should.equal([0, 1, 2])
}

pub fn confirmed_hole_ids_empty_for_no_drill_lines_test() {
  projection.confirmed_hole_ids([rl(ToolBlockKind, None, None)])
  |> should.equal([])
}

// drilled_count advances as the dry-run stream confirms DrillHole lines, and
// equals the board hole count once the run has fully streamed.
pub fn drilled_count_advances_mid_stream_test() {
  let m_aligned = aligned_jogging_model()
  let #(m_dry, _) = app.update(m_aligned, model.RunDryRun)
  let m = pump_through_pause(m_dry, 3, 400)
  // Positive mid-run …
  { projection.drilled_count(m) > 0 } |> should.be_true
  // … and equal to an INDEPENDENT count derived straight off the wire — the
  // confirmed prefix's unique DrillHoleKind hole_ids — computed here WITHOUT
  // calling `drilled_count`/`progress`/`drilled_of` (the old assertion compared
  // `drilled_count` to `drilled_of`, which reads `progress(...).drilled`, itself
  // `drilled_count` — a literal x == x tautology). This now FAILS if
  // `drilled_count` is off by one or counts the wrong line kind.
  projection.drilled_count(m) |> should.equal(independent_drilled_count(m))
}

/// Count drilled holes straight off the controller wire, mirroring what
/// `drilled_count` SHOULD compute but derived INDEPENDENTLY in the test (the
/// confirmed prefix = the first `sent` rendered lines; a hole is a DrillHoleKind
/// line with a `hole_id`, deduped). Deliberately avoids `projection.drilled_count`
/// / `progress` / `confirmed_hole_ids` so it is a true cross-check.
fn independent_drilled_count(m: Model) -> Int {
  let wire = controller.state(m.controller)
  let #(sent, _total) = printer.stream_progress(wire)
  printer.stream_rendered(wire)
  |> list.take(sent)
  |> list.filter_map(fn(rl: RenderedLine) {
    case rl.origin.kind, rl.origin.hole_id {
      DrillHoleKind, Some(id) -> Ok(id)
      _, _ -> Error(Nil)
    }
  })
  |> list.unique
  |> list.length
}

pub fn drilled_count_is_all_holes_when_done_test() {
  let m = done_model()
  // A Done run reads every hole drilled (the standing `Done` signal).
  projection.drilled_count(m) |> should.equal(board_holes(m))
}

pub fn drilled_count_is_zero_before_run_test() {
  projection.drilled_count(base_model()) |> should.equal(0)
}

// bit_changes_seen == tool_order length − 1 (one swap per tool boundary after the
// first). Computed independently off the job's rendered tool_order.
pub fn bit_changes_seen_is_tool_count_minus_one_test() {
  let m = done_model()
  let expected = tool_order_len(m) - 1
  projection.bit_changes_seen(m) |> should.equal(expected)
  // The fixture is multi-tool, so this is a real (positive) count.
  { expected > 0 } |> should.be_true
}

pub fn bit_changes_seen_is_zero_with_no_alignment_test() {
  projection.bit_changes_seen(base_model()) |> should.equal(0)
}

// summary is HaveSummary only when the job is Done: total_holes = board count,
// bit_changes = tool count − 1, total_time a sane "M:SS"/"MM:SS" string.
pub fn summary_present_when_done_test() {
  let m = done_model()
  case projection.summary(m) {
    HaveSummary(Summary(total_holes:, total_time:, bit_changes:)) -> {
      total_holes |> should.equal(board_holes(m))
      bit_changes |> should.equal(tool_order_len(m) - 1)
      is_mmss(total_time) |> should.be_true
      // EXACT-value pin: total_time = per_hole_seconds × total_holes. For this
      // run (per_hole = 1.5s, 130 holes) that is 195s = "3:15". Shape-checking
      // alone (is_mmss) let a 10×-wrong feed pass; this pins the arithmetic.
      total_holes |> should.equal(130)
      total_time |> should.equal("3:15")
    }
    NoSummary -> should.fail()
  }
}

pub fn summary_absent_when_not_done_test() {
  projection.summary(base_model()) |> should.equal(NoSummary)
  projection.summary(aligned_jogging_model()) |> should.equal(NoSummary)
  projection.summary(drilling_model()) |> should.equal(NoSummary)
}

// ── telemetry group ───────────────────────────────────────────────────────────

// telemetry_bit is the run's first tool's diameter as "X.Xmm", or "—" with no
// alignment.
pub fn telemetry_bit_is_first_tool_diameter_test() {
  let m = aligned_jogging_model()
  let label = projection.telemetry_bit(m)
  // It ends in "mm" and parses as a positive diameter.
  string.ends_with(label, "mm") |> should.be_true
  let num = string.drop_end(label, 2)
  case float.parse(num) {
    Ok(d) -> { d >. 0.0 } |> should.be_true
    // "10" is the special-cased integer form (fmt_mm) — also valid + positive.
    Error(_) -> { num == "10" } |> should.be_true
  }
}

pub fn telemetry_bit_is_dash_with_no_alignment_test() {
  projection.telemetry_bit(base_model()) |> should.equal("—")
}

// telemetry_eta is "—" before a run, an "M:SS" string mid-run, "0:00" when fully
// streamed.
pub fn telemetry_eta_is_dash_before_run_test() {
  projection.telemetry_eta(base_model()) |> should.equal("—")
}

pub fn telemetry_eta_is_mmss_mid_run_test() {
  let m_aligned = aligned_jogging_model()
  let #(m_dry, _) = app.update(m_aligned, model.RunDryRun)
  let m = pump_through_pause(m_dry, 1, 400)
  is_mmss(projection.telemetry_eta(m)) |> should.be_true
}

// EXACT-value pin for the ETA arithmetic (a 10×-wrong feed only a shape-check
// would miss). At the dry-run START every hole is still remaining (drilled 0 of
// 130), so the ETA is the full run estimate: `per_hole_seconds × 130`. With the
// fixture's applied_config (DryRun snapshot: hover 1.0, drill plunge_feed 120 →
// per_hole = 2·hover / (feed/60) + 0.5 = 2.0/2.0 + 0.5 = 1.5s), that is
// 1.5 × 130 = 195s = "3:15". This pins the per-hole-seconds × remaining product.
pub fn telemetry_eta_exact_value_at_dry_run_start_test() {
  let m_aligned = aligned_jogging_model()
  let #(m_dry, _) = app.update(m_aligned, model.RunDryRun)
  // Precondition: nothing drilled yet, so remaining == the full board.
  projection.drilled_count(m_dry) |> should.equal(0)
  projection.telemetry_eta(m_dry) |> should.equal("3:15")
}

pub fn telemetry_eta_is_zero_when_done_test() {
  // A Done run has every hole drilled → no remaining time.
  projection.telemetry_eta(done_model()) |> should.equal("0:00")
}

// telemetry_spindle reads the LIVE editable config (by design, ADR note in
// projection.gleam) — assert that behavior, do not "fix" it.
pub fn telemetry_spindle_reads_live_config_test() {
  let base = base_model()
  let label = projection.telemetry_spindle(base)
  // The label is built from the live config's spindle_speed + pwm_max.
  label
  |> should.equal(
    "ON · " <> base.config.spindle_speed <> "/" <> base.config.pwm_max <> " PWM",
  )
  // Editing the LIVE config changes the telemetry (it is not a snapshot).
  let edited =
    model.Model(
      ..base,
      config: model.Config(
        ..base.config,
        spindle_speed: "12345",
        pwm_max: "200",
      ),
    )
  projection.telemetry_spindle(edited)
  |> should.equal("ON · 12345/200 PWM")
}

// ── small helpers ─────────────────────────────────────────────────────────────

fn rl(
  kind: gcode_program.OpKind,
  tool: option.Option(String),
  hole_id: option.Option(Int),
) -> RenderedLine {
  RenderedLine(
    wire: "",
    origin: LineOrigin(
      op_index: 0,
      kind: kind,
      tool: tool,
      hole_id: hole_id,
      pause: None,
    ),
  )
}

/// The file-order tool list the projections derive bit changes off, computed
/// independently from the job + alignment + drill config (`applied_config`,
/// Drill) — mirroring `projection.bit_changes_seen`.
fn tool_order_len(m: Model) -> Int {
  let j = job_of(m)
  let assert Some(al) = j.alignment
  let cfg = config.GcodeConfig(..m.applied_config, mode: config.Drill)
  gcode_program.render_context(j.board, al, cfg).tool_order |> list.length
}

// A string is a sane "M:SS" / "MM:SS" time: minutes, a colon, two-digit seconds.
fn is_mmss(s: String) -> Bool {
  case string.split(s, ":") {
    [mm, ss] -> string.length(ss) == 2 && int_ok(mm) && int_ok(ss)
    _ -> False
  }
}

fn int_ok(s: String) -> Bool {
  case int.parse(s) {
    Ok(_) -> True
    Error(_) -> False
  }
}
