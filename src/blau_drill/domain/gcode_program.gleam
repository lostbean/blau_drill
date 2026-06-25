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
////    the next `G1 X.. Y.. F<xy_feed>` travel move (ADR-0015: controlled XY
////    travel — the speed is operator-tunable, the Z is still the safe height).
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

/// A drilled hole already projected into machine space, carrying the fitted
/// surface Z at its BOARD location. `surface_z` is `alignment.surface_z` of the
/// hole's board coords (the plane is board-frame) — every per-hole Z line is
/// computed relative to it, so a tilted board drills the right depth everywhere.
type MachineHole {
  MachineHole(tool: ToolId, x: Float, y: Float, surface_z: Float)
}

/// The in-band pause sentinel emitted (in place of `M0`) when `cfg.app_pause`
/// is on. It is NOT a real Marlin command, so the streaming FSM intercepts it,
/// pauses the stream, and never writes it to the port. It is deliberately a bare
/// token (no leading `(`/`;`, non-blank), so `stream_lines` KEEPS it through the
/// sanitize pass — the streamed program carries the pause marker, the FSM
/// consumes it. See `printer.feed_stream` and ADR-0009.
pub const app_pause_marker = "M0_APP_PAUSE"

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
      // The surface plane is BOARD-frame, so evaluate it at the hole's board
      // coords (NOT the machine projection). Every per-hole Z references this.
      let sz = alignment.surface_z(alignment.z_plane, hole.x, hole.y)
      MachineHole(tool: hole.tool, x: mx, y: my, surface_z: sz)
    })

  let by_tool = group_by_tool(machine_holes)

  // The bit-exchange position: the whole-board centroid (center of mass of all
  // machine-space holes). Computed ONCE — the same exchange spot for every tool
  // block — so every bit swap happens at a consistent, board-centered location.
  let centroid = centroid_machine(machine_holes)

  // The program-wide travel/safe Z. With a tilted surface plane each hole's
  // local "safe" is `surface_z + zsafe`; a SINGLE travel height that clears
  // EVERY hole — `max(surface_z) + zsafe` — keeps the XY-safe invariant trivial
  // (one constant Z, always above every hole's surface by at least zsafe), so an
  // XY rapid can never traverse where the bit could strike the board. Per-hole
  // plunge/retract still reference their OWN surface_z; only inter-hole travel
  // uses this shared ceiling.
  let safe_z = travel_safe_z(machine_holes, cfg)

  // Select the active per-mode feed profile (ADR-0015). Every controlled move
  // (XY travel, plunge, retract) formats with this profile's feed.
  let feeds = case cfg.mode {
    Drill -> cfg.drill_feeds
    DryRun -> cfg.dry_run_feeds
  }

  let body =
    list.flat_map(order, fn(tool) {
      let holes = case dict.get(by_tool, tool) {
        Ok(hs) -> hs
        Error(_) -> []
      }
      tool_block(tool, holes, board.tools, cfg, feeds, centroid, safe_z)
    })

  let lines =
    list.flatten([
      header(board, order, cfg),
      preamble(cfg),
      prepare(cfg, centroid, safe_z, feeds),
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
// Preamble — unit/mode setup ONLY.
//
// ADR-0010: the alignment affine owns XY and the fitted surface plane owns Z, so
// the plane IS the surface datum — there is no start-of-run touch-off and no
// `G92` origin reset. Per-hole Z is computed plane-relative in absolute machine
// coordinates. The first in-app pause is therefore the FIRST tool's bit change,
// emitted by the first tool block (not a touch-off here).
// ---------------------------------------------------------------------------

fn preamble(_cfg: GcodeConfig) -> List(String) {
  [
    "G04 P0 ( dwell for no time -- G64 should not smooth over this point )",
    "G94       (Millimeters per minute feed rate.)",
    "G21       (Units == Millimeters.)",
    "G91.1     (Incremental arc distance mode.)",
    "G90       (Absolute coordinates.)",
    "",
  ]
}

// ---------------------------------------------------------------------------
// Prepare pose (ADR-0014) — drill mode only.
//
// Entering Drill always follows a planner flush (the host's Quickstop: raw
// M410+M400). The drill program's opening lines then re-establish a KNOWN, SAFE
// initial condition before the first tool block: retract Z to the program-wide
// travel/safe height, then travel (AT that safe Z) to the board-centroid setup
// pose — the same well-defined spot used for bit changes. So drilling always
// starts from a settled, defined pose, never wherever the flushed dry-run left
// the head.
//
// XY-only-at-safe-Z invariant: the Z retract (a `G0 Z<safe>` upward move — going
// UP to safe is never a plunge hazard) comes BEFORE the controlled
// `G1 X.. Y.. F<xy_feed>` travel, so the XY traverse is at the safe ceiling.
//
// DRILL ONLY: the dry-run is entered from Aligning where nothing streams, so its
// flush is a benign no-op and it needs no prepare. Gating on `cfg.mode == Drill`
// keeps the dry-run program byte-identical (no perturbation of its line set).
fn prepare(
  cfg: GcodeConfig,
  centroid: #(Float, Float),
  safe_z: Float,
  feeds: config.FeedProfile,
) -> List(String) {
  case cfg.mode {
    DryRun -> []
    Drill -> {
      let #(cx, cy) = centroid
      [
        "G0 Z" <> fmt5(safe_z) <> " ( prepare: retract to travel-safe Z )",
        "G1 X"
          <> fmt5(cx)
          <> " Y"
          <> fmt5(cy)
          <> " F"
          <> fmt5(feeds.xy_feed)
          <> " ( prepare: travel to board-centroid setup pose )",
      ]
    }
  }
}

// A pause point: the real `M0` machine-stop line (DEFAULT, and g-code export),
// OR the in-app pause sentinel when `app_pause` is on. Either way the program
// PAUSES here — the bit swap / touch-off opportunity is never skipped, only its
// mechanism changes (printer panel vs in-app Resume). See ADR-0009.
fn pause_line(cfg: GcodeConfig, m0_line: String) -> String {
  case cfg.app_pause {
    True -> app_pause_marker
    False -> m0_line
  }
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
  feeds: config.FeedProfile,
  centroid: #(Float, Float),
  safe_z: Float,
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
        pause_line(cfg, "M0      (Temporary machine stop.)"),
      ],
      spindle_on_step(cfg),
      [
        // Return to the program-wide travel/safe Z after the swap (NOT absolute
        // zsafe): with a tilted plane the safe height is surface-relative, and
        // this single ceiling clears every hole.
        "G0 Z" <> fmt5(safe_z),
        "G04 P1.00000",
        "",
        // Belt-and-braces default feed for the holes that follow. Every move now
        // carries its own explicit F (ADR-0015), so this is redundant, but it is
        // kept (sourced from the active profile's xy_feed) to minimize behavioral
        // surprise vs the prior per-tool `G1 F<drill_feed>` line.
        "G1 F" <> fmt5(feeds.xy_feed),
      ],
    ])

  list.append(
    change,
    list.flat_map(holes, fn(h) { drill_hole(h, cfg, feeds, safe_z) }),
  )
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
// STRUCTURAL invariant 1: every hole is `G1 X.. Y.. F<xy_feed>` at the current
// safe Z, then plunge (`F<plunge_feed>`), then ALWAYS retract to zsafe
// (`F<retract_feed>`). Per ADR-0015 every move carries its own feed; only the
// SPEED changes — the XY is still commanded at the program-wide safe height.
// ---------------------------------------------------------------------------

fn drill_hole(
  hole: MachineHole,
  cfg: GcodeConfig,
  feeds: config.FeedProfile,
  safe_z: Float,
) -> List(String) {
  safe_move(safe_z, feeds, hole.x, hole.y, fn() {
    [plunge_line(hole, cfg, feeds)]
  })
}

// Travel to (x, y) at the program-wide travel/safe Z, run `body` (the plunge),
// then retract back to that same safe Z. XY is only ever commanded at safe_z, so
// invariant 1 holds: the bit can never traverse XY where it could strike the
// board. The XY travel is a controlled `G1 ... F<xy_feed>` (ADR-0015), the
// retract a controlled `G1 Z<safe_z> F<retract_feed>`.
fn safe_move(
  safe_z: Float,
  feeds: config.FeedProfile,
  x: Float,
  y: Float,
  body: fn() -> List(String),
) -> List(String) {
  list.flatten([
    [fmt_xy_travel(x, y, feeds.xy_feed)],
    body(),
    [retract(safe_z, feeds.retract_feed)],
  ])
}

fn retract(safe_z: Float, retract_feed: Float) -> String {
  fmt_g1_z_feed(safe_z, retract_feed)
}

// The plunge line, PLANE-RELATIVE: the target Z is the hole's local surface plus
// the config offset, moved at `feeds.plunge_feed` (ADR-0015). In Drill ->
// `G1 Z<surface + zdrill> F<plunge_feed>` (zdrill negative). In DryRun ->
// `G1 Z<surface + hover> F<plunge_feed>` (hover positive), so a negative Z is
// unrepresentable in dry-run as long as surface + hover >= 0.
fn plunge_line(
  hole: MachineHole,
  cfg: GcodeConfig,
  feeds: config.FeedProfile,
) -> String {
  case cfg.mode {
    Drill -> fmt_g1_z_feed(hole.surface_z +. cfg.zdrill, feeds.plunge_feed)
    DryRun ->
      "G1 Z"
      <> fmt5(hole.surface_z +. cfg.hover)
      <> " F"
      <> fmt5(feeds.plunge_feed)
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

// The program-wide travel/safe Z: the HIGHEST hole surface plus zsafe, so a
// single travel height clears every hole by at least zsafe. Empty list -> just
// zsafe (the flat-bed default). This is the only Z used for inter-hole XY rapids
// and the post-swap return-to-cut height; per-hole plunge/retract reference each
// hole's own surface_z.
fn travel_safe_z(holes: List(MachineHole), cfg: GcodeConfig) -> Float {
  let max_surface =
    list.fold(holes, 0.0, fn(acc, h) { float.max(acc, h.surface_z) })
  max_surface +. cfg.zsafe
}

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
    list.map(points, fn(p) {
      MachineHole(tool: "", x: p.0, y: p.1, surface_z: 0.0)
    }),
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

// Controlled inter-hole XY travel (ADR-0015): `G1 X.. Y.. F<xy_feed>` (was an
// uncontrolled `G0` rapid). Only the speed is settable; the Z is unchanged — the
// caller (`safe_move`) only ever emits this at the program-wide safe height.
fn fmt_xy_travel(x: Float, y: Float, xy_feed: Float) -> String {
  "G1 X" <> fmt5(x) <> " Y" <> fmt5(y) <> " F" <> fmt5(xy_feed)
}

// A controlled Z move carrying its own feed: `G1 Z<z> F<feed>` (plunge/retract).
fn fmt_g1_z_feed(z: Float, feed: Float) -> String {
  "G1 Z" <> fmt5(z) <> " F" <> fmt5(feed)
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
