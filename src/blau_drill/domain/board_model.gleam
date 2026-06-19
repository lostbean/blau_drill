//// The immutable parse of the KiCad outputs — `holes`, `outline`, `fiducials`,
//// `tools`, and a bounding box — entirely in **board coordinates**. Ported 1:1
//// from `BlauDrill.BoardModel`.
////
//// `parse/1` takes the raw KiCad exports (`drl` required, `edge_cuts`
//// optional). It deliberately holds **no machine coordinates**: the back-side
//// X-mirror is NOT applied here — negative X values are preserved verbatim.
////
//// The Excellon `.drl` parser targets KiCad's metric/decimal/absolute export:
//// `M48` opens the header (required), `; ...` comments are ignored, `TnC<dia>`
//// defines a tool, `%` ends the header, a bare `Tn` selects the active tool,
//// `X<dec>Y<dec>` lines are holes, `M30` ends the program. Tool ids stay as
//// strings ("T1").
////
//// The absolute-page-coordinate trap rejects broken exports (origin never set)
//// via two checks: any single coordinate beyond 250 mm, or the bbox corner
//// nearest the origin farther than 100 mm out.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/regexp.{type Regexp}
import gleam/result
import gleam/string

/// A tool identifier as it appears in the drill file, e.g. `"T1"`.
pub type ToolId =
  String

/// The mapping of tool id to bit diameter in millimetres.
pub type ToolTable =
  Dict(ToolId, Float)

/// A single drill location in board space.
pub type Hole {
  Hole(x: Float, y: Float, tool: ToolId)
}

/// The kind of a registration-candidate reference mark.
pub type FiducialKind {
  Cross
  HoleKind
}

/// A registration-candidate reference mark, in board coordinates.
pub type Fiducial {
  Fiducial(x: Float, y: Float, kind: FiducialKind)
}

/// The board outline as a closed polyline of `#(x, y)` points.
pub type Outline =
  List(#(Float, Float))

/// Axis-aligned bounding box over the holes: `#(min_x, min_y, max_x, max_y)`.
pub type Bbox =
  #(Float, Float, Float, Float)

/// The parsed board model. `outline` is `None` when no Edge.Cuts SVG is
/// supplied. `fiducials` is always `[]` by design.
pub type BoardModel {
  BoardModel(
    holes: List(Hole),
    outline: option.Option(Outline),
    fiducials: List(Fiducial),
    tools: ToolTable,
    bbox: Bbox,
  )
}

/// The raw KiCad export inputs. Only `drl` is required.
pub type Inputs {
  Inputs(drl: option.Option(String), edge_cuts: option.Option(String))
}

/// A parse failure. Mirrors the Elixir error atoms / tagged tuples.
pub type ParseError {
  MissingDrl
  MissingM48Header
  NoHoles
  HoleWithNoTool(line: String)
  AbsolutePageCoordinates(details: PageErrorDetails)
}

/// Detail about why an export was rejected as absolute-page coordinates.
pub type PageErrorDetails {
  /// A single coordinate exceeded the plausible bed size (250 mm).
  CoordinateOverBedSize(threshold_mm: Float, sample: List(Hole))
  /// The bbox corner nearest the origin is too far out (> 100 mm).
  BboxFarFromOrigin(threshold_mm: Float, origin_offset_mm: Float, bbox: Bbox)
}

// Any hole coordinate beyond this (mm, absolute value) means the export is in
// absolute page coordinates, not board coordinates centred near the origin.
const max_plausible_coord_mm = 250.0

// If the bbox corner nearest the origin is farther than this (mm), the whole
// hole cloud has been pushed off into a far quadrant.
const max_origin_offset_mm = 100.0

/// Parse the KiCad outputs into a `BoardModel`.
///
/// Only `drl` is required. Returns `Ok(BoardModel)` or `Error(ParseError)`.
pub fn parse(inputs: Inputs) -> Result(BoardModel, ParseError) {
  case inputs.drl {
    None -> Error(MissingDrl)
    Some(drl) -> {
      use #(tools, holes) <- result.try(parse_drl_body(drl))
      use _ <- result.try(check_page_coordinates(holes))
      let outline = parse_outline(inputs.edge_cuts)
      Ok(BoardModel(
        holes: holes,
        outline: outline,
        fiducials: [],
        tools: tools,
        bbox: bbox(holes),
      ))
    }
  }
}

/// Convenience for the common `.drl`-only case. Equivalent to
/// `parse(Inputs(Some(drl), None))`.
pub fn parse_drl(drl: String) -> Result(BoardModel, ParseError) {
  parse(Inputs(drl: Some(drl), edge_cuts: None))
}

// --- Excellon .drl parsing --------------------------------------------------

type ScanState {
  ScanState(tools: ToolTable, holes: List(Hole), active: option.Option(ToolId))
}

fn parse_drl_body(drl: String) -> Result(#(ToolTable, List(Hole)), ParseError) {
  let lines =
    drl
    |> split_lines
    |> list.map(string.trim)

  case list.contains(lines, "M48") {
    False -> Error(MissingM48Header)
    True -> scan(lines, ScanState(tools: dict.new(), holes: [], active: None))
  }
}

// Split on \r?\n, mirroring `String.split(~r/\r?\n/)`.
fn split_lines(s: String) -> List(String) {
  s
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  |> string.split("\n")
}

fn scan(
  lines: List(String),
  state: ScanState,
) -> Result(#(ToolTable, List(Hole)), ParseError) {
  case lines {
    [] ->
      case state.holes {
        [] -> Error(NoHoles)
        _ -> Ok(#(state.tools, list.reverse(state.holes)))
      }
    [line, ..rest] -> {
      case is_comment(line) || line == "" {
        True -> scan(rest, state)
        False ->
          case tool_def(line) {
            Ok(#(tool, diameter)) ->
              scan(
                rest,
                ScanState(
                  ..state,
                  tools: dict.insert(state.tools, tool, diameter),
                ),
              )
            Error(_) ->
              case tool_select(line, state.tools) {
                Ok(tool) -> scan(rest, ScanState(..state, active: Some(tool)))
                Error(_) ->
                  case coordinate(line) {
                    Ok(#(x, y)) ->
                      case state.active {
                        None -> Error(HoleWithNoTool(line))
                        Some(tool) -> {
                          let hole = Hole(x: x, y: y, tool: tool)
                          scan(
                            rest,
                            ScanState(..state, holes: [hole, ..state.holes]),
                          )
                        }
                      }
                    // Header keywords, M30, and any other non-data directive
                    // are skipped.
                    Error(_) -> scan(rest, state)
                  }
              }
          }
      }
    }
  }
}

fn is_comment(line: String) -> Bool {
  string.starts_with(line, ";")
}

// `T1C0.600` -> #("T1", 0.6)
fn tool_def(line: String) -> Result(#(ToolId, Float), Nil) {
  let re = compile("^(T\\d+)C([0-9]+(?:\\.[0-9]+)?)$")
  case regexp.scan(re, line) {
    [match] ->
      case match.submatches {
        [Some(tool), Some(diameter)] ->
          case to_float(diameter) {
            Ok(d) -> Ok(#(tool, d))
            Error(_) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// A bare `T1` selects an already-defined tool.
fn tool_select(line: String, tools: ToolTable) -> Result(ToolId, Nil) {
  let re = compile("^(T\\d+)$")
  case regexp.scan(re, line) {
    [match] ->
      case match.submatches {
        [Some(tool)] ->
          case dict.has_key(tools, tool) {
            True -> Ok(tool)
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// `X-57.15Y80.01` -> #(-57.15, 80.01)
fn coordinate(line: String) -> Result(#(Float, Float), Nil) {
  let re = compile("^X(-?[0-9]+(?:\\.[0-9]+)?)Y(-?[0-9]+(?:\\.[0-9]+)?)$")
  case regexp.scan(re, line) {
    [match] ->
      case match.submatches {
        [Some(x), Some(y)] ->
          case to_float(x), to_float(y) {
            Ok(fx), Ok(fy) -> Ok(#(fx, fy))
            _, _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// Parse a decimal string (which may be integer-form like "0" or "80") to Float,
// matching the regex-constrained input. `float.parse` rejects bare integers, so
// fall back to int.parse.
fn to_float(str: String) -> Result(Float, Nil) {
  case float.parse(str) {
    Ok(f) -> Ok(f)
    Error(_) -> parse_int_as_float(str)
  }
}

fn parse_int_as_float(str: String) -> Result(Float, Nil) {
  case int.parse(str) {
    Ok(i) -> Ok(int.to_float(i))
    Error(_) -> Error(Nil)
  }
}

// --- The absolute-page-coordinate trap -------------------------------------

fn check_page_coordinates(holes: List(Hole)) -> Result(Nil, ParseError) {
  let #(min_x, min_y, max_x, max_y) = bbox(holes)

  let oversized =
    list.filter(holes, fn(h) {
      float.absolute_value(h.x) >. max_plausible_coord_mm
      || float.absolute_value(h.y) >. max_plausible_coord_mm
    })

  // Distance from the origin to the bbox edge along each axis.
  let off_x = float.max(min_x, 0.0) +. float.max(float.negate(max_x), 0.0)
  let off_y = float.max(min_y, 0.0) +. float.max(float.negate(max_y), 0.0)
  let origin_offset = float_sqrt(off_x *. off_x +. off_y *. off_y)

  case oversized != [], origin_offset >. max_origin_offset_mm {
    True, _ ->
      Error(
        AbsolutePageCoordinates(CoordinateOverBedSize(
          threshold_mm: max_plausible_coord_mm,
          sample: list.take(oversized, 3),
        )),
      )
    False, True ->
      Error(
        AbsolutePageCoordinates(
          BboxFarFromOrigin(
            threshold_mm: max_origin_offset_mm,
            origin_offset_mm: round_to(origin_offset, 3),
            bbox: #(min_x, min_y, max_x, max_y),
          ),
        ),
      )
    False, False -> Ok(Nil)
  }
}

// --- Bounding box -----------------------------------------------------------

// Holes are guaranteed non-empty here (NoHoles is rejected earlier). If called
// on an empty list, fall back to all-zero so the type stays total.
fn bbox(holes: List(Hole)) -> Bbox {
  case holes {
    [] -> #(0.0, 0.0, 0.0, 0.0)
    [first, ..rest] -> {
      list.fold(rest, #(first.x, first.y, first.x, first.y), fn(acc, h) {
        let #(min_x, min_y, max_x, max_y) = acc
        #(
          float.min(min_x, h.x),
          float.min(min_y, h.y),
          float.max(max_x, h.x),
          float.max(max_y, h.y),
        )
      })
    }
  }
}

// --- Edge.Cuts SVG outline --------------------------------------------------

fn parse_outline(svg: option.Option(String)) -> option.Option(Outline) {
  case svg {
    None -> None
    Some(s) ->
      case path_d(s) {
        Ok(d) ->
          case coordinate_pairs(d) {
            [] -> None
            points -> Some(points)
          }
        Error(_) -> None
      }
  }
}

// Extract the `d="..."` attribute of the first `<path ...>`. The Elixir uses
// `~r/<path[^>]*\bd="([^"]*)"/s`, but KiCad inserts newlines inside the
// `<path style="...">` tag and inside the d-attribute, so `[^>]*` with the `s`
// flag is needed. Gleam's regexp (JS RegExp) `.` excludes newlines unless the
// dotall flag is set; here we use explicit character classes so newlines are
// matched, mirroring the Elixir `/s` behaviour.
fn path_d(svg: String) -> Result(String, Nil) {
  // `[^>]` already matches newlines (it is a negated class, not `.`), so this
  // works across the multi-line opening tag.
  let re = compile("<path[^>]*\\bd=\"([^\"]*)\"")
  case regexp.scan(re, svg) {
    [match, ..] ->
      case match.submatches {
        [Some(d), ..] -> Ok(d)
        _ -> Error(Nil)
      }
    [] -> Error(Nil)
  }
}

// Pull every `x,y` numeric pair out of the path data, ignoring command letters.
fn coordinate_pairs(d: String) -> Outline {
  let re = compile("(-?[0-9]+(?:\\.[0-9]+)?)\\s*,\\s*(-?[0-9]+(?:\\.[0-9]+)?)")
  regexp.scan(re, d)
  |> list.filter_map(fn(match) {
    case match.submatches {
      [Some(x), Some(y)] ->
        case to_float(x), to_float(y) {
          Ok(fx), Ok(fy) -> Ok(#(fx, fy))
          _, _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

// --- helpers ---------------------------------------------------------------

fn compile(pattern: String) -> Regexp {
  let assert Ok(re) = regexp.from_string(pattern)
  re
}

fn float_sqrt(x: Float) -> Float {
  let assert Ok(r) = float.square_root(x)
  r
}

// Round to N decimals, half away from zero (matching Erlang Float.round/2).
// Used only for the diagnostic `origin_offset_mm` detail field.
fn round_to(v: Float, decimals: Int) -> Float {
  let factor = pow10(decimals)
  let sign = case v <. 0.0 {
    True -> -1.0
    False -> 1.0
  }
  sign *. int.to_float(float.round(float.absolute_value(v) *. factor)) /. factor
}

fn pow10(n: Int) -> Float {
  case n {
    0 -> 1.0
    _ -> 10.0 *. pow10(n - 1)
  }
}
