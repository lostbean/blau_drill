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
import blau_drill/domain/job
import blau_drill/test_support.{base_model}
import blau_drill/ui/model.{type Model, HaveJob}
import blau_drill/ui/stages.{CaptureNext, FitNext}
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

fn render_align(m: Model) -> String {
  element.to_string(stages.align(m))
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
