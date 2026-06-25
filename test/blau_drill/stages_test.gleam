//// Unit tests for the pure helpers in the `ui/stages` view layer. The views
//// themselves render in a browser and aren't headlessly testable, but the
//// next-step highlight derivation is a pure function of (captured, target).

import blau_drill/ui/stages.{CaptureNext, FitNext}
import gleeunit/should

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
