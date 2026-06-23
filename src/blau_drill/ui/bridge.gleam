//// Phase-4 translation layer: maps the real `domain` / `control` values into
//// the flat `model.Model` shape the pure views render, and back. Keeping this
//// in one module means `app.gleam` stays an orchestrator and the views never
//// learn about the domain types.
////
//// Everything here is pure. The helpers, in brief:
////   * `feature_candidates` — the 4 bbox-corner-nearest holes (registration
////     targets), deduped.
////   * `board_of` — the canvas-facing `Board` from a parsed `BoardModel`.
////   * `printer_state` — `control` FSM → UI `PrinterState` for the gates.
////   * `estimate_machine_point` — pre-fit click-to-jump (1 capture → translate,
////     2+ → similarity), the inverse of the canvas's board-space estimate.
////   * config coercion — settings strings → `domain/config.GcodeConfig`.

import blau_drill/control/printer
import blau_drill/domain/board_model.{type BoardModel}
import blau_drill/domain/config.{type GcodeConfig}
import blau_drill/domain/transform2d.{type Point}
import blau_drill/ui/model
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// ── board_model → canvas Board ───────────────────────────────────────────────

/// Build the canvas-facing `Board` from a parsed domain `BoardModel`. Holes are
/// carried verbatim (board coords) with status `Pending`; tools come from the
/// tool table; the outline is the optional Edge.Cuts path; the candidates are
/// the corner-nearest holes.
pub fn board_of(bm: BoardModel) -> model.Board {
  let #(minx, miny, maxx, maxy) = bm.bbox
  let holes =
    list.map(bm.holes, fn(h) {
      model.Hole(x: h.x, y: h.y, tool: h.tool, status: model.Pending)
    })
  let tools =
    bm.tools
    |> dict.to_list
    |> list.map(fn(pair) { model.Tool(id: pair.0, diameter: pair.1) })
    |> list.sort(fn(a, b) { string.compare(a.id, b.id) })
  let outline = case bm.outline {
    Some(pts) -> pts
    None -> []
  }
  model.Board(
    holes: holes,
    tools: tools,
    bbox: model.BBox(minx:, miny:, maxx:, maxy:),
    outline: outline,
    candidates: feature_candidates(bm),
  )
}

/// The board-transform for a given side, over the board's own bbox.
///
///   * `Front` → `identity` (the canvas renders the `.drl`'s native orientation).
///   * `Back`  → an X-mirror about the bbox **centre** X, so the flipped board
///     keeps the same footprint.
///
/// Returns a plain `Transform2D` so future sides / rotations are just different
/// constructors — there is no `Front`/`Back` special-casing downstream.
pub fn board_xform(
  side: model.BoardSide,
  bbox: board_model.Bbox,
) -> transform2d.Transform2D {
  case side {
    model.Front -> transform2d.identity()
    model.Back -> {
      let #(minx, _miny, maxx, _maxy) = bbox
      let cx = { minx +. maxx } /. 2.0
      transform2d.mirror_x_about(cx)
    }
  }
}

/// Build the canvas-facing `Board` for a given side, applying ONE transform to
/// every coordinate: each hole's `(x, y)`, every outline point, and every
/// candidate point. The bbox is **recomputed** from the transformed holes (a
/// transform can reorder min/max, so the old corners are not reused). Tools have
/// no coordinates and pass through unchanged; hole tool/status and ordering are
/// preserved.
///
/// `working_board(bm, Front)` equals `board_of(bm)` exactly (identity ⇒ no-op).
///
/// Implemented as `board_of(working_board_model(bm, side))` so the canvas board,
/// the alignment job, and the g-code all derive from ONE transformed source (the
/// working `BoardModel`). The flip lives in exactly one place.
pub fn working_board(bm: BoardModel, side: model.BoardSide) -> model.Board {
  board_of(working_board_model(bm, side))
}

/// Apply ONE board transform (`board_xform(side, bm.bbox)`) to the parsed
/// `BoardModel`, producing the WORKING model the canvas, the alignment job, and
/// the g-code all derive from. The flip lives in exactly one place.
///
/// Every hole `(x, y)` and every fiducial `(x, y)` are transformed (tool / kind
/// preserved); the outline points are transformed when present; tools (no
/// coordinates) pass through. The bbox is **recomputed** from the transformed
/// holes (a transform can reorder min/max, so the old corners are not reused).
/// Hole order is preserved.
///
/// `Front` is a no-op: `working_board_model(bm, Front) == bm` (identity).
pub fn working_board_model(
  bm: BoardModel,
  side: model.BoardSide,
) -> BoardModel {
  let xf = board_xform(side, bm.bbox)
  let holes =
    list.map(bm.holes, fn(h) {
      let #(x, y) = transform2d.apply(xf, #(h.x, h.y))
      board_model.Hole(x:, y:, tool: h.tool)
    })
  let outline = case bm.outline {
    Some(pts) -> Some(list.map(pts, transform2d.apply(xf, _)))
    None -> None
  }
  let fiducials =
    list.map(bm.fiducials, fn(f) {
      let #(x, y) = transform2d.apply(xf, #(f.x, f.y))
      board_model.Fiducial(x:, y:, kind: f.kind)
    })
  board_model.BoardModel(
    holes:,
    outline:,
    fiducials:,
    tools: bm.tools,
    bbox: bbox_of_holes(holes),
  )
}

/// Recompute an axis-aligned bbox `#(min_x, min_y, max_x, max_y)` from a list of
/// (already transformed) holes. Folds min/max over the hole coordinates; empty
/// holes yield a degenerate zero bbox (the parser guarantees at least one hole,
/// so this is a safe floor).
fn bbox_of_holes(holes: List(board_model.Hole)) -> board_model.Bbox {
  case holes {
    [] -> #(0.0, 0.0, 0.0, 0.0)
    [first, ..rest] -> {
      list.fold(rest, #(first.x, first.y, first.x, first.y), fn(acc, h) {
        let #(minx, miny, maxx, maxy) = acc
        #(
          float.min(minx, h.x),
          float.min(miny, h.y),
          float.max(maxx, h.x),
          float.max(maxy, h.y),
        )
      })
    }
  }
}

/// The parse diagnostic shown after Stage 1.
pub fn diagnostic_of(bm: BoardModel) -> model.Diagnostic {
  let #(minx, miny, maxx, maxy) = bm.bbox
  model.Diagnostic(
    hole_count: list.length(bm.holes),
    tool_count: dict.size(bm.tools),
    width: round2(maxx -. minx),
    height: round2(maxy -. miny),
  )
}

/// The registration candidates: the hole nearest each bbox corner, deduped,
/// preserving corner order.
pub fn feature_candidates(bm: BoardModel) -> List(Point) {
  let #(minx, miny, maxx, maxy) = bm.bbox
  let corners = [#(minx, miny), #(maxx, miny), #(maxx, maxy), #(minx, maxy)]
  corners
  |> list.map(fn(corner) {
    let nearest = nearest_hole(bm, corner)
    nearest
  })
  |> dedup_points
}

fn nearest_hole(bm: BoardModel, corner: Point) -> Point {
  case bm.holes {
    [] -> corner
    [first, ..rest] -> {
      let init = #(#(first.x, first.y), dist2(#(first.x, first.y), corner))
      let #(best, _) =
        list.fold(rest, init, fn(acc, h) {
          let #(_best, best_d) = acc
          let p = #(h.x, h.y)
          let d = dist2(p, corner)
          case d <. best_d {
            True -> #(p, d)
            False -> acc
          }
        })
      best
    }
  }
}

fn dist2(a: Point, b: Point) -> Float {
  let dx = a.0 -. b.0
  let dy = a.1 -. b.1
  dx *. dx +. dy *. dy
}

fn dedup_points(pts: List(Point)) -> List(Point) {
  list.fold(pts, [], fn(acc: List(Point), p: Point) {
    case list.any(acc, fn(q: Point) { q.0 == p.0 && q.1 == p.1 }) {
      True -> acc
      False -> list.append(acc, [p])
    }
  })
}

// ── control FSM → UI PrinterState ────────────────────────────────────────────

/// Map the `control` printer state into the flat UI `PrinterState` the views
/// gate off. Streaming and Jogging map straight across; Idle is "connected,
/// motors off"; Faulted is loud; Disconnected is no port.
pub fn printer_state(s: printer.PrinterState) -> model.PrinterState {
  case s {
    printer.Disconnected -> model.Disconnected
    printer.Idle(_, _) -> model.Idle
    printer.Jogging(_, _) -> model.Jogging
    printer.Streaming(_, _) -> model.Streaming
    printer.Faulted -> model.Faulted
  }
}

// ── parse error → operator copy ──────────────────────────────────────────────

/// Operator-facing message for a parse failure. The absolute-page-coordinate
/// trap gets the "drill origin not set" guidance.
pub fn parse_error_message(err: board_model.ParseError) -> String {
  case err {
    board_model.MissingDrl -> "No drill file selected."
    board_model.MissingM48Header ->
      "Not a valid Excellon drill file (no M48 header)."
    board_model.NoHoles -> "Drill file contains no holes."
    board_model.HoleWithNoTool(line) -> "Hole with no selected tool: " <> line
    board_model.AbsolutePageCoordinates(_) ->
      "Drill origin not set: coordinates look like an absolute KiCad page "
      <> "export. Re-export with the Drill/Place File Origin placed on a "
      <> "fiducial."
  }
}

// ── alignment-fit diagnostics ────────────────────────────────────────────────

/// Diagnose a completed (over-tolerance) fit from its per-point errors + tol.
/// `point_errors` is in capture order (from `alignment.point_errors`). Returns a
/// `model.FitDiag` with per-point residuals, the worst point, a likely-cause
/// hint, and `can_override: True` (a transform was solved).
pub fn diagnose_fit(point_errors: List(Float), tol: Float) -> model.FitDiag {
  let points =
    point_errors
    |> list.index_map(fn(e, i) { model.PointResidual(index: i, error_mm: e) })
  let worst = worst_point(points)
  model.FitDiag(
    points:,
    worst:,
    hint: fit_hint(points, worst, tol),
    can_override: True,
  )
}

/// Diagnosis for a degenerate fit (collinear / coincident points): no per-point
/// residuals (the fit didn't solve) and NO override — just geometry guidance.
pub fn degenerate_diagnosis() -> model.FitDiag {
  model.FitDiag(
    points: [],
    worst: model.NoWorst,
    hint: "Points are nearly in a line (or too close together). Capture a third "
      <> "point well off that line — spread the fiducials across the board.",
    can_override: False,
  )
}

fn worst_point(points: List(model.PointResidual)) -> model.WorstOpt {
  case points {
    [] -> model.NoWorst
    [first, ..rest] ->
      model.HaveWorst(
        list.fold(rest, first, fn(acc, p) {
          case p.error_mm >. acc.error_mm {
            True -> p
            False -> acc
          }
        }),
      )
  }
}

/// Heuristic likely-cause hint:
///   * one point much worse than the rest → that point is likely mis-captured;
///   * all points similarly over tolerance → a systematic error (wrong board
///     origin / wrong point clicked / board shifted);
///   * otherwise → generic recapture guidance.
fn fit_hint(
  points: List(model.PointResidual),
  worst: model.WorstOpt,
  tol: Float,
) -> String {
  case worst {
    model.NoWorst -> "Capture at least 3 well-spread points and fit again."
    model.HaveWorst(w) -> {
      // Median-ish reference: the second-worst error. If the worst dwarfs the
      // rest, it's an outlier (one bad capture); if all are high, it's systemic.
      let others =
        points
        |> list.filter(fn(p) { p.index != w.index })
        |> list.map(fn(p) { p.error_mm })
      let next_worst = case others {
        [] -> 0.0
        _ -> list.fold(others, 0.0, float.max)
      }
      case w.error_mm >. 2.0 *. float.max(next_worst, tol), next_worst <=. tol {
        // Worst is a clear outlier AND the rest are within tolerance.
        True, True ->
          "Point "
          <> int.to_string(w.index + 1)
          <> " is off by "
          <> float.to_string(round2(w.error_mm))
          <> " mm while the others are within tolerance — it was likely "
          <> "mis-captured. Recapture just that point."
        // All points are over tolerance: a systematic problem.
        _, False ->
          "All points are over tolerance — likely the wrong board origin, the "
          <> "wrong feature clicked, or the board shifted between captures. "
          <> "Re-check the board origin and recapture."
        // Mixed.
        _, _ ->
          "Worst point ("
          <> int.to_string(w.index + 1)
          <> ") is "
          <> float.to_string(round2(w.error_mm))
          <> " mm off. Recapture it (or all) and fit again."
      }
    }
  }
}

// ── pre-fit click-to-jump estimate ───────────────────────────────────────────

/// Best machine point for a board point, using whatever transform is available:
///   * a solved transform → forward apply;
///   * 1 capture → translation;
///   * 2+ captures → similarity from the first two pairs;
///   * 0 captures → `Error(Nil)` (nothing to map with).
pub fn board_to_machine(
  transform: model.TransformOpt,
  captures: List(model.Capture),
  board: Point,
) -> Result(Point, Nil) {
  case transform {
    model.HaveTransform(t) -> Ok(transform2d.apply(t, board))
    model.NoTransform -> estimate_machine_point(captures, board)
  }
}

fn estimate_machine_point(
  captures: List(model.Capture),
  board: Point,
) -> Result(Point, Nil) {
  case captures {
    [] -> Error(Nil)
    [c1] -> {
      // translation: machine ≈ board − (board₁ − machine₁)
      let #(bx, by) = board
      let #(b1x, b1y) = c1.board
      let #(m1x, m1y) = c1.machine
      Ok(#(bx -. { b1x -. m1x }, by -. { b1y -. m1y }))
    }
    [c1, c2, ..] -> {
      // similarity from the first two pairs.
      let #(bx, by) = board
      let #(b1x, b1y) = c1.board
      let #(m1x, m1y) = c1.machine
      let #(b2x, b2y) = c2.board
      let #(m2x, m2y) = c2.machine
      let bdx = b2x -. b1x
      let bdy = b2y -. b1y
      let mdx = m2x -. m1x
      let mdy = m2y -. m1y
      let blen2 = bdx *. bdx +. bdy *. bdy
      case blen2 <. 1.0e-9 {
        True -> Ok(#(bx -. { b1x -. m1x }, by -. { b1y -. m1y }))
        False -> {
          let sr = { mdx *. bdx +. mdy *. bdy } /. blen2
          let si = { mdy *. bdx -. mdx *. bdy } /. blen2
          let dx = bx -. b1x
          let dy = by -. b1y
          Ok(#(m1x +. { sr *. dx -. si *. dy }, m1y +. { si *. dx +. sr *. dy }))
        }
      }
    }
  }
}

/// The inverse of `board_to_machine` for the pre-fit crosshair: given the
/// captures and the live MACHINE head, estimate where the head sits in BOARD
/// space (so the crosshair can be drawn before a solved transform exists).
///   * 1 capture → translation: board ≈ machine + (board₁ − machine₁);
///   * 2+ captures → inverse similarity from the first two pairs;
///   * 0 captures → `Error(Nil)`.
pub fn board_to_machine_inverse(
  captures: List(model.Capture),
  head: model.Head,
) -> Result(Point, Nil) {
  let machine = #(head.x, head.y)
  case captures {
    [] -> Error(Nil)
    [c1] -> {
      let #(mx, my) = machine
      let #(b1x, b1y) = c1.board
      let #(m1x, m1y) = c1.machine
      Ok(#(mx +. { b1x -. m1x }, my +. { b1y -. m1y }))
    }
    [c1, c2, ..] -> {
      let #(mx, my) = machine
      let #(b1x, b1y) = c1.board
      let #(m1x, m1y) = c1.machine
      let #(b2x, b2y) = c2.board
      let #(m2x, m2y) = c2.machine
      let mdx = m2x -. m1x
      let mdy = m2y -. m1y
      let bdx = b2x -. b1x
      let bdy = b2y -. b1y
      let mlen2 = mdx *. mdx +. mdy *. mdy
      case mlen2 <. 1.0e-9 {
        True -> Ok(#(mx +. { b1x -. m1x }, my +. { b1y -. m1y }))
        False -> {
          // inverse similarity: s = bd/md applied to (machine − m1) + b1.
          let sr = { bdx *. mdx +. bdy *. mdy } /. mlen2
          let si = { bdy *. mdx -. bdx *. mdy } /. mlen2
          let dx = mx -. m1x
          let dy = my -. m1y
          Ok(#(b1x +. { sr *. dx -. si *. dy }, b1y +. { si *. dx +. sr *. dy }))
        }
      }
    }
  }
}

// ── config coercion (settings strings → GcodeConfig) ─────────────────────────

/// Coerce the settings strings into a `GcodeConfig` for a run, with the given
/// mode. Invalid / blank numeric fields fall back to the `config.default()`
/// value for that field, so a run always has a safe, complete config.
/// Machine-specific fields (port/baud/limits/spindle G-code/pwm) live in the UI
/// Config and are not part of the generator tunables this returns.
pub fn gcode_config(c: model.Config, mode: config.Mode) -> GcodeConfig {
  let d = config.default()
  config.GcodeConfig(
    mode:,
    zdrill: parse_float(c.zdrill, d.zdrill),
    zsafe: parse_float(c.zsafe, d.zsafe),
    zchange: parse_float(c.zchange, d.zchange),
    drill_feed: parse_float(c.drill_feed, d.drill_feed),
    spindle_speed: parse_int(c.spindle_speed, d.spindle_speed),
    hover: parse_float(c.hover, d.hover),
  )
}

/// Parse the spindle on/off raw G-code commands from the config for `PulseSpindle`.
pub fn spindle_commands(c: model.Config) -> #(String, String) {
  #(c.spindle_on, c.spindle_off)
}

/// The selected baud as an Int (falls back to 115200).
pub fn baud(c: model.Config) -> Int {
  parse_int(c.baud, 115_200)
}

fn parse_float(s: String, fallback: Float) -> Float {
  case float.parse(s) {
    Ok(f) -> f
    Error(_) ->
      case int.parse(s) {
        Ok(i) -> int.to_float(i)
        Error(_) -> fallback
      }
  }
}

fn parse_int(s: String, fallback: Int) -> Int {
  case int.parse(s) {
    Ok(i) -> i
    Error(_) ->
      case float.parse(s) {
        Ok(f) -> float.round(f)
        Error(_) -> fallback
      }
  }
}

// ── small helpers ────────────────────────────────────────────────────────────

fn round2(v: Float) -> Float {
  int.to_float(float.round(v *. 100.0)) /. 100.0
}
