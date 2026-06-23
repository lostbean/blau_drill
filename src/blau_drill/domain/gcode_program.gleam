//// The generated Marlin G-code for **one mode** (`DryRun | Drill`) — the
//// safety-critical heart of blau-drill.
////
//// `build/3` takes a `BoardModel`, a **solved** `Alignment`, and a config, and
//// emits the full program as a list of lines. Dry-run and real are the *same*
//// generator with one parameter flipped.
////
//// ## The two safety invariants, enforced structurally
////
//// 1. **Never traverse XY without Z safe.** Every hole is drilled through the
////    `safe_move` combinator, which *always* emits a retract to `zsafe` before
////    the next `G0 X.. Y..` rapid.
//// 2. **Spindle running before any plunge (drill mode).** A tool block emits
////    its holes only after the spindle-on step; in `DryRun` the plunge depth is
////    the positive hover, so a negative Z is unrepresentable in that mode.

import blau_drill/domain/alignment.{type Alignment}
import blau_drill/domain/board_model.{type BoardModel, type ToolId}
import blau_drill/domain/config.{type GcodeConfig, Drill, DryRun}
import blau_drill/domain/transform2d
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/string

/// Axis-aligned bounding box of the drilled holes in machine space.
pub type BboxMachine =
  #(Float, Float, Float, Float)

/// A drilled hole already projected into machine space.
type MachineHole {
  MachineHole(tool: ToolId, x: Float, y: Float)
}

/// The generated program value.
pub type GcodeProgram {
  GcodeProgram(
    lines: List(String),
    mode: config.Mode,
    bbox_machine: BboxMachine,
    tool_order: List(ToolId),
  )
}

/// Build the G-code program for `board` under `alignment`, with `cfg`.
///
/// Requires an `Alignment` (the solved transform). A hole lives only in board
/// space; its machine coordinate is the derived view
/// `transform2d.apply(alignment.transform, hole)`, computed here on demand.
pub fn build(
  board: BoardModel,
  alignment: Alignment,
  cfg: GcodeConfig,
) -> GcodeProgram {
  let transform = alignment.transform
  let order = tool_order(board)

  let machine_holes =
    list.map(board.holes, fn(hole) {
      let #(mx, my) = transform2d.apply(transform, #(hole.x, hole.y))
      MachineHole(tool: hole.tool, x: mx, y: my)
    })

  let by_tool = group_by_tool(machine_holes)

  // The bit-exchange position: the whole-board centroid (center of mass of all
  // machine-space holes). Computed ONCE — the same exchange spot for every tool
  // block — so every bit swap happens at a consistent, board-centered location.
  let centroid = centroid_machine(machine_holes)

  let body =
    list.flat_map(order, fn(tool) {
      let holes = case dict.get(by_tool, tool) {
        Ok(hs) -> hs
        Error(_) -> []
      }
      tool_block(tool, holes, board.tools, cfg, centroid)
    })

  let lines =
    list.flatten([
      header(board, order, cfg),
      preamble(),
      body,
      postamble(cfg),
    ])

  GcodeProgram(
    lines: lines,
    mode: cfg.mode,
    bbox_machine: bbox_machine(machine_holes),
    tool_order: order,
  )
}

// ---------------------------------------------------------------------------
// Streamable view — the form actually fed over the ok/resend handshake.
//
// `build` emits a HUMAN-READABLE program: blank grouping lines `""` and
// full-line `( ... )` comments. Real Marlin does NOT reliably emit an `ok` for
// a blank line, so streaming `program.lines` VERBATIM stalls the handshake on
// the first blank line (it hangs on hardware; the simulator masks it by acking
// everything). `stream_lines` returns the same lines with the non-command noise
// (blank/whitespace-only lines and FULL-LINE comments) dropped, in original
// order. `program.lines` itself is left untouched — the rich form is correct for
// human-readable export/preview.
// ---------------------------------------------------------------------------

/// The lines to actually stream: `program.lines` minus blank lines and
/// full-line comments. Order preserved; only `list.filter`, never reorder.
pub fn stream_lines(program: GcodeProgram) -> List(String) {
  list.filter(program.lines, is_streamable)
}

/// A line is streamable iff, after trimming, it is non-empty AND does not begin
/// with a comment marker (`(` RepRap-style or `;`). Commands with a TRAILING
/// inline comment (e.g. `"M0      (Temporary machine stop.)"`) start with a
/// command token, so they pass — only FULL-LINE comments and blanks are dropped.
pub fn is_streamable(line: String) -> Bool {
  let trimmed = string.trim(line)
  trimmed != ""
  && !string.starts_with(trimmed, "(")
  && !string.starts_with(trimmed, ";")
}

// ---------------------------------------------------------------------------
// Tool ordering — file order of first appearance.
// ---------------------------------------------------------------------------

fn tool_order(board: BoardModel) -> List(ToolId) {
  board.holes
  |> list.map(fn(h) { h.tool })
  |> list.unique
}

// Group machine holes by tool, preserving per-tool file order: each tool's hole
// list keeps the order the holes appeared in the input.
fn group_by_tool(holes: List(MachineHole)) -> Dict(ToolId, List(MachineHole)) {
  holes
  |> list.fold(dict.new(), fn(acc, h) {
    let existing = case dict.get(acc, h.tool) {
      Ok(hs) -> hs
      Error(_) -> []
    }
    dict.insert(acc, h.tool, [h, ..existing])
  })
  |> dict.map_values(fn(_, hs) { list.reverse(hs) })
}

// ---------------------------------------------------------------------------
// Header (honest banner — intentionally NOT the pcb2gcode vanity banner).
// ---------------------------------------------------------------------------

fn header(
  board: BoardModel,
  order: List(ToolId),
  cfg: GcodeConfig,
) -> List(String) {
  let sizes =
    order
    |> list.map(fn(tool) {
      "[" <> fmt_diameter(tool_diameter(board.tools, tool)) <> "mm]"
    })
    |> string.join(" ")

  [
    "( blau-drill native G-code )",
    "( mode: " <> mode_string(cfg.mode) <> " )",
    "",
    "( This file uses "
      <> int.to_string(list.length(order))
      <> " drill bit sizes. )",
    "( Bit sizes: " <> sizes <> " )",
    "",
  ]
}

fn mode_string(mode: config.Mode) -> String {
  case mode {
    DryRun -> "dry_run"
    Drill -> "drill"
  }
}

// ---------------------------------------------------------------------------
// Preamble — the touch-off block + unit/mode setup.
// ---------------------------------------------------------------------------

fn preamble() -> List(String) {
  [
    "(MSG, Position drill on the fiducial and touch off.)",
    "M0      (Jog to fiducial, lower bit until it touches, then resume.)",
    "G04 P0 ( dwell for no time -- G64 should not smooth over this point )",
    "G92 X0 Y0 Z0",
    "",
    "G94       (Millimeters per minute feed rate.)",
    "G21       (Units == Millimeters.)",
    "G91.1     (Incremental arc distance mode.)",
    "G90       (Absolute coordinates.)",
    "",
  ]
}

// ---------------------------------------------------------------------------
// Per-tool block.
//
// STRUCTURAL invariant 2: the block's holes are emitted only AFTER the
// spindle-on step, so in Drill mode no plunge can precede the M3 S255.
// ---------------------------------------------------------------------------

fn tool_block(
  tool: ToolId,
  holes: List(MachineHole),
  tools: board_model.ToolTable,
  cfg: GcodeConfig,
  centroid: #(Float, Float),
) -> List(String) {
  let diameter = fmt_diameter(tool_diameter(tools, tool))
  let #(cx, cy) = centroid

  let change =
    list.flatten([
      [
        "G00 Z" <> fmt5(cfg.zchange) <> " (Retract)",
        // Move XY to the board centroid at the retracted (zchange) height, so
        // the operator swaps the bit at a consistent, board-centered spot.
        // Emitted AFTER the Z retract, so it travels at the safe retract height.
        "G0 X"
          <> fmt5(cx)
          <> " Y"
          <> fmt5(cy)
          <> " (Move to bit-exchange position — board centre)",
        tool,
        "M5      (Spindle stop.)",
        "G04 P1.00000",
        "(MSG, Change tool bit to drill size " <> diameter <> "mm)",
        "M6      (Tool change.)",
        "M0      (Temporary machine stop.)",
      ],
      spindle_on_step(cfg),
      [
        "G0 Z" <> fmt5(cfg.zsafe),
        "G04 P1.00000",
        "",
        "G1 F" <> fmt5(cfg.drill_feed),
      ],
    ])

  list.append(change, list.flat_map(holes, fn(h) { drill_hole(h, cfg) }))
}

// The spindle arm/disarm step. In Drill, emit M3 S<speed> ON THE SAME LINE
// (Marlin quirk). In DryRun, leave it OFF and say so.
fn spindle_on_step(cfg: GcodeConfig) -> List(String) {
  case cfg.mode {
    Drill -> [
      "M3 S"
      <> int.to_string(cfg.spindle_speed)
      <> "      (Spindle on clockwise at full PWM.)",
    ]
    DryRun -> ["( dry run: spindle left OFF )"]
  }
}

// ---------------------------------------------------------------------------
// Per-hole emission — the `safe_move` combinator.
//
// STRUCTURAL invariant 1: every hole is `G0 X.. Y..` at the current safe Z,
// then plunge, then ALWAYS retract to zsafe.
// ---------------------------------------------------------------------------

fn drill_hole(hole: MachineHole, cfg: GcodeConfig) -> List(String) {
  safe_move(cfg, hole.x, hole.y, fn() { [plunge_line(cfg)] })
}

// Travel to (x, y) at a safe Z, run `body` (the plunge), then retract to zsafe.
fn safe_move(
  cfg: GcodeConfig,
  x: Float,
  y: Float,
  body: fn() -> List(String),
) -> List(String) {
  list.flatten([[fmt_xy_rapid(x, y)], body(), [retract(cfg)]])
}

fn retract(cfg: GcodeConfig) -> String {
  fmt_g1_z(cfg.zsafe)
}

// The plunge line. In Drill -> `G1 Z-2.50000`. In DryRun -> the positive hover
// with the annotation, so a negative Z is unrepresentable in dry-run.
fn plunge_line(cfg: GcodeConfig) -> String {
  case cfg.mode {
    Drill -> fmt_g1_z(cfg.zdrill)
    DryRun ->
      "G1 Z"
      <> fmt5(cfg.hover)
      <> "  ( dry-run hover, was Z"
      <> fmt5(cfg.zdrill)
      <> " )"
  }
}

// ---------------------------------------------------------------------------
// Postamble — final retract, home, spindle off, program end.
// ---------------------------------------------------------------------------

fn postamble(cfg: GcodeConfig) -> List(String) {
  [
    "G00 Z" <> fmt3(cfg.zchange) <> " ( All done -- retract )",
    "G04 P0 ( dwell for no time -- G64 should not smooth over this point )",
    "G00 X0.0 Y0.0 Z0.0  ( move back to home )",
    "",
    "",
    "M5      (Spindle off.)",
    "G04 P1.000000",
    "M9      (Coolant off.)",
    "M2      (Program end.)",
    "",
  ]
}

// ---------------------------------------------------------------------------
// Bounding box (machine space)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Centroid (center of mass, machine space)
//
// The MEAN of all machine hole X's and Y's — every hole counts, so dense
// regions pull the centroid (this is NOT the bbox center). Used as the
// bit-exchange position. Empty list -> #(0.0, 0.0).
// ---------------------------------------------------------------------------

fn centroid_machine(holes: List(MachineHole)) -> #(Float, Float) {
  case holes {
    [] -> #(0.0, 0.0)
    _ -> {
      let #(sum_x, sum_y, n) =
        list.fold(holes, #(0.0, 0.0, 0), fn(acc, h) {
          let #(sum_x, sum_y, n) = acc
          #(sum_x +. h.x, sum_y +. h.y, n + 1)
        })
      let count = int.to_float(n)
      #(sum_x /. count, sum_y /. count)
    }
  }
}

// A thin public wrapper so `centroid_machine` is unit-testable without exposing
// the private `MachineHole` type: takes raw machine-space #(x, y) points.
pub fn centroid_of_points(points: List(#(Float, Float))) -> #(Float, Float) {
  centroid_machine(
    list.map(points, fn(p) { MachineHole(tool: "", x: p.0, y: p.1) }),
  )
}

fn bbox_machine(holes: List(MachineHole)) -> BboxMachine {
  case holes {
    [] -> #(0.0, 0.0, 0.0, 0.0)
    [first, ..rest] ->
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

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

// `%.5f` — coordinates and Z values: 57.15 -> "57.15000". The FFI rounds to 5
// decimals first then collapses -0.0 to +0.0, so board X=0 prints "X0.00000".
fn fmt5(v: Float) -> String {
  float_to_decimals(v, 5)
}

// `%.3f` — the postamble retract height: 30.0 -> "30.000".
fn fmt3(v: Float) -> String {
  float_to_decimals(v, 3)
}

fn fmt_xy_rapid(x: Float, y: Float) -> String {
  "G0 X" <> fmt5(x) <> " Y" <> fmt5(y)
}

fn fmt_g1_z(z: Float) -> String {
  "G1 Z" <> fmt5(z)
}

// Diameter formatting: 0.600 -> "0.6", 1.000 -> "1", 1.200 -> "1.2".
fn fmt_diameter(d: Float) -> String {
  float_to_diameter(d)
}

fn tool_diameter(tools: board_model.ToolTable, tool: ToolId) -> Float {
  // The tool is always present (it came from the same parse); fall back to 0.0.
  case dict.get(tools, tool) {
    Ok(d) -> d
    Error(_) -> 0.0
  }
}

// --- FFI: number formatting matching the Erlang output exactly --------------

@external(javascript, "./gcode_ffi.mjs", "fmtDecimals")
fn float_to_decimals(f: Float, decimals: Int) -> String

@external(javascript, "./gcode_ffi.mjs", "fmtDiameter")
fn float_to_diameter(f: Float) -> String
