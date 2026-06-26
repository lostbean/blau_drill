//// BoardModel tests, ported from `test/blau_drill/board_model_test.exs`. The
//// segby_v1 fixture is embedded as a string constant (the JS target can't read
//// files at runtime). Ground-truth values (tool table, hole counts, bbox,
//// outline corners) are taken verbatim from the Elixir test.

import blau_drill/domain/board_model.{
  type BoardModel, type Hole, AbsolutePageCoordinates, Hole, Inputs,
}
import blau_drill/fixtures
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// --- tool table -------------------------------------------------------------

pub fn parses_all_five_tools_test() {
  let assert Ok(board) = board_model.parse_drl(segby_drl())
  board.tools
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> should.equal([
    #("T1", 0.6),
    #("T2", 0.7),
    #("T3", 0.8),
    #("T4", 1.0),
    #("T5", 1.2),
  ])
}

// --- holes ------------------------------------------------------------------

pub fn parses_total_hole_count_test() {
  let assert Ok(board) = board_model.parse_drl(segby_drl())
  list.length(board.holes) |> should.equal(130)
}

pub fn per_tool_hole_counts_test() {
  let assert Ok(board) = board_model.parse_drl(segby_drl())
  count_tool(board.holes, "T1") |> should.equal(40)
  count_tool(board.holes, "T2") |> should.equal(4)
  count_tool(board.holes, "T3") |> should.equal(38)
  count_tool(board.holes, "T4") |> should.equal(42)
  count_tool(board.holes, "T5") |> should.equal(6)
}

pub fn first_t1_hole_test() {
  let assert Ok(board) = board_model.parse_drl(segby_drl())
  let assert [first, ..] = board.holes
  // The first parsed hole carries file-order id 0 (ADR-0016).
  first |> should.equal(Hole(id: 0, x: -57.15, y: 80.01, tool: "T1"))
}

pub fn integer_form_coordinate_test() {
  // X0.0Y49.53 on T4 — the "0.0" integer-ish form must parse to a float.
  let assert Ok(board) = board_model.parse_drl(segby_drl())
  list.any(board.holes, fn(h) { h.x == 0.0 && h.y == 49.53 && h.tool == "T4" })
  |> should.be_true
}

// ADR-0016: holes carry a stable file-parse-order id, assigned 0..n-1 over the
// holes in the order they appear in the .drl. Tool grouping happens later
// (in gcode_program); the id is fixed at parse time.
pub fn hole_ids_are_file_order_test() {
  let assert Ok(board) = board_model.parse_drl(segby_drl())
  // The ids, read in file order, are exactly 0, 1, 2, ..., n-1.
  let ids = list.map(board.holes, fn(h) { h.id })
  let expected = list.index_map(board.holes, fn(_, i) { i })
  ids |> should.equal(expected)
  // First hole is id 0; last is n-1.
  let assert Ok(first) = list.first(board.holes)
  first.id |> should.equal(0)
  let assert Ok(last) = list.last(board.holes)
  last.id |> should.equal(list.length(board.holes) - 1)
}

pub fn preserves_negative_x_test() {
  // Mirroring is Transform2D's job, never the parser's.
  let assert Ok(board) = board_model.parse_drl(segby_drl())
  list.any(board.holes, fn(h) { h.x == -57.15 }) |> should.be_true
  list.any(board.holes, fn(h) { h.x == 57.15 }) |> should.be_false
}

// --- bbox -------------------------------------------------------------------

pub fn bbox_over_all_holes_test() {
  let assert Ok(board) = board_model.parse_drl(segby_drl())
  board.bbox |> should.equal(#(-81.28, -3.81, 0.0, 80.01))
}

// --- absolute-page trap -----------------------------------------------------

pub fn rejects_large_absolute_page_coords_test() {
  let body = "X135.0Y-149.0\nX140.0Y-152.0"
  let is_page_err = case board_model.parse_drl(synthetic_drl(body)) {
    Error(AbsolutePageCoordinates(_)) -> True
    _ -> False
  }
  is_page_err |> should.be_true
}

pub fn does_not_reject_segby_test() {
  let assert Ok(_) = board_model.parse_drl(segby_drl())
  Nil
}

pub fn accepts_near_origin_one_negative_axis_test() {
  let body = "X-80.0Y80.0\nX0.0Y-3.0"
  let assert Ok(_) = board_model.parse_drl(synthetic_drl(body))
  Nil
}

// --- malformed input --------------------------------------------------------

pub fn missing_m48_is_error_test() {
  // Drop the M48 header line.
  let no_header = drop_first_line(segby_drl())
  should.be_true(is_error(board_model.parse_drl(no_header)))
}

pub fn garbage_input_is_error_test() {
  should.be_true(is_error(board_model.parse_drl("this is not a drill file")))
}

pub fn empty_input_is_error_test() {
  should.be_true(is_error(board_model.parse_drl("")))
}

pub fn hole_with_undefined_tool_is_error_test() {
  let no_select = "M48\nMETRIC\nT1C0.600\n%\nG90\nG05\nX1.0Y1.0\nM30\n"
  should.be_true(is_error(board_model.parse_drl(no_select)))
}

// --- outline (Edge.Cuts) ----------------------------------------------------

pub fn parses_outline_polyline_test() {
  let assert Ok(board) =
    board_model.parse(Inputs(
      drl: Some(segby_drl()),
      edge_cuts: Some(segby_svg()),
    ))
  let assert Some(outline) = board.outline
  list.contains(outline, #(0.0, 0.0)) |> should.be_true
  list.contains(outline, #(89.5799, 0.0)) |> should.be_true
  list.contains(outline, #(89.5799, 89.7874)) |> should.be_true
  list.contains(outline, #(0.0, 89.7874)) |> should.be_true
}

pub fn outline_nil_without_edge_cuts_test() {
  let assert Ok(board) = board_model.parse_drl(segby_drl())
  board.outline |> should.equal(None)
}

// --- fiducials --------------------------------------------------------------

pub fn fiducials_always_empty_test() {
  let assert Ok(board) = board_model.parse_drl(segby_drl())
  board.fiducials |> should.equal([])
  list.length(board.holes) |> should.equal(130)
}

// --- parse_drl convenience --------------------------------------------------

pub fn parse_drl_equivalent_to_parse_test() {
  board_model.parse_drl(segby_drl())
  |> should.equal(
    board_model.parse(Inputs(drl: Some(segby_drl()), edge_cuts: None)),
  )
}

// --- helpers ----------------------------------------------------------------

fn count_tool(holes: List(Hole), tool: String) -> Int {
  holes
  |> list.filter(fn(h) { h.tool == tool })
  |> list.length
}

fn is_error(r: Result(BoardModel, a)) -> Bool {
  case r {
    Error(_) -> True
    Ok(_) -> False
  }
}

fn drop_first_line(s: String) -> String {
  case string_split_once(s, "\n") {
    Ok(#(_, rest)) -> rest
    Error(_) -> s
  }
}

// A minimal well-formed header with the given body, mirroring the Elixir
// `drl/1` helper in the test.
fn synthetic_drl(body: String) -> String {
  "M48\nMETRIC\nT1C0.600\n%\nG90\nG05\nT1\n" <> body <> "\nM30\n"
}

fn string_split_once(s: String, on: String) -> Result(#(String, String), Nil) {
  string.split_once(s, on)
}

// --- embedded fixtures ------------------------------------------------------

fn segby_drl() -> String {
  fixtures.segby_drl()
}

fn segby_svg() -> String {
  "<svg>
<path style=\"fill:none;
stroke:#000000; stroke-width:0.0500; stroke-opacity:1;
stroke-linecap:round; stroke-linejoin:round;fill:none\"
d=\"M 0.0000,0.0000
89.5799,0.0000
89.5799,89.7874
0.0000,89.7874
Z\" />
</svg>"
}
