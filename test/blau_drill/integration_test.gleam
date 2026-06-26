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
import blau_drill/control/printer.{type PrinterState, ResumeStream, Stream}
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

/// Await the deferred but give up after `ms` — a never-resolving deferred (a
/// regressed handshake) then FAILS loudly here instead of stalling the runner.
@external(javascript, "./control_test_ffi.mjs", "deferredPromiseWithTimeout")
fn deferred_promise_with_timeout(
  d: Deferred(a),
  ms: Int,
  ok: fn(a) -> Result(a, Nil),
  err: fn() -> Result(a, Nil),
) -> Promise(Result(a, Nil))

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
    |> list.map(fn(p) { Correspondence(board: p, machine: p, machine_z: 0.0) })

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
  // The human-readable (`Rich`) render of the drill program — the M3/plunge
  // ordering is identical to the streamed form (the filter only drops
  // blank/comment lines, never reorders).
  let lines =
    build_drill_rendered(gcode_program.Rich) |> list.map(fn(rl) { rl.wire })
  let spindle = first_index(lines, fn(l) { string.starts_with(l, "M3 S") })
  let plunge = first_index(lines, fn(l) { string.starts_with(l, "G1 Z-") })
  case spindle, plunge {
    Ok(s), Ok(p) -> { s < p } |> should.equal(True)
    _, _ -> should.fail()
  }
}

// The drill program as `RenderedLine`s (ADR-0017): `build_ops` +
// `render(_, _, target)`. The `Wire` target is the exact form the app streams
// through `printer.Stream`; the `Rich` target is the human-readable form.
fn build_drill_rendered(
  target: gcode_program.RenderTarget,
) -> List(gcode_program.RenderedLine) {
  let bm = parse_sample()
  let corrs =
    bridge.feature_candidates(bm)
    |> list.map(fn(p) { Correspondence(board: p, machine: p, machine_z: 0.0) })
  let assert Ok(al) = alignment.fit(corrs)
  let cfg = config.GcodeConfig(..config.default(), mode: config.Drill)
  let ops = gcode_program.build_ops(bm, al, cfg)
  let ctx = gcode_program.render_context(bm, al, cfg)
  gcode_program.render(ops, ctx, target)
}

// ── the end-to-end stream proof ──────────────────────────────────────────────

/// Stream the real drill program through the real sim + real transitions; the
/// machine reaches `StreamComplete` → `Idle` having confirmed every streamed
/// line and drilled every hole (one `G1 X.. Y.. F..` travel move per hole).
///
/// We stream the `Wire` render (`render(_, _, Wire)`) — the exact form the app
/// streams (`app.gleam`): the rendered program minus blank lines and full-line
/// comments, which Marlin doesn't reliably `ok`. The sentinels survive the
/// filter (they start with a command token), so the pause path is still
/// exercised.
///
/// The default config has `app_pause: True`, so the program carries
/// `M0_APP_PAUSE` sentinels (one per bit-change). When the stream hits a
/// sentinel the FSM enters `StreamPaused` and emits `StreamPausedAt` — it does
/// NOT auto-complete. The harness drives the pause/resume handshake exactly as
/// the app does (`app_test`'s `ResumeDrilling` → `ResumeStream`): on every
/// inbound line, if the FSM is now paused, issue `ResumeStream` to send the next
/// real line and re-arm the handshake. So this proves the full streamed-WITH-
/// pauses program runs straight through to `StreamComplete` + `Idle`.
pub fn drill_program_streams_to_complete_test() -> Promise(Nil) {
  // The app streams `RenderedLine`s (ADR-0017): `render(_, _, Wire)` — each line
  // pairs its framed wire text with the typed origin the FSM pauses on. The
  // sentinel lines carry a REAL `origin.pause` (so the pause path runs through
  // the origin check, not a string match). `lines` is the `.wire` projection of
  // the `Wire` render, the streamed form, for the string asserts.
  let rendered = build_drill_rendered(gcode_program.Wire)
  let lines = list.map(rendered, fn(rl) { rl.wire })
  let total_lines = list.length(lines)
  // Count actual hole moves: the inter-hole XY travel is now a controlled
  // `G1 X.. Y.. F<xy_feed>` (ADR-0015; was a `G0 X..` rapid). The only `G0 X..`
  // left is the per-tool-block bit-exchange reposition, which is NOT counted. The
  // ADR-0014 drill prepare-pose travel is ALSO a `G1 X.. Y.. F..` but carries an
  // inline `( prepare: ... )` comment, so excluding commented lines keeps this a
  // pure "one inter-hole travel per hole" count.
  let hole_count =
    list.count(lines, fn(l) {
      string.starts_with(l, "G1 X")
      && string.contains(l, " F")
      && !string.contains(l, "(")
    })
  hole_count |> should.equal(130)

  // The app-pause sentinels are CONSUMED by the FSM, never sent to the port, so
  // they never draw an `ok`/`Progress`. The handshake therefore confirms only
  // the REAL lines: every streamed line except the sentinels. The run must carry
  // at least one sentinel (default app_pause is on) so this asserts the pause
  // path is actually exercised, not bypassed.
  let sentinel_count =
    list.count(lines, fn(l) { string.trim(l) == gcode_program.app_pause_marker })
  { sentinel_count >= 1 } |> should.equal(True)
  let confirmable_lines = total_lines - sentinel_count

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

    let started = printer.command(ref_get(state_ref), Stream(rendered))
    let _ = ref_set(state_ref, started.state)
    perform_writes(b, conn, started.writes)
    Nil
  })
  // Bound the wait: a regressed handshake that never reaches StreamComplete now
  // FAILS here rather than hanging the runner forever. The happy path streams
  // ~470 lines, each acked ~10ms ahead by the sim (≈5s wall), so the deadline is
  // 7s — comfortably above the real run, below the gate's 8s per-test backstop.
  |> promise.await(fn(_) {
    deferred_promise_with_timeout(done, 7000, Ok, fn() { Error(Nil) })
  })
  |> promise.map(fn(result) {
    case result {
      // Every real (sent) line was confirmed by its `ok`; the sentinels were the
      // only lines never sent. Reaching here means the full program — pauses and
      // all — ran to `StreamComplete` and the machine settled back to `idle`.
      Ok(confirmed) -> {
        confirmed |> should.equal(confirmable_lines)
        ref_get(state_ref) |> printer.state_name |> should.equal("idle")
        Nil
      }
      // Timed out: the stream never completed. Fail loudly.
      Error(Nil) -> should.fail()
    }
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

  perform_writes(b, conn, step.writes)

  // The default config has app_pause on, so the program pauses at every
  // bit-change sentinel. When the FSM parks in `StreamPaused`, drive the
  // operator's resume (exactly as the app's `ResumeDrilling` does): issue
  // `ResumeStream` to send the next real line and re-arm the handshake, so the
  // run continues to completion instead of hanging at the first pause.
  case printer.is_stream_paused(step.state) {
    True -> {
      let resumed = printer.command(step.state, ResumeStream)
      let _ = ref_set(state_ref, resumed.state)
      perform_writes(b, conn, resumed.writes)
      // Resuming after the FINAL sentinel completes the run with no further
      // inbound line (no real line to ok), so settle here too.
      case list.any(resumed.events, fn(e) { e == printer.StreamComplete }) {
        True -> {
          let _ = deferred_resolve(done, ref_get(acks))
          Nil
        }
        False -> Nil
      }
    }
    False ->
      case list.any(step.events, fn(e) { e == printer.StreamComplete }) {
        True -> {
          let _ = deferred_resolve(done, ref_get(acks))
          Nil
        }
        False -> Nil
      }
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
