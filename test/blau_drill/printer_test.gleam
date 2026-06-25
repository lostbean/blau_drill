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
  CancelStream, Connect, Energize, Faulted, Faulting, Halt, Jog, MoveTo,
  NotEnergized, PositionUpdate, Progress, PulseSpindle, Reconnect, Recovered,
  Refused, Release, ResumeStream, Stream, StreamPausedAt, Where, X, Y,
}
import blau_drill/control/protocol
import blau_drill/domain/gcode_program
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
}

// Regression: Marlin remembers its line number across a USB session, but the app
// resets ITS counter to 0 on (re)connect. Without telling Marlin, the next send
// (N1) mismatches Marlin's "Last Line: N" and triggers
// "Error:Line Number is not Last Line Number+1" + Resend. So Connect must emit a
// raw `M110 N0` (reset line number) to resync. Seen on real hardware.
pub fn connect_emits_m110_line_reset_test() {
  let step = cmd(printer.new(), Connect)
  // M110 N0 is sent RAW (out-of-band — it IS the line-number reset), so the
  // stripped form equals the literal payload (no N-prefix/checksum added).
  step.writes |> should.equal(["M110 N0"])
}

pub fn reconnect_emits_m110_line_reset_test() {
  let faulted = cmd(idle(), Halt).state
  let step = cmd(faulted, Reconnect)
  step.state |> printer.state_name |> should.equal("idle")
  list.contains(step.writes, "M110 N0") |> should.be_true
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
  // Energized: emits G91 / G0 X1 / G90 in order, then M114 to read the position.
  stripped_writes(step) |> should.equal(["G91", "G0 X1", "G90", "M114"])
  step.state |> printer.state_name |> should.equal("jogging")
}

// Regression for the on-hardware disconnect: a `Resend:` / `Error:Line Number`
// reply that arrives while NOT streaming (Jogging/Idle) must be ignored — never
// trigger a (numbered) resend, change state, or emit writes. The original bug
// numbered interactive jogs, so Marlin replied with these, the non-streaming
// feed path didn't service them, and the counter desynced into a resend storm.
// Now interactive commands are unnumbered so Marlin shouldn't send these at all,
// but a stray one must still be handled gracefully.
pub fn resend_while_jogging_is_ignored_test() {
  let s = jogging()
  let step1 =
    feed(s, "Error:Line Number is not Last Line Number+1, Last Line: 8")
  step1.state |> should.equal(s)
  step1.writes |> should.equal([])
  step1.events |> should.equal([])

  let step2 = feed(s, "Resend: 9")
  step2.state |> should.equal(s)
  step2.writes |> should.equal([])
  step2.events |> should.equal([])
}

pub fn resend_while_idle_is_ignored_test() {
  let s = idle()
  let step = feed(s, "Resend: 9")
  step.state |> should.equal(s)
  step.writes |> should.equal([])
  step.events |> should.equal([])
}

// A pending Where (M114) must not be falsely resolved by a non-position reply
// like a stray Resend/Error — it keeps waiting (no PositionUpdate, no writes).
pub fn resend_does_not_resolve_pending_where_test() {
  let waiting = cmd(jogging(), Where).state
  let step = feed(waiting, "Error:Line Number is not Last Line Number+1")
  step.writes |> should.equal([])
  has_event(step.events, fn(e) {
    case e {
      PositionUpdate(_) -> True
      _ -> False
    }
  })
  |> should.be_false
}

// Interactive one-off commands (jog/move/spindle) are sent UNNUMBERED — raw,
// like M112/M114. Line numbers + checksums + the resend handshake are only used
// for the streamed program (dry-run/drill), where line loss matters. Numbering
// interactive jogs caused an unrecoverable counter desync on real hardware:
// Marlin's "Last Line: N" drifted from the host's and every send got an
// "Error:Line Number is not Last Line Number+1" + Resend (which the non-streaming
// feed path never serviced). Raw interactive lines don't touch the N-counter, so
// no desync. (The stream path stays numbered — see the stream tests.)
pub fn jog_is_unnumbered_raw_test() {
  let step = cmd(jogging(), Jog(X, 1.0))
  // Raw: bare G-code, no N-prefix/checksum; M114 (also raw) closes the burst.
  step.writes |> should.equal(["G91", "G0 X1", "G90", "M114"])
}

// Click-to-jump (MoveTo) is a SAFE pre-fit jump (ADR-0011): LIFT Z by a RELATIVE
// amount (G91 / G0 Z+<lift> / G90) FIRST, then travel XY at that lifted height,
// and STOP — no absolute descend (pre-fit there is no surface datum, so an
// absolute Z could plunge the bit DOWN into the board; a relative up-lift can't).
// Raw/unnumbered like other interactive commands. The relative lift amount is
// passed in (from config) so the pure core stays config-agnostic.
pub fn move_to_is_unnumbered_raw_test() {
  let step = cmd(jogging(), MoveTo(12.5, -3.0, 5.0))
  // Exact burst: G91, lift +5 (relative up), G90, travel XY, then M114 so the
  // settled position is read in the same sequence. NO absolute Z retract/descend.
  step.writes
  |> should.equal(["G91", "G0 Z5", "G90", "G0 X12.500 Y-3", "M114"])
}

pub fn jog_fractional_mm_is_three_decimals_test() {
  let step = cmd(jogging(), Jog(Y, 1.5))
  stripped_writes(step) |> should.equal(["G91", "G0 Y1.500", "G90", "M114"])
}

pub fn move_to_in_idle_writes_nothing_test() {
  let step = cmd(idle(), MoveTo(10.0, 20.0, 5.0))
  step.writes |> should.equal([])
  has_event(step.events, fn(e) {
    e == Refused(MoveTo(10.0, 20.0, 5.0), NotEnergized)
  })
  |> should.be_true
}

pub fn move_to_lifts_relative_before_xy_test() {
  // Safety (ADR-0011): the Z move is a RELATIVE lift framed by G91/G90 and comes
  // BEFORE the XY travel, so the bit rises (never plunges) and is never dragged
  // across the board at the current Z. The trailing M114 reads the settled head.
  let step = cmd(jogging(), MoveTo(12.5, -3.0, 5.0))
  let assert [first, second, third, fourth, fifth] = stripped_writes(step)
  // Relative mode is switched ON before the Z lift...
  first |> should.equal("G91")
  string.starts_with(second, "G0 Z5") |> should.be_true
  // ...and OFF again before the XY travel (relative wraps ONLY the lift).
  third |> should.equal("G90")
  string.contains(fourth, "X12.500") |> should.be_true
  string.contains(fourth, "Z") |> should.be_false
  fifth |> should.equal("M114")
}

// SAFETY (ADR-0011): a pre-fit jump can NEVER command the bit DOWN. The ONLY Z
// move in the burst is the relative lift wrapped in G91/G90 — there is NO
// absolute Z retract and NO descend line, so no datum-less absolute Z can plunge.
pub fn move_to_has_no_absolute_z_move_test() {
  let writes = stripped_writes(cmd(jogging(), MoveTo(12.5, -3.0, 5.0)))
  // The relative lift is wrapped: G91 then G90 both present.
  list.contains(writes, "G91") |> should.be_true
  list.contains(writes, "G90") |> should.be_true
  // Exactly ONE Z move in the whole burst (the lift) — no second Z (no descend).
  let z_moves = list.filter(writes, fn(w) { string.starts_with(w, "G0 Z") })
  z_moves |> should.equal(["G0 Z5"])
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

// ── benign stream cancel (graceful "go back", NOT a fault) ────────────────────

// CancelStream is the benign counterpart to Halt: it stops feeding the program
// (no more lines go out) and returns the machine to a CONNECTED, motors-energized
// state — JOGGING — WITHOUT emitting M112 and WITHOUT faulting. This is what
// navigating BACK from a dry-run uses: a dry-run is only ever started from
// Jogging, so the motors are still held and the head is locked in position;
// returning to Jogging reflects that (the operator can immediately re-jog and the
// UI shows motors live). The head hasn't moved and the dry-run is spindle-off
// (nothing to switch off), so stopping mid-stream is safe and must not drop the
// connection. Contrast halt_from_streaming_*, which DOES fault.
pub fn cancel_stream_returns_to_jogging_without_m112_test() {
  let program = ["G90", "G0 X1 Y1", "M400"]
  let s0 = cmd(jogging(), Stream(program))
  let s1 = feed(s0.state, "ok")
  // Mid-stream cancel: back to jogging (motors live), NO write at all (no M112,
  // no further lines).
  let step = cmd(s1.state, CancelStream)
  step.state |> printer.state_name |> should.equal("jogging")
  step.writes |> should.equal([])
  // Accepted, never a Faulting event — the connection is preserved.
  has_event(step.events, fn(e) { e == Accepted(CancelStream) })
  |> should.be_true
  has_event(step.events, fn(e) {
    case e {
      Faulting(_) -> True
      _ -> False
    }
  })
  |> should.be_false
}

// After a benign cancel the machine is Jogging (motors held), so a fresh stream
// starts cleanly (line state is sound — the cancel did not corrupt the counter).
pub fn cancel_stream_then_fresh_stream_works_test() {
  let program = ["G90", "G0 X1 Y1", "M400"]
  let s0 = cmd(jogging(), Stream(program))
  let s1 = feed(s0.state, "ok")
  let cancelled = cmd(s1.state, CancelStream).state
  // A new stream from the cancelled (Jogging) machine sends only its first line.
  let again = cmd(cancelled, Stream(["G91", "M400"]))
  stripped_writes(again) |> should.equal(["G91"])
  again.state |> printer.state_name |> should.equal("streaming")
}

// CancelStream is only meaningful while streaming. From any non-streaming state
// it is a benign no-op success: no write, no state change, no fault.
pub fn cancel_stream_while_idle_is_noop_test() {
  let step = cmd(idle(), CancelStream)
  step.writes |> should.equal([])
  step.state |> printer.state_name |> should.equal("idle")
  has_event(step.events, fn(e) { e == Accepted(CancelStream) })
  |> should.be_true
}

pub fn cancel_stream_while_jogging_is_noop_test() {
  let step = cmd(jogging(), CancelStream)
  step.writes |> should.equal([])
  step.state |> printer.state_name |> should.equal("jogging")
}

pub fn cancel_stream_while_disconnected_is_refused_test() {
  let step = cmd(printer.new(), CancelStream)
  step.writes |> should.equal([])
  step.state |> printer.state_name |> should.equal("disconnected")
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
  // Reconnect resyncs Marlin's line counter (raw M110 N0) — see
  // reconnect_emits_m110_line_reset_test.
  step.writes |> should.equal(["M110 N0"])
  has_event(step.events, fn(e) { e == Recovered }) |> should.be_true
}

pub fn energize_is_raw_after_reconnect_test() {
  // Interactive commands are unnumbered; after a halt+reconnect cycle, energize
  // still emits a RAW M17 (no N-prefix). Marlin's line counter is resynced by the
  // M110 N0 that Reconnect emits — see reconnect_emits_m110_line_reset_test.
  let after_energize = cmd(idle(), Energize).state
  let faulted = cmd(after_energize, Halt).state
  let recovered = cmd(faulted, Reconnect).state
  let step = cmd(recovered, Energize)
  step.writes |> should.equal(["M17"])
}

// ── in-app pause / resume (the M0_APP_PAUSE sentinel — ADR-0009) ──────────────
//
// When app_pause is on, the streamed program carries `M0_APP_PAUSE` sentinels in
// place of M0. The FSM must intercept each one: pause the stream (write NOTHING,
// the sentinel never reaches the port), emit a pause event, and wait for
// ResumeStream — which sends the NEXT REAL line and re-arms the handshake. Abort
// (Halt) and cancel (CancelStream) stay reachable from the paused state.

const pause = "M0_APP_PAUSE"

// The sentinel constant in the test matches the generator's exported marker.
pub fn pause_marker_matches_generator_test() {
  pause |> should.equal(gcode_program.app_pause_marker)
}

// A sentinel mid-stream: on the ok that WOULD advance onto it, the FSM pauses —
// no write goes out, the sentinel is consumed, and a pause event is emitted.
pub fn stream_pauses_at_sentinel_without_writing_it_test() {
  let program = ["G90", pause, "G0 X1 Y1", "M400"]
  let s0 = cmd(idle(), Stream(program))
  // First line G90 is in flight; ack it → would advance onto the sentinel.
  let s1 = feed(s0.state, "ok")
  // PAUSED: nothing written (the sentinel is NOT sent to the port).
  s1.writes |> should.equal([])
  s1.state |> printer.state_name |> should.equal("stream_paused")
  // The progress for the just-confirmed G90 still fires, plus a pause event.
  has_event(s1.events, fn(e) { e == Progress(1, 4, "G90") }) |> should.be_true
  has_event(s1.events, fn(e) {
    case e {
      StreamPausedAt(_, _) -> True
      _ -> False
    }
  })
  |> should.be_true
}

// While paused, inbound lines are informational: no write, no advance, no leak of
// the sentinel to the port.
pub fn paused_ignores_inbound_and_sends_nothing_test() {
  let program = ["G90", pause, "G0 X1 Y1"]
  let paused = feed(cmd(idle(), Stream(program)).state, "ok").state
  paused |> printer.state_name |> should.equal("stream_paused")
  let step = feed(paused, "ok")
  // Still paused, still nothing written — a spurious ok cannot resume.
  step.writes |> should.equal([])
  step.state |> printer.state_name |> should.equal("stream_paused")
}

// ResumeStream from paused sends the NEXT REAL line (the one after the sentinel)
// and returns to Streaming — the handshake resumes from there.
pub fn resume_stream_sends_next_real_line_test() {
  let program = ["G90", pause, "G0 X1 Y1", "M400"]
  let paused = feed(cmd(idle(), Stream(program)).state, "ok").state
  let step = cmd(paused, ResumeStream)
  // The sentinel is skipped; the next REAL line (G0 X1 Y1) goes out.
  stripped_writes(step) |> should.equal(["G0 X1 Y1"])
  step.state |> printer.state_name |> should.equal("streaming")
  has_event(step.events, fn(e) { e == Accepted(ResumeStream) })
  |> should.be_true
}

// End-to-end: a program with one mid-stream sentinel streams every REAL line
// (the sentinel is NEVER among the writes), pausing once and resuming through.
pub fn stream_with_sentinel_writes_every_real_line_once_test() {
  let program = ["G90", pause, "G0 X1 Y1", "M400"]
  let writes = run_stream_through_pauses(idle(), program)
  // Exactly the real lines, in order — the sentinel is consumed, never written.
  writes |> should.equal(["G90", "G0 X1 Y1", "M400"])
  list.contains(writes, pause) |> should.be_false
}

// A program that OPENS with the sentinel (the touch-off pause) pauses on START —
// the first line is never sent; resume sends the real first line.
pub fn stream_pauses_immediately_when_first_line_is_sentinel_test() {
  let program = [pause, "G90", "M400"]
  let step = cmd(idle(), Stream(program))
  // No write at all on start; straight into paused.
  step.writes |> should.equal([])
  step.state |> printer.state_name |> should.equal("stream_paused")
  has_event(step.events, fn(e) { e == StreamPausedAt(0, 3) }) |> should.be_true
  // Resume sends the first real line.
  let step2 = cmd(step.state, ResumeStream)
  stripped_writes(step2) |> should.equal(["G90"])
  step2.state |> printer.state_name |> should.equal("streaming")
}

// SAFETY: Halt (M112) is reachable from the paused state — abort is never lost
// behind a pause.
pub fn halt_from_paused_faults_and_sends_m112_test() {
  let program = ["G90", pause, "G0 X1 Y1"]
  let paused = feed(cmd(idle(), Stream(program)).state, "ok").state
  let step = cmd(paused, Halt)
  step.state |> should.equal(Faulted)
  step.writes |> should.equal(["M112"])
  has_event(step.events, fn(e) {
    case e {
      Faulting(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

// SAFETY: CancelStream (benign back) is reachable from the paused state — returns
// to Jogging (motors live), no write, no fault.
pub fn cancel_from_paused_returns_to_jogging_test() {
  let program = ["G90", pause, "G0 X1 Y1"]
  let paused = feed(cmd(jogging(), Stream(program)).state, "ok").state
  let step = cmd(paused, CancelStream)
  step.state |> printer.state_name |> should.equal("jogging")
  step.writes |> should.equal([])
  has_event(step.events, fn(e) { e == Accepted(CancelStream) })
  |> should.be_true
}

// A second Stream while paused is refused (Busy) — a run is already in flight.
pub fn second_stream_while_paused_is_refused_test() {
  let program = ["G90", pause, "G0 X1 Y1"]
  let paused = feed(cmd(idle(), Stream(program)).state, "ok").state
  let step = cmd(paused, Stream(["G91"]))
  step.writes |> should.equal([])
  has_event(step.events, fn(e) { e == Refused(Stream(["G91"]), Busy) })
  |> should.be_true
}

// ResumeStream in a non-paused state is a benign no-op: no write, no state change
// (a stray resume click can never move the head).
pub fn resume_stream_while_idle_is_noop_test() {
  let step = cmd(idle(), ResumeStream)
  step.writes |> should.equal([])
  step.state |> printer.state_name |> should.equal("idle")
}

pub fn resume_stream_while_streaming_is_noop_test() {
  let program = ["G90", "M400"]
  let s0 = cmd(idle(), Stream(program))
  let step = cmd(s0.state, ResumeStream)
  // No extra write; still streaming on the same in-flight line.
  step.writes |> should.equal([])
  step.state |> printer.state_name |> should.equal("streaming")
}

// Two sentinels in one program (touch-off + a bit change): the stream pauses
// TWICE and resumes through both, writing every real line exactly once.
pub fn stream_with_two_sentinels_pauses_twice_test() {
  let program = [pause, "G90", pause, "G0 X1 Y1", "M400"]
  let writes = run_stream_through_pauses(idle(), program)
  writes |> should.equal(["G90", "G0 X1 Y1", "M400"])
}

// Drive a stream to completion, auto-resuming at each pause, collecting every
// bare line written (the sentinel never appears — it is consumed, never sent).
fn run_stream_through_pauses(
  state: PrinterState,
  program: List(String),
) -> List(String) {
  let s0 = printer.command(state, Stream(program))
  drive_through(s0.state, stripped_writes(s0))
}

fn drive_through(state: PrinterState, acc: List(String)) -> List(String) {
  case printer.is_streaming(state), printer.is_stream_paused(state) {
    True, _ -> {
      let step = printer.feed(state, "ok")
      drive_through(step.state, list.append(acc, stripped_writes(step)))
    }
    _, True -> {
      let step = printer.command(state, ResumeStream)
      drive_through(step.state, list.append(acc, stripped_writes(step)))
    }
    False, False -> acc
  }
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
