//// Regression guard for `app.restore_target/2` — the reload safety cap.
////
//// SAFETY PROPERTY ENCODED HERE: a page reload must NEVER resume directly into
//// a stage that depends on a live serial connection or a solved alignment
//// (DryRun / Drill / Done), nor into Align without a parsed board. Connection
//// and alignment are always discarded on reload, so the only safe non-Load
//// resume targets are `Settings` (always) and `Align` (only with a board).
//// Everything else collapses to `Load`. The bug this guards: a reload that
//// resumed straight into a connection/alignment-dependent stage with no live
//// machine state behind it.

import blau_drill/app
import blau_drill/ui/model.{Align, Done, Drill, DryRun, Load, Settings}
import gleeunit/should

// ── Settings: always safe ────────────────────────────────────────────────────

pub fn restore_settings_with_board_test() {
  app.restore_target(Ok(Settings), True) |> should.equal(Settings)
}

pub fn restore_settings_without_board_test() {
  app.restore_target(Ok(Settings), False) |> should.equal(Settings)
}

// ── Align: only with a board ──────────────────────────────────────────────────

pub fn restore_align_with_board_test() {
  app.restore_target(Ok(Align), True) |> should.equal(Align)
}

pub fn restore_align_without_board_caps_to_load_test() {
  // No board ⇒ nothing to align ⇒ collapse to Load.
  app.restore_target(Ok(Align), False) |> should.equal(Load)
}

// ── DryRun / Drill / Done: always capped to Load ──────────────────────────────
// These require a live connection + a solved alignment that a reload discards.

pub fn restore_dryrun_with_board_caps_to_load_test() {
  app.restore_target(Ok(DryRun), True) |> should.equal(Load)
}

pub fn restore_dryrun_without_board_caps_to_load_test() {
  app.restore_target(Ok(DryRun), False) |> should.equal(Load)
}

pub fn restore_drill_with_board_caps_to_load_test() {
  app.restore_target(Ok(Drill), True) |> should.equal(Load)
}

pub fn restore_drill_without_board_caps_to_load_test() {
  app.restore_target(Ok(Drill), False) |> should.equal(Load)
}

pub fn restore_done_with_board_caps_to_load_test() {
  app.restore_target(Ok(Done), True) |> should.equal(Load)
}

pub fn restore_done_without_board_caps_to_load_test() {
  app.restore_target(Ok(Done), False) |> should.equal(Load)
}

// ── Load: stays Load ──────────────────────────────────────────────────────────

pub fn restore_load_with_board_test() {
  app.restore_target(Ok(Load), True) |> should.equal(Load)
}

pub fn restore_load_without_board_test() {
  app.restore_target(Ok(Load), False) |> should.equal(Load)
}

// ── Error(Nil): no / garbage hash ─────────────────────────────────────────────

pub fn restore_error_with_board_caps_to_load_test() {
  app.restore_target(Error(Nil), True) |> should.equal(Load)
}

pub fn restore_error_without_board_caps_to_load_test() {
  app.restore_target(Error(Nil), False) |> should.equal(Load)
}
