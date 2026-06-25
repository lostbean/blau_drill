//// Tests for the PURE Marlin protocol-emulator core (`marlin_emulator`).
////
//// This emulator is the safety net that catches — headlessly — the bugs that
//// otherwise only appear on real hardware: streaming stalls (blank line gets no
//// `ok`), line-number desync (Error+Resend), motor-enable failures (motion
//// ignored while steppers off), and M0-pause-blocks-forever. Each test below
//// pins one of those behaviours to the exact Marlin wire reply.

import blau_drill/control/marlin_emulator as emu
import blau_drill/control/protocol
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

fn approx(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. 1.0e-9
}

// ── initial state ─────────────────────────────────────────────────────────────

pub fn new_starts_clean_test() {
  let s = emu.new()
  s.last_line |> should.equal(0)
  s.motors_on |> should.equal(False)
  s.abs |> should.equal(True)
  s.paused |> should.equal(False)
  approx(s.x, 0.0) |> should.be_true
  approx(s.y, 0.0) |> should.be_true
  approx(s.z, 0.0) |> should.be_true
}

// ── motor state (M17 / M18 / M84) ─────────────────────────────────────────────

pub fn m17_energizes_test() {
  let #(s, replies) = emu.feed(emu.new(), "M17")
  s.motors_on |> should.equal(True)
  replies |> should.equal(["ok"])
}

pub fn m18_disables_test() {
  let #(on, _) = emu.feed(emu.new(), "M17")
  let #(off, replies) = emu.feed(on, "M18")
  off.motors_on |> should.equal(False)
  replies |> should.equal(["ok"])
}

pub fn m84_disables_test() {
  let #(on, _) = emu.feed(emu.new(), "M17")
  let #(off, replies) = emu.feed(on, "M84")
  off.motors_on |> should.equal(False)
  replies |> should.equal(["ok"])
}

// ── motion gated by motors (the motor-enable bug class) ───────────────────────

pub fn move_ignored_when_motors_off_test() {
  // Motors OFF: a move is acked but the head does NOT move.
  let #(s, replies) = emu.feed(emu.new(), "G0 X10")
  approx(s.x, 0.0) |> should.be_true
  replies |> should.equal(["ok"])
}

pub fn absolute_move_when_motors_on_test() {
  let #(s, _) = emu.feed(emu.new(), "M17")
  let #(s, _) = emu.feed(s, "G90")
  let #(s, replies) = emu.feed(s, "G0 X10 Y5")
  let s = emu.tick_all(s)
  approx(s.x, 10.0) |> should.be_true
  approx(s.y, 5.0) |> should.be_true
  replies |> should.equal(["ok"])
}

pub fn relative_move_when_motors_on_test() {
  let #(s, _) = emu.feed(emu.new(), "M17")
  let #(s, _) = emu.feed(s, "G91")
  let #(s, _) = emu.feed(s, "G0 X1")
  let #(s, _) = emu.feed(s, "G0 X1")
  let s = emu.tick_all(s)
  approx(s.x, 2.0) |> should.be_true
}

pub fn multiple_queued_relative_moves_chain_off_queue_end_test() {
  // Several relative moves admitted before any drain must chain off the END of
  // the pending queue, not the live head. A missing axis word holds the queued
  // (pending) value rather than the live-head value.
  let #(s, _) = emu.feed(emu.new(), "M17")
  let #(s, _) = emu.feed(s, "G91")
  // X: 0 -> 1 -> 3 -> 3 (last move omits X, holds pending 3).
  // Y: 0 -> 0 -> 0 -> 2.5
  let #(s, _) = emu.feed(s, "G0 X1")
  let #(s, _) = emu.feed(s, "G0 X2")
  let #(s, _) = emu.feed(s, "G0 Y2.5")
  let s = emu.tick_all(s)
  approx(s.x, 3.0) |> should.be_true
  approx(s.y, 2.5) |> should.be_true
}

pub fn missing_axis_unchanged_test() {
  let #(s, _) = emu.feed(emu.new(), "M17")
  let #(s, _) = emu.feed(s, "G90")
  let #(s, _) = emu.feed(s, "G0 X10 Y5")
  // Only Z given now -> X/Y hold, Z set.
  let #(s, _) = emu.feed(s, "G0 Z3")
  let s = emu.tick_all(s)
  approx(s.x, 10.0) |> should.be_true
  approx(s.y, 5.0) |> should.be_true
  approx(s.z, 3.0) |> should.be_true
}

pub fn negative_axis_value_test() {
  let #(s, _) = emu.feed(emu.new(), "M17")
  let #(s, _) = emu.feed(s, "G90")
  let #(s, _) = emu.feed(s, "G0 X-3.5 Y2.25")
  let s = emu.tick_all(s)
  approx(s.x, -3.5) |> should.be_true
  approx(s.y, 2.25) |> should.be_true
}

pub fn g1_also_moves_test() {
  let #(s, _) = emu.feed(emu.new(), "M17")
  let #(s, _) = emu.feed(s, "G90")
  let #(s, _) = emu.feed(s, "G1 X4")
  let s = emu.tick_all(s)
  approx(s.x, 4.0) |> should.be_true
}

pub fn g90_word_does_not_match_g91_test() {
  // Token matching: G90 must not flip on a G91-prefixed word and vice versa.
  let #(s, _) = emu.feed(emu.new(), "M17")
  let #(s, _) = emu.feed(s, "G91")
  s.abs |> should.equal(False)
  let #(s, _) = emu.feed(s, "G90")
  s.abs |> should.equal(True)
}

// ── M114 reply round-trips through protocol.parse_m114 ─────────────────────────

pub fn position_line_round_trips_test() {
  let #(s, _) = emu.feed(emu.new(), "M17")
  let #(s, _) = emu.feed(s, "G90")
  let #(s, _) = emu.feed(s, "G0 X12.34 Y-5.67 Z8.0")
  let s = emu.tick_all(s)
  let line = emu.position_line(s)
  let assert Ok(pos) = protocol.parse_m114(line)
  approx(pos.x, 12.34) |> should.be_true
  approx(pos.y, -5.67) |> should.be_true
  approx(pos.z, 8.0) |> should.be_true
}

pub fn m114_reply_is_position_then_ok_test() {
  let #(s, _) = emu.feed(emu.new(), "M17")
  let #(s, _) = emu.feed(s, "G90")
  let #(s, _) = emu.feed(s, "G0 X1 Y2")
  let s = emu.tick_all(s)
  let #(_, replies) = emu.feed(s, "M114")
  replies |> should.equal([emu.position_line(s), "ok"])
  // And the reply's position line parses back to the emulator's coords.
  let assert [line, "ok"] = replies
  let assert Ok(pos) = protocol.parse_m114(line)
  approx(pos.x, 1.0) |> should.be_true
  approx(pos.y, 2.0) |> should.be_true
}

// ── blank line -> NO ok (the streaming-stall bug) ─────────────────────────────

pub fn blank_line_no_ok_test() {
  let s = emu.new()
  emu.feed(s, "") |> should.equal(#(s, []))
}

pub fn whitespace_line_no_ok_test() {
  let s = emu.new()
  emu.feed(s, "   ") |> should.equal(#(s, []))
}

// ── numbered handshake (the line-number-desync / resend bug) ──────────────────

fn numbered(n: Int, cmd: String) -> String {
  let body = "N" <> int.to_string(n) <> " " <> cmd
  body <> "*" <> int.to_string(protocol.checksum(body))
}

pub fn numbered_line_accepted_test() {
  // N1 from last_line 0 -> accepted, advances, executes M17.
  let #(s, replies) = emu.feed(emu.new(), numbered(1, "M17"))
  s.last_line |> should.equal(1)
  s.motors_on |> should.equal(True)
  replies |> should.equal(["ok"])
}

pub fn numbered_wrong_number_resends_test() {
  let #(s, _) = emu.feed(emu.new(), numbered(1, "M17"))
  // Skip to N3 (expected N2) -> Error+Resend, no advance.
  let #(s2, replies) = emu.feed(s, numbered(3, "G90"))
  s2.last_line |> should.equal(1)
  replies
  |> should.equal([
    "Error:Line Number is not Last Line Number+1, Last Line: 1",
    "Resend: 2",
  ])
}

pub fn numbered_bad_checksum_resends_test() {
  let #(s, _) = emu.feed(emu.new(), numbered(1, "M17"))
  // Correct number N2 but a corrupted checksum -> Error+Resend, no advance.
  let body = "N2 G90"
  let corrupt = body <> "*" <> int.to_string(protocol.checksum(body) + 1)
  let #(s2, replies) = emu.feed(s, corrupt)
  s2.last_line |> should.equal(1)
  replies
  |> should.equal([
    "Error:Line Number is not Last Line Number+1, Last Line: 1",
    "Resend: 2",
  ])
}

pub fn numbered_resend_then_correct_test() {
  let #(s, _) = emu.feed(emu.new(), numbered(1, "M17"))
  let #(s, _) = emu.feed(s, numbered(3, "G90"))
  // The host resends N2 correctly -> accepted.
  let #(s, replies) = emu.feed(s, numbered(2, "G90"))
  s.last_line |> should.equal(2)
  s.abs |> should.equal(True)
  replies |> should.equal(["ok"])
}

pub fn numbered_move_obeys_motor_gate_test() {
  // A streamed (numbered) move is gated by motors exactly like a raw one.
  let #(s, _) = emu.feed(emu.new(), numbered(1, "G0 X10"))
  // motors still off -> no movement, but the line WAS accepted.
  s.last_line |> should.equal(1)
  approx(s.x, 0.0) |> should.be_true
  let #(s, _) = emu.feed(s, numbered(2, "M17"))
  let #(s, _) = emu.feed(s, numbered(3, "G90"))
  let #(s, _) = emu.feed(s, numbered(4, "G0 X10"))
  let s = emu.tick_all(s)
  approx(s.x, 10.0) |> should.be_true
}

pub fn malformed_numbered_line_resends_test() {
  // A numbered-looking line ("N...*") that can't parse -> Error+Resend.
  let #(s, replies) = emu.feed(emu.new(), "Nfoo M17*99")
  s.last_line |> should.equal(0)
  replies
  |> should.equal([
    "Error:Line Number is not Last Line Number+1, Last Line: 0",
    "Resend: 1",
  ])
}

// ── M110 line-number reset ─────────────────────────────────────────────────────

pub fn m110_resets_counter_test() {
  // Accept N1, N2, then M110 N0 resets last_line to 0.
  let #(s, _) = emu.feed(emu.new(), numbered(1, "M17"))
  let #(s, _) = emu.feed(s, numbered(2, "G90"))
  s.last_line |> should.equal(2)
  let #(s, replies) = emu.feed(s, "M110 N0")
  s.last_line |> should.equal(0)
  replies |> should.equal(["ok"])
}

pub fn m110_sets_arbitrary_counter_test() {
  let #(s, replies) = emu.feed(emu.new(), "M110 N42")
  s.last_line |> should.equal(42)
  replies |> should.equal(["ok"])
}

// ── M0 pause blocks; resume releases the deferred ok ──────────────────────────

pub fn m0_pause_blocks_no_ok_test() {
  let #(s, replies) = emu.feed(emu.new(), "M0 (stop)")
  s.paused |> should.equal(True)
  replies |> should.equal([])
}

pub fn m1_pause_blocks_no_ok_test() {
  let #(s, replies) = emu.feed(emu.new(), "M1")
  s.paused |> should.equal(True)
  replies |> should.equal([])
}

pub fn resume_releases_deferred_ok_test() {
  let #(s, _) = emu.feed(emu.new(), "M0 (stop)")
  let #(s, replies) = emu.resume(s)
  s.paused |> should.equal(False)
  replies |> should.equal(["ok"])
}

pub fn resume_when_not_paused_is_noop_test() {
  let s = emu.new()
  emu.resume(s) |> should.equal(#(s, []))
}

// ── M112 emergency + harmless config lines ack ────────────────────────────────

pub fn m112_acks_test() {
  emu.feed(emu.new(), "M112") |> should.equal(#(emu.new(), ["ok"]))
}

pub fn unknown_harmless_line_acks_test() {
  // M3 spindle / G4 dwell / G92 set-origin all ack with ["ok"].
  let #(_, r1) = emu.feed(emu.new(), "M3 S1000")
  r1 |> should.equal(["ok"])
  let #(_, r2) = emu.feed(emu.new(), "G4 P100")
  r2 |> should.equal(["ok"])
  let #(_, r3) = emu.feed(emu.new(), "G92 X0 Y0")
  r3 |> should.equal(["ok"])
}

// ── comment stripping ──────────────────────────────────────────────────────────

pub fn inline_comment_ignored_test() {
  let #(s, replies) = emu.feed(emu.new(), "M17 (energize)")
  s.motors_on |> should.equal(True)
  replies |> should.equal(["ok"])
}

// ── admit / drain split (ADR-0013): feed ADMITS, tick DRAINS ──────────────────

fn motors_on() -> emu.EmulatorState {
  let #(s, _) = emu.feed(emu.new(), "M17")
  s
}

pub fn feed_admits_but_does_not_move_head_test() {
  // Feed a long move; with NO tick the queue is non-empty and the head has NOT
  // advanced — the "still moving / in-flight" state.
  let #(s, replies) = emu.feed(motors_on(), "G0 X100 Y0")
  replies |> should.equal(["ok"])
  s.queue |> should.not_equal([])
  approx(s.x, 0.0) |> should.be_true
  approx(s.y, 0.0) |> should.be_true
}

pub fn tick_drains_to_target_test() {
  // Feed a move, drain the queue fully -> head lands exactly on the target and
  // the queue empties.
  let #(s, _) = emu.feed(motors_on(), "G0 X10 Y0")
  let s = emu.tick(s, 100.0)
  approx(s.x, 10.0) |> should.be_true
  s.queue |> should.equal([])
}

pub fn tick_partial_then_complete_test() {
  // A move of length 10; a tick of 4 advances 4mm (still queued), then a tick of
  // 10 finishes it exactly on target.
  let #(s, _) = emu.feed(motors_on(), "G0 X10 Y0")
  let s = emu.tick(s, 4.0)
  approx(s.x, 4.0) |> should.be_true
  s.queue |> should.not_equal([])
  let s = emu.tick(s, 10.0)
  approx(s.x, 10.0) |> should.be_true
  s.queue |> should.equal([])
}

pub fn tick_carries_leftover_budget_across_moves_test() {
  // Two queued 10mm X moves; a single big tick drains both, landing on X20.
  let #(s, _) = emu.feed(motors_on(), "G0 X10")
  let #(s, _) = emu.feed(s, "G0 X20")
  let s = emu.tick(s, 100.0)
  approx(s.x, 20.0) |> should.be_true
  s.queue |> should.equal([])
}

pub fn tick_on_empty_queue_is_noop_test() {
  let s = motors_on()
  let after = emu.tick(s, 50.0)
  after |> should.equal(s)
}

pub fn tick_all_drains_whole_queue_test() {
  let #(s, _) = emu.feed(motors_on(), "G0 X3")
  let #(s, _) = emu.feed(s, "G0 X9")
  let s = emu.tick_all(s)
  approx(s.x, 9.0) |> should.be_true
  s.queue |> should.equal([])
}

// ── halt clears the queue (the abort-mid-move assertion) ──────────────────────

pub fn halt_clears_queue_leaving_head_at_last_drained_pos_test() {
  // Feed a long move, partially drain so the head is mid-flight, THEN halt:
  // queue empties and the head stays where the last tick left it.
  let #(s, _) = emu.feed(motors_on(), "G0 X100 Y0")
  let s = emu.tick(s, 30.0)
  approx(s.x, 30.0) |> should.be_true
  s.queue |> should.not_equal([])
  let s = emu.halt(s)
  s.queue |> should.equal([])
  approx(s.x, 30.0) |> should.be_true
}

pub fn halt_mid_move_stops_motion_test() {
  // Feed a long move, do NOT tick (queue non-empty = "still moving"), halt ->
  // queue empty. This is the "physical motion continues after abort" regression.
  let #(s, _) = emu.feed(motors_on(), "G0 X500")
  s.queue |> should.not_equal([])
  let s = emu.halt(s)
  s.queue |> should.equal([])
  approx(s.x, 0.0) |> should.be_true
}

// ── M410 quickstop empties the planner queue (ADR-0014) ───────────────────────
//
// The host's Quickstop emits a raw `M410` to flush Marlin's planner. The emulator
// must model that flush so a test can ASSERT it: feeding `M410` empties the
// motion queue (reusing the same path `halt` does) and acks `["ok"]`. This is the
// behaviour the dry-run → drill flush relies on — moves already queued must be
// CANCELLED, not drained.
pub fn m410_flushes_the_motion_queue_test() {
  // Energize, then feed a long move so the queue is non-empty (still in flight).
  let #(s, _) = emu.feed(emu.new(), "M17")
  let #(s, _) = emu.feed(s, "G0 X500")
  s.queue |> should.not_equal([])
  // M410: flush the planner — queue empties, acked with ["ok"].
  let #(after, replies) = emu.feed(s, "M410")
  after.queue |> should.equal([])
  replies |> should.equal(["ok"])
}

// ── envelope: out-of-bounds moves are rejected (Error reply), not admitted ─────

fn small_envelope() -> emu.EmulatorState {
  // A tight box: 0..50 on each axis.
  let s =
    emu.with_bounds(emu.Bounds(min: #(0.0, 0.0, 0.0), max: #(50.0, 50.0, 50.0)))
  let #(s, _) = emu.feed(s, "M17")
  s
}

pub fn out_of_bounds_move_rejected_not_enqueued_test() {
  let s = small_envelope()
  let #(after, replies) = emu.feed(s, "G0 X999")
  // Error line observable, but an `ok` keeps the handshake alive.
  list_contains_error(replies) |> should.be_true
  replies |> ends_with_ok |> should.be_true
  // NOT admitted: queue unchanged, head unchanged.
  after.queue |> should.equal([])
  approx(after.x, 0.0) |> should.be_true
}

pub fn negative_out_of_bounds_move_rejected_test() {
  let s = small_envelope()
  let #(after, replies) = emu.feed(s, "G0 X-5")
  list_contains_error(replies) |> should.be_true
  after.queue |> should.equal([])
  approx(after.x, 0.0) |> should.be_true
}

pub fn in_bounds_move_with_explicit_bounds_admitted_test() {
  let s = small_envelope()
  let #(after, replies) = emu.feed(s, "G0 X25 Y10")
  replies |> should.equal(["ok"])
  after.queue |> should.not_equal([])
  let after = emu.tick_all(after)
  approx(after.x, 25.0) |> should.be_true
  approx(after.y, 10.0) |> should.be_true
}

fn list_contains_error(replies: List(String)) -> Bool {
  list.any(replies, fn(r) { string.starts_with(r, "Error:") })
}

fn ends_with_ok(replies: List(String)) -> Bool {
  case list.last(replies) {
    Ok("ok") -> True
    _ -> False
  }
}

// ── motors-off move: acked, nothing enqueued (unchanged behavior) ─────────────

pub fn motors_off_move_acks_nothing_enqueued_test() {
  let #(after, replies) = emu.feed(emu.new(), "G0 X10")
  replies |> should.equal(["ok"])
  after.queue |> should.equal([])
  approx(after.x, 0.0) |> should.be_true
}

// ── force: drop the emulator into an exact state ──────────────────────────────

pub fn force_constructs_exact_state_test() {
  let b = emu.Bounds(min: #(-5.0, -5.0, -5.0), max: #(5.0, 5.0, 5.0))
  let q = [emu.QueuedMove(tx: 1.0, ty: 2.0, tz: 3.0, remaining: 4.0)]
  let s =
    emu.force(
      last_line: 7,
      motors_on: True,
      abs: False,
      x: 1.5,
      y: 2.5,
      z: 3.5,
      paused: True,
      queue: q,
      bounds: b,
    )
  s.last_line |> should.equal(7)
  s.motors_on |> should.equal(True)
  s.abs |> should.equal(False)
  approx(s.x, 1.5) |> should.be_true
  approx(s.y, 2.5) |> should.be_true
  approx(s.z, 3.5) |> should.be_true
  s.paused |> should.equal(True)
  s.queue |> should.equal(q)
  s.bounds |> should.equal(b)
}
