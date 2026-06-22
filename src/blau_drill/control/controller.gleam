//// The thin effectful shell around the pure `printer` state machine — the
//// integration layer the UI (Phase 4) drives. It graduates the Phase-0 spike's
//// effect plumbing into a reusable module:
////
////   * holds the `printer.PrinterState`, the chosen `Backend`, and the live
////     `Conn` in a `Controller` record;
////   * turns operator commands into pure `printer.command` steps, then performs
////     the resulting writes as Lustre effects;
////   * feeds inbound serial lines into `printer.feed` (driving the handshake)
////     and surfaces stream progress / position / faults as `Event`s.
////
//// CRITICAL: the framed writes a step returns are written sequentially inside
//// ONE `effect.from` (see `write_seq_effect`), never via `effect.batch` —
//// `effect.batch` reverses synchronous run order, which would corrupt an
//// order-dependent jog (`G91`/`G0`/`G90`) into `G90`/`G0`/`G91`. The pure core
//// already returns the writes in order; this layer preserves that order.
////
//// This module is the only place transport effects live. The pure transition
//// logic stays in `printer`; everything testable-without-a-browser is there.

import blau_drill/control/backend.{type Backend, type Conn}
import blau_drill/control/printer.{type Command, type Event, type PrinterState}
import gleam/javascript/promise.{type Promise}
import lustre/effect.{type Effect}

// ── controller record ────────────────────────────────────────────────────────

/// Everything the controller needs: the chosen transport, the live connection
/// (once open), and the pure state machine value.
pub type Controller {
  Controller(backend: Backend, conn: ConnOpt, state: PrinterState)
}

/// `Option`-shaped wrapper for the connection handle (kept local so the record
/// stays flat and pattern matches read cleanly).
pub type ConnOpt {
  NoConn
  HaveConn(Conn)
}

/// Messages the host app routes into the controller. The host wraps these in its
/// own `Msg` and forwards them to `update`.
pub type ControllerMsg {
  /// The operator issued a command.
  Issue(Command)
  /// The transport open resolved.
  Opened(Result(Conn, String))
  /// An inbound serial line arrived from the read loop.
  Inbound(String)
  /// The read loop hit an error / the port vanished.
  Lost(String)
  /// A write completed (or failed). A failed write is treated as serial loss.
  WriteDone(Result(Nil, String))
}

/// What a controller `update` hands back to the host: the next controller, the
/// effect to run, and the pure events emitted by the transition (so the host can
/// react — animate progress, surface a position, show a fault).
pub type ControllerOut {
  ControllerOut(
    controller: Controller,
    effect: Effect(ControllerMsg),
    events: List(Event),
  )
}

// ── construction ─────────────────────────────────────────────────────────────

/// A fresh controller for the given backend, disconnected.
pub fn new(backend: Backend) -> Controller {
  Controller(backend: backend, conn: NoConn, state: printer.new())
}

/// Swap the transport (only meaningful while disconnected). The host should gate
/// this on `Disconnected`.
pub fn set_backend(controller: Controller, backend: Backend) -> Controller {
  Controller(..controller, backend: backend)
}

// ── effect to open the port ──────────────────────────────────────────────────

/// Open the chosen backend at `baud`. For the real Web Serial port this MUST be
/// called from a user gesture. Resolves into an `Opened` message.
pub fn connect(controller: Controller, baud: Int) -> Effect(ControllerMsg) {
  let backend = controller.backend
  use dispatch <- effect.from
  backend.open(baud)
  |> promise.map(fn(res) { dispatch(Opened(res)) })
  Nil
}

/// Re-open a previously-authorized port at `baud` WITHOUT a picker / user gesture
/// (via the backend's `open_existing`). Safe to call on load; resolves into the
/// same `Opened` message, so an `Error("no granted port")` simply leaves the app
/// disconnected with no prompt. Used for auto-reconnect.
pub fn connect_existing(
  controller: Controller,
  baud: Int,
) -> Effect(ControllerMsg) {
  let backend = controller.backend
  use dispatch <- effect.from
  backend.open_existing(baud)
  |> promise.map(fn(res) { dispatch(Opened(res)) })
  Nil
}

// ── the update loop ──────────────────────────────────────────────────────────

/// Route a `ControllerMsg` through the state machine and the transport.
pub fn update(controller: Controller, msg: ControllerMsg) -> ControllerOut {
  case msg {
    Issue(cmd) -> run_step(controller, printer.command(controller.state, cmd))

    Inbound(line) -> run_step(controller, printer.feed(controller.state, line))

    Lost(reason) ->
      run_step(controller, printer.serial_lost(controller.state, reason))

    Opened(Ok(conn)) -> {
      // Record the connection, drive the pure machine to Idle, and install the
      // read loop once.
      let step = printer.command(controller.state, printer.Connect)
      let c = Controller(..controller, conn: HaveConn(conn), state: step.state)
      ControllerOut(
        controller: c,
        effect: read_effect(controller.backend, conn),
        events: step.events,
      )
    }

    Opened(Error(_reason)) ->
      // Open failed: stay disconnected, no writes, no events. The host surfaces
      // the reason from its own error channel if it cares.
      ControllerOut(controller, effect.none(), [])

    WriteDone(Ok(_)) -> ControllerOut(controller, effect.none(), [])

    WriteDone(Error(reason)) ->
      // A write failure is serial loss — fault the machine.
      run_step(controller, printer.serial_lost(controller.state, reason))
  }
}

// ── glue: run a pure step, then perform its writes ───────────────────────────

/// Apply a pure `printer.Step`: adopt the next state, and emit one effect that
/// writes the step's framed payloads IN ORDER (or none).
fn run_step(controller: Controller, step: printer.Step) -> ControllerOut {
  let c = Controller(..controller, state: step.state)
  let eff = case c.conn, step.writes {
    _, [] -> effect.none()
    HaveConn(conn), writes -> write_seq_effect(c.backend, conn, writes)
    NoConn, _ -> effect.none()
  }
  ControllerOut(controller: c, effect: eff, events: step.events)
}

// ── effects: read loop and ordered writes ────────────────────────────────────

fn read_effect(b: Backend, conn: Conn) -> Effect(ControllerMsg) {
  use dispatch <- effect.from
  b.start_reading(conn, fn(line) { dispatch(Inbound(line)) }, fn(reason) {
    dispatch(Lost(reason))
  })
  Nil
}

/// Write a sequence of already-framed payloads to the port IN ORDER, within a
/// SINGLE effect, so ordering is deterministic and independent of `effect.batch`
/// (which reverses synchronous order). Each payload gets the trailing newline.
fn write_seq_effect(
  b: Backend,
  conn: Conn,
  payloads: List(String),
) -> Effect(ControllerMsg) {
  use dispatch <- effect.from
  perform_writes(b, conn, payloads)
  |> promise.map(fn(res) { dispatch(WriteDone(res)) })
  Nil
}

/// Write a burst of framed payloads to the port, SERIALIZED: each write is
/// awaited before the next begins, and the burst short-circuits on the first
/// error. Returns a single `Result` for the whole burst.
///
/// Serialization is essential, not stylistic: a Web Serial `WritableStream`
/// allows only one active writer at a time, so firing the lines of a jog burst
/// (`G91`/`G0`/`G90`) concurrently makes the 2nd `getWriter()` throw "stream is
/// locked" — which the controller would read as serial loss and disconnect. This
/// is exactly the first-jog-disconnect bug; awaiting each write avoids the
/// overlapping writer. Each payload gets the trailing newline.
pub fn perform_writes(
  b: Backend,
  conn: Conn,
  payloads: List(String),
) -> Promise(Result(Nil, String)) {
  case payloads {
    [] -> promise.resolve(Ok(Nil))
    [payload, ..rest] ->
      b.write(conn, payload <> "\n")
      |> promise.await(fn(res) {
        case res {
          // Await this write fully before starting the next (single-writer rule).
          Ok(_) -> perform_writes(b, conn, rest)
          // Short-circuit: surface the failure so the caller can fault.
          Error(reason) -> promise.resolve(Error(reason))
        }
      })
  }
}

// ── inspection ───────────────────────────────────────────────────────────────

/// The current pure state (for the UI to render badges / gate buttons).
pub fn state(controller: Controller) -> PrinterState {
  controller.state
}

/// Whether a live connection is held.
pub fn is_connected(controller: Controller) -> Bool {
  case controller.conn {
    HaveConn(_) -> True
    NoConn -> False
  }
}

/// Close the port (best effort) and reset to disconnected.
pub fn disconnect(
  controller: Controller,
) -> #(Controller, Effect(ControllerMsg)) {
  let eff = case controller.conn {
    HaveConn(conn) -> {
      let b = controller.backend
      use _dispatch <- effect.from
      b.close(conn)
      Nil
    }
    NoConn -> effect.none()
  }
  let step = printer.command(controller.state, printer.Disconnect)
  #(Controller(..controller, conn: NoConn, state: step.state), eff)
}
