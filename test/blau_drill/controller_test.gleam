//// Light unit tests for the controller shell's simple, pure-ish inspectors.
//// The async update / handshake loop is covered by `control_test.gleam` (it
//// drives the real simulator transport); here we only pin the construction and
//// inspection helpers that need no browser.

import blau_drill/control/controller
import blau_drill/control/printer
import blau_drill/control/transport
import gleam/list
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

// ── comms log: the controller surfaces every TX / RX / note in `out.log` ──────

// A written line is logged as TX. Connecting (Issue(Connect)) emits the raw
// `M110 N0` line-counter reset — assert it shows up as a LogTx.
pub fn update_logs_tx_writes_test() {
  let c = controller.new(transport.simulator())
  let out = controller.update(c, controller.Issue(printer.Connect))
  list.contains(out.log, controller.LogTx("M110 N0")) |> should.be_true
}

// An inbound line is logged as RX (whether or not it drives any writes).
pub fn update_logs_rx_inbound_test() {
  let c = controller.new(transport.simulator())
  let out = controller.update(c, controller.Inbound("ok"))
  list.contains(out.log, controller.LogRx("ok")) |> should.be_true
}

// A serial loss is logged as a Note (not as wire traffic).
pub fn update_logs_note_on_loss_test() {
  let c = controller.new(transport.simulator())
  let out = controller.update(c, controller.Lost("device gone"))
  list.any(out.log, fn(l) {
    case l {
      controller.LogNote(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}
