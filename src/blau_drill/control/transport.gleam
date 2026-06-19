//// Concrete `Backend` records: the real Web Serial transport and the in-browser
//// simulator. Each wires its `.mjs` externals into the common `backend.Backend`
//// shape so the controller is transport-agnostic.

import blau_drill/control/backend.{type Backend, type Conn, Backend}
import gleam/javascript/promise.{type Promise}

// ── real Web Serial ──────────────────────────────────────────────────────────

@external(javascript, "./serial_ffi.mjs", "hasSerial")
fn serial_has_serial() -> Bool

@external(javascript, "./serial_ffi.mjs", "requestAndOpen")
fn serial_open(baud: Int) -> Promise(Result(Conn, String))

@external(javascript, "./serial_ffi.mjs", "openExisting")
fn serial_open_existing(baud: Int) -> Promise(Result(Conn, String))

@external(javascript, "./serial_ffi.mjs", "write")
fn serial_write(conn: Conn, line: String) -> Promise(Result(Nil, String))

@external(javascript, "./serial_ffi.mjs", "startReading")
fn serial_start_reading(
  conn: Conn,
  on_line: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./serial_ffi.mjs", "close")
fn serial_close(conn: Conn) -> Promise(Nil)

/// The real Web Serial backend (Chromium-only; needs a user-gesture connect).
pub fn web_serial() -> Backend {
  Backend(
    name: "Web Serial",
    available: serial_has_serial,
    open: serial_open,
    open_existing: serial_open_existing,
    write: serial_write,
    start_reading: serial_start_reading,
    close: serial_close,
  )
}

// ── simulator ────────────────────────────────────────────────────────────────

@external(javascript, "./sim_ffi.mjs", "open")
fn sim_open(baud: Int) -> Promise(Result(Conn, String))

@external(javascript, "./sim_ffi.mjs", "openExisting")
fn sim_open_existing(baud: Int) -> Promise(Result(Conn, String))

@external(javascript, "./sim_ffi.mjs", "write")
fn sim_write(conn: Conn, line: String) -> Promise(Result(Nil, String))

@external(javascript, "./sim_ffi.mjs", "startReading")
fn sim_start_reading(
  conn: Conn,
  on_line: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./sim_ffi.mjs", "close")
fn sim_close(conn: Conn) -> Promise(Nil)

/// The simulator backend: connects instantly, always available, replies as a
/// Marlin would. Lets the whole flow run with no hardware.
pub fn simulator() -> Backend {
  Backend(
    name: "Simulator",
    available: fn() { True },
    open: sim_open,
    open_existing: sim_open_existing,
    write: sim_write,
    start_reading: sim_start_reading,
    close: sim_close,
  )
}
