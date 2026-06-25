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

/// One admitted-but-not-yet-executed move (the planner buffer entry, per
/// ADR-0013). `tx/ty/tz` is the ABSOLUTE target, resolved at admission time from
/// the head position + abs/rel mode — so it is independent of any later G90/G91
/// change. `remaining` is the distance (mm) still to travel to that target.
pub type QueuedMove {
  QueuedMove(tx: Float, ty: Float, tz: Float, remaining: Float)
}

/// The injected XYZ machine envelope (ADR-0013). Moves whose resolved target
/// falls outside `[min, max]` on any axis are rejected, not admitted. Bounds are
/// operator/hardware config — supplied at construction, never a product default.
pub type Bounds {
  Bounds(min: #(Float, Float, Float), max: #(Float, Float, Float))
}

/// The emulator's view of the machine. Only the state real bugs need is modelled.
pub type EmulatorState {
  EmulatorState(
    /// Marlin's last accepted line number. `M110 N<k>` resets this to `k`.
    last_line: Int,
    /// Steppers energized? `M17` -> True; `M18`/`M84` -> False. Starts False.
    motors_on: Bool,
    /// G90 absolute (start True) vs G91 relative.
    abs: Bool,
    /// Integrated machine position (mm). Advances ONLY on `tick`, never on `feed`.
    x: Float,
    y: Float,
    z: Float,
    /// True while halted on an `M0`/`M1` pause; blocks until `resume/1`.
    paused: Bool,
    /// Admitted moves awaiting execution — the planner buffer. `feed` ENQUEUES;
    /// `tick` DRAINS. Non-empty here = "physical motion still in flight".
    queue: List(QueuedMove),
    /// The injected XYZ envelope. A move past it is rejected at admission.
    bounds: Bounds,
  )
}

/// A generous default envelope so existing zero-arg `new()` call sites and tests
/// are not constrained by the (operator-config) limits. NOT a product default for
/// real motion limits — those are injected via `with_bounds`.
fn default_bounds() -> Bounds {
  Bounds(min: #(-1000.0, -1000.0, -1000.0), max: #(1000.0, 1000.0, 1000.0))
}

/// A freshly powered emulator: nothing accepted, motors off, absolute, at origin,
/// empty queue, and the generous default envelope.
pub fn new() -> EmulatorState {
  EmulatorState(
    last_line: 0,
    motors_on: False,
    abs: True,
    x: 0.0,
    y: 0.0,
    z: 0.0,
    paused: False,
    queue: [],
    bounds: default_bounds(),
  )
}

/// A freshly powered emulator with an explicit, test-injected envelope. Use this
/// over `new()` whenever the test cares about the bounds (ADR-0013: limits are
/// operator/hardware config, supplied — never defaulted — for real use).
pub fn with_bounds(bounds: Bounds) -> EmulatorState {
  EmulatorState(..new(), bounds: bounds)
}

/// Test seam (ADR-0013): construct an `EmulatorState` with arbitrary field values
/// directly, so a test can drop the emulator into ANY condition without driving it
/// there command by command.
pub fn force(
  last_line last_line: Int,
  motors_on motors_on: Bool,
  abs abs: Bool,
  x x: Float,
  y y: Float,
  z z: Float,
  paused paused: Bool,
  queue queue: List(QueuedMove),
  bounds bounds: Bounds,
) -> EmulatorState {
  EmulatorState(
    last_line: last_line,
    motors_on: motors_on,
    abs: abs,
    x: x,
    y: y,
    z: z,
    paused: paused,
    queue: queue,
    bounds: bounds,
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
    // M410 quickstop: flush the planner — empty the motion queue (the abort the
    // host's Quickstop relies on, ADR-0014), reusing `halt`. Ack with ["ok"].
    FlushQueue -> #(halt(state), ["ok"])
    // Everything else (M3/M5/G4/G92/M6/M400/unknown-but-harmless) -> ok. (M400 is
    // wait-for-queue; after M410 the queue is already empty, so an immediate ok.)
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
  FlushQueue
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
                                False ->
                                  case has_word(cmd, "M410") {
                                    True -> FlushQueue
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
}

// ADMIT a move from a move line (ADR-0013: `feed` admits, `tick` drains). The
// HEAD POSITION IS UNCHANGED here; a move is only ENQUEUED.
//
// MOTOR-ENABLE choice: when motors are off the move is IGNORED — acked with
// `["ok"]`, nothing enqueued. Real Marlin won't physically move with steppers
// disabled; the key invariant is that motion has no effect when motors are off,
// so an e2e test can prove the host energized the steppers (`M17`) before
// streaming.
//
// ENVELOPE choice (ADR-0013): if the resolved ABSOLUTE target lands outside the
// injected `bounds` on any axis, the move is NOT admitted (queue + head
// unchanged). The reply is `["Error:Out of bounds (axis)", "ok"]` — the `Error:`
// line is observable by a test while the trailing `ok` keeps the stream
// handshake alive (real Marlin with software endstops clamps and continues).
fn apply_move(
  state: EmulatorState,
  cmd: String,
) -> #(EmulatorState, List(String)) {
  case state.motors_on {
    False -> #(state, ["ok"])
    True -> {
      // Resolve the absolute target now, so the queued move is independent of
      // any later abs/rel-mode change.
      //
      // ORIGIN (ADR-0013 admit/drain): a move resolves against the END of the
      // pending queue, NOT the live head. The head has not advanced yet for
      // moves still queued ahead of this one, so a relative move chains off the
      // last queued target (or the live head when the queue is empty), and a
      // MISSING axis word carries the pending (queue-end) value.
      let #(ox, oy, oz) = queue_end(state)
      let tx = integrate(state.abs, ox, axis(cmd, "X"))
      let ty = integrate(state.abs, oy, axis(cmd, "Y"))
      let tz = integrate(state.abs, oz, axis(cmd, "Z"))
      case out_of_bounds(state.bounds, tx, ty, tz) {
        option.Some(axis_name) -> #(state, [
          "Error:Out of bounds (" <> axis_name <> ")",
          "ok",
        ])
        option.None -> {
          // Distance is measured from the same queue-end origin to the new
          // target so a multi-move queue's per-move distances stay correct.
          let remaining = distance(#(ox, oy, oz), #(tx, ty, tz))
          let move = QueuedMove(tx: tx, ty: ty, tz: tz, remaining: remaining)
          #(EmulatorState(..state, queue: list_append_one(state.queue, move)), [
            "ok",
          ])
        }
      }
    }
  }
}

// The origin for resolving the NEXT admitted move: the target of the last
// queued move if the queue is non-empty, else the live head. Moves admitted
// ahead of the head have not drained yet, so chaining off the live head would
// collapse them onto the same target (ADR-0013 admit/drain).
fn queue_end(state: EmulatorState) -> #(Float, Float, Float) {
  case last(state.queue) {
    option.Some(move) -> #(move.tx, move.ty, move.tz)
    option.None -> #(state.x, state.y, state.z)
  }
}

// The last element of a list, or None if empty.
fn last(xs: List(a)) -> option.Option(a) {
  case xs {
    [] -> option.None
    [x] -> option.Some(x)
    [_, ..rest] -> last(rest)
  }
}

// The first axis whose target falls outside `[min, max]`, else None.
fn out_of_bounds(
  bounds: Bounds,
  tx: Float,
  ty: Float,
  tz: Float,
) -> option.Option(String) {
  let Bounds(min: #(min_x, min_y, min_z), max: #(max_x, max_y, max_z)) = bounds
  case tx <. min_x || tx >. max_x {
    True -> option.Some("X")
    False ->
      case ty <. min_y || ty >. max_y {
        True -> option.Some("Y")
        False ->
          case tz <. min_z || tz >. max_z {
            True -> option.Some("Z")
            False -> option.None
          }
      }
  }
}

// Euclidean distance between two 3D points.
fn distance(a: #(Float, Float, Float), b: #(Float, Float, Float)) -> Float {
  let #(ax, ay, az) = a
  let #(bx, by, bz) = b
  let dx = bx -. ax
  let dy = by -. ay
  let dz = bz -. az
  let sq = dx *. dx +. dy *. dy +. dz *. dz
  case float.square_root(sq) {
    Ok(d) -> d
    Error(_) -> 0.0
  }
}

// Append one element to the END of a list (queue order: FIFO).
fn list_append_one(xs: List(a), x: a) -> List(a) {
  case xs {
    [] -> [x]
    [head, ..rest] -> [head, ..list_append_one(rest, x)]
  }
}

/// Advance the head by draining the queue (ADR-0013: `tick` DRAINS). `dt` is the
/// distance budget (mm) to consume this tick. The head moves toward the head
/// move's target; when a move completes (`remaining <= dt`) the head snaps
/// exactly to that target and the LEFTOVER budget carries to the next queued
/// move. A `tick` on an empty queue is a no-op. The head only ever advances here.
pub fn tick(state: EmulatorState, dt: Float) -> EmulatorState {
  case state.queue {
    // Empty queue -> nothing to drain. No-op.
    [] -> state
    [move, ..rest] ->
      case dt <=. 0.0 {
        True -> state
        False ->
          case move.remaining <=. dt {
            // This move completes: snap the head to its target, carry leftover
            // budget into the rest of the queue.
            True -> {
              let landed =
                EmulatorState(
                  ..state,
                  x: move.tx,
                  y: move.ty,
                  z: move.tz,
                  queue: rest,
                )
              tick(landed, dt -. move.remaining)
            }
            // Partial progress: move the head a fraction toward the target and
            // reduce the move's remaining distance.
            False -> {
              let fraction = dt /. move.remaining
              let nx = state.x +. { move.tx -. state.x } *. fraction
              let ny = state.y +. { move.ty -. state.y } *. fraction
              let nz = state.z +. { move.tz -. state.z } *. fraction
              EmulatorState(..state, x: nx, y: ny, z: nz, queue: [
                QueuedMove(..move, remaining: move.remaining -. dt),
                ..rest
              ])
            }
          }
      }
  }
}

/// Drain the ENTIRE queue regardless of `dt` — advance fully so the head lands on
/// the final queued target. A convenience for tests that want "advance fully".
pub fn tick_all(state: EmulatorState) -> EmulatorState {
  case state.queue {
    [] -> state
    [move, ..rest] -> {
      let landed =
        EmulatorState(..state, x: move.tx, y: move.ty, z: move.tz, queue: rest)
      tick_all(landed)
    }
  }
}

/// Clear the queue — physical motion STOPS (ADR-0013: the abort). The head stays
/// wherever the last completed `tick` left it.
pub fn halt(state: EmulatorState) -> EmulatorState {
  EmulatorState(..state, queue: [])
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
