//// The drilling program as a typed **`Operation` algebra**, rendered to Marlin
//// G-code strings at the wire edge (ADR-0016) — the safety-critical heart of
//// blau-drill.
////
//// `build_ops/3` takes a `BoardModel`, a **solved** `Alignment`, and a config,
//// and produces a symbolic `List(Operation)` that carries DRILLING INTENT (a
//// hole at a *board* point), not resolved G-code numbers. `render/3` turns that
//// list into `RenderedLine`s for a chosen `RenderTarget` (the streamed `Wire`
//// form, or the human-readable `Rich` form), using the immutable run-start
//// numbers in a `RenderContext`. Structure is read from the types; it is never
//// recovered by parsing strings.
////
//// The module is just that: the typed `Operation` algebra (`build_ops`) plus a
//// pure renderer (`render(ops, ctx, target) -> RenderedLine`). The app renders
//// the `Wire` form to stream and the `Rich` form for the human-readable view;
//// no intermediate flattened-to-strings program value exists.
////
//// ## The two safety invariants, enforced structurally (in the renderer)
////
//// 1. **Never traverse XY without Z safe.** A `DrillHole` renders as the atom
////    travel→plunge→retract in ONE function (`render_drill_hole`); the inter-hole
////    travel is `G1 X.. Y.. F<xy_feed>` at `ctx.safe_z` and the retract returns to
////    `ctx.safe_z` (ADR-0015: controlled XY travel — operator-tunable speed, the Z
////    is still the safe height). There is no standalone XY-move primitive a caller
////    could emit at an unsafe Z.
//// 2. **Spindle running before any plunge (drill mode).** A `ToolBlock` (which
////    renders spindle-on) always precedes its `DrillHole`s in the op list, so in
////    `Drill` no plunge can precede the `M3 S255`. In `DryRun` the plunge depth is
////    the positive hover, so a negative Z is unrepresentable in that mode.

import blau_drill/domain/alignment.{type Alignment}
import blau_drill/domain/board_model.{
  type BoardModel, type HoleId, type ToolId, type ToolTable,
}
import blau_drill/domain/config.{
  type FeedProfile, type GcodeConfig, type Mode, Drill, DryRun,
}
import blau_drill/domain/transform2d.{type Transform2D}
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A 2D point — a board point OR a machine point (see each field's doc). Board
/// points are carried symbolically on `Operation`s; machine numbers are derived
/// at render time from the `RenderContext`'s transform.
pub type Point =
  #(Float, Float)

/// Why the program pauses (ADR-0009 in-app pause). NEVER a string sentinel — the
/// reason is typed, and `printer.gleam` reads `origin.pause` instead of grepping.
pub type PauseReason {
  /// A bit change for `tool` (the only reason `build_ops` emits today).
  BitChange(tool: ToolId)
  /// A start-of-run touch-off. Exists in the type (ADR-0016) but NOT emitted by
  /// `build_ops` — ADR-0010 removed the touch-off (the plane is the Z datum).
  TouchOff
}

/// The typed drilling operation algebra (ADR-0016). Ops carry intent; the
/// numbers (feeds, safe Z, centroid, mode, transform) live in a `RenderContext`.
pub type Operation {
  /// Unit/mode setup (G94/G21/G90/G91.1) plus the honest header.
  Preamble
  /// ADR-0014 flush-then-prepare pose (drill mode only): retract to safe Z, then
  /// travel at safe Z to the board centroid.
  Prepare(centroid: Point, safe_z: Float)
  /// A bit exchange for `tool`: retract, park at the centroid, M5/M6, then
  /// (after the `Pause`) spindle-on and return to cut height.
  ToolBlock(tool: ToolId)
  /// A hole at a BOARD point. Renders travel→plunge→retract; the renderer
  /// projects `board` to machine XY and reads the plane-relative Z.
  DrillHole(hole_id: HoleId, board: Point)
  /// An in-app pause (ADR-0009); never a string sentinel.
  Pause(reason: PauseReason)
  /// Home, spindle off, M2.
  Postamble
}

/// The immutable run-start numbers a render needs. Derived once from
/// `board + alignment + cfg` by `render_context`.
///
/// Beyond the ADR-0016 sketch (`mode, feeds, safe_z, centroid, cfg`) this carries
/// what the render math reaches for that is NOT on `cfg`:
/// - `transform`/`z_plane` — the alignment math `render` applies to each
///   `DrillHole.board` point (machine XY via `transform`, plane-relative Z via
///   `z_plane`).
/// - `tools` — the tool→diameter table (the header + each tool block's MSG line
///   need the diameter; it lives on the board, not on `cfg`).
/// - `tool_order` — the file-order tool list (the header lists the bit sizes in
///   this order).
pub type RenderContext {
  RenderContext(
    mode: Mode,
    feeds: FeedProfile,
    safe_z: Float,
    centroid: Point,
    cfg: GcodeConfig,
    transform: Transform2D,
    z_plane: alignment.ZPlane,
    tools: ToolTable,
    tool_order: List(ToolId),
  )
}

/// Which view to render: the streamed wire form, or the human-readable form.
pub type RenderTarget {
  /// Commands only — the streamed form (blank lines + full-line comments dropped).
  Wire
  /// Human-readable — comments and blank grouping lines kept.
  Rich
}

/// The `OpKind` of the op a rendered line came from (ADR-0017 reads this off the
/// origin instead of grepping the wire string).
pub type OpKind {
  PreambleKind
  PrepareKind
  ToolBlockKind
  DrillHoleKind
  PauseKind
  PostambleKind
}

/// The typed back-reference a rendered line carries (ADR-0017 depends on this).
pub type LineOrigin {
  LineOrigin(
    /// Index (0-based) of the `Operation` in the `build_ops` list this line came
    /// from. One op may render to many lines, all sharing its index.
    op_index: Int,
    kind: OpKind,
    /// `Some` on every `ToolBlock`-rendered line (the block's tool).
    tool: Option(ToolId),
    /// `Some` on every `DrillHole`-rendered line.
    hole_id: Option(HoleId),
    /// `Some` on the single `Pause`-stop line.
    pause: Option(PauseReason),
  )
}

/// A rendered G-code line plus its typed origin.
pub type RenderedLine {
  RenderedLine(wire: String, origin: LineOrigin)
}

/// The permanent in-band pause sentinel the renderer emits (`pause_line`) in
/// place of `M0` when `cfg.app_pause` is on. It is NOT a real Marlin command, so
/// the streaming FSM intercepts it, pauses the stream, and never writes it to the
/// port; `printer.in_app_pause` distinguishes it from a real `M0` when app_pause
/// is off. It is deliberately a bare token (no leading `(`/`;`, non-blank), so the
/// `Wire` render KEEPS it through the streamable filter — the streamed program
/// carries the marker, the FSM consumes it. See `printer.feed_stream` and
/// ADR-0009/0017.
pub const app_pause_marker = "M0_APP_PAUSE"

// ---------------------------------------------------------------------------
// A hole projected into machine space, carrying its file-order id and the
// fitted surface Z at its BOARD location. The id rides along through tool
// grouping (ADR-0016: hole identity is file-parse order). `surface_z` is
// `alignment.surface_z` of the hole's board coords (the plane is board-frame) —
// every per-hole Z line is computed relative to it, so a tilted board drills
// the right depth everywhere.
// ---------------------------------------------------------------------------

type MachineHole {
  MachineHole(
    id: HoleId,
    tool: ToolId,
    board: Point,
    x: Float,
    y: Float,
    surface_z: Float,
  )
}

// ---------------------------------------------------------------------------
// build_ops — the symbolic op list (ADR-0016). Pure.
// ---------------------------------------------------------------------------

/// Build the symbolic `Operation` list from `board`, a **solved** `alignment`,
/// and `cfg`. Pure. The op list is
/// `[Preamble, Prepare(centroid, safe_z)? (drill only),
///   <for each tool in tool_order: ToolBlock(tool), Pause(BitChange(tool)),
///    <DrillHole(id, board_xy) per hole>>, Postamble]`.
///
/// A hole lives only in board space here; its machine coordinate is derived at
/// render time. The `DrillHole`s ride the file-order `hole_id` through the
/// per-tool grouping.
pub fn build_ops(
  board: BoardModel,
  alignment: Alignment,
  cfg: GcodeConfig,
) -> List(Operation) {
  let order = tool_order(board)
  let machine_holes = machine_holes(board, alignment)
  let by_tool = group_by_tool(machine_holes)
  let centroid = centroid_machine(machine_holes)
  let safe_z = travel_safe_z(machine_holes, cfg)

  let prepare = case cfg.mode {
    Drill -> [Prepare(centroid: centroid, safe_z: safe_z)]
    DryRun -> []
  }

  let body =
    list.flat_map(order, fn(tool) {
      let holes = case dict.get(by_tool, tool) {
        Ok(hs) -> hs
        Error(_) -> []
      }
      [
        ToolBlock(tool: tool),
        Pause(reason: BitChange(tool: tool)),
        ..list.map(holes, fn(h) { DrillHole(hole_id: h.id, board: h.board) })
      ]
    })

  list.flatten([[Preamble], prepare, body, [Postamble]])
}

/// The render context derived from the same inputs `build_ops` uses (centroid,
/// safe_z, feeds, mode, transform, z_plane). Pure. Lets callers build the ctx
/// without re-deriving centroid/safe_z themselves.
pub fn render_context(
  board: BoardModel,
  alignment: Alignment,
  cfg: GcodeConfig,
) -> RenderContext {
  let machine_holes = machine_holes(board, alignment)
  let feeds = case cfg.mode {
    Drill -> cfg.drill_feeds
    DryRun -> cfg.dry_run_feeds
  }
  RenderContext(
    mode: cfg.mode,
    feeds: feeds,
    safe_z: travel_safe_z(machine_holes, cfg),
    centroid: centroid_machine(machine_holes),
    cfg: cfg,
    transform: alignment.transform,
    z_plane: alignment.z_plane,
    tools: board.tools,
    tool_order: tool_order(board),
  )
}

fn machine_holes(board: BoardModel, alignment: Alignment) -> List(MachineHole) {
  list.map(board.holes, fn(hole) {
    let board_pt = #(hole.x, hole.y)
    let #(mx, my) = transform2d.apply(alignment.transform, board_pt)
    // The surface plane is BOARD-frame, so evaluate it at the hole's board
    // coords (NOT the machine projection). Every per-hole Z references this.
    let sz = alignment.surface_z(alignment.z_plane, hole.x, hole.y)
    MachineHole(
      id: hole.id,
      tool: hole.tool,
      board: board_pt,
      x: mx,
      y: my,
      surface_z: sz,
    )
  })
}

// ---------------------------------------------------------------------------
// render — ops → lines, for a chosen target. Pure & deterministic.
// ---------------------------------------------------------------------------

/// Render `ops` to lines under `ctx`, for `target`. `Wire` = commands only (the
/// streamed form); `Rich` = comments + blanks kept (human-readable). Pure and
/// deterministic given `(ops, ctx)` — the `fmt5` FFI is the single
/// number-formatting authority, so the wire output is byte-stable.
pub fn render(
  ops: List(Operation),
  ctx: RenderContext,
  target: RenderTarget,
) -> List(RenderedLine) {
  ops
  |> list.index_map(fn(op, i) { render_op(op, i, ctx, target) })
  |> list.flatten
}

fn render_op(
  op: Operation,
  op_index: Int,
  ctx: RenderContext,
  target: RenderTarget,
) -> List(RenderedLine) {
  let lines = case op {
    Preamble -> render_preamble(ctx, op_index)
    Prepare(centroid, safe_z) -> render_prepare(centroid, safe_z, ctx, op_index)
    ToolBlock(tool) -> render_tool_block(tool, ctx, op_index)
    Pause(reason) -> render_pause(reason, ctx, op_index)
    DrillHole(hole_id, board) ->
      render_drill_hole(hole_id, board, ctx, op_index)
    Postamble -> render_postamble(ctx, op_index)
  }
  filter_for_target(lines, target)
}

// A `Rich` render keeps everything; a `Wire` render drops the non-command noise
// (blank/whitespace-only lines and FULL-LINE `(`/`;` comments), in original
// order — the `is_streamable` predicate. The dropped lines are exactly the ones
// Marlin can't reliably `ok` (blanks) or that carry no command (full-line
// comments), so the `Wire` form is the one actually fed over the handshake.
fn filter_for_target(
  lines: List(RenderedLine),
  target: RenderTarget,
) -> List(RenderedLine) {
  case target {
    Rich -> lines
    Wire -> list.filter(lines, fn(rl) { is_streamable(rl.wire) })
  }
}

// ---------------------------------------------------------------------------
// Per-op renderers. Each tags its lines with a `LineOrigin`.
// ---------------------------------------------------------------------------

fn render_preamble(ctx: RenderContext, op_index: Int) -> List(RenderedLine) {
  let origin = base_origin(op_index, PreambleKind)
  list.flatten([header(ctx), preamble()])
  |> list.map(fn(line) { RenderedLine(wire: line, origin: origin) })
}

fn render_prepare(
  centroid: Point,
  safe_z: Float,
  ctx: RenderContext,
  op_index: Int,
) -> List(RenderedLine) {
  let origin = base_origin(op_index, PrepareKind)
  let #(cx, cy) = centroid
  [
    "G0 Z" <> fmt5(safe_z) <> " ( prepare: retract to travel-safe Z )",
    "G1 X"
      <> fmt5(cx)
      <> " Y"
      <> fmt5(cy)
      <> " F"
      <> fmt5(ctx.feeds.xy_feed)
      <> " ( prepare: travel to board-centroid setup pose )",
  ]
  |> list.map(fn(line) { RenderedLine(wire: line, origin: origin) })
}

// The pre-pause portion of a bit exchange: retract → park at centroid → T<n> →
// M5 → dwell → MSG → M6. (Spindle-on + return-to-cut come AFTER the pause, in
// `render_pause`, so the wire byte-order matches today's `tool_block`.) Every
// line is tagged with the block's tool.
fn render_tool_block(
  tool: ToolId,
  ctx: RenderContext,
  op_index: Int,
) -> List(RenderedLine) {
  let origin =
    LineOrigin(
      op_index: op_index,
      kind: ToolBlockKind,
      tool: Some(tool),
      hole_id: None,
      pause: None,
    )
  let diameter = fmt_diameter(tool_diameter(ctx.tools, tool))
  let #(cx, cy) = ctx.centroid

  [
    "G00 Z" <> fmt5(ctx.cfg.zchange) <> " (Retract)",
    // Move XY to the board centroid at the retracted (zchange) height, so the
    // operator swaps the bit at a consistent, board-centered spot. Emitted AFTER
    // the Z retract, so it travels at the safe retract height.
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
  ]
  |> list.map(fn(line) { RenderedLine(wire: line, origin: origin) })
}

// The pause renders the single stop line (PauseKind, carrying the reason), then
// the post-pause recovery: spindle-on, return to the program-wide safe Z, the
// settle dwell, a blank grouping line, and the belt-and-braces default feed.
// Those recovery lines belong to the bit change, so they are tagged ToolBlockKind
// with the block's tool — keeping "every ToolBlock-origin line has Some(tool)"
// true and leaving exactly ONE PauseKind line. This split is what keeps the Wire
// byte-order identical to today's `tool_block` (pause wedged after M6, before
// spindle-on), under the fixed op order `[ToolBlock, Pause, holes..]`.
fn render_pause(
  reason: PauseReason,
  ctx: RenderContext,
  op_index: Int,
) -> List(RenderedLine) {
  let tool = case reason {
    BitChange(tool: t) -> Some(t)
    TouchOff -> None
  }
  let pause_origin =
    LineOrigin(
      op_index: op_index,
      kind: PauseKind,
      tool: tool,
      hole_id: None,
      pause: Some(reason),
    )
  let recovery_origin =
    LineOrigin(
      op_index: op_index,
      kind: ToolBlockKind,
      tool: tool,
      hole_id: None,
      pause: None,
    )

  let stop_line = RenderedLine(wire: pause_line(ctx.cfg), origin: pause_origin)

  let recovery =
    list.flatten([
      spindle_on_step(ctx.cfg),
      [
        // Return to the program-wide travel/safe Z after the swap (NOT absolute
        // zsafe): with a tilted plane the safe height is surface-relative, and
        // this single ceiling clears every hole.
        "G0 Z" <> fmt5(ctx.safe_z),
        "G04 P1.00000",
        "",
        // Belt-and-braces default feed for the holes that follow. Every move now
        // carries its own explicit F (ADR-0015), so this is redundant, but it is
        // kept (sourced from the active profile's xy_feed) to minimize behavioral
        // surprise vs the prior per-tool `G1 F<drill_feed>` line.
        "G1 F" <> fmt5(ctx.feeds.xy_feed),
      ],
    ])
    |> list.map(fn(line) { RenderedLine(wire: line, origin: recovery_origin) })

  [stop_line, ..recovery]
}

// A `DrillHole` renders as the atom travel→plunge→retract (invariant 1). The
// inter-hole travel is `G1 X.. Y.. F<xy_feed>` at `ctx.safe_z`; the plunge is
// plane-relative; the retract returns to `ctx.safe_z`. The board point is
// projected to machine XY and the plane-relative Z is read here.
fn render_drill_hole(
  hole_id: HoleId,
  board: Point,
  ctx: RenderContext,
  op_index: Int,
) -> List(RenderedLine) {
  let origin =
    LineOrigin(
      op_index: op_index,
      kind: DrillHoleKind,
      tool: None,
      hole_id: Some(hole_id),
      pause: None,
    )
  let #(x, y) = transform2d.apply(ctx.transform, board)
  let #(bx, by) = board
  let surface_z = alignment.surface_z(ctx.z_plane, bx, by)

  [
    fmt_xy_travel(x, y, ctx.feeds.xy_feed),
    plunge_line(surface_z, ctx),
    retract(ctx.safe_z, ctx.feeds.retract_feed),
  ]
  |> list.map(fn(line) { RenderedLine(wire: line, origin: origin) })
}

fn render_postamble(ctx: RenderContext, op_index: Int) -> List(RenderedLine) {
  let origin = base_origin(op_index, PostambleKind)
  postamble(ctx.cfg)
  |> list.map(fn(line) { RenderedLine(wire: line, origin: origin) })
}

fn base_origin(op_index: Int, kind: OpKind) -> LineOrigin {
  LineOrigin(
    op_index: op_index,
    kind: kind,
    tool: None,
    hole_id: None,
    pause: None,
  )
}

// ---------------------------------------------------------------------------
// The streamable filter — the `Wire` render keeps only these lines.
//
// A render emits a HUMAN-READABLE program: blank grouping lines `""` and
// full-line `( ... )` comments. Real Marlin does NOT reliably emit an `ok` for a
// blank line, so streaming those VERBATIM stalls the handshake on the first
// blank line. The `Wire` render drops the non-command noise (blank/whitespace-
// only lines and FULL-LINE comments), in original order — exactly the lines that
// must not reach the port. This is the predicate that does it.
// ---------------------------------------------------------------------------

// A line is streamable iff, after trimming, it is non-empty AND does not begin
// with a comment marker (`(` RepRap-style or `;`). Commands with a TRAILING
// inline comment (e.g. `"M0      (Temporary machine stop.)"`) start with a
// command token, so they pass — only FULL-LINE comments and blanks are dropped.
fn is_streamable(line: String) -> Bool {
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

fn header(ctx: RenderContext) -> List(String) {
  let order = ctx.tool_order
  let sizes =
    order
    |> list.map(fn(tool) {
      "[" <> fmt_diameter(tool_diameter(ctx.tools, tool)) <> "mm]"
    })
    |> string.join(" ")

  [
    "( blau-drill native G-code )",
    "( mode: " <> mode_string(ctx.cfg.mode) <> " )",
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
// `G92` origin reset. The first in-app pause is the FIRST tool's bit change.
// ---------------------------------------------------------------------------

fn preamble() -> List(String) {
  [
    "G04 P0 ( dwell for no time -- G64 should not smooth over this point )",
    "G94       (Millimeters per minute feed rate.)",
    "G21       (Units == Millimeters.)",
    "G91.1     (Incremental arc distance mode.)",
    "G90       (Absolute coordinates.)",
    "",
  ]
}

// A pause point: the real `M0` machine-stop line (DEFAULT, and g-code export),
// OR the in-app pause sentinel when `app_pause` is on. Either way the program
// PAUSES here — the bit swap / touch-off opportunity is never skipped, only its
// mechanism changes (printer panel vs in-app Resume). See ADR-0009.
fn pause_line(cfg: GcodeConfig) -> String {
  case cfg.app_pause {
    True -> app_pause_marker
    False -> "M0      (Temporary machine stop.)"
  }
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
// Per-hole emission — the safe travel→plunge→retract atom (invariant 1).
//
// Every hole is `G1 X.. Y.. F<xy_feed>` at the safe Z, then plunge
// (`F<plunge_feed>`), then ALWAYS retract to safe Z (`F<retract_feed>`).
// ---------------------------------------------------------------------------

fn retract(safe_z: Float, retract_feed: Float) -> String {
  fmt_g1_z_feed(safe_z, retract_feed)
}

// The plunge line, PLANE-RELATIVE: the target Z is the hole's local surface plus
// the config offset, moved at `feeds.plunge_feed` (ADR-0015). In Drill ->
// `G1 Z<surface + zdrill> F<plunge_feed>` (zdrill negative). In DryRun ->
// `G1 Z<surface + hover> F<plunge_feed>` (hover positive), so a negative Z is
// unrepresentable in dry-run as long as surface + hover >= 0.
fn plunge_line(surface_z: Float, ctx: RenderContext) -> String {
  case ctx.cfg.mode {
    Drill -> fmt_g1_z_feed(surface_z +. ctx.cfg.zdrill, ctx.feeds.plunge_feed)
    DryRun ->
      "G1 Z"
      <> fmt5(surface_z +. ctx.cfg.hover)
      <> " F"
      <> fmt5(ctx.feeds.plunge_feed)
      <> "  ( dry-run hover, was Z"
      <> fmt5(ctx.cfg.zdrill)
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
// Bounding box / centroid / travel-safe Z (machine space)
// ---------------------------------------------------------------------------

// The program-wide travel/safe Z: the HIGHEST hole surface plus zsafe, so a
// single travel height clears every hole by at least zsafe. Empty list -> just
// zsafe (the flat-bed default).
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

// Controlled inter-hole XY travel (ADR-0015): `G1 X.. Y.. F<xy_feed>`.
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

fn tool_diameter(tools: ToolTable, tool: ToolId) -> Float {
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
