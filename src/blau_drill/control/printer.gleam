//// The serial control state machine. It owns the Marlin wire protocol behind a
//// handful of verbs and four active states, modelled with sum types so illegal
//// states are unrepresentable.
////
//// ## Architecture: a PURE core with effects pushed to the edges
////
//// The whole state machine is a pair of pure, total functions over a
//// `PrinterState` value:
////
////   * `command(state, Command) -> Step` — apply an operator command.
////   * `feed(state, line)        -> Step` — feed one inbound serial line in
////     (drives the streaming ok-handshake and `where` resolution).
////
//// A `Step` is `#(next_state, writes, events)`:
////
////   * `writes` is a list of ALREADY-FRAMED payloads to send to the port, IN
////     ORDER. The integration layer writes them sequentially inside ONE effect
////     (never `effect.batch`, which reverses synchronous order and would corrupt
////     an order-dependent jog `G91`/`G0`/`G90` into `G90`/`G0`/`G91`).
////   * `events` is a list of things the outside world (UI / integration layer)
////     cares about — stream progress, a resolved position, a fault, and whether
////     a command was accepted or refused.
////
//// Because the line counter, the in-flight stream job, and the pending `where`
//// all live INSIDE the state value, both functions are pure and the transition
//// tests run with no browser and no transport: feed synthetic inbound lines,
//// assert the emitted writes and the resulting state.
////
//// ## States and transitions
////
////     Disconnected ─connect→ Idle ─energize(M17)→ Jogging ─release(M18)→ Idle
////     Idle/Jogging ─stream→ Streaming ─(all ok'd)→ Idle
////     any active ─halt(M112)|serial-loss→ Faulted ─reconnect→ Idle
////
//// Energize-before-jog is STRUCTURAL: `Jog`/`MoveTo`/`PulseSpindle` are only
//// actioned in `Jogging`, and the only way into `Jogging` emits `M17` as the
//// entry action, so a de-energized jog cannot be expressed.

import blau_drill/control/protocol
import gleam/list
import gleam/string

// ── public types ─────────────────────────────────────────────────────────────

/// Which axis a relative jog moves.
pub type Axis {
  X
  Y
  Z
}

/// The connection mode. A sum type so callers can only offer legal actions and
/// the machine can reject illegal ones structurally. Each variant carries
/// exactly the data that state needs.
pub type PrinterState {
  /// No port. Only `Connect` is meaningful.
  Disconnected
  /// Connected, motors NOT energized. Motion is refused here (energize first).
  /// `line_no` is the Marlin line counter; `pending` tracks an in-flight `where`.
  Idle(line_no: Int, pending: Pending)
  /// Motors energized (after M17). Motion is allowed.
  Jogging(line_no: Int, pending: Pending)
  /// A G-code program is in flight via the ok-handshake — one line at a time.
  Streaming(line_no: Int, job: StreamJob)
  /// Aborted / serial-loss. Loud and reachable from any active state. Only
  /// `Halt` (no-op) and `Reconnect` do anything here.
  Faulted
}

/// A streaming job: the program lines, the index of the line currently in
/// flight (0-based), and the total.
pub type StreamJob {
  StreamJob(lines: List(String), idx: Int, total: Int)
}

/// A one-shot request an inbound line resolves. Only `where` (M114) is pending
/// in `Idle`/`Jogging`.
pub type Pending {
  PendingNone
  PendingWhere
}

/// Operator commands. These are the verbs the UI / integration layer drives the
/// machine with.
pub type Command {
  /// Mark the port connected: `Disconnected -> Idle`. (The transport open is an
  /// effect performed by the integration layer; this records the connected
  /// state and resets the line counter.)
  Connect
  /// Mark the port disconnected: any state -> `Disconnected`.
  Disconnect
  /// Energize steppers and enter `Jogging` (emits M17). `Idle -> Jogging`.
  Energize
  /// Release steppers: `Jogging -> Idle` (emits M18).
  Release
  /// Relative jog of `axis` by `mm`. Only valid in `Jogging`.
  Jog(axis: Axis, mm: Float)
  /// Absolute rapid (`G0 X.. Y..`) to a machine point. Only valid in `Jogging`.
  MoveTo(x: Float, y: Float)
  /// Pulse the configured spindle: `on_cmd`, an `G4 P800` dwell, then `off_cmd`.
  /// Only valid in `Jogging` (gated like motion).
  PulseSpindle(on_cmd: String, off_cmd: String)
  /// Query live position (M114). Valid in `Idle`/`Jogging`.
  Where
  /// Stream a G-code program with the ok-handshake. Valid in `Idle`/`Jogging`.
  Stream(lines: List(String))
  /// Emergency abort (M112, raw): any active state -> `Faulted`.
  Halt
  /// Recover after a fault: `Faulted -> Idle` (resets the line counter).
  Reconnect
}

/// Why a command was refused.
pub type Refusal {
  /// Motion attempted while not energized (in `Idle`).
  NotEnergized
  /// A second stream / jog attempted while streaming.
  Busy
  /// A motion / stream / energize attempted while faulted.
  WhileFaulted
  /// Any command attempted while disconnected (except `Connect`).
  NotConnected
}

/// Things the outside world cares about, emitted by a transition. The UI/
/// integration layer maps these to side effects (animating progress, surfacing
/// a position, showing a fault) — the core never performs them.
pub type Event {
  /// A command was accepted and actioned.
  Accepted(Command)
  /// A command was refused (and wrote nothing).
  Refused(Command, Refusal)
  /// One stream line was confirmed by its `ok`. `sent` is the count confirmed
  /// so far (1..total), `line` is the just-confirmed raw line.
  Progress(sent: Int, total: Int, line: String)
  /// A `where`/M114 reply resolved to a position.
  PositionUpdate(protocol.Position)
  /// A stream finished (all lines ok'd) and the machine returned to `Idle`.
  StreamComplete
  /// The machine entered `Faulted`. `reason` describes why (abort, serial loss).
  Faulting(reason: String)
  /// The machine recovered from a fault to `Idle`.
  Recovered
}

/// The result of a pure transition: the next state, the framed payloads to
/// write (IN ORDER, sent in one effect), and the events to surface.
pub type Step {
  Step(state: PrinterState, writes: List(String), events: List(Event))
}

// ── construction ─────────────────────────────────────────────────────────────

/// The starting state: no port.
pub fn new() -> PrinterState {
  Disconnected
}

// ── command transitions (pure) ───────────────────────────────────────────────

/// Apply an operator command to the current state. Pure and total: returns the
/// next state, the framed writes to perform in order, and the events to surface.
pub fn command(state: PrinterState, cmd: Command) -> Step {
  case state, cmd {
    // ── connect / disconnect ────────────────────────────────────────────────
    // On connect, reset Marlin's line counter to match ours: send `M110 N0`
    // raw. Marlin remembers its last line number across the USB session, so
    // without this the first numbered send (N1) mismatches its expectation and
    // it replies "Error:Line Number is not Last Line Number+1" + Resend.
    Disconnected, Connect ->
      accepted(Idle(line_no: 0, pending: PendingNone), ["M110 N0"], cmd)
    _, Connect ->
      accepted(Idle(line_no: 0, pending: PendingNone), ["M110 N0"], cmd)

    _, Disconnect -> Step(Disconnected, [], [Accepted(Disconnect)])

    // ── from Disconnected: everything else is refused ───────────────────────
    Disconnected, _ -> refused(state, cmd, NotConnected)

    // ── energize / release ──────────────────────────────────────────────────
    // Interactive one-offs (energize/release/jog/move/spindle) are sent RAW —
    // unnumbered, like M112/M114. Only the streamed program uses line numbers +
    // the resend handshake (where line loss matters and is recoverable). Adding
    // these to the N-counter desynced it from Marlin on real hardware (every send
    // → "Error:Line Number..." + Resend, never serviced outside streaming).
    Idle(line_no, _), Energize ->
      // Energize is the structural entry into Jogging: emit M17 then settle.
      accepted(Jogging(line_no: line_no, pending: PendingNone), ["M17"], cmd)
    _, Energize ->
      case state {
        Faulted -> refused(state, cmd, WhileFaulted)
        _ -> refused(state, cmd, Busy)
      }

    Jogging(line_no, _), Release ->
      accepted(Idle(line_no: line_no, pending: PendingNone), ["M18"], cmd)
    _, Release -> refuse_for_state(state, cmd)

    // ── motion (gated behind Jogging) ───────────────────────────────────────
    // All raw/unnumbered (see energize note). Order within a burst is preserved
    // by the controller writing them sequentially in one effect.
    Jogging(line_no, pending), Jog(axis, mm) -> {
      // Relative move: switch to relative, move, restore absolute.
      let move = "G0 " <> axis_letter(axis) <> protocol.format_mm(mm)
      accepted(
        Jogging(line_no: line_no, pending: pending),
        ["G91", move, "G90"],
        cmd,
      )
    }
    _, Jog(_, _) -> refuse_motion(state, cmd)

    Jogging(line_no, pending), MoveTo(x, y) -> {
      // Absolute rapid (already in G90/absolute).
      let line =
        "G0 X" <> protocol.format_mm(x) <> " Y" <> protocol.format_mm(y)
      accepted(Jogging(line_no: line_no, pending: pending), [line], cmd)
    }
    _, MoveTo(_, _) -> refuse_motion(state, cmd)

    Jogging(line_no, pending), PulseSpindle(on_cmd, off_cmd) ->
      // Test the configured spindle: on, a short dwell, then off.
      accepted(
        Jogging(line_no: line_no, pending: pending),
        [on_cmd, "G4 P800", off_cmd],
        cmd,
      )
    _, PulseSpindle(_, _) -> refuse_motion(state, cmd)

    // ── where (M114, raw) ───────────────────────────────────────────────────
    Idle(line_no, _), Where -> {
      let #(payload, n) = protocol.frame("M114", line_no)
      accepted(Idle(line_no: n, pending: PendingWhere), [payload], cmd)
    }
    Jogging(line_no, _), Where -> {
      let #(payload, n) = protocol.frame("M114", line_no)
      accepted(Jogging(line_no: n, pending: PendingWhere), [payload], cmd)
    }
    _, Where -> refuse_for_state(state, cmd)

    // ── stream (ok-handshake) ───────────────────────────────────────────────
    Idle(line_no, _), Stream(lines) -> start_stream(line_no, lines, cmd)
    Jogging(line_no, _), Stream(lines) -> start_stream(line_no, lines, cmd)
    Streaming(_, _), Stream(_) -> refused(state, cmd, Busy)
    Faulted, Stream(_) -> refused(state, cmd, WhileFaulted)

    // ── halt (M112, raw) — always reachable from an active state ─────────────
    Faulted, Halt ->
      // Halt while already faulted is a no-op success (no write).
      Step(Faulted, [], [Accepted(Halt)])
    _, Halt -> {
      // From any active state: emit M112 raw (counter unchanged) and fault.
      let line_no = current_line_no(state)
      let #(payload, _n) = protocol.frame("M112", line_no)
      Step(Faulted, [payload], [Accepted(Halt), Faulting("halt (M112)")])
    }

    // ── reconnect (Faulted -> Idle) ─────────────────────────────────────────
    // Like Connect, resync Marlin's line counter with a raw `M110 N0`.
    Faulted, Reconnect ->
      Step(Idle(line_no: 0, pending: PendingNone), ["M110 N0"], [
        Accepted(Reconnect),
        Recovered,
      ])
    _, Reconnect -> refuse_for_state(state, cmd)
  }
}

// ── inbound line handling (pure — drives the handshake) ──────────────────────

/// Feed one inbound serial line into the machine. In `Streaming` this drives the
/// ok-handshake; in `Idle`/`Jogging` a position line resolves a pending `where`.
/// Pure and total.
pub fn feed(state: PrinterState, raw_line: String) -> Step {
  let line = trim(raw_line)
  case state {
    Streaming(line_no, job) -> feed_stream(line_no, job, line)

    Idle(line_no, PendingWhere) ->
      feed_where(state, line_no, line, fn(n, p) { Idle(line_no: n, pending: p) })
    Jogging(line_no, PendingWhere) ->
      feed_where(state, line_no, line, fn(n, p) {
        Jogging(line_no: n, pending: p)
      })

    // No pending request: inbound lines are informational, ignore.
    _ -> Step(state, [], [])
  }
}

/// Signal that the transport read loop hit an error / serial loss. Any active
/// state faults loudly (aborting a stream); already-disconnected/faulted is a
/// no-op. Pure.
pub fn serial_lost(state: PrinterState, reason: String) -> Step {
  case state {
    Disconnected -> Step(state, [], [])
    Faulted -> Step(state, [], [])
    _ -> Step(Faulted, [], [Faulting("serial loss: " <> reason)])
  }
}

// ── inbound helpers ──────────────────────────────────────────────────────────

fn feed_where(
  _state: PrinterState,
  line_no: Int,
  line: String,
  rebuild: fn(Int, Pending) -> PrinterState,
) -> Step {
  case protocol.parse_m114(line) {
    Ok(pos) -> Step(rebuild(line_no, PendingNone), [], [PositionUpdate(pos)])
    // Probably the trailing `ok`; keep waiting for the position line.
    Error(_) -> Step(rebuild(line_no, PendingWhere), [], [])
  }
}

/// The streaming ok-handshake (THE critical invariant). `ok` confirms the
/// current line and advances (sending the next); `Resend:` / `Error` re-send the
/// CURRENT line WITHOUT advancing; any other line is informational and ignored.
/// Exactly one line is ever in flight.
fn feed_stream(line_no: Int, job: StreamJob, line: String) -> Step {
  case classify_reply(line) {
    ReplyOk -> {
      let next = job.idx + 1
      let confirmed = line_at(job.lines, job.idx)
      let progress = Progress(sent: next, total: job.total, line: confirmed)
      case next >= job.total {
        True ->
          // All lines accepted: a completed stream returns to Idle, NOT back to
          // the originating mode.
          Step(Idle(line_no: line_no, pending: PendingNone), [], [
            progress,
            StreamComplete,
          ])
        False -> {
          // Advance and send the next line.
          let job2 = StreamJob(..job, idx: next)
          let next_line = line_at(job2.lines, next)
          let #(payload, n) = protocol.frame(next_line, line_no)
          Step(Streaming(line_no: n, job: job2), [payload], [progress])
        }
      }
    }
    ReplyResend -> {
      // NAK / recoverable Error: re-send the CURRENT line without advancing.
      let cur = line_at(job.lines, job.idx)
      let #(payload, n) = protocol.frame(cur, line_no)
      Step(Streaming(line_no: n, job: job), [payload], [])
    }
    // Position / busy / echo during a stream: informational, ignore.
    ReplyOther -> Step(Streaming(line_no: line_no, job: job), [], [])
  }
}

type Reply {
  ReplyOk
  ReplyResend
  ReplyOther
}

fn classify_reply(line: String) -> Reply {
  case starts_with(line, "ok") {
    True -> ReplyOk
    False ->
      case starts_with(line, "Resend:") || starts_with(line, "Error") {
        True -> ReplyResend
        False -> ReplyOther
      }
  }
}

// ── command helpers ──────────────────────────────────────────────────────────

fn start_stream(line_no: Int, lines: List(String), cmd: Command) -> Step {
  case lines {
    // Empty program: nothing to stream — stay put, accept, no writes.
    [] -> accepted(Idle(line_no: line_no, pending: PendingNone), [], cmd)
    [first, ..] -> {
      let job = StreamJob(lines: lines, idx: 0, total: list.length(lines))
      // Entry action: send the first line.
      let #(payload, n) = protocol.frame(first, line_no)
      Step(Streaming(line_no: n, job: job), [payload], [Accepted(cmd)])
    }
  }
}

fn accepted(state: PrinterState, writes: List(String), cmd: Command) -> Step {
  Step(state, writes, [Accepted(cmd)])
}

fn refused(state: PrinterState, cmd: Command, reason: Refusal) -> Step {
  // A refusal writes NOTHING — the core invariant for the gates.
  Step(state, [], [Refused(cmd, reason)])
}

/// Motion refused: distinguish "not energized" (in Idle) from other states.
fn refuse_motion(state: PrinterState, cmd: Command) -> Step {
  case state {
    Idle(_, _) -> refused(state, cmd, NotEnergized)
    Streaming(_, _) -> refused(state, cmd, Busy)
    Faulted -> refused(state, cmd, WhileFaulted)
    _ -> refused(state, cmd, NotConnected)
  }
}

/// Generic refusal for non-motion commands valid only in specific states.
fn refuse_for_state(state: PrinterState, cmd: Command) -> Step {
  case state {
    Faulted -> refused(state, cmd, WhileFaulted)
    Streaming(_, _) -> refused(state, cmd, Busy)
    Disconnected -> refused(state, cmd, NotConnected)
    _ -> refused(state, cmd, NotEnergized)
  }
}

// ── small pure helpers ───────────────────────────────────────────────────────

fn axis_letter(axis: Axis) -> String {
  case axis {
    X -> "X"
    Y -> "Y"
    Z -> "Z"
  }
}

fn current_line_no(state: PrinterState) -> Int {
  case state {
    Idle(n, _) -> n
    Jogging(n, _) -> n
    Streaming(n, _) -> n
    _ -> 0
  }
}

fn line_at(lines: List(String), idx: Int) -> String {
  case list.drop(lines, idx) {
    [x, ..] -> x
    [] -> ""
  }
}

// ── inspection helpers (for the UI / integration layer) ──────────────────────

/// A short stable name for the current state (for badges / logs).
pub fn state_name(state: PrinterState) -> String {
  case state {
    Disconnected -> "disconnected"
    Idle(_, _) -> "idle"
    Jogging(_, _) -> "jogging"
    Streaming(_, _) -> "streaming"
    Faulted -> "faulted"
  }
}

/// Whether the machine is currently streaming.
pub fn is_streaming(state: PrinterState) -> Bool {
  case state {
    Streaming(_, _) -> True
    _ -> False
  }
}

/// Current stream progress as `#(sent, total)`, or `#(0, 0)` when not streaming.
/// `sent` is the index of the line currently in flight (i.e. confirmed so far).
pub fn stream_progress(state: PrinterState) -> #(Int, Int) {
  case state {
    Streaming(_, job) -> #(job.idx, job.total)
    _ -> #(0, 0)
  }
}

// ── tiny string helpers ──────────────────────────────────────────────────────

fn trim(s: String) -> String {
  string.trim(s)
}

fn starts_with(s: String, prefix: String) -> Bool {
  string.starts_with(s, prefix)
}
