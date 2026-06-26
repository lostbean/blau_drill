//// Session-coordination end-to-end pins (ADR-0012 / ADR-0013).
////
//// TEST (a) `confirm_registration_starts_the_drill_stream` is a regression guard
//// (was red before ADR-0012). The bug it pins: in the old `app.confirm_registration`
//// the DryRun→Drilling transition did three un-atomic writes — advance the job
//// FSM, set `screen: Drill`, and issue `Stream(drill_program)` — but the dry-run
//// stream was STILL in flight (`Streaming`), so the printer FSM refused the drill
//// `Stream` with `Busy` (`printer.gleam`: `Streaming(_,_), Stream(_) -> refused(..., Busy)`).
//// The result the operator saw: the UI flipped to the Drill screen, but the wire
//// was still running the OLD dry-run program — the drill never started. ADR-0012
//// made ConfirmRegistration a single transition that cancels (now quickstops, per
//// ADR-0014) the in-flight stream FIRST and then streams the drill program, so
//// this is GREEN and guards against the regression.
////
//// TEST (b) `abort_mid_move_stops_the_head` is the abort-stops-motion regression
//// (ADR-0013): a move admitted to the emulator's motion queue but not yet
//// drained is "still moving"; `halt` (abort / M112) must clear the queue so the
//// head stops. This PASSES NOW (the queue + halt landed in chunk 1/1b).
////
//// NOTE on test (b)'s level — it is a MARLIN-CORE test, not a wire-level one.
//// The work order's first choice was to drive it through the EmuBackend
//// transport and inspect the queue via the `emuQueueLen`/`emuHalt` FFI hooks.
//// That path is NOT expressible with the hooks that exist today: the live
//// `write` FFI (`emulator_ffi.mjs`) ALWAYS auto-pumps the motion queue
//// (`conn.state = tick_all(nextState)` on every write), so a move written
//// through the Backend is drained to completion immediately — there is no way to
//// reach a `queue > 0` ("still moving") state through `write`, and there is no
//// `emuFeedNoDrain`/feed-without-drain hook. So per the work order's sanctioned
//// fallback, test (b) drives the PURE core (`emu.feed` admits, `emu.halt`
//// clears) directly, which proves the same property — abort clears in-flight
//// motion — at the core where it lives. Reaching the identical assertion at the
//// wire level would require a new no-drain emulator FFI hook (escalation, noted
//// in the chunk report).

import blau_drill/app
import blau_drill/control/controller
import blau_drill/control/marlin_emulator as emu
import blau_drill/control/printer
import blau_drill/domain/config
import blau_drill/domain/gcode_program
import blau_drill/test_support.{aligned_jogging_model_from, base_model}
import blau_drill/ui/model.{type Model, HaveJob}
import gleam/list
import gleam/option.{Some}
import gleeunit/should

// The DRILL program's streamed-line count for this model — built EXACTLY the way
// `app.confirm_registration` builds it (same board, same alignment, Drill mode):
// the `Wire` render of `build_ops`, the form the app streams. This is the length
// the wire SHOULD be running after ConfirmRegistration.
fn drill_program_len(m: Model) -> Int {
  let assert HaveJob(j) = m.job
  let assert Some(al) = j.alignment
  let drill_cfg = config.GcodeConfig(..m.applied_config, mode: config.Drill)
  let ops = gcode_program.build_ops(j.board, al, drill_cfg)
  let ctx = gcode_program.render_context(j.board, al, drill_cfg)
  gcode_program.render(ops, ctx, gcode_program.Wire)
  |> list.length
}

// ── TEST (a): regression guard — ConfirmRegistration starts the DRILL stream ───
// (was red before ADR-0012)
//
// After RunDryRun the printer is `Streaming` the DRY-RUN program. ConfirmRegistration
// then advances the job to Drilling and issues `Stream(drill)`.
//
// THE ASSERTION proves the drill program is ACTUALLY on the wire by comparing the
// streaming program's total line count against the freshly-built DRILL program's
// length. The dry-run and drill programs differ in length (Drill mode adds the
// spindle on/off lines per tool block and a different mode header), so this is an
// unambiguous discriminator: "still running the dry-run program" vs "running the
// drill program".
//
//   GREEN (ADR-0012): the in-flight dry-run stream is quickstopped first, then the
//   drill `Stream` is admitted, so `stream_progress(...).total == drill_program_len`.
//
//   WAS RED (before the fix): the drill `Stream` was refused `Busy` (the dry-run
//   stream was still in flight), so the printer stayed on the DRY-RUN program and
//   its `total` was the DRY-RUN length, which did NOT equal `drill_program_len`.
//   (Empirically: dry-run total = 452, drill program = 457.)
pub fn confirm_registration_starts_the_drill_stream_test() {
  let m_aligned = aligned_jogging_model_from(base_model())

  // RunDryRun: the job is DryRun and the dry-run program is STREAMING.
  let #(m_dryrun, _e1) = app.update(m_aligned, model.RunDryRun)
  controller.state(m_dryrun.controller)
  |> printer.is_streaming
  |> should.be_true

  // The length the DRILL stream should run at once ConfirmRegistration starts it.
  let want_drill_len = drill_program_len(m_dryrun)

  // THE ACT: confirm registration (DryRun → Drilling).
  let #(m_drill, _e2) = app.update(m_dryrun, model.ConfirmRegistration)

  // THE ASSERTION: the wire is now running the DRILL program — its streaming
  // `total` equals the drill program's length. (Was RED: the drill Stream was
  // refused Busy, so the printer stayed on the shorter dry-run program.)
  let #(_sent, total) =
    printer.stream_progress(controller.state(m_drill.controller))
  total |> should.equal(want_drill_len)
}

// ── TEST (b): abort-mid-move stops the head (ADR-0013) — PASSES NOW ───────────
//
// Energize the pure emulator core, feed a LONG move (admitted to the planner
// queue, NOT drained → "still moving"), then `halt` (the abort / M112). The queue
// must be empty after the halt: physical motion stops. Before the queue + halt
// landed, "still moving after abort" was the regression this pins.
pub fn abort_mid_move_stops_the_head_test() {
  // M17 energizes the steppers so the move is actually admitted (motion is gated
  // on motors; a move with steppers off is acked but never enqueued).
  let #(energized, _ok) = emu.feed(emu.new(), "M17")

  // A long move: admitted to the queue but NOT drained (no tick) — the head has
  // not advanced, motion is "in flight".
  let #(moving, replies) = emu.feed(energized, "G0 X500")
  replies |> should.equal(["ok"])
  moving.queue |> should.not_equal([])

  // ABORT: halt clears the planner queue — physical motion stops where it is.
  let stopped = emu.halt(moving)
  stopped.queue |> should.equal([])
}

// ── TEST (c): Quickstop's M410 FLUSHES the queued dry-run moves (ADR-0014) ─────
//
// This is the e2e-level proof of the ADR-0014 flush — the assertion the existing
// `confirm_registration_starts_the_drill_stream_test` lacked. That test checks
// the streamed program is the DRILL program by line count, but it does NOT prove
// the planner was flushed (the host merely stopped sending dry-run lines).
//
// WHY AT THE PURE-CORE LEVEL (not through the Backend transport): the live `write`
// FFI (`emulator_ffi.mjs`) ALWAYS auto-pumps the queue (`tick_all` on every
// write), so a move written through the Backend drains immediately — there is no
// way to reach a `queue > 0` ("still moving") state through `write`. So, exactly
// as test (b) does, this drives the PURE emulator core (`emu.feed`), where the
// flush is observable: feed queued dry-run moves WITHOUT ticking, then feed the
// quickstop's `M410` and assert the queue is EMPTY — the dry-run moves are GONE,
// not drained. (The old test only proved the host stopped sending.)
pub fn quickstop_flushes_queued_dry_run_moves_test() {
  // Energize the pure emulator so moves are actually admitted to the planner.
  let #(energized, _ok) = emu.feed(emu.new(), "M17")

  // Feed several "queued dry-run moves" WITHOUT ticking — they sit in the planner
  // (in flight), exactly the moves the bug let keep executing under the drill.
  let #(s, _) = emu.feed(energized, "G0 X100")
  let #(s, _) = emu.feed(s, "G0 Y100")
  s.queue |> should.not_equal([])

  // The quickstop's planner-flush line: M410 EMPTIES the queue — the queued
  // dry-run moves are CANCELLED, not drained. This is the assertion the old test
  // lacked: it proves the flush physically empties the planner.
  let #(flushed, replies) = emu.feed(s, "M410")
  flushed.queue |> should.equal([])
  replies |> should.equal(["ok"])

  // The full Quickstop write pair ends with M400 (wait for the now-empty queue):
  // with the queue already empty it is an immediate ok.
  let #(_settled, m400_replies) = emu.feed(flushed, "M400")
  m400_replies |> should.equal(["ok"])
}
