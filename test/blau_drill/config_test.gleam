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
  d.drill_feeds |> should.equal(config.default_drill_feeds())
  d.dry_run_feeds |> should.equal(config.default_dry_run_feeds())
  d.spindle_speed |> should.equal(config.default_spindle_speed)
  d.hover |> should.equal(config.default_hover)
  d.app_pause |> should.equal(config.default_app_pause)
}

// ── per-mode feed profiles (ADR-0015) ────────────────────────────────────────

// The drill profile: xy + plunge from the tuned base, retract a touch faster.
pub fn default_drill_feeds_values_test() {
  let f = config.default_drill_feeds()
  f.xy_feed |> should.equal(config.default_drill_feed)
  f.plunge_feed |> should.equal(config.default_drill_feed)
  // retract a touch faster — 1.5× the tuned base.
  f.retract_feed |> should.equal(config.default_drill_feed *. 1.5)
}

// The dry-run profile: xy 2× drill xy (the headline ask), plunge/retract match
// drill (the hover move is small).
pub fn default_dry_run_feeds_values_test() {
  let dry = config.default_dry_run_feeds()
  let drill = config.default_drill_feeds()
  // Dry-run xy is double the drill xy.
  dry.xy_feed |> should.equal(config.default_drill_feed *. 2.0)
  dry.xy_feed |> should.equal(drill.xy_feed *. 2.0)
  // Plunge/retract match the drill profile.
  dry.plunge_feed |> should.equal(drill.plunge_feed)
  dry.retract_feed |> should.equal(drill.retract_feed)
}

// The two profiles construct cleanly and the default() wires them in.
pub fn default_carries_both_profiles_test() {
  let d = config.default()
  d.drill_feeds.xy_feed |> should.equal(200.0)
  d.dry_run_feeds.xy_feed |> should.equal(400.0)
}

// app_pause defaults ON (ADR-0009): the in-app pause workflow IS the default —
// the operator drives the run from the screen, so M0 (which blocks on the
// printer's own panel and stalls a screen-driven run at 0) is omitted and the app
// pauses/resumes on screen. A future g-code EXPORT still keeps M0.
pub fn default_app_pause_is_true_test() {
  config.default().app_pause |> should.be_true
  config.default_app_pause |> should.be_true
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
  let c =
    Correspondence(board: #(1.0, 2.0), machine: #(3.0, 4.0), machine_z: 0.0)
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
    |> pending_alignment.add(Correspondence(
      board: #(0.0, 0.0),
      machine: #(0.0, 0.0),
      machine_z: 0.0,
    ))
  pending_alignment.count(p) |> should.equal(1)
}

pub fn count_after_n_adds_is_n_test() {
  let c1 =
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: 0.0)
  let c2 =
    Correspondence(board: #(1.0, 1.0), machine: #(1.0, 1.0), machine_z: 0.0)
  let c3 =
    Correspondence(board: #(2.0, 2.0), machine: #(2.0, 2.0), machine_z: 0.0)
  let p =
    pending_alignment.new()
    |> pending_alignment.add(c1)
    |> pending_alignment.add(c2)
    |> pending_alignment.add(c3)
  pending_alignment.count(p) |> should.equal(3)
}

pub fn add_preserves_append_order_test() {
  // The list is append-only: the captured list reads in insertion order.
  let c1 =
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: 0.0)
  let c2 =
    Correspondence(board: #(1.0, 1.0), machine: #(1.0, 1.0), machine_z: 0.0)
  let c3 =
    Correspondence(board: #(2.0, 2.0), machine: #(2.0, 2.0), machine_z: 0.0)
  let p =
    pending_alignment.new()
    |> pending_alignment.add(c1)
    |> pending_alignment.add(c2)
    |> pending_alignment.add(c3)
  p.captured |> should.equal([c1, c2, c3])
}
