//// Regression test for the first-jog disconnect: a jog emits a G91/G0/G90 burst
//// (3 framed lines). The real Web Serial WritableStream allows only ONE active
//// writer at a time, so firing the three writes CONCURRENTLY makes the 2nd
//// getWriter() throw "stream is locked" → the controller treats that as serial
//// loss → DISCONNECT. The fix: serialize the burst (await each write before the
//// next). `controller.perform_writes` must drive a multi-line burst through a
//// lock-enforcing fake with NO lock error and all lines written, in order.
////
//// This is the headless analogue of the on-hardware failure (energize = 1 write
//// worked; jog = 3 writes disconnected).

import blau_drill/control/backend.{type Backend, type Conn, Backend}
import blau_drill/control/controller
import gleam/javascript/promise.{type Promise}
import gleeunit/should

// ── lock-enforcing fake transport (test FFI) ─────────────────────────────────

@external(javascript, "./write_lock_test_ffi.mjs", "newLockedConn")
fn new_locked_conn() -> Conn

@external(javascript, "./write_lock_test_ffi.mjs", "lockedWrite")
fn locked_write(conn: Conn, line: String) -> Promise(Result(Nil, String))

@external(javascript, "./write_lock_test_ffi.mjs", "writtenCount")
fn written_count(conn: Conn) -> Int

@external(javascript, "./write_lock_test_ffi.mjs", "hadLockError")
fn had_lock_error(conn: Conn) -> Bool

/// A backend whose `write` enforces the single-active-writer rule (like a real
/// WritableStream): overlapping writes resolve to Error("stream is locked").
fn locked_backend() -> Backend {
  Backend(
    name: "locked-fake",
    available: fn() { True },
    open: fn(_baud) { promise.resolve(Ok(new_locked_conn())) },
    open_existing: fn(_baud) { promise.resolve(Error("n/a")) },
    write: locked_write,
    start_reading: fn(_c, _on_line, _on_err) { Nil },
    close: fn(_c) { promise.resolve(Nil) },
  )
}

// ── the regression proof ──────────────────────────────────────────────────────

/// Driving a 3-line jog burst through `perform_writes` against the lock-enforcing
/// fake must NOT trigger a lock error and must write all three lines in order.
/// (With concurrent writes this fails: only the first lands, the others error.)
pub fn jog_burst_serializes_without_lock_error_test() -> Promise(Nil) {
  let conn = new_locked_conn()
  let b = locked_backend()
  let burst = ["N2 G91*19", "N3 G0 X1*99", "N4 G90*20"]

  controller.perform_writes(b, conn, burst)
  |> promise.map(fn(result) {
    // The whole burst succeeds...
    result |> should.equal(Ok(Nil))
    // ...with no single-writer-lock collision...
    had_lock_error(conn) |> should.equal(False)
    // ...and all three lines actually written.
    written_count(conn) |> should.equal(3)
    Nil
  })
}

/// A write failure mid-burst must surface as an Error (so the controller can
/// fault), not be silently swallowed.
pub fn burst_propagates_write_error_test() -> Promise(Nil) {
  let conn = new_locked_conn()
  let b =
    Backend(..locked_backend(), write: fn(_c, _line) {
      promise.resolve(Error("port not writable"))
    })

  controller.perform_writes(b, conn, ["N1 M17*20"])
  |> promise.map(fn(result) {
    case result {
      Error(_) -> Nil
      Ok(_) -> should.fail()
    }
  })
}
