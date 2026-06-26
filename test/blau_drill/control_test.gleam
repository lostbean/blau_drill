//// End-to-end control test: runs a short G-code stream through the REAL
//// in-browser simulator transport (`sim_ffi.mjs`) and the REAL pure transition
//// code (`printer.command` / `printer.feed`), asserting the machine reaches
//// `Idle` after exactly N acks.
////
//// The sim acks each streamed line via `setTimeout`, so the handshake is
//// genuinely asynchronous — this test returns a `Promise(Nil)` that gleeunit
//// awaits. It is the closest headless analogue to driving real hardware: the
//// only thing it cannot exercise is the real Web Serial port (which needs a USB
//// device and a user gesture and so is verified only by compilation).
////
//// A small JS shim (`control_test_ffi.mjs`) provides a mutable cell and a
//// deferred Promise so the async read callback can fold inbound lines into the
//// pure state; ALL protocol and state-machine logic stays in Gleam.

import blau_drill/control/backend.{type Backend, type Conn}
import blau_drill/control/printer.{type PrinterState, Stream}
import blau_drill/control/transport
import blau_drill/domain/gcode_program.{
  type RenderedLine, DrillHoleKind, LineOrigin, RenderedLine,
}
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{None}
import gleeunit/should

// Wrap a bare-string program into a `RenderedLine` program (ADR-0017): the FSM
// streams `RenderedLine`s now. A benign non-pause origin — only `.wire` matters
// for these wire-protocol e2e tests.
fn prog(lines: List(String)) -> List(RenderedLine) {
  list.map(lines, fn(l) {
    RenderedLine(
      wire: l,
      origin: LineOrigin(
        op_index: 0,
        kind: DrillHoleKind,
        tool: None,
        hole_id: None,
        pause: None,
      ),
    )
  })
}

// ── mutable cell + deferred (test-only FFI) ──────────────────────────────────

type Ref(a)

@external(javascript, "./control_test_ffi.mjs", "newRef")
fn new_ref(value: a) -> Ref(a)

@external(javascript, "./control_test_ffi.mjs", "refGet")
fn ref_get(ref: Ref(a)) -> a

@external(javascript, "./control_test_ffi.mjs", "refSet")
fn ref_set(ref: Ref(a), value: a) -> a

type Deferred(a)

@external(javascript, "./control_test_ffi.mjs", "newDeferred")
fn new_deferred() -> Deferred(a)

/// Await the deferred but give up after `ms` — a never-resolving deferred (a
/// regressed handshake that parks forever) then FAILS loudly here instead of
/// stalling the runner. (Belt-and-braces with the gate's 8s per-test backstop.)
@external(javascript, "./control_test_ffi.mjs", "deferredPromiseWithTimeout")
fn deferred_promise_with_timeout(
  d: Deferred(a),
  ms: Int,
  ok: fn(a) -> Result(a, Nil),
  err: fn() -> Result(a, Nil),
) -> Promise(Result(a, Nil))

@external(javascript, "./control_test_ffi.mjs", "deferredResolve")
fn deferred_resolve(d: Deferred(a), value: a) -> a

// ── the end-to-end stream proof ──────────────────────────────────────────────

/// Stream a short program through the real sim + real transitions; resolve once
/// the machine reaches Idle, then assert it confirmed all N lines.
pub fn stream_through_sim_reaches_idle_test() -> Promise(Nil) {
  let program = ["G90", "G0 X1 Y1", "G1 Z-1.0", "G1 Z1.0", "G0 X0 Y0", "M400"]
  let total = list.length(program)

  let b = transport.simulator()
  // Count of confirmed acks, the live pure state, and a done-signal.
  let acks = new_ref(0)
  let state_ref: Ref(PrinterState) = new_ref(printer.new())
  let done: Deferred(Int) = new_deferred()

  // Connect, then run the stream.
  b.open(115_200)
  |> promise.map(fn(res) {
    let assert Ok(conn) = res

    // Mark connected (pure Connect), then install the read loop. Inbound lines
    // are fed into the pure machine; each progress event bumps the ack count;
    // completion (machine leaves Streaming -> Idle) resolves the deferred.
    let connected = printer.command(printer.new(), printer.Connect)
    let _ = ref_set(state_ref, connected.state)

    b.start_reading(
      conn,
      fn(line) { on_inbound(b, conn, state_ref, acks, done, line) },
      fn(_reason) { Nil },
    )

    // Kick off the stream: the pure command emits the first framed write.
    let started = printer.command(ref_get(state_ref), Stream(prog(program)))
    let _ = ref_set(state_ref, started.state)
    perform_writes(b, conn, started.writes)
    Nil
  })
  // Bound the wait: a regressed handshake that never reaches Idle now FAILS here
  // rather than hanging the runner. The sim acks each line ~ahead on a setTimeout,
  // so this short program settles well under the 7s deadline (below the gate's 8s
  // per-test backstop). Mirrors `integration_test`.
  |> promise.await(fn(_) {
    deferred_promise_with_timeout(done, 7000, Ok, fn() { Error(Nil) })
  })
  |> promise.map(fn(result) {
    case result {
      // The machine reached Idle having confirmed exactly N lines.
      Ok(confirmed) -> {
        confirmed |> should.equal(total)
        ref_get(state_ref) |> printer.state_name |> should.equal("idle")
        Nil
      }
      // Timed out: the stream never completed. Fail loudly.
      Error(Nil) -> should.fail()
    }
  })
}

/// One inbound line: feed it into the pure machine, perform any writes it asks
/// for (the next stream line), count progress, and resolve when streaming ends.
fn on_inbound(
  b: Backend,
  conn: Conn,
  state_ref: Ref(PrinterState),
  acks: Ref(Int),
  done: Deferred(Int),
  line: String,
) -> Nil {
  let step = printer.feed(ref_get(state_ref), line)
  let _ = ref_set(state_ref, step.state)

  // Count each confirmed line (one Progress event per ok).
  let progressed =
    list.any(step.events, fn(e) {
      case e {
        printer.Progress(_, _, _, _) -> True
        _ -> False
      }
    })
  case progressed {
    True -> {
      let _ = ref_set(acks, ref_get(acks) + 1)
      Nil
    }
    False -> Nil
  }

  // Perform any next-line write the handshake produced.
  perform_writes(b, conn, step.writes)

  // When the stream is done (back in Idle), resolve with the ack count.
  case printer.is_streaming(step.state) {
    False ->
      case list.any(step.events, fn(e) { e == printer.StreamComplete }) {
        True -> {
          let _ = deferred_resolve(done, ref_get(acks))
          Nil
        }
        False -> Nil
      }
    True -> Nil
  }
}

/// Write framed payloads to the sim in order (each with the trailing newline).
fn perform_writes(b: Backend, conn: Conn, writes: List(String)) -> Nil {
  list.each(writes, fn(payload) {
    let _ = b.write(conn, payload <> "\n")
    Nil
  })
}
