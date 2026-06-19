//// Protocol (framing / checksum / mm-format / M114 parse) tests, copied from
//// the Phase-0 spike. Ground-truth values were computed from the Elixir
//// `BlauDrill.PrinterConnection` helpers, so these double as a 1:1 wire-format
//// regression against the reference.

import blau_drill/control/protocol
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// ── checksum (XOR fold over `N<n> <line>`) ────────────────────────────────────

pub fn checksum_n1_m17_test() {
  protocol.checksum("N1 M17") |> should.equal(20)
}

pub fn checksum_n123_test() {
  protocol.checksum("N123 G1 X10") |> should.equal(81)
}

pub fn checksum_empty_test() {
  // XOR fold of nothing is 0.
  protocol.checksum("") |> should.equal(0)
}

// ── framing (N<n> <line>*<checksum>, OOB raw) ─────────────────────────────────

pub fn frame_m17_test() {
  protocol.frame("M17", 0) |> should.equal(#("N1 M17*20", 1))
}

pub fn frame_jog_sequence_test() {
  // A jog frames three lines with a monotonically increasing counter; each
  // matches the Elixir output exactly.
  let #(g91, n1) = protocol.frame("G91", 1)
  g91 |> should.equal("N2 G91*19")
  let #(g0, n2) = protocol.frame("G0 X1.000", n1)
  g0 |> should.equal("N3 G0 X1.000*125")
  let #(g90, _n3) = protocol.frame("G90", n2)
  g90 |> should.equal("N4 G90*20")
}

pub fn frame_absolute_move_test() {
  protocol.frame("G0 X12.500 Y-3.000", 4)
  |> should.equal(#("N5 G0 X12.500 Y-3.000*53", 5))
}

pub fn frame_oob_m112_raw_test() {
  // M112 is out-of-band: raw, no number, no checksum, counter unchanged.
  protocol.frame("M112", 7) |> should.equal(#("M112", 7))
}

pub fn frame_oob_m114_raw_test() {
  protocol.frame("M114", 7) |> should.equal(#("M114", 7))
}

pub fn is_oob_test() {
  protocol.is_oob("M112") |> should.equal(True)
  protocol.is_oob("M114") |> should.equal(True)
  protocol.is_oob("M17") |> should.equal(False)
  protocol.is_oob("G0 X1") |> should.equal(False)
}

// ── mm formatting (floats → 3 decimals; whole → plain) ────────────────────────

pub fn format_mm_whole_test() {
  protocol.format_mm(1.0) |> should.equal("1")
  protocol.format_mm(-3.0) |> should.equal("-3")
  protocol.format_mm(0.0) |> should.equal("0")
}

pub fn format_mm_fraction_test() {
  protocol.format_mm(1.5) |> should.equal("1.500")
  protocol.format_mm(12.5) |> should.equal("12.500")
  protocol.format_mm(-0.1) |> should.equal("-0.100")
}

// ── M114 parse ────────────────────────────────────────────────────────────────

pub fn parse_m114_position_test() {
  let line = "X:10.00 Y:5.00 Z:0.00 E:0.00 Count X:0 Y:0 Z:0"
  protocol.parse_m114(line)
  |> should.equal(Ok(protocol.Position(10.0, 5.0, 0.0)))
}

pub fn parse_m114_negative_test() {
  let line = "X:-3.50 Y:0.00 Z:1.25 E:0.00 Count X:0 Y:0 Z:0"
  protocol.parse_m114(line)
  |> should.equal(Ok(protocol.Position(-3.5, 0.0, 1.25)))
}

pub fn parse_m114_non_position_test() {
  // A bare `ok` is not a position line.
  protocol.parse_m114("ok") |> should.equal(Error(Nil))
}
