//// A PURE Marlin protocol-emulator core — the faithful "other end of the wire".
////
//// This is the unit-testable heart of a Marlin emulator: a pure function over
//// emulator state. `feed/2` takes one already-framed line the host wrote and
//// returns `#(next_state, replies)` where `replies` are exactly the lines real
//// Marlin would emit, in order. `resume/1` releases an `M0`/`M1` pause (the
//// panel-button press) and emits the deferred `ok`.
////
//// It deliberately models the behaviours that ONLY a faithful emulator can catch
//// headlessly — the bugs that otherwise surface only on real hardware:
////   * a blank line gets NO `ok` (the streaming-stall bug);
//// * a numbered line out of sequence / with a bad checksum yields the Marlin
////     `Error:Line Number...` + `Resend:` pair and does NOT advance (the
////     line-number-desync / resend bug);
////   * a move while steppers are DISABLED has no effect (the motor-enable bug):
////     real Marlin will not physically move with motors off, so for our purposes
////     the move is acked but ignored — an e2e test can then prove the host
////     energized the steppers (`M17`) before streaming;
////   * an `M0`/`M1` pause BLOCKS — it emits no `ok` until `resume/1` (the
////     M0-blocks-forever bug).
////
//// There is NO IO here: no FFI, no timers, no Backend wiring. Chunk 2 wires this
//// into a `Backend` seam. Float formatting is pure (no FFI), to 2 decimals, and
//// the `M114` reply round-trips through `protocol.parse_m114`.

import blau_drill/control/protocol
import gleam/float
import gleam/int
import gleam/option
import gleam/regexp
import gleam/string

/// The emulator's view of the machine. Only the state real bugs need is modelled.
pub type EmulatorState {
  EmulatorState(
    /// Marlin's last accepted line number. `M110 N<k>` resets this to `k`.
    last_line: Int,
    /// Steppers energized? `M17` -> True; `M18`/`M84` -> False. Starts False.
    motors_on: Bool,
    /// G90 absolute (start True) vs G91 relative.
    abs: Bool,
    /// Integrated machine position (mm).
    x: Float,
    y: Float,
    z: Float,
    /// True while halted on an `M0`/`M1` pause; blocks until `resume/1`.
    paused: Bool,
  )
}

/// A freshly powered emulator: nothing accepted, motors off, absolute, at origin.
pub fn new() -> EmulatorState {
  EmulatorState(
    last_line: 0,
    motors_on: False,
    abs: True,
    x: 0.0,
    y: 0.0,
    z: 0.0,
    paused: False,
  )
}

/// Feed one already-framed line (what the host wrote) and get back
/// `#(next_state, replies)`. `replies` are the lines Marlin would emit in order.
pub fn feed(
  state: EmulatorState,
  line: String,
) -> #(EmulatorState, List(String)) {
  let trimmed = string.trim(line)
  case trimmed {
    // Blank line -> NO ok. Real Marlin acks nothing for an empty line; a host
    // that waits for one stalls forever. (The streaming-stall bug.)
    "" -> #(state, [])
    _ ->
      case is_numbered(trimmed) {
        True -> feed_numbered(state, trimmed)
        // `M110` is accepted unnumbered and resets the line counter.
        False ->
          case is_m110(trimmed) {
            True -> #(EmulatorState(..state, last_line: parse_n(trimmed, 0)), [
              "ok",
            ])
            // Any other raw (unnumbered) interactive command.
            False -> execute(state, trimmed)
          }
      }
  }
}

/// Release an `M0`/`M1` pause (the operator pressing the panel button). When
/// paused, clears the pause and emits the deferred `ok`; otherwise a no-op.
pub fn resume(state: EmulatorState) -> #(EmulatorState, List(String)) {
  case state.paused {
    True -> #(EmulatorState(..state, paused: False), ["ok"])
    False -> #(state, [])
  }
}

/// The `M114` reply line for the current position. Public so a test can prove it
/// round-trips through `protocol.parse_m114`. Two-decimal axis values, with the
/// `E`/`Count` tail Marlin appends.
pub fn position_line(state: EmulatorState) -> String {
  "X:"
  <> fmt(state.x)
  <> " Y:"
  <> fmt(state.y)
  <> " Z:"
  <> fmt(state.z)
  <> " E:0.00 Count X:0 Y:0 Z:0"
}

// ── numbered (streamed) lines ────────────────────────────────────────────────

// A numbered line looks like `N<n> <cmd>*<checksum>` — starts with `N` and has a
// `*`. Interactive raw lines have neither.
fn is_numbered(trimmed: String) -> Bool {
  string.starts_with(trimmed, "N") && string.contains(trimmed, "*")
}

fn feed_numbered(
  state: EmulatorState,
  trimmed: String,
) -> #(EmulatorState, List(String)) {
  case parse_numbered(trimmed) {
    // Malformed numbered line -> treat as a format/checksum error.
    Error(_) -> #(state, resend_reply(state))
    Ok(#(n, body, cmd, sent_cs)) -> {
      let valid = n == state.last_line + 1 && protocol.checksum(body) == sent_cs
      case valid {
        // Wrong line number or bad checksum: ask for a resend, do NOT advance.
        False -> #(state, resend_reply(state))
        // Accepted: advance the counter, then execute the inner command.
        True -> execute(EmulatorState(..state, last_line: n), cmd)
      }
    }
  }
}

// `["Error:Line Number is not Last Line Number+1, Last Line: <last>", "Resend: <last+1>"]`.
fn resend_reply(state: EmulatorState) -> List(String) {
  [
    "Error:Line Number is not Last Line Number+1, Last Line: "
      <> int.to_string(state.last_line),
    "Resend: " <> int.to_string(state.last_line + 1),
  ]
}

// Parse `N<n> <cmd>*<cs>` into `#(n, body, cmd, cs)` where `body` is the part
// BEFORE the `*` (i.e. `"N<n> <cmd>"`, what the checksum covers) and `cmd` is the
// inner command (everything after `N<n> `). Total: any parse failure is `Error`.
fn parse_numbered(trimmed: String) -> Result(#(Int, String, String, Int), Nil) {
  case string.split_once(trimmed, "*") {
    Error(_) -> Error(Nil)
    Ok(#(body, cs_str)) ->
      case int.parse(string.trim(cs_str)) {
        Error(_) -> Error(Nil)
        Ok(sent_cs) ->
          // body = "N<n> <cmd>"
          case string.split_once(body, " ") {
            Error(_) -> Error(Nil)
            Ok(#(n_token, cmd)) ->
              case int.parse(string.drop_start(n_token, 1)) {
                Error(_) -> Error(Nil)
                Ok(n) -> Ok(#(n, body, cmd, sent_cs))
              }
          }
      }
  }
}

// ── command execution (shared by the raw path and the numbered inner command) ─

// Execute one command string (no `N`/`*` framing). Returns the replies. Most
// commands ack with `["ok"]`.
fn execute(
  state: EmulatorState,
  raw: String,
) -> #(EmulatorState, List(String)) {
  let cmd = strip_comment(raw)
  case classify(cmd) {
    Motors(on) -> #(EmulatorState(..state, motors_on: on), ["ok"])
    Absolute(is_abs) -> #(EmulatorState(..state, abs: is_abs), ["ok"])
    Move -> apply_move(state, cmd)
    ReportPosition -> #(state, [position_line(state), "ok"])
    // M0/M1 pause: blocks — NO ok until `resume/1`.
    Pause -> #(EmulatorState(..state, paused: True), [])
    // M112 emergency: ack. (Minimal: no halted flag needed by chunk 1.)
    Emergency -> #(state, ["ok"])
    // Everything else (M3/M5/G4/G92/M6/unknown-but-harmless) -> ok.
    Other -> #(state, ["ok"])
  }
}

type Command {
  Motors(on: Bool)
  Absolute(is_abs: Bool)
  Move
  ReportPosition
  Pause
  Emergency
  Other
}

// Classify a (comment-stripped) command by its leading G/M word. G-words are
// matched as TOKENS (mirroring `sim_ffi.mjs` / the Elixir `(?:^|\s)WORD(?![.\d])`)
// so `G0`/`G1` don't match `G04`/`G90`, and `G90`/`G91` don't match `G91.1`.
fn classify(cmd: String) -> Command {
  case has_word(cmd, "M17") {
    True -> Motors(True)
    False ->
      case has_word(cmd, "M18") || has_word(cmd, "M84") {
        True -> Motors(False)
        False ->
          case has_word(cmd, "M114") {
            True -> ReportPosition
            False ->
              case has_word(cmd, "G90") {
                True -> Absolute(True)
                False ->
                  case has_word(cmd, "G91") {
                    True -> Absolute(False)
                    False ->
                      case
                        has_word(cmd, "G0")
                        || has_word(cmd, "G00")
                        || has_word(cmd, "G1")
                        || has_word(cmd, "G01")
                      {
                        True -> Move
                        False ->
                          case has_word(cmd, "M0") || has_word(cmd, "M1") {
                            True -> Pause
                            False ->
                              case has_word(cmd, "M112") {
                                True -> Emergency
                                False -> Other
                              }
                          }
                      }
                  }
              }
          }
      }
  }
}

// Integrate X/Y/Z from a move line. If `abs`, set the coord to the word value;
// otherwise add it. Missing words leave that axis unchanged.
//
// MOTOR-ENABLE choice: when motors are off the move is REFUSED — acked with
// `["ok"]` but position is unchanged. Real Marlin won't physically move with
// steppers disabled; for our purposes the key invariant is that motion has no
// effect when motors are off, so an e2e test can prove the host energized the
// steppers (`M17`) before streaming.
fn apply_move(
  state: EmulatorState,
  cmd: String,
) -> #(EmulatorState, List(String)) {
  case state.motors_on {
    False -> #(state, ["ok"])
    True -> {
      let x = axis(cmd, "X")
      let y = axis(cmd, "Y")
      let z = axis(cmd, "Z")
      let next =
        EmulatorState(
          ..state,
          x: integrate(state.abs, state.x, x),
          y: integrate(state.abs, state.y, y),
          z: integrate(state.abs, state.z, z),
        )
      #(next, ["ok"])
    }
  }
}

fn integrate(
  is_abs: Bool,
  current: Float,
  word: option.Option(Float),
) -> Float {
  case word {
    option.None -> current
    option.Some(v) ->
      case is_abs {
        True -> v
        False -> current +. v
      }
  }
}

// ── parsing helpers (regexp, mirroring protocol/sim conventions) ──────────────

// Match a G/M word as a token: `(?:^|\s)WORD(?![.\d])`. Mirrors `sim_ffi.mjs`.
fn has_word(line: String, word: String) -> Bool {
  case regexp.from_string("(?:^|\\s)" <> word <> "(?![.\\d])") {
    Ok(re) -> regexp.check(re, line)
    Error(_) -> False
  }
}

// Pull an axis word value (`X-3.5`) as a float; `None` if the axis is absent.
fn axis(line: String, ax: String) -> option.Option(Float) {
  case regexp.from_string(ax <> "(-?\\d+(?:\\.\\d+)?)") {
    Error(_) -> option.None
    Ok(re) ->
      case regexp.scan(re, line) {
        [match, ..] ->
          case match.submatches {
            [option.Some(v), ..] -> parse_loose(v)
            _ -> option.None
          }
        [] -> option.None
      }
  }
}

fn parse_loose(s: String) -> option.Option(Float) {
  case parse_float_str(s) {
    Ok(f) -> option.Some(f)
    Error(_) -> option.None
  }
}

// Parse "N0" from `M110 N0` (or any `N<k>`); default when absent.
fn parse_n(line: String, default: Int) -> Int {
  case regexp.from_string("N(-?\\d+)") {
    Error(_) -> default
    Ok(re) ->
      case regexp.scan(re, line) {
        [match, ..] ->
          case match.submatches {
            [option.Some(v), ..] ->
              case int.parse(v) {
                Ok(n) -> n
                Error(_) -> default
              }
            _ -> default
          }
        [] -> default
      }
  }
}

fn is_m110(trimmed: String) -> Bool {
  has_word(trimmed, "M110")
}

// Drop a trailing `( comment )` / `; comment` so matching sees only the command.
fn strip_comment(raw: String) -> String {
  let no_paren = case string.split_once(raw, "(") {
    Ok(#(before, _)) -> before
    Error(_) -> raw
  }
  let no_semi = case string.split_once(no_paren, ";") {
    Ok(#(before, _)) -> before
    Error(_) -> no_paren
  }
  string.trim(no_semi)
}

// ── pure float helpers (gleam stdlib only — no project FFI) ───────────────────

// Loose float parse: accepts a bare integer (`"10"`) as well as `"10.5"` /
// `"-3.5"`. `float.parse` requires a decimal point, so bare ints fall through to
// `int.parse`.
fn parse_float_str(s: String) -> Result(Float, Nil) {
  case float.parse(s) {
    Ok(f) -> Ok(f)
    Error(_) ->
      case int.parse(s) {
        Ok(i) -> Ok(int.to_float(i))
        Error(_) -> Error(Nil)
      }
  }
}

// Format a float to exactly 2 decimal places using integer arithmetic, so the
// output is deterministic and `protocol.parse_m114`-parseable (it matches the
// `-?\d+(?:\.\d+)?` axis regex). `float.round` rounds half away from zero.
fn fmt(v: Float) -> String {
  let scaled = float.round(v *. 100.0)
  let neg = scaled < 0
  let magnitude = int.absolute_value(scaled)
  let whole = magnitude / 100
  let frac = magnitude % 100
  let frac_str = case frac < 10 {
    True -> "0" <> int.to_string(frac)
    False -> int.to_string(frac)
  }
  let sign = case neg {
    True -> "-"
    False -> ""
  }
  sign <> int.to_string(whole) <> "." <> frac_str
}
