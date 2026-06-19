//// Pure Marlin wire-protocol helpers, ported 1:1 from the Elixir
//// `BlauDrill.PrinterConnection` (`framed/2`, `checksum/1`, `format_mm/1`,
//// `parse_m114/1`) by way of the Phase-0 spike. These are pure functions with
//// no IO so they are exercised directly by `protocol_test.gleam`.
////
//// The framing rules mirror the reference exactly:
////   * `M112` and `M114` are out-of-band — sent raw, no line number / checksum.
////   * every other line is framed `N<n> <line>*<checksum>` where the checksum
////     is the XOR of every byte of the string `N<n> <line>`.

import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/regexp
import gleam/result
import gleam/string

/// A position parsed from an `M114` reply.
pub type Position {
  Position(x: Float, y: Float, z: Float)
}

/// Marlin XOR checksum over the `N<n> <line>` body string. This is the
/// bitwise-XOR fold of every UTF-8 byte, matching the Elixir
/// `:binary.bin_to_list/1 |> Enum.reduce(0, &Bitwise.bxor/2)`.
pub fn checksum(body: String) -> Int {
  body
  |> string_to_bytes
  |> list.fold(0, fn(acc, byte) { int.bitwise_exclusive_or(acc, byte) })
}

/// Out-of-band commands bypass line numbering (sent raw): `M112`, `M114`.
pub fn is_oob(raw: String) -> Bool {
  string.starts_with(raw, "M112") || string.starts_with(raw, "M114")
}

/// Frame a raw line for the given line counter. Returns `#(payload, next_line_no)`.
///
/// For OOB commands the payload is the raw line and the counter is unchanged.
/// Otherwise the payload is `N<n> <line>*<checksum>` and the counter advances.
pub fn frame(raw: String, line_no: Int) -> #(String, Int) {
  case is_oob(raw) {
    True -> #(raw, line_no)
    False -> {
      let n = line_no + 1
      let body = "N" <> int.to_string(n) <> " " <> raw
      let payload = body <> "*" <> int.to_string(checksum(body))
      #(payload, n)
    }
  }
}

/// Format millimetres the way the Elixir code does: floats to 3 decimals,
/// integers plain. Gleam has no untyped number, so the caller passes a Float;
/// a whole-number float is rendered without a decimal part to match the
/// integer branch of `format_mm/1`.
pub fn format_mm(mm: Float) -> String {
  case is_whole(mm) {
    True -> int.to_string(float.round(mm))
    False -> float_to_decimals(mm, 3)
  }
}

/// Parse `X:.. Y:.. Z:..` floats out of an M114 reply line. Returns `Error(Nil)`
/// for a non-position line (e.g. a bare `ok`), mirroring `:no_match`.
pub fn parse_m114(line: String) -> Result(Position, Nil) {
  use x <- result.try(parse_axis(line, "X"))
  use y <- result.try(parse_axis(line, "Y"))
  use z <- result.try(parse_axis(line, "Z"))
  Ok(Position(x, y, z))
}

fn parse_axis(line: String, axis: String) -> Result(Float, Nil) {
  let assert Ok(re) = regexp.from_string(axis <> ":(-?\\d+(?:\\.\\d+)?)")
  case regexp.scan(re, line) {
    [match, ..] ->
      case match.submatches {
        [option_val, ..] ->
          case option_val {
            option.Some(v) -> parse_float_loose(v)
            option.None -> Error(Nil)
          }
        [] -> Error(Nil)
      }
    [] -> Error(Nil)
  }
}

/// Parse a float that may be written as an integer (`"10"`), like Elixir's
/// `Float.parse/1` does not but the M114 regex permits.
fn parse_float_loose(s: String) -> Result(Float, Nil) {
  case float.parse(s) {
    Ok(f) -> Ok(f)
    Error(_) ->
      case int.parse(s) {
        Ok(i) -> Ok(int.to_float(i))
        Error(_) -> Error(Nil)
      }
  }
}

// ── helpers ──────────────────────────────────────────────────────────────────

@external(javascript, "./protocol_ffi.mjs", "stringToBytes")
fn string_to_bytes(s: String) -> List(Int)

@external(javascript, "./protocol_ffi.mjs", "floatToDecimals")
fn float_to_decimals(f: Float, decimals: Int) -> String

fn is_whole(f: Float) -> Bool {
  float.round(f) |> int.to_float == f
}
