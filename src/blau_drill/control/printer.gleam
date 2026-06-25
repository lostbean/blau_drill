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
import blau_drill/domain/gcode_program
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
  /// A stream halted at an in-app pause point (a `M0_APP_PAUSE` sentinel — the
  /// in-app pause workflow, ADR-0009). NOTHING is in flight: the FSM consumed
  /// the sentinel (never wrote it to the port) and is waiting for the operator's
  /// `ResumeStream` to send the next real line and resume the handshake. `job.idx`
  /// points AT the sentinel; resume sends `job.idx + 1`. `Halt` and
  /// `CancelStream` stay reachable here (abort is never lost behind a pause).
  StreamPaused(line_no: Int, job: StreamJob)
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
  /// Click-to-jump to an absolute machine XY. A SAFE jump (ADR-0011): lift Z by a
  /// RELATIVE amount (`z_lift`) FIRST, then travel XY at that lifted height — and
  /// STOP (no absolute descend). Pre-fit there is no surface datum, so an absolute
  /// 'retract'/descend could plunge the bit into the board; a relative up-lift can
  /// NEVER plunge regardless of the current Z. After the lift + travel the head is
  /// left high and the operator jogs DOWN onto the target. `z_lift` is supplied by
  /// the caller from config (the configured z-safe rise) so the core stays
  /// config-agnostic.
  MoveTo(x: Float, y: Float, z_lift: Float)
  /// Pulse the configured spindle: `on_cmd`, an `G4 P800` dwell, then `off_cmd`.
  /// Only valid in `Jogging` (gated like motion).
  PulseSpindle(on_cmd: String, off_cmd: String)
  /// Query live position (M114). Valid in `Idle`/`Jogging`.
  Where
  /// Stream a G-code program with the ok-handshake. Valid in `Idle`/`Jogging`.
  Stream(lines: List(String))
  /// Resume a stream halted at an in-app pause point: `StreamPaused -> Streaming`.
  /// Consumes nothing new — it sends the next REAL line (the one after the
  /// already-consumed `M0_APP_PAUSE` sentinel) and re-arms the ok-handshake. A
  /// benign no-op in any non-paused state (so a stray resume can't move the head).
  ResumeStream
  /// Benign stream cancel: `Streaming -> Idle`. Stops feeding the program (no
  /// further lines go out) and returns to a CONNECTED, non-streaming state
  /// WITHOUT emitting M112 and WITHOUT faulting. This is the graceful counterpart
  /// to `Halt` for navigating away from a dry-run: the machine hasn't moved, the
  /// dry-run is spindle-off, so dropping the remaining lines is safe and the
  /// connection (and any captured alignment in the host) is preserved. A no-op in
  /// any non-streaming connected state. Use `Halt` for a real emergency abort.
  CancelStream
  /// Graceful planner flush — emits raw `M410` (abort queued/buffered moves NOW,
  /// clear the planner) + `M400` (wait for the now-empty queue). RAW/unnumbered
  /// (like M112/M114) so they action immediately rather than queue behind the
  /// very moves they must cancel. Valid from `Streaming`/`StreamPaused`/`Jogging`
  /// -> `Jogging` (motors stay energized, alignment trust preserved). Distinct
  /// from `CancelStream` (host stop, no write) and `Halt` (M112 -> Faulted). It
  /// is the flush `CancelStream` was wrongly assumed to be (ADR-0014).
  Quickstop
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
  /// The stream halted at an in-app pause point (a `M0_APP_PAUSE` sentinel). The
  /// UI surfaces the bit-change / resume modal; the operator's `ResumeStream`
  /// continues the run. `pending` is the count of lines confirmed so far (the
  /// sentinel does not count — it is never sent), `total` the program length.
  StreamPausedAt(pending: Int, total: Int)
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
    Jogging(line_no, _pending), Jog(axis, mm) -> {
      // Relative move: switch to relative, move, restore absolute. M114 is the
      // LAST line of the SAME burst so the position reply reflects the settled
      // head — the caller no longer needs a separate (racing) query.
      let move = "G0 " <> axis_letter(axis) <> protocol.format_mm(mm)
      accepted(
        Jogging(line_no: line_no, pending: PendingWhere),
        ["G91", move, "G90", "M114"],
        cmd,
      )
    }
    _, Jog(_, _) -> refuse_motion(state, cmd)

    Jogging(line_no, _pending), MoveTo(x, y, z_lift) -> {
      // SAFE pre-fit jump (ADR-0011): LIFT Z by a RELATIVE amount FIRST, then
      // travel XY at that lifted height — and STOP. A relative up-lift (G91 / G0
      // Z+<lift> / G90) can NEVER plunge the bit, regardless of the current Z or a
      // missing surface datum; an ABSOLUTE retract/descend could (pre-fit there is
      // no datum). So there is NO absolute descend here — after the lift + travel
      // the head is left high and the operator jogs DOWN onto the target.
      //
      // ORDERING IS CRITICAL: G91 must wrap ONLY the lift (G91 → G0 Z+ → G90),
      // then the XY travel runs in absolute mode (G90). The controller writes these
      // in order in ONE effect (never effect.batch). M114 is the LAST line of the
      // SAME burst, so the position reply reflects the SETTLED head — no race.
      let xy = "G0 X" <> protocol.format_mm(x) <> " Y" <> protocol.format_mm(y)
      let writes = [
        "G91",
        "G0 Z" <> protocol.format_mm(z_lift),
        "G90",
        xy,
        "M114",
      ]
      accepted(Jogging(line_no: line_no, pending: PendingWhere), writes, cmd)
    }
    _, MoveTo(_, _, _) -> refuse_motion(state, cmd)

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
    StreamPaused(_, _), Stream(_) -> refused(state, cmd, Busy)
    Faulted, Stream(_) -> refused(state, cmd, WhileFaulted)

    // ── resume an in-app pause (StreamPaused -> Streaming) ───────────────────
    // Send the next REAL line (the one after the already-consumed sentinel) and
    // re-arm the handshake. Any non-paused state is a benign no-op (never moves
    // the head): a stray resume click while idle/jogging/streaming does nothing.
    StreamPaused(line_no, job), ResumeStream -> resume_stream(line_no, job, cmd)
    _, ResumeStream -> accepted(state, [], cmd)

    // ── cancel stream (benign "go back") — NO write, NO fault ────────────────
    // Stop feeding the program and return to JOGGING (motors stay energized),
    // staying connected. A dry-run is only ever started from Jogging, so the
    // motors are still held and the head is locked in position — returning to
    // Jogging reflects that, so the operator can immediately jog/re-capture and
    // the UI shows MOTORS LIVE. Unlike Halt (M112), this writes nothing and never
    // faults (head hasn't moved, dry-run is spindle-off). The line counter resets
    // to 0 like a fresh connection so a subsequent stream starts cleanly (we
    // stopped mid-handshake, so the in-flight `N` was never `ok`'d).
    Streaming(_, _), CancelStream ->
      accepted(Jogging(line_no: 0, pending: PendingNone), [], cmd)
    // A paused stream cancels the same way: drop the remaining program, return to
    // Jogging (motors live), no write, no fault — the abort/back path is reachable
    // through a pause exactly as through an active stream.
    StreamPaused(_, _), CancelStream ->
      accepted(Jogging(line_no: 0, pending: PendingNone), [], cmd)
    // Benign no-op when there is nothing to cancel (already connected, idle/jog).
    Idle(_, _), CancelStream -> accepted(state, [], cmd)
    Jogging(_, _), CancelStream -> accepted(state, [], cmd)
    Faulted, CancelStream -> refused(state, cmd, WhileFaulted)

    // ── quickstop (graceful planner flush — raw M410 + M400, ADR-0014) ───────
    // The flush CancelStream was wrongly assumed to be: emit RAW (unnumbered)
    // M410 (abort all queued/buffered moves NOW, clear the planner) + M400 (wait
    // for the now-empty queue), so they action immediately rather than queue
    // behind the very moves they must cancel. Lands in Jogging (motors stay
    // energized — alignment trust, ADR-0011), NOT Faulted. The two writes are an
    // order-dependent burst returned as ONE list; the controller writes them in
    // ONE effect (never effect.batch).
    //
    // From a stream we interrupted mid-handshake, so the in-flight `N` was never
    // ok'd: reset line_no to 0 (like CancelStream) so the next stream starts at
    // N1. From Jogging keep the existing line_no.
    Streaming(_, _), Quickstop ->
      accepted(Jogging(line_no: 0, pending: PendingNone), ["M410", "M400"], cmd)
    StreamPaused(_, _), Quickstop ->
      accepted(Jogging(line_no: 0, pending: PendingNone), ["M410", "M400"], cmd)
    Jogging(line_no, _), Quickstop ->
      accepted(
        Jogging(line_no: line_no, pending: PendingNone),
        ["M410", "M400"],
        cmd,
      )
    // Idle = connected, motors OFF, nothing streaming: nothing to flush. Quickstop
    // is a motion-control verb, so it is REFUSED here (NotEnergized) — keeping it
    // a motion-gated command. (Disconnected is covered by the catch-all above;
    // Faulted refuses WhileFaulted.)
    Faulted, Quickstop -> refused(state, cmd, WhileFaulted)
    Idle(_, _), Quickstop -> refuse_motion(state, cmd)

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

    // Nothing is in flight while paused (the sentinel was never sent), so an
    // inbound line is informational: stay paused, write nothing.
    StreamPaused(_, _) -> Step(state, [], [])

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
          // Advance to the next line. If it is the in-app pause sentinel, PAUSE
          // here instead of sending it: consume the sentinel (idx points AT it,
          // so resume continues with idx+1) and emit a pause event. The sentinel
          // is never framed and never written to the port.
          let job2 = StreamJob(..job, idx: next)
          let next_line = line_at(job2.lines, next)
          case is_pause_sentinel(next_line) {
            True ->
              Step(StreamPaused(line_no: line_no, job: job2), [], [
                progress,
                StreamPausedAt(pending: next, total: job.total),
              ])
            False -> {
              let #(payload, n) = protocol.frame(next_line, line_no)
              Step(Streaming(line_no: n, job: job2), [payload], [progress])
            }
          }
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
      // Entry action: send the first line — UNLESS it is the in-app pause
      // sentinel (a program can OPEN with the touch-off pause), in which case
      // pause immediately and wait for the operator's resume. The sentinel is
      // consumed (idx 0), never written; resume sends line 1.
      case is_pause_sentinel(first) {
        True ->
          Step(StreamPaused(line_no: line_no, job: job), [], [
            Accepted(cmd),
            StreamPausedAt(pending: 0, total: job.total),
          ])
        False -> {
          let #(payload, n) = protocol.frame(first, line_no)
          Step(Streaming(line_no: n, job: job), [payload], [Accepted(cmd)])
        }
      }
    }
  }
}

/// Resume a paused stream: the sentinel at `job.idx` was already consumed, so we
/// advance one past it and send that real line — re-arming the handshake. If the
/// sentinel was the LAST line (no real line follows), the stream is complete.
fn resume_stream(line_no: Int, job: StreamJob, cmd: Command) -> Step {
  let next = job.idx + 1
  case next >= job.total {
    True ->
      // The sentinel was the final line: nothing more to send, run is complete.
      Step(Idle(line_no: line_no, pending: PendingNone), [], [
        Accepted(cmd),
        StreamComplete,
      ])
    False -> {
      let job2 = StreamJob(..job, idx: next)
      let next_line = line_at(job2.lines, next)
      let #(payload, n) = protocol.frame(next_line, line_no)
      Step(Streaming(line_no: n, job: job2), [payload], [Accepted(cmd)])
    }
  }
}

/// True when a streamed line is the in-app pause sentinel (`M0_APP_PAUSE`): the
/// FSM intercepts it (pause, write nothing) rather than sending it to the port.
fn is_pause_sentinel(line: String) -> Bool {
  trim(line) == gcode_program.app_pause_marker
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
    StreamPaused(_, _) -> refused(state, cmd, Busy)
    Faulted -> refused(state, cmd, WhileFaulted)
    _ -> refused(state, cmd, NotConnected)
  }
}

/// Generic refusal for non-motion commands valid only in specific states.
fn refuse_for_state(state: PrinterState, cmd: Command) -> Step {
  case state {
    Faulted -> refused(state, cmd, WhileFaulted)
    Streaming(_, _) -> refused(state, cmd, Busy)
    StreamPaused(_, _) -> refused(state, cmd, Busy)
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
    StreamPaused(n, _) -> n
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
    StreamPaused(_, _) -> "stream_paused"
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

/// Whether the machine is currently halted at an in-app pause point.
pub fn is_stream_paused(state: PrinterState) -> Bool {
  case state {
    StreamPaused(_, _) -> True
    _ -> False
  }
}

/// Current stream progress as `#(sent, total)`, or `#(0, 0)` when not streaming.
/// `sent` is the index of the line currently in flight (i.e. confirmed so far).
/// While paused, `sent` is the count confirmed before the pause sentinel (which
/// is never sent, so it does not count).
pub fn stream_progress(state: PrinterState) -> #(Int, Int) {
  case state {
    Streaming(_, job) -> #(job.idx, job.total)
    StreamPaused(_, job) -> #(job.idx, job.total)
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
