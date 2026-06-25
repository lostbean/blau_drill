// In-browser Marlin EMULATOR backend — a thin async PUMP over the PURE emulator
// core (`marlin_emulator.gleam`, compiled to `marlin_emulator.mjs` in this same
// directory). Unlike `sim_ffi.mjs` (which acks every line and models nothing),
// this drives the FAITHFUL core, so headless e2e tests can catch the bugs that
// otherwise only surface on real hardware: streaming stalls (blank line / M0),
// line-number desync (resend), and motor-enable failing.
//
// The core is PURE: `feed(state, line) -> #(next_state, replies)` and
// `resume(state) -> #(next_state, replies)`. Gleam compiles the 2-tuple to a JS
// 2-element array `[nextState, replies]`, and `replies` is a Gleam `List` (which
// the prelude makes iterable / `.toArray()`-able). This FFI keeps the live state
// on the `Conn`, feeds each written line through the core, and emits every reply
// line back to the host via `onLine` — asynchronously (microtask), so the
// handshake stays genuinely async like a real serial port (and like the sim).

import { Ok, Error } from "../../gleam.mjs";
import {
  new$ as emuNew,
  feed,
  resume,
  tick,
  tick_all,
  halt,
} from "./marlin_emulator.mjs";

// A connection holds the live (immutable) core state plus the inbound callback.
export function makeConn() {
  return { state: emuNew(), onLine: null };
}

// The emulator "connects" instantly. Async to share the Backend.open signature.
export async function open(_baud) {
  return new Ok(makeConn());
}

// Like the sim, the emulator has no "previously-authorized device" concept, so
// auto-reconnect reports none granted and lets the host fall back to a normal
// open.
export async function openExisting(_baud) {
  return new Error("no granted port");
}

export function startReading(conn, onLine, _onError) {
  conn.onLine = onLine;
}

// Emit every reply line from the core to the host, on a microtask so inbound
// lines arrive asynchronously (genuine async handshake, awaited by the e2e).
function emitReplies(conn, replies) {
  // `replies` is a Gleam List — iterable via the prelude. Snapshot to an array
  // first so the async emit walks a stable list.
  const lines = [...replies];
  Promise.resolve().then(() => {
    for (const line of lines) {
      if (conn.onLine) conn.onLine(line);
    }
  });
}

// Write one (already-framed) line: feed it through the PURE core, then AUTO-PUMP
// the motion queue so the move actually EXECUTES (the head lands on its target),
// then emit the core's reply lines. Returns Promise(Result(Nil)).
//
// ADR-0013 ("one core, two drivers"): this live in-app Backend is the AUTO-PUMP
// driver — a written move admitted to the queue by `feed` is immediately drained
// by `tick_all`, so the simulator behaves like a real printer that runs the move
// to completion. We pump synchronously on write (deterministic, no JS interval is
// needed for the live sim) — this keeps existing wire-level position assertions
// (emuX/emuY/emuZ) true. The DETERMINISTIC freeze-mid-move path (for the
// abort-mid-move test) is a SEPARATE path exposed via the e2e tick/halt hooks
// below; `write` must always fully drain so live moves execute.
export async function write(conn, raw) {
  const [nextState, replies] = feed(conn.state, String(raw));
  conn.state = tick_all(nextState); // AUTO-PUMP: drain the motion queue (ADR-0013)
  emitReplies(conn, replies);
  return new Ok(undefined);
}

export async function close(_conn) {
  return undefined;
}

// ── e2e-only helpers (NOT part of the Backend seam) ──────────────────────────

// Release an `M0`/`M1` pause (the operator pressing the panel button). Used only
// by the e2e M0 test — there is no "resume" command on the wire. Feeds the
// core's `resume`, advances state, and emits the deferred `ok`.
export function emuResume(conn) {
  const [nextState, replies] = resume(conn.state);
  conn.state = nextState;
  emitReplies(conn, replies);
  return undefined;
}

// Inspect the emulator's stepper state at the WIRE level (the core's
// `motors_on` field). Lets the connect->energize e2e prove energize actually
// flipped the motors, not just the FSM.
export function emuMotorsOn(conn) {
  return conn.state.motors_on;
}

// Inspect the emulator's integrated position (mm) — used by the jog e2e to prove
// motion advanced at the wire level.
export function emuX(conn) {
  return conn.state.x;
}

export function emuY(conn) {
  return conn.state.y;
}

export function emuZ(conn) {
  return conn.state.z;
}

// ── deterministic motion-queue drive helpers (ADR-0013, e2e-only) ─────────────
//
// These expose the DETERMINISTIC pump path (the half NOT taken by `write`): a
// test can `feed` a long move (admitted but undrained), inspect the queue, then
// drive `tick`/`halt` by hand to assert the freeze-mid-move / abort-stops-the-head
// regression. Like emuX/emuMotorsOn, they read/write `conn.state` directly and are
// NOT part of the Backend seam.

// Number of admitted-but-not-yet-executed moves in the planner buffer.
export function emuQueueLen(conn) {
  return [...conn.state.queue].length;
}

// Advance the head by a distance budget `dt` (mm), draining toward the queue
// head. Used to step a move forward part-way (freeze-mid-move).
export function emuTick(conn, dt) {
  conn.state = tick(conn.state, dt);
  return undefined;
}

// Drain the WHOLE queue: land the head on the final target.
export function emuTickAll(conn) {
  conn.state = tick_all(conn.state);
  return undefined;
}

// Clear the queue: motion stops where the last completed tick left the head
// (the `halt`/abort affordance).
export function emuHalt(conn) {
  conn.state = halt(conn.state);
  return undefined;
}
