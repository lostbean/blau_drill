//// Unit tests for the small pure domain modules:
////   * `domain/config` — the generator tunable defaults.
////   * `domain/correspondence` — the captured board<->machine pair record.
////   * `domain/pending_alignment` — the append-only registration accumulator.

import blau_drill/domain/config
import blau_drill/domain/correspondence.{Correspondence}
import blau_drill/domain/pending_alignment
import gleeunit/should

// ── config.default() ─────────────────────────────────────────────────────────

pub fn default_is_dry_run_test() {
  config.default().mode |> should.equal(config.DryRun)
}

pub fn default_fields_match_consts_test() {
  let d = config.default()
  d.zdrill |> should.equal(config.default_zdrill)
  d.zsafe |> should.equal(config.default_zsafe)
  d.zchange |> should.equal(config.default_zchange)
  d.drill_feed |> should.equal(config.default_drill_feed)
  d.spindle_speed |> should.equal(config.default_spindle_speed)
  d.hover |> should.equal(config.default_hover)
  d.app_pause |> should.equal(config.default_app_pause)
}

// app_pause defaults OFF: M0 is kept by default (ADR-0009 — the in-app pause
// workflow is opt-in; any g-code export keeps the mandatory machine stop).
pub fn default_app_pause_is_false_test() {
  config.default().app_pause |> should.be_false
  config.default_app_pause |> should.be_false
}

pub fn default_const_values_test() {
  // Pin the documented default values so a stray edit to a const is caught.
  config.default_zdrill |> should.equal(-2.5)
  config.default_zsafe |> should.equal(5.0)
  config.default_zchange |> should.equal(30.0)
  config.default_drill_feed |> should.equal(200.0)
  config.default_spindle_speed |> should.equal(255)
  config.default_hover |> should.equal(0.2)
}

// ── correspondence ───────────────────────────────────────────────────────────

pub fn correspondence_field_access_test() {
  let c = Correspondence(board: #(1.0, 2.0), machine: #(3.0, 4.0))
  c.board |> should.equal(#(1.0, 2.0))
  c.machine |> should.equal(#(3.0, 4.0))
}

// ── pending_alignment ────────────────────────────────────────────────────────

pub fn new_pending_is_empty_test() {
  pending_alignment.new() |> pending_alignment.count |> should.equal(0)
}

pub fn add_increments_count_test() {
  let p =
    pending_alignment.new()
    |> pending_alignment.add(
      Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0)),
    )
  pending_alignment.count(p) |> should.equal(1)
}

pub fn count_after_n_adds_is_n_test() {
  let c1 = Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0))
  let c2 = Correspondence(board: #(1.0, 1.0), machine: #(1.0, 1.0))
  let c3 = Correspondence(board: #(2.0, 2.0), machine: #(2.0, 2.0))
  let p =
    pending_alignment.new()
    |> pending_alignment.add(c1)
    |> pending_alignment.add(c2)
    |> pending_alignment.add(c3)
  pending_alignment.count(p) |> should.equal(3)
}

pub fn add_preserves_append_order_test() {
  // The list is append-only: the captured list reads in insertion order.
  let c1 = Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0))
  let c2 = Correspondence(board: #(1.0, 1.0), machine: #(1.0, 1.0))
  let c3 = Correspondence(board: #(2.0, 2.0), machine: #(2.0, 2.0))
  let p =
    pending_alignment.new()
    |> pending_alignment.add(c1)
    |> pending_alignment.add(c2)
    |> pending_alignment.add(c3)
  p.captured |> should.equal([c1, c2, c3])
}
