//// Unit tests for the pure helpers in the `ui/stages` view layer, plus
//// RENDER-LEVEL gate tests for the Align stage's Fit / Restart buttons.
////
//// The next-step highlight derivation is a pure function of (captured, target).
//// The Fit / Restart button `disabled` gates are FSM-authoritative
//// (`job.can(j, FitE)` / `job.can(j, RestartAlignmentE)`) and previously had NO
//// render-level test — `next_step` was the only thing exercised, so a mutation
//// dropping the gate from a button's `disabled` survived. The render tests below
//// render `stages.align(model) |> element.to_string` for representative job states
//// and assert each button's `disabled` attribute, pinning the gate's authority at
//// the view boundary.

import blau_drill/domain/correspondence.{type Correspondence, Correspondence}
import blau_drill/domain/fit_geometry.{Mirrored, ScaleOff, Sheared, Tilted}
import blau_drill/domain/job
import blau_drill/test_support.{base_model}
import blau_drill/ui/model.{type Model, HaveJob}
import blau_drill/ui/projection
import blau_drill/ui/stages.{CaptureNext, FitNext}
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import lustre/element

// ── next_step: below the 3-point fit minimum, Capture is next ────────────────

pub fn next_step_zero_captured_is_capture_test() {
  stages.next_step(0, 3) |> should.equal(CaptureNext)
}

pub fn next_step_below_minimum_is_capture_test() {
  stages.next_step(2, 3) |> should.equal(CaptureNext)
}

// ── next_step: at/above the minimum (incl. N/N), Fit is next ─────────────────

pub fn next_step_at_minimum_is_fit_test() {
  stages.next_step(3, 3) |> should.equal(FitNext)
}

pub fn next_step_below_target_but_fittable_is_fit_test() {
  stages.next_step(3, 4) |> should.equal(FitNext)
}

pub fn next_step_at_target_is_fit_test() {
  stages.next_step(4, 4) |> should.equal(FitNext)
}

// ── render-level button-gate tests (S3) ──────────────────────────────────────

// A Registering job with `corrs` captured, on a base (connected/idle) model. The
// job FSM is the gate's authority, so we drive it directly into the state under
// test and let the projections + view read it.
fn registering_model(corrs: List(Correspondence)) -> Model {
  let base = base_model()
  let assert HaveJob(j0) = base.job
  let assert Ok(reg) = job.transition(j0, job.StartRegistering)
  let j =
    list.fold(corrs, reg, fn(acc, c) {
      let assert Ok(acc) = job.transition(acc, job.Capture(c))
      acc
    })
  model.Model(..base, job: HaveJob(j))
}

// An Aligned job (clean fit over 3 exact correspondences) on a base model.
fn aligned_model() -> Model {
  let m = registering_model(three_exact_corrs())
  let assert HaveJob(j) = m.job
  let assert Ok(aligned) = job.transition(j, job.Fit(0.1))
  model.Model(..m, job: HaveJob(aligned))
}

fn three_exact_corrs() -> List(Correspondence) {
  [
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: -1.0),
    Correspondence(board: #(1.0, 0.0), machine: #(1.0, 0.0), machine_z: -1.0),
    Correspondence(board: #(0.0, 1.0), machine: #(0.0, 1.0), machine_z: -1.0),
  ]
}

// 4 CONSISTENT (coplanar) captures, XY exact → an Aligned fit with n == 4 and a
// Z residual ~0 (the Z gate passed). Drives the quality panel's "Z residual" line.
fn four_consistent_z_corrs() -> List(Correspondence) {
  let plane_z = fn(bx: Float, by: Float) { 0.2 *. bx +. 0.1 *. by +. 1.0 }
  [
    Correspondence(
      board: #(0.0, 0.0),
      machine: #(0.0, 0.0),
      machine_z: plane_z(0.0, 0.0),
    ),
    Correspondence(
      board: #(10.0, 0.0),
      machine: #(10.0, 0.0),
      machine_z: plane_z(10.0, 0.0),
    ),
    Correspondence(
      board: #(0.0, 10.0),
      machine: #(0.0, 10.0),
      machine_z: plane_z(0.0, 10.0),
    ),
    Correspondence(
      board: #(10.0, 10.0),
      machine: #(10.0, 10.0),
      machine_z: plane_z(10.0, 10.0),
    ),
  ]
}

// THE Z3/Z9 scenario (ADR-0020): 4 captures, XY EXACT, but the 4th same-side
// fiducial was jogged to Z9 while the others are coplanar at Z3 → z_max blows past
// tol → AlignmentRejected (for DEPTH, not XY).
fn z_inconsistent_corrs() -> List(Correspondence) {
  [
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: 3.0),
    Correspondence(board: #(10.0, 0.0), machine: #(10.0, 0.0), machine_z: 3.0),
    Correspondence(board: #(0.0, 10.0), machine: #(0.0, 10.0), machine_z: 3.0),
    Correspondence(board: #(10.0, 10.0), machine: #(10.0, 10.0), machine_z: 9.0),
  ]
}

// An Aligned model over 4 CONSISTENT-Z captures (n == 4, Z verified).
fn aligned_four_consistent_model() -> Model {
  let m = registering_model(four_consistent_z_corrs())
  let assert HaveJob(j) = m.job
  let assert Ok(aligned) = job.transition(j, job.Fit(0.1))
  model.Model(..m, job: HaveJob(aligned))
}

// A Z-REJECTED model: XY-perfect 4-capture Z3/Z9 fit at the default 0.1 tol →
// AlignmentRejected for depth. The rejected box should surface the Z residual.
fn z_rejected_model() -> Model {
  let m = registering_model(z_inconsistent_corrs())
  let assert HaveJob(j) = m.job
  let assert Ok(rejected) = job.transition(j, job.Fit(0.1))
  model.Model(..m, job: HaveJob(rejected))
}

// An XY-REJECTED model: 4 captures, Z consistent (~0 Z residual) but the 4th XY
// nudged +0.4 mm in Y → XY residual ~0.1 > the 0.05 gate → AlignmentRejected for
// REGISTRATION (XY), not DEPTH.
fn xy_rejected_model() -> Model {
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
    |> list.fold(reg, fn(acc, c) {
      let assert Ok(acc) = job.transition(acc, job.Capture(c))
      acc
    })
  let assert Ok(rejected) = job.transition(j, job.Fit(0.05))
  model.Model(..base, job: HaveJob(rejected))
}

fn render_align(m: Model) -> String {
  element.to_string(stages.align(m))
}

// Mirror of stages' private `fmt3` (round to 3 decimals) so a test can assert the
// exact formatted Z value that the view renders.
fn fmt3_local(v: Float) -> String {
  let scaled = int.to_float(float.round(v *. 1000.0)) /. 1000.0
  float.to_string(scaled)
}

// The Align stage renders each button as `<button class="…" [disabled]
// type="button">LABEL…</button>`. The `disabled` attribute (when present) sits
// immediately before `type="button">LABEL`, so `disabled type="button">LABEL` is
// an unambiguous DISABLED marker, while `type="button">LABEL` is present in BOTH
// forms — so "enabled" is asserted as the disabled-marker being ABSENT (the button
// class itself varies with the next-step emphasis, so we key off the attribute,
// not the class).
const fit_marker = "type=\"button\">Fit Alignment"

const fit_disabled = "disabled type=\"button\">Fit Alignment"

const restart_marker = "type=\"button\">↺"

const restart_disabled = "disabled type=\"button\">↺"

// The Fit button is present-and-DISABLED: the disabled marker appears.
fn fit_is_disabled(html: String) -> Bool {
  string.contains(html, fit_disabled)
}

// The Fit button is present-and-ENABLED: the button is rendered (marker present)
// but the disabled form is NOT.
fn fit_is_enabled(html: String) -> Bool {
  string.contains(html, fit_marker) && !string.contains(html, fit_disabled)
}

fn restart_is_disabled(html: String) -> Bool {
  string.contains(html, restart_disabled)
}

fn restart_is_enabled(html: String) -> Bool {
  string.contains(html, restart_marker)
  && !string.contains(html, restart_disabled)
}

// FIT is GATED: disabled with < 3 captures (FitE legal but count guard fails) and
// in Aligned (FitE illegal — Fit is only legal in Registering); ENABLED in
// Registering with >= 3. This pins the `!job_can_fit(model)` + count guard on the
// Fit button's `disabled`, which had no render test (a mutation dropping the gate
// re-enabled an illegal click from Aligned and survived the suite).
pub fn fit_button_disabled_with_too_few_captures_test() {
  let html = render_align(registering_model(list.take(three_exact_corrs(), 2)))
  fit_is_disabled(html) |> should.be_true
}

pub fn fit_button_enabled_in_registering_with_three_test() {
  let html = render_align(registering_model(three_exact_corrs()))
  fit_is_enabled(html) |> should.be_true
}

pub fn fit_button_disabled_when_aligned_test() {
  // FitE is illegal in Aligned (Fit only in Registering) → the button is hard
  // disabled even though 3 captures are present. This is the illegal-click guard.
  let html = render_align(aligned_model())
  fit_is_disabled(html) |> should.be_true
}

// RESTART is GATED on `job_can_restart` (legal in Registering / Aligned /
// AlignmentRejected): ENABLED in Aligned, DISABLED in Parsed (RestartAlignmentE
// is not legal there). Pins the Restart button's `disabled` gate at the view.
pub fn restart_button_enabled_when_aligned_test() {
  let html = render_align(aligned_model())
  restart_is_enabled(html) |> should.be_true
}

pub fn restart_button_disabled_when_parsed_test() {
  // base_model() is a fresh Parsed job → RestartAlignmentE is illegal → disabled.
  let html = render_align(base_model())
  restart_is_disabled(html) |> should.be_true
}

// ── Z3: the two-parallel-axes quality panel + failing-axis rejected box ───────
//        (ADR-0020 — "The panel shows two parallel axes; the failing one is the
//         headline"). These supersede the Z2 single-line assertions: the redesign
//         replaced the flat "Z residual max …" line with a DEPTH (Z) readout that
//         sits beside REGISTRATION (XY) and carries its own pass/fail.

// The quality panel always shows BOTH axes by name, so the operator reads the two
// quality dimensions in matched terms.
pub fn quality_panel_shows_both_axes_test() {
  let html = render_align(aligned_four_consistent_model())
  string.contains(html, "REGISTRATION") |> should.be_true
  string.contains(html, "DEPTH") |> should.be_true
}

// An Aligned fit with >= 4 CONSISTENT captures: DEPTH passes (a green readout with
// the max-off-plane number + tol), NOT the "unverified" nudge and NOT a rejection.
pub fn quality_panel_depth_passes_at_four_consistent_captures_test() {
  let html = render_align(aligned_four_consistent_model())
  // The DEPTH readout shows its max-off-plane number with the tolerance.
  string.contains(html, "max") |> should.be_true
  string.contains(html, "tol") |> should.be_true
  // It is verified (not the unverified nudge) and the fit is not rejected.
  string.contains(html, "Z unverified") |> should.be_false
  string.contains(html, "Rejected") |> should.be_false
}

// An Aligned fit with exactly 3 captures cannot self-check its plane, so the DEPTH
// readout shows the muted "Z unverified — capture a 4th fiducial" hint instead of
// a pass.
pub fn quality_panel_shows_z_unverified_at_three_captures_test() {
  // aligned_model() is a clean fit over THREE exact correspondences (n == 3).
  let html = render_align(aligned_model())
  string.contains(html, "Z unverified") |> should.be_true
  // REGISTRATION still shows its real XY quality alongside.
  string.contains(html, "REGISTRATION") |> should.be_true
}

// A Z-rejected fit (4-capture Z3/Z9, XY-perfect): the rejected box's HEADLINE
// names DEPTH (Z) as the failing axis, the per-point list shows substantial Z
// errors (>0.5 mm, NOT the ~0.001 mm XY residuals), and the override button quotes
// the Z error — so nothing on screen contradicts the depth rejection.
pub fn rejected_box_headlines_depth_for_z_failure_test() {
  let html = render_align(z_rejected_model())
  // The rejected box headline names the DEPTH (Z) axis.
  string.contains(html, "Rejected") |> should.be_true
  string.contains(html, "DEPTH") |> should.be_true
  // The actionable depth message tells the operator to match contact heights.
  string.contains(html, "contact height") |> should.be_true
  // The override button quotes the Z error AS A DEPTH amount (not the XY 0.002 mm).
  string.contains(html, "depth") |> should.be_true
}

// The Z-rejected per-point list shows SUBSTANTIAL depth errors (the Z3/Z9 plane
// misses each point by ~1.2–1.4 mm), NOT the tiny 0.001 mm XY residuals that made
// the old panel look fine. We assert a value clearly in the Z range (1.x mm) is
// present and the misleading 0.001 / 0.002 XY values are NOT the headline.
pub fn rejected_box_per_point_list_shows_z_errors_test() {
  let html = render_align(z_rejected_model())
  let z_max = projection.z_residual_max(z_rejected_model())
  // The worst Z residual (≈1.5 mm) is formatted and present in the box.
  string.contains(html, fmt3_local(z_max)) |> should.be_true
  // The per-point list is over a substantial range, not 0.001 mm.
  string.contains(html, "0.001 mm") |> should.be_false
}

// A Z-rejected fit shows NO lone green GOOD headline that hides the Z failure —
// the old bug where the screen read "99% GOOD" AND "rejected" at once. In the
// redesign the XY % lives INSIDE the (truthfully-passing) REGISTRATION readout,
// while the DEPTH axis is RED (`quality-value bad`) and the rejected box headlines
// DEPTH — so the green is never the standalone verdict.
pub fn z_rejected_fit_has_no_lone_good_headline_test() {
  let html = render_align(z_rejected_model())
  // The fit is rejected for depth, so it must read as Rejected.
  string.contains(html, "Rejected") |> should.be_true
  // The DEPTH axis renders RED (the failing-axis color) — the panel does not read
  // as a flat green pass.
  string.contains(html, "quality-value bad") |> should.be_true
  // The DEPTH axis is the headline of the rejection: the rejected title names it.
  string.contains(html, "DEPTH (Z) over tolerance") |> should.be_true
}

// The quality % is UNCHANGED for an XY-good fit regardless of Z: a 4-consistent-Z
// Aligned fit (XY residual ~0) reads 100% GOOD exactly like a 3-capture clean fit
// — Z is NOT folded into the quality projection (it gates separately). The % lives
// in the REGISTRATION readout in the new layout.
pub fn quality_pct_unchanged_by_z_test() {
  let three_html = render_align(aligned_model())
  let four_html = render_align(aligned_four_consistent_model())
  // Both are XY-perfect → 100% GOOD; the Z addition did not alter the %.
  string.contains(three_html, "100% GOOD") |> should.be_true
  string.contains(four_html, "100% GOOD") |> should.be_true
}

// A pure-XY rejection still headlines REGISTRATION and quotes the XY error in the
// override — the redesign keeps the existing XY path when XY is the failing axis.
pub fn rejected_box_headlines_registration_for_xy_failure_test() {
  let html = render_align(xy_rejected_model())
  string.contains(html, "Rejected") |> should.be_true
  string.contains(html, "REGISTRATION") |> should.be_true
}

// ── F3: advisory fit verdict + breakdown (ADR-0019) ──────────────────────────

// sanity_reason_text: the exact human-readable line per SanityFlag variant.
pub fn sanity_reason_text_mirrored_test() {
  stages.sanity_reason_text(Mirrored)
  |> should.equal("board may be mirrored — check Front/Back")
}

pub fn sanity_reason_text_scale_x_test() {
  stages.sanity_reason_text(ScaleOff("x", 1.07))
  |> should.equal("scale X 1.07×")
}

pub fn sanity_reason_text_scale_y_test() {
  stages.sanity_reason_text(ScaleOff("y", 0.95))
  |> should.equal("scale Y 0.95×")
}

pub fn sanity_reason_text_sheared_test() {
  stages.sanity_reason_text(Sheared(3.5))
  |> should.equal("shear 3.5° (check captures)")
}

pub fn sanity_reason_text_tilted_test() {
  stages.sanity_reason_text(Tilted(4.25))
  |> should.equal("board tilted 4.25°")
}

// A MIRRORED-but-exact fit on a real job, in `Aligned`. The board→machine map
// mirrors X (`(bx, by) -> (-bx, by)`), so the solved transform has `det < 0`
// (mirrored) yet projects every captured point EXACTLY — residual 0, so a
// generous tolerance lands the job in `Aligned` (Proceed enabled), with the only
// sanity flag being `Mirrored` (a Suspect verdict). Lifted from projection_test's
// `suspect_aligned_model` (the F2 fixture).
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
  model.Model(..base, job: HaveJob(aligned))
}

// Render smoke: a clean (identity) aligned fit renders the Plausible verdict and
// the numeric breakdown (tilt + scale labels with values).
pub fn align_renders_plausible_verdict_test() {
  let html = render_align(aligned_model())
  string.contains(html, "Plausible") |> should.be_true
  // breakdown is present (labels + a scale value)
  string.contains(html, "tilt") |> should.be_true
  string.contains(html, "scale X") |> should.be_true
  string.contains(html, "1.0×") |> should.be_true
}

// Render smoke: a mirrored aligned fit renders the Suspect verdict and the
// mirror reason line.
pub fn align_renders_suspect_mirrored_verdict_test() {
  let html = render_align(suspect_aligned_model())
  string.contains(html, "Suspect") |> should.be_true
  string.contains(html, "mirrored") |> should.be_true
  // the breakdown shows mirror yes
  string.contains(html, "yes") |> should.be_true
}

// The Proceed-to-Dry-run button renders with its label; the disabled form (when
// present) puts `disabled` immediately before the type attribute.
const proceed_marker = "type=\"button\">Proceed to Dry-run"

const proceed_disabled = "disabled type=\"button\">Proceed to Dry-run"

fn proceed_is_enabled(html: String) -> Bool {
  string.contains(html, proceed_marker)
  && !string.contains(html, proceed_disabled)
}

// THE ADVISORY INVARIANT: a Suspect verdict must NOT gate Proceed. Both a clean
// (Plausible) aligned fit and a mirrored (Suspect) aligned fit have residual 0
// (well within tolerance), so for the SAME good residual the Proceed button is
// ENABLED regardless of the verdict — the verdict is display-only. This pins that
// surfacing the verdict changed no gating (ADR-0011/0019).
pub fn suspect_verdict_does_not_gate_proceed_test() {
  let plausible_html = render_align(aligned_model())
  let suspect_html = render_align(suspect_aligned_model())
  // sanity: the two fixtures really do differ in verdict
  string.contains(plausible_html, "Plausible") |> should.be_true
  string.contains(suspect_html, "Suspect") |> should.be_true
  // identical Proceed enablement: both ENABLED for a good residual.
  proceed_is_enabled(plausible_html) |> should.be_true
  proceed_is_enabled(suspect_html) |> should.be_true
}
