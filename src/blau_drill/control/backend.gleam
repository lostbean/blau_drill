//// The single serial-backend interface both the real Web Serial port and the
//// in-browser simulator implement. It is the transport seam the control state
//// machine writes through: a `Backend` is a record of effectful functions, so
//// the controller never branches on which transport it is talking to.
////
//// The contract: `open` connects, `write` sends ONE already-framed payload (the
//// caller appends `"\n"`), and inbound lines are pushed to a callback the app
//// installs once via `start_reading` — one decoded line at a time as a `String`.

import gleam/javascript/promise.{type Promise}

/// Opaque connection handle. Each backend's externals return their own JS
/// object behind this type; the caller only ever passes it back to the same
/// backend's functions.
pub type Conn

/// A serial backend. All motion-bearing IO goes through `write`; reading is
/// started once and delivers decoded lines line-by-line to `on_line`.
pub type Backend {
  Backend(
    /// Human label for the log / UI ("Web Serial" or "Simulator").
    name: String,
    /// True only if this transport is actually usable in this browser
    /// (real backend feature-detects `navigator.serial`).
    available: fn() -> Bool,
    /// Connect. For the real port this MUST be invoked from a user gesture
    /// (it calls `navigator.serial.requestPort()`); the sim connects instantly.
    /// Resolves `Error(reason)` on failure (cancelled picker, open error).
    open: fn(Int) -> Promise(Result(Conn, String)),
    /// Re-open a PREVIOUSLY-AUTHORIZED port with no picker / no user gesture
    /// (real backend uses `navigator.serial.getPorts()`). Resolves
    /// `Error("no granted port")` when none is available — used for
    /// auto-reconnect on load. The sim has no such concept and always errors.
    open_existing: fn(Int) -> Promise(Result(Conn, String)),
    /// Write one payload to the port (caller has already framed it). Resolves
    /// `Error` if the port is gone.
    write: fn(Conn, String) -> Promise(Result(Nil, String)),
    /// Start the inbound read loop, handing each decoded line to `on_line`.
    /// `on_error` fires once on a read error / disconnect (serial loss).
    start_reading: fn(Conn, fn(String) -> Nil, fn(String) -> Nil) -> Nil,
    /// Close the port (best effort).
    close: fn(Conn) -> Promise(Nil),
  )
}
