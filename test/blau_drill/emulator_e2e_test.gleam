//// End-to-end suite driving the REAL pure transition code (`printer.command` /
//// `printer.feed`) through the FAITHFUL emulator transport
//// (`transport.emulator()` over `emulator_ffi.mjs` pumping the pure
//// `marlin_emulator` core). Each test maps to a real hardware bug class the thin
//// simulator could never surface, because the sim acks everything and models
//// nothing.
////
//// Shape mirrors `control_test.gleam`: the emulator replies on a microtask, so
//// the handshake is genuinely asynchronous — every test returns a `Promise(Nil)`
//// gleeunit awaits, folding inbound lines into the pure state via a mutable
//// `Ref` and signalling completion via a `Deferred`. FFI inspectors
//// (`emu_motors_on` / `emu_x` / `emu_resume`) let the tests assert the
//// emulator's WIRE-LEVEL state, not just the FSM.

import blau_drill/control/backend.{type Backend, type Conn}
import blau_drill/control/printer.{type PrinterState}
import blau_drill/control/transport
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/string
import gleeunit/should

// ── mutable cell + deferred (test-only FFI, shared with control_test) ─────────

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

@external(javascript, "./control_test_ffi.mjs", "deferredPromise")
fn deferred_promise(d: Deferred(a)) -> Promise(a)

@external(javascript, "./control_test_ffi.mjs", "deferredResolve")
fn deferred_resolve(d: Deferred(a), value: a) -> a

// A tick: a resolved promise we can `await` to let pending microtask emits flush.
@external(javascript, "./control_test_ffi.mjs", "tick")
fn tick() -> Promise(Nil)

// ── emulator wire-level inspectors (e2e-only FFI) ────────────────────────────

@external(javascript, "./control/emulator_ffi.mjs", "emuMotorsOn")
fn emu_motors_on(conn: Conn) -> Bool

@external(javascript, "./control/emulator_ffi.mjs", "emuX")
fn emu_x(conn: Conn) -> Float

@external(javascript, "./control/emulator_ffi.mjs", "emuResume")
fn emu_resume(conn: Conn) -> Nil

// ── (1) connect -> energize: THE motor-enable regression repro ────────────────

/// Open the emulator, drive `Connect` (emits `M110 N0`) and feed its `ok`, then
/// `Energize` (emits `M17`) and feed its `ok`. Asserts the FSM reaches `Jogging`
/// AND — the faithful part — the EMULATOR reports motors ON. This proves energize
/// flipped the steppers at the WIRE level, so it catches the reported "motor
/// enable not working" regression if it lives in the protocol layer.
pub fn connect_then_energize_motors_on_test() -> Promise(Nil) {
  let b = transport.emulator()
  let state_ref: Ref(PrinterState) = new_ref(printer.new())
  let lines: Ref(List(String)) = new_ref([])
  let done: Deferred(Bool) = new_deferred()
  let conn_ref: Ref(Result(Conn, Nil)) = new_ref(Error(Nil))

  b.open(115_200)
  |> promise.await(fn(res) {
    let assert Ok(conn) = res
    let _ = ref_set(conn_ref, Ok(conn))

    // Collect every inbound line; fold each into the pure machine. When the
    // motors-on ok lands after M17, the FSM is already in Jogging.
    b.start_reading(
      conn,
      fn(line) {
        let _ = ref_set(lines, list.append(ref_get(lines), [line]))
        let step = printer.feed(ref_get(state_ref), line)
        let _ = ref_set(state_ref, step.state)
        Nil
      },
      fn(_reason) { Nil },
    )

    // Connect: FSM -> Idle, emits M110 N0 raw.
    let connected = printer.command(printer.new(), printer.Connect)
    let _ = ref_set(state_ref, connected.state)
    perform_writes(b, conn, connected.writes)
    tick()
  })
  |> promise.await(fn(_) {
    let assert Ok(conn) = ref_get(conn_ref)
    // Energize: Idle -> Jogging, emits M17 (the motor-enable command).
    let energized = printer.command(ref_get(state_ref), printer.Energize)
    let _ = ref_set(state_ref, energized.state)
    perform_writes(b, conn, energized.writes)
    tick()
  })
  |> promise.await(fn(_) {
    let assert Ok(conn) = ref_get(conn_ref)
    let _ = deferred_resolve(done, emu_motors_on(conn))
    deferred_promise(done)
  })
  |> promise.map(fn(motors_on) {
    // FSM reached Jogging...
    ref_get(state_ref) |> printer.state_name |> should.equal("jogging")
    // ...AND the emulator's steppers are actually ON (wire-level proof).
    motors_on |> should.equal(True)
    Nil
  })
}

// ── (2) jog advances, no resend on the raw path ───────────────────────────────

/// After energize, issue a `Jog` (emits `["G91","G0 X1","G90","M114"]` RAW —
/// unnumbered). Feed replies. Asserts the emulator position ADVANCED (wire-level)
/// AND it emitted NO `Error:`/`Resend:` for the interactive raw path (those are
/// only for the numbered stream handshake; a raw jog must never trip them).
pub fn jog_advances_and_no_resend_test() -> Promise(Nil) {
  let b = transport.emulator()
  let state_ref: Ref(PrinterState) = new_ref(printer.new())
  let lines: Ref(List(String)) = new_ref([])
  let conn_ref: Ref(Result(Conn, Nil)) = new_ref(Error(Nil))

  let record = fn(b: Backend, state_ref: Ref(PrinterState), lines, conn) {
    fn(line) {
      let _ = ref_set(lines, list.append(ref_get(lines), [line]))
      let step = printer.feed(ref_get(state_ref), line)
      let _ = ref_set(state_ref, step.state)
      // The raw jog ends with M114; its position reply re-arms nothing more.
      perform_writes(b, conn, step.writes)
      Nil
    }
  }

  b.open(115_200)
  |> promise.await(fn(res) {
    let assert Ok(conn) = res
    let _ = ref_set(conn_ref, Ok(conn))
    b.start_reading(conn, record(b, state_ref, lines, conn), fn(_) { Nil })

    let connected = printer.command(printer.new(), printer.Connect)
    let _ = ref_set(state_ref, connected.state)
    perform_writes(b, conn, connected.writes)
    tick()
  })
  |> promise.await(fn(_) {
    let assert Ok(conn) = ref_get(conn_ref)
    let energized = printer.command(ref_get(state_ref), printer.Energize)
    let _ = ref_set(state_ref, energized.state)
    perform_writes(b, conn, energized.writes)
    tick()
  })
  |> promise.await(fn(_) {
    let assert Ok(conn) = ref_get(conn_ref)
    // Relative jog X by +1mm.
    let jogged =
      printer.command(ref_get(state_ref), printer.Jog(printer.X, 1.0))
    let _ = ref_set(state_ref, jogged.state)
    perform_writes(b, conn, jogged.writes)
    tick()
  })
  |> promise.await(fn(_) { tick() })
  |> promise.map(fn(_) {
    let assert Ok(conn) = ref_get(conn_ref)
    // The head moved +1mm in X (motors were energized first).
    emu_x(conn) |> should.equal(1.0)
    // No resend/error line on the interactive raw path.
    let bad =
      list.any(ref_get(lines), fn(l) {
        starts_with(l, "Error:") || starts_with(l, "Resend:")
      })
    bad |> should.equal(False)
    Nil
  })
}

// ── (3) numbered stream completes through the emulator ─────────────────────────

/// Stream a small NUMBERED program (`printer.Stream` frames each line with an
/// `N`-counter + checksum). Because the emulator VALIDATES the line number and
/// checksum, reaching `StreamComplete`/Idle proves the numbered handshake works
/// end to end (correct N sequencing, correct checksums). Modelled on
/// `control_test`'s stream test but through the faithful emulator.
pub fn stream_completes_through_emulator_test() -> Promise(Nil) {
  let program = ["G90", "G0 X1 Y1", "G1 Z-1.0", "G1 Z1.0", "G0 X0 Y0", "M400"]
  let total = list.length(program)

  let b = transport.emulator()
  let acks = new_ref(0)
  let state_ref: Ref(PrinterState) = new_ref(printer.new())
  let done: Deferred(Int) = new_deferred()
  let conn_ref: Ref(Result(Conn, Nil)) = new_ref(Error(Nil))

  b.open(115_200)
  |> promise.await(fn(res) {
    let assert Ok(conn) = res
    let _ = ref_set(conn_ref, Ok(conn))

    b.start_reading(
      conn,
      fn(line) { on_stream_line(b, conn, state_ref, acks, done, line) },
      fn(_reason) { Nil },
    )

    // Connect FIRST (FSM -> Idle), and send its `M110 N0` to RESET the emulator's
    // line counter so the numbered stream validates from N1. Its `ok` arrives
    // while the FSM is in Idle, where `feed` ignores it — so it never miscounts
    // as a stream ack. (The original sim control_test sidesteps this by never
    // sending M110; the faithful emulator REQUIRES it, hence the separate phase.)
    let connected = printer.command(printer.new(), printer.Connect)
    let _ = ref_set(state_ref, connected.state)
    perform_writes(b, conn, connected.writes)
    tick()
  })
  |> promise.await(fn(_) {
    let assert Ok(conn) = ref_get(conn_ref)
    // Now kick off the stream: the pure command emits the first framed write.
    let started = printer.command(ref_get(state_ref), printer.Stream(program))
    let _ = ref_set(state_ref, started.state)
    perform_writes(b, conn, started.writes)
    deferred_promise(done)
  })
  |> promise.map(fn(confirmed) {
    confirmed |> should.equal(total)
    ref_get(state_ref) |> printer.state_name |> should.equal("idle")
    Nil
  })
}

fn on_stream_line(
  b: Backend,
  conn: Conn,
  state_ref: Ref(PrinterState),
  acks: Ref(Int),
  done: Deferred(Int),
  line: String,
) -> Nil {
  let step = printer.feed(ref_get(state_ref), line)
  let _ = ref_set(state_ref, step.state)

  let progressed =
    list.any(step.events, fn(e) {
      case e {
        printer.Progress(_, _, _) -> True
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

  perform_writes(b, conn, step.writes)

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

// ── (4) a blank line stalls; the same program WITHOUT it advances ─────────────

/// Documents the streaming-stall bug the sanitize fix prevents: a blank line
/// gets NO `ok` from real Marlin, so a host waiting for one hangs forever. Drives
/// the emulator core directly (via raw writes + the wire-level inspector), proving
/// a blank write produces NO inbound line, whereas a real command DOES ack and
/// the head moves. (Driving a blank THROUGH the numbered FSM is impossible — the
/// FSM never emits a blank — so this is a direct wire-level assertion, the
/// accepted shape for a stall test.)
pub fn blank_line_would_stall_test() -> Promise(Nil) {
  let b = transport.emulator()
  let got: Ref(List(String)) = new_ref([])
  let conn_ref: Ref(Result(Conn, Nil)) = new_ref(Error(Nil))

  b.open(115_200)
  |> promise.await(fn(res) {
    let assert Ok(conn) = res
    let _ = ref_set(conn_ref, Ok(conn))
    b.start_reading(
      conn,
      fn(line) {
        let _ = ref_set(got, list.append(ref_get(got), [line]))
        Nil
      },
      fn(_) { Nil },
    )
    // Energize so a subsequent move would take effect, then write a BLANK line.
    let _ = b.write(conn, "M17\n")
    let _ = b.write(conn, "   \n")
    tick()
  })
  |> promise.await(fn(_) { tick() })
  |> promise.map(fn(_) {
    // Exactly ONE ok — for M17. The blank produced no reply at all (the stall).
    ref_get(got) |> should.equal(["ok"])
    Nil
  })
}

// ── (5) M0 blocks until resume ────────────────────────────────────────────────

/// Feed a program containing a literal `M0` (NOT the in-app sentinel, so it IS
/// framed and written to the wire). The emulator BLOCKS on M0 — no `ok` — so the
/// numbered handshake stalls and never reaches Idle, until `emu_resume` releases
/// it (the panel-button press), after which it completes. Proves M0 blocks and
/// motivates the in-app pause workflow.
pub fn m0_blocks_until_resume_test() -> Promise(Nil) {
  // M0 is the 2nd line: line 1 acks, M0 stalls, then G0 X0 + M400 finish.
  let program = ["G0 X1", "M0", "G0 X0", "M400"]
  let total = list.length(program)

  let b = transport.emulator()
  let acks = new_ref(0)
  let state_ref: Ref(PrinterState) = new_ref(printer.new())
  let done: Deferred(Int) = new_deferred()
  let conn_ref: Ref(Result(Conn, Nil)) = new_ref(Error(Nil))

  b.open(115_200)
  |> promise.await(fn(res) {
    let assert Ok(conn) = res
    let _ = ref_set(conn_ref, Ok(conn))

    b.start_reading(
      conn,
      fn(line) { on_stream_line(b, conn, state_ref, acks, done, line) },
      fn(_reason) { Nil },
    )

    // Phase 1 — Connect (resets the emulator counter via M110 N0). Its `ok`
    // is consumed while the FSM is in Idle, so it never miscounts as a stream ack.
    let connected = printer.command(printer.new(), printer.Connect)
    let _ = ref_set(state_ref, connected.state)
    perform_writes(b, conn, connected.writes)
    tick()
  })
  |> promise.await(fn(_) {
    // Phase 2 — Energize (M17) so the moves would take effect. Consumed in
    // Jogging; its `ok` is likewise ignored by `feed`, no miscount.
    let assert Ok(conn) = ref_get(conn_ref)
    let energized = printer.command(ref_get(state_ref), printer.Energize)
    let _ = ref_set(state_ref, energized.state)
    perform_writes(b, conn, energized.writes)
    tick()
  })
  |> promise.await(fn(_) {
    // Phase 3 — start the stream. Line 1 acks, then M0 STALLS (no ok).
    let assert Ok(conn) = ref_get(conn_ref)
    let started = printer.command(ref_get(state_ref), printer.Stream(program))
    let _ = ref_set(state_ref, started.state)
    perform_writes(b, conn, started.writes)
    tick()
  })
  |> promise.await(fn(_) { tick() })
  |> promise.await(fn(_) {
    // STALLED on M0: only line 1 confirmed, still streaming, not Idle.
    ref_get(acks) |> should.equal(1)
    printer.is_streaming(ref_get(state_ref)) |> should.equal(True)

    // Release the pause (panel button). The deferred `ok` lets the handshake
    // advance past M0 and run to completion.
    let assert Ok(conn) = ref_get(conn_ref)
    emu_resume(conn)
    deferred_promise(done)
  })
  |> promise.map(fn(confirmed) {
    confirmed |> should.equal(total)
    ref_get(state_ref) |> printer.state_name |> should.equal("idle")
    Nil
  })
}

// ── shared helpers ────────────────────────────────────────────────────────────

/// Write framed payloads to the emulator in order (each with the trailing
/// newline), exactly as the integration layer would.
fn perform_writes(b: Backend, conn: Conn, writes: List(String)) -> Nil {
  list.each(writes, fn(payload) {
    let _ = b.write(conn, payload <> "\n")
    Nil
  })
}

fn starts_with(s: String, prefix: String) -> Bool {
  string.starts_with(s, prefix)
}
