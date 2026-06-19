//// Light unit tests for the controller shell's simple, pure-ish inspectors.
//// The async update / handshake loop is covered by `control_test.gleam` (it
//// drives the real simulator transport); here we only pin the construction and
//// inspection helpers that need no browser.

import blau_drill/control/controller
import blau_drill/control/printer
import blau_drill/control/transport
import gleeunit/should

// ── new ──────────────────────────────────────────────────────────────────────

pub fn new_is_not_connected_test() {
  // A fresh controller holds no live connection.
  controller.new(transport.simulator())
  |> controller.is_connected
  |> should.be_false
}

pub fn new_state_is_disconnected_test() {
  // The pure machine starts Disconnected (printer.new()).
  controller.new(transport.simulator())
  |> controller.state
  |> should.equal(printer.Disconnected)
}

// ── set_backend ──────────────────────────────────────────────────────────────

pub fn set_backend_keeps_disconnected_state_test() {
  // Swapping the backend on a fresh controller leaves the connection + pure
  // state untouched (only the transport changes).
  let c =
    controller.new(transport.simulator())
    |> controller.set_backend(transport.web_serial())
  controller.is_connected(c) |> should.be_false
  controller.state(c) |> should.equal(printer.Disconnected)
}

pub fn set_backend_then_sim_again_state_test() {
  let c =
    controller.new(transport.web_serial())
    |> controller.set_backend(transport.simulator())
  controller.is_connected(c) |> should.be_false
  controller.state(c) |> should.equal(printer.Disconnected)
}
