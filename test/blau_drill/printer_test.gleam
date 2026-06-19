//// Pure state-machine tests — the high-value proof. These drive the PURE
//// transition functions (`printer.command` / `printer.feed`) with synthetic
//// inbound lines and assert the emitted writes (TX) and the resulting state.
//// No browser, no transport: the whole machine runs in-process.
////
//// Behaviours ported from the Elixir `printer_connection_test.exs`:
////   * energize-before-jog: jog in Idle writes nothing & is refused; only after
////     energize does it emit framed G91/G0/G90;
////   * the streaming ok-handshake (one in flight); Resend re-sends; Error
////     re-sends; completion returns to Idle;
////   * M112 from each active state -> Faulted, sent raw; reconnect -> Idle;
////   * M114 -> position parsed; sent raw.

import blau_drill/control/printer.{
  type Command, type Event, type PrinterState, type Step, Accepted, Busy,
  Connect, Energize, Faulted, Faulting, Halt, Jog, MoveTo, NotEnergized,
  PositionUpdate, Progress, PulseSpindle, Reconnect, Recovered, Refused, Release,
  Stream, Where, X, Y,
}
import blau_drill/control/protocol
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// ── helpers ──────────────────────────────────────────────────────────────────

/// Strip an `N<n> ` prefix and `*<checksum>` suffix from a framed line so tests
/// compare the bare gcode payload, mirroring the Elixir test's `strip_line/1`.
fn strip(line: String) -> String {
  // Drop a leading "N<digits> " then a trailing "*<digits>".
  let after_n = case string.split_once(line, " ") {
    Ok(#(first, rest)) ->
      case string.starts_with(first, "N") {
        True -> rest
        False -> line
      }
    Error(_) -> line
  }
  case string.split_once(after_n, "*") {
    Ok(#(body, _cs)) -> body
    Error(_) -> after_n
  }
}

fn stripped_writes(step: Step) -> List(String) {
  list.map(step.writes, strip)
}

/// A connected, idle machine (line counter 0).
fn idle() -> PrinterState {
  let step = printer.command(printer.new(), Connect)
  step.state
}

/// An energized (jogging) machine. Asserts energize emitted exactly M17.
fn jogging() -> PrinterState {
  let step = printer.command(idle(), Energize)
  step.state
}

/// Drive a command and return the resulting step.
fn cmd(state: PrinterState, c: Command) -> Step {
  printer.command(state, c)
}

/// Feed an inbound line and return the resulting step.
fn feed(state: PrinterState, line: String) -> Step {
  printer.feed(state, line)
}

fn has_event(events: List(Event), pred: fn(Event) -> Bool) -> Bool {
  list.any(events, pred)
}

// ── lifecycle ────────────────────────────────────────────────────────────────

pub fn starts_disconnected_test() {
  printer.new() |> printer.state_name |> should.equal("disconnected")
}

pub fn connect_goes_idle_test() {
  let step = cmd(printer.new(), Connect)
  step.state |> printer.state_name |> should.equal("idle")
  step.writes |> should.equal([])
}

pub fn energize_goes_jogging_and_sends_m17_test() {
  let step = cmd(idle(), Energize)
  step.state |> printer.state_name |> should.equal("jogging")
  // M17 is framed (N1 M17*..). Bare payload must be exactly "M17".
  stripped_writes(step) |> should.equal(["M17"])
  has_event(step.events, fn(e) { e == Accepted(Energize) }) |> should.be_true
}

pub fn release_goes_idle_and_sends_m18_test() {
  let step = cmd(jogging(), Release)
  step.state |> printer.state_name |> should.equal("idle")
  stripped_writes(step) |> should.equal(["M18"])
}

// ── energize-before-jog snap invariant ───────────────────────────────────────

pub fn jog_in_idle_writes_nothing_and_refuses_test() {
  let step = cmd(idle(), Jog(X, 1.0))
  // The core invariant: a jog from idle writes NOTHING.
  step.writes |> should.equal([])
  // ...and is refused with NotEnergized, staying idle.
  step.state |> printer.state_name |> should.equal("idle")
  has_event(step.events, fn(e) { e == Refused(Jog(X, 1.0), NotEnergized) })
  |> should.be_true
}

pub fn jog_in_jogging_emits_relative_move_framed_test() {
  let step = cmd(jogging(), Jog(X, 1.0))
  // Energized: emits exactly G91 / G0 X1 / G90 in order.
  stripped_writes(step) |> should.equal(["G91", "G0 X1", "G90"])
  step.state |> printer.state_name |> should.equal("jogging")
}

pub fn jog_framing_is_correct_and_ordered_test() {
  // After M17 (N1) the jog frames N2/N3/N4 with correct XOR checksums, in order.
  let step = cmd(jogging(), Jog(X, 1.0))
  step.writes
  |> should.equal(["N2 G91*19", "N3 G0 X1*99", "N4 G90*20"])
}

pub fn jog_fractional_mm_is_three_decimals_test() {
  let step = cmd(jogging(), Jog(Y, 1.5))
  stripped_writes(step) |> should.equal(["G91", "G0 Y1.500", "G90"])
}

pub fn move_to_in_idle_writes_nothing_test() {
  let step = cmd(idle(), MoveTo(10.0, 20.0))
  step.writes |> should.equal([])
  has_event(step.events, fn(e) {
    e == Refused(MoveTo(10.0, 20.0), NotEnergized)
  })
  |> should.be_true
}

pub fn move_to_in_jogging_emits_absolute_g0_test() {
  let step = cmd(jogging(), MoveTo(12.5, -3.0))
  stripped_writes(step) |> should.equal(["G0 X12.500 Y-3"])
  // Absolute — must NOT switch to relative like jog does.
  list.any(stripped_writes(step), fn(w) { string.contains(w, "G91") })
  |> should.be_false
}

pub fn pulse_spindle_in_idle_writes_nothing_test() {
  let step = cmd(idle(), PulseSpindle("M3 S255", "M5"))
  step.writes |> should.equal([])
}

pub fn pulse_spindle_in_jogging_emits_on_dwell_off_test() {
  let step = cmd(jogging(), PulseSpindle("M3 S200", "M5"))
  // Configured commands verbatim, on before off, with a dwell between.
  stripped_writes(step) |> should.equal(["M3 S200", "G4 P800", "M5"])
}

// ── where (M114) ──────────────────────────────────────────────────────────────

pub fn where_sends_m114_raw_test() {
  let step = cmd(idle(), Where)
  // M114 is out-of-band: sent raw (no N/checksum).
  step.writes |> should.equal(["M114"])
}

pub fn where_resolves_position_from_reply_test() {
  let after_query = cmd(idle(), Where)
  // The trailing position line resolves the pending where.
  let line = "X:10.00 Y:20.00 Z:5.00 E:0.00 Count X:0 Y:0 Z:0"
  let step = feed(after_query.state, line)
  has_event(step.events, fn(e) {
    e == PositionUpdate(protocol.Position(10.0, 20.0, 5.0))
  })
  |> should.be_true
  step.state |> printer.state_name |> should.equal("idle")
}

pub fn where_ignores_bare_ok_keeps_pending_test() {
  let after_query = cmd(idle(), Where)
  // A bare `ok` before the position line is not a position: keep waiting.
  let step = feed(after_query.state, "ok")
  step.events |> should.equal([])
  // Still pending: a subsequent position line still resolves it.
  let step2 = feed(step.state, "X:1.00 Y:2.00 Z:3.00 E:0 Count X:0 Y:0 Z:0")
  has_event(step2.events, fn(e) {
    e == PositionUpdate(protocol.Position(1.0, 2.0, 3.0))
  })
  |> should.be_true
}

// ── streaming ok-handshake (one in flight) ───────────────────────────────────

pub fn stream_sends_first_line_only_test() {
  let program = ["G90", "G0 X1 Y1", "G0 X2 Y2", "M400"]
  let step = cmd(idle(), Stream(program))
  // Entry action: send ONLY the first line — one in flight.
  stripped_writes(step) |> should.equal(["G90"])
  step.state |> printer.state_name |> should.equal("streaming")
}

pub fn stream_advances_one_line_per_ok_test() {
  let program = ["G90", "G0 X1 Y1", "G0 X2 Y2", "M400"]
  // Drive the whole handshake by feeding one `ok` per confirmed line.
  let writes = run_stream(idle(), program)
  // Every line is sent exactly once, in order.
  writes |> should.equal(program)
}

pub fn stream_completes_to_idle_test() {
  let program = ["G90", "G0 X1 Y1", "M400"]
  let final_state = run_stream_state(idle(), program)
  // Elixir semantics: a completed stream returns to IDLE (not the originating
  // mode), even when started from Jogging.
  final_state |> printer.state_name |> should.equal("idle")
}

pub fn stream_started_from_jogging_completes_to_idle_test() {
  let program = ["G90", "M400"]
  let final_state = run_stream_state(jogging(), program)
  final_state |> printer.state_name |> should.equal("idle")
}

pub fn stream_emits_one_progress_per_confirmed_line_test() {
  let program = ["G90", "G0 X1 Y1", "M400"]
  let progress = run_stream_progress(idle(), program)
  // Exactly one progress event per line, sent monotonically 1..N, total fixed,
  // confirmed line echoed in order.
  progress
  |> should.equal([#(1, 3, "G90"), #(2, 3, "G0 X1 Y1"), #(3, 3, "M400")])
}

pub fn stream_resend_resends_current_without_advancing_test() {
  let program = ["G90", "G0 X1 Y1", "G0 X2 Y2"]
  // Start the stream (first line G90 is in flight).
  let s0 = cmd(idle(), Stream(program))
  // Ack G90 -> sends G0 X1 Y1 (idx 1 now in flight).
  let s1 = feed(s0.state, "ok")
  stripped_writes(s1) |> should.equal(["G0 X1 Y1"])
  // A Resend: re-sends the CURRENT line (idx 1) WITHOUT advancing.
  let s2 = feed(s1.state, "Resend: 3")
  stripped_writes(s2) |> should.equal(["G0 X1 Y1"])
  // No progress is emitted on a resend (no line confirmed).
  s2.events |> should.equal([])
  // Still streaming, still on the same line.
  printer.stream_progress(s2.state) |> should.equal(#(1, 3))
  // A subsequent ok advances normally.
  let s3 = feed(s2.state, "ok")
  stripped_writes(s3) |> should.equal(["G0 X2 Y2"])
}

pub fn stream_error_line_resends_current_test() {
  let program = ["G90", "G0 X1 Y1"]
  let s0 = cmd(idle(), Stream(program))
  // An "Error..." line is treated like a resend of the current line (G90).
  let s1 = feed(s0.state, "Error:checksum mismatch")
  stripped_writes(s1) |> should.equal(["G90"])
  printer.stream_progress(s1.state) |> should.equal(#(0, 2))
}

pub fn stream_ignores_informational_lines_test() {
  let program = ["G90", "M400"]
  let s0 = cmd(idle(), Stream(program))
  // A position / busy / echo line during a stream is ignored: no write, no
  // advance.
  let s1 = feed(s0.state, "X:1.00 Y:2.00 Z:0.00 E:0 Count X:0 Y:0 Z:0")
  s1.writes |> should.equal([])
  printer.stream_progress(s1.state) |> should.equal(#(0, 2))
  // The handshake still proceeds on the next ok.
  let s2 = feed(s1.state, "ok")
  stripped_writes(s2) |> should.equal(["M400"])
}

pub fn stream_resend_then_complete_still_totals_n_in_order_test() {
  let program = ["G90", "G0 X1 Y1", "G0 X2 Y2"]
  // NAK the 2nd line once; progress must still be one-per-line in order.
  let progress = run_stream_progress_with_resend(idle(), program, 1)
  progress
  |> should.equal([
    #(1, 3, "G90"),
    #(2, 3, "G0 X1 Y1"),
    #(3, 3, "G0 X2 Y2"),
  ])
}

pub fn empty_stream_stays_idle_test() {
  let step = cmd(idle(), Stream([]))
  step.writes |> should.equal([])
  step.state |> printer.state_name |> should.equal("idle")
}

pub fn second_stream_while_streaming_is_refused_test() {
  let program = ["G90", "M400"]
  let s0 = cmd(idle(), Stream(program))
  let step = cmd(s0.state, Stream(["G91"]))
  step.writes |> should.equal([])
  has_event(step.events, fn(e) { e == Refused(Stream(["G91"]), Busy) })
  |> should.be_true
}

pub fn jog_while_streaming_is_refused_test() {
  let program = ["G90", "M400"]
  let s0 = cmd(idle(), Stream(program))
  let step = cmd(s0.state, Jog(X, 1.0))
  step.writes |> should.equal([])
  has_event(step.events, fn(e) { e == Refused(Jog(X, 1.0), Busy) })
  |> should.be_true
}

// ── faulted is loud and reachable from any active state ───────────────────────

pub fn halt_from_idle_faults_and_sends_m112_raw_test() {
  let step = cmd(idle(), Halt)
  step.state |> should.equal(Faulted)
  // M112 is out-of-band: sent raw.
  step.writes |> should.equal(["M112"])
  has_event(step.events, fn(e) {
    case e {
      Faulting(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

pub fn halt_from_jogging_faults_and_sends_m112_raw_test() {
  let step = cmd(jogging(), Halt)
  step.state |> should.equal(Faulted)
  step.writes |> should.equal(["M112"])
}

pub fn halt_from_streaming_faults_and_sends_m112_raw_test() {
  let program = ["G90", "G0 X1 Y1", "M400"]
  let s0 = cmd(idle(), Stream(program))
  let s1 = feed(s0.state, "ok")
  // Abort mid-stream: M112 raw, machine faults, stream aborted.
  let step = cmd(s1.state, Halt)
  step.state |> should.equal(Faulted)
  step.writes |> should.equal(["M112"])
}

pub fn serial_loss_mid_stream_faults_test() {
  let program = ["G90", "G0 X1 Y1", "M400"]
  let s0 = cmd(idle(), Stream(program))
  let s1 = feed(s0.state, "ok")
  // Serial loss during a stream: abort and fault (no write).
  let step = printer.serial_lost(s1.state, "device disconnected")
  step.state |> should.equal(Faulted)
  step.writes |> should.equal([])
  has_event(step.events, fn(e) {
    case e {
      Faulting(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

pub fn motion_while_faulted_is_refused_test() {
  let faulted = cmd(idle(), Halt).state
  let step = cmd(faulted, Jog(X, 1.0))
  step.writes |> should.equal([])
  step.state |> should.equal(Faulted)
}

pub fn energize_while_faulted_is_refused_test() {
  let faulted = cmd(idle(), Halt).state
  let step = cmd(faulted, Energize)
  step.writes |> should.equal([])
  step.state |> should.equal(Faulted)
}

pub fn halt_while_faulted_is_noop_ok_test() {
  let faulted = cmd(idle(), Halt).state
  let step = cmd(faulted, Halt)
  // No second M112, stays faulted, accepted.
  step.writes |> should.equal([])
  step.state |> should.equal(Faulted)
  has_event(step.events, fn(e) { e == Accepted(Halt) }) |> should.be_true
}

pub fn reconnect_recovers_to_idle_test() {
  let faulted = cmd(idle(), Halt).state
  let step = cmd(faulted, Reconnect)
  step.state |> printer.state_name |> should.equal("idle")
  step.writes |> should.equal([])
  has_event(step.events, fn(e) { e == Recovered }) |> should.be_true
}

pub fn reconnect_resets_line_counter_test() {
  // Energize (N1), then halt, then reconnect: the next framed line must start at
  // N1 again (counter reset, like the Elixir reopen).
  let after_energize = cmd(idle(), Energize).state
  let faulted = cmd(after_energize, Halt).state
  let recovered = cmd(faulted, Reconnect).state
  // Energize again and check the frame counter restarted from 1.
  let step = cmd(recovered, Energize)
  step.writes |> should.equal(["N1 M17*20"])
}

// ── stream drivers (drive the pure handshake with synthetic acks) ────────────

/// Run a stream to completion, feeding `ok`s until the machine leaves the
/// `Streaming` state, collecting all the bare (stripped) lines written across
/// the whole exchange in order. Data-driven on the real state so it can't
/// over- or under-feed.
fn run_stream(state: PrinterState, program: List(String)) -> List(String) {
  let s0 = printer.command(state, Stream(program))
  ack_collect(s0.state, stripped_writes(s0))
}

fn ack_collect(state: PrinterState, acc: List(String)) -> List(String) {
  case printer.is_streaming(state) {
    False -> acc
    True -> {
      let step = printer.feed(state, "ok")
      ack_collect(step.state, list.append(acc, stripped_writes(step)))
    }
  }
}

/// Run a stream to completion and return the final state.
fn run_stream_state(
  state: PrinterState,
  program: List(String),
) -> PrinterState {
  let s0 = printer.command(state, Stream(program))
  ack_to_done(s0.state)
}

fn ack_to_done(state: PrinterState) -> PrinterState {
  case printer.is_streaming(state) {
    False -> state
    True -> ack_to_done(printer.feed(state, "ok").state)
  }
}

/// Run a stream and collect each progress event as `#(sent, total, line)`.
fn run_stream_progress(
  state: PrinterState,
  program: List(String),
) -> List(#(Int, Int, String)) {
  let s0 = printer.command(state, Stream(program))
  progress_collect(s0.state, [])
}

fn progress_collect(
  state: PrinterState,
  acc: List(#(Int, Int, String)),
) -> List(#(Int, Int, String)) {
  case printer.is_streaming(state) {
    False -> acc
    True -> {
      let step = printer.feed(state, "ok")
      let acc2 = list.append(acc, progress_tuples(step.events))
      progress_collect(step.state, acc2)
    }
  }
}

/// Like `run_stream_progress` but injects ONE `Resend:` after confirming
/// `resend_after` lines, proving the resend does not double-count or skip.
fn run_stream_progress_with_resend(
  state: PrinterState,
  program: List(String),
  resend_after: Int,
) -> List(#(Int, Int, String)) {
  let s0 = printer.command(state, Stream(program))
  resend_collect(s0.state, [], 0, resend_after, False)
}

fn resend_collect(
  state: PrinterState,
  acc: List(#(Int, Int, String)),
  confirmed: Int,
  resend_after: Int,
  did_resend: Bool,
) -> List(#(Int, Int, String)) {
  case printer.is_streaming(state) {
    False -> acc
    True ->
      case confirmed == resend_after && !did_resend {
        True -> {
          // Inject a Resend before the next ok: re-sends current, no progress.
          let r = printer.feed(state, "Resend: 99")
          r.events |> should.equal([])
          resend_collect(r.state, acc, confirmed, resend_after, True)
        }
        False -> {
          let step = printer.feed(state, "ok")
          let acc2 = list.append(acc, progress_tuples(step.events))
          resend_collect(
            step.state,
            acc2,
            confirmed + 1,
            resend_after,
            did_resend,
          )
        }
      }
  }
}

fn progress_tuples(events: List(Event)) -> List(#(Int, Int, String)) {
  list.filter_map(events, fn(e) {
    case e {
      Progress(sent, total, line) -> Ok(#(sent, total, line))
      _ -> Error(Nil)
    }
  })
}
