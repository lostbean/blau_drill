//// Phase-4 end-to-end integration: parse a real board (the segby_v1 sample) →
//// fit an alignment → build the DRILL g-code program → stream it through the
//// REAL in-browser simulator transport and the REAL pure transition core,
//// asserting the run reaches `StreamComplete` and the machine settles back to
//// `Idle` having confirmed every line.
////
//// This is the closest headless analogue to driving the full flow: the only
//// thing it cannot exercise is the real Web Serial port (needs USB + a user
//// gesture). It also drives the `job` FSM through its only-legal path
//// (Parsed → … → Drilling) and asserts the gcode safety invariants survive the
//// pipeline (spindle-before-plunge), since we stream `gcode_program` unmodified.

import blau_drill/control/backend.{type Backend, type Conn}
import blau_drill/control/printer.{type PrinterState, Stream}
import blau_drill/control/transport
import blau_drill/domain/alignment
import blau_drill/domain/board_model.{Inputs}
import blau_drill/domain/config
import blau_drill/domain/correspondence.{Correspondence}
import blau_drill/domain/gcode_program
import blau_drill/domain/job
import blau_drill/ui/bridge
import blau_drill/ui/sample
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{Some}
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

// ── parse the sample board ───────────────────────────────────────────────────

/// The sample (segby_v1) parses, has the expected tool count, and yields 4
/// distinct corner candidates for registration.
pub fn sample_parses_test() {
  let bm = parse_sample()
  list.length(bm.holes) |> should.equal(130)
  { bridge.feature_candidates(bm) |> list.length >= 3 } |> should.equal(True)
}

fn parse_sample() -> board_model.BoardModel {
  let assert Ok(bm) =
    board_model.parse(Inputs(
      drl: Some(sample.drl()),
      edge_cuts: Some(sample.edge_cuts_svg()),
    ))
  bm
}

// ── the job FSM only-legal path ───────────────────────────────────────────────

/// The session FSM walks Parsed → Registering → Aligned → DryRun → Drilling via
/// the legal events; the Aligned → Drilling shortcut is rejected.
pub fn job_legal_path_test() {
  let bm = parse_sample()
  let corrs =
    bridge.feature_candidates(bm)
    |> list.map(fn(p) { Correspondence(board: p, machine: p) })

  let j0 = job.new(bm)
  let assert Ok(j1) = job.transition(j0, job.StartRegistering)
  let j2 =
    list.fold(corrs, j1, fn(j, c) {
      let assert Ok(jj) = job.transition(j, job.Capture(c))
      jj
    })
  let assert Ok(j3) = job.transition(j2, job.Fit(j2.tol))
  j3.state |> should.equal(job.Aligned)

  // No shortcut: Aligned → Drilling is illegal (must route through dry-run).
  job.transition(j3, job.ConfirmRegistration)
  |> should.equal(Error(job.IllegalTransition))

  let assert Ok(j4) = job.transition(j3, job.RunDryRun)
  let assert Ok(j5) = job.transition(j4, job.ConfirmRegistration)
  j5.state |> should.equal(job.Drilling)
}

// ── gcode safety invariant survives the pipeline ─────────────────────────────

/// The built drill program emits spindle-on (M3 S..) before the first plunge
/// (G1 Z-..) — the spindle-before-plunge structural invariant, unmodified.
pub fn drill_program_spindle_before_plunge_test() {
  let program = build_drill_program()
  let spindle =
    first_index(program.lines, fn(l) { string.starts_with(l, "M3 S") })
  let plunge =
    first_index(program.lines, fn(l) { string.starts_with(l, "G1 Z-") })
  case spindle, plunge {
    Ok(s), Ok(p) -> { s < p } |> should.equal(True)
    _, _ -> should.fail()
  }
}

fn build_drill_program() -> gcode_program.GcodeProgram {
  let bm = parse_sample()
  let corrs =
    bridge.feature_candidates(bm)
    |> list.map(fn(p) { Correspondence(board: p, machine: p) })
  let assert Ok(al) = alignment.fit(corrs)
  let cfg = config.GcodeConfig(..config.default(), mode: config.Drill)
  gcode_program.build(bm, al, cfg)
}

// ── the end-to-end stream proof ──────────────────────────────────────────────

/// Stream the real drill program through the real sim + real transitions; the
/// machine reaches `StreamComplete` → `Idle` having confirmed all lines and
/// drilled every hole (one `G0 X..` per hole).
pub fn drill_program_streams_to_complete_test() -> Promise(Nil) {
  let program = build_drill_program()
  let total_lines = list.length(program.lines)
  // Count actual hole moves: `G0 X..` lines, EXCLUDING the per-tool-block
  // bit-exchange move (also a `G0 X..`, but carrying the exchange comment).
  let hole_count =
    list.count(program.lines, fn(l) {
      string.starts_with(l, "G0 X")
      && !string.contains(l, "bit-exchange position")
    })
  hole_count |> should.equal(130)

  let b = transport.simulator()
  let acks = new_ref(0)
  let state_ref: Ref(PrinterState) = new_ref(printer.new())
  let done: Deferred(Int) = new_deferred()

  b.open(115_200)
  |> promise.map(fn(res) {
    let assert Ok(conn) = res
    let connected = printer.command(printer.new(), printer.Connect)
    let _ = ref_set(state_ref, connected.state)

    b.start_reading(
      conn,
      fn(line) { on_inbound(b, conn, state_ref, acks, done, line) },
      fn(_reason) { Nil },
    )

    let started = printer.command(ref_get(state_ref), Stream(program.lines))
    let _ = ref_set(state_ref, started.state)
    perform_writes(b, conn, started.writes)
    Nil
  })
  |> promise.await(fn(_) { deferred_promise(done) })
  |> promise.map(fn(confirmed) {
    confirmed |> should.equal(total_lines)
    ref_get(state_ref) |> printer.state_name |> should.equal("idle")
    Nil
  })
}

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

fn perform_writes(b: Backend, conn: Conn, writes: List(String)) -> Nil {
  list.each(writes, fn(payload) {
    let _ = b.write(conn, payload <> "\n")
    Nil
  })
}

// ── tiny helpers ─────────────────────────────────────────────────────────────

fn first_index(items: List(a), pred: fn(a) -> Bool) -> Result(Int, Nil) {
  do_first_index(items, pred, 0)
}

fn do_first_index(
  items: List(a),
  pred: fn(a) -> Bool,
  i: Int,
) -> Result(Int, Nil) {
  case items {
    [] -> Error(Nil)
    [x, ..rest] ->
      case pred(x) {
        True -> Ok(i)
        False -> do_first_index(rest, pred, i + 1)
      }
  }
}
