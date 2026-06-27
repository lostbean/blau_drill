//// RENDER-LEVEL gate test for the operator backend picker in the shell sidebar.
////
//// ADR-0021: the picker offers only Web Serial and the faithful Emulator — the
//// thin Simulator is test-only and must NOT appear as an operator-selectable
//// option. We render `shell.sidebar(model) |> element.to_string` and assert the
//// two real options are present and the "Simulator" option label is gone,
//// pinning the picker's options at the view boundary so a regression that
//// re-adds the Simulator option is caught.
////
//// NOTE: this checks the rendered MARKUP. The at-size visual (the dropdown looks
//// right in a real Chromium viewport) is the coordinator's browser check.

import blau_drill/test_support.{base_model}
import blau_drill/ui/shell
import gleam/string
import gleeunit/should
import lustre/element

fn picker_html() -> String {
  shell.sidebar(base_model()) |> element.to_string
}

// ── the two offered options are present ───────────────────────────────────────

pub fn picker_offers_web_serial_test() {
  picker_html() |> string.contains("Web Serial (CNC)") |> should.equal(True)
}

pub fn picker_offers_emulator_test() {
  picker_html() |> string.contains(">Emulator<") |> should.equal(True)
}

// ── the thin Simulator is NOT an operator option (ADR-0021) ───────────────────

pub fn picker_omits_simulator_option_test() {
  // The "Simulator" option label was the only place that string appeared in the
  // picker; with the option removed it must not render.
  picker_html() |> string.contains(">Simulator<") |> should.equal(False)
}

pub fn picker_omits_sim_option_value_test() {
  // The legacy `<option value="sim">` is gone too.
  picker_html() |> string.contains("value=\"sim\"") |> should.equal(False)
}
