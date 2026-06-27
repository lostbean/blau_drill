//// The top-down PCB view, rendered as a Lustre SVG view.
////
//// It renders the FR4 substrate, the drill holes (coloured by tool, or by
//// drilled/pending status during a run), the optional board outline, fiducial
//// registration markers (captured / current / pending), and a live rotating
//// machine-head crosshair whose styling reflects head confidence. Zoom (1x-12x)
//// and a tool legend are included. It is a PURE VIEW: zoom lives in the model,
//// and all motion/gating is decided upstream.
////
//// ## Projection
////
//// The viewBox is sized to the board's OWN aspect ratio (plus PAD), so
//// `preserveAspectRatio="xMidYMid meet"` letterboxes the whole board into the
//// container without cropping — width AND height. One board mm = one viewBox
//// unit. Y is FLIPPED (board +Y is up, SVG +Y is down).
////
//// ## Interactions (emit Lustre Msgs)
////
////   * Click a fiducial marker → `SetCurrentTarget(index)` (select + jump).
////   * Enter/Space on a focused fiducial → same (keyboard a11y).
////   * Click anywhere on the board during Align → `JumpTo(board_point)` (the
////     SVG click is converted to board coords via `canvas_ffi` + the inverse
////     projection here).
////   * Zoom buttons → `ZoomIn` / `ZoomOut` / `ResetView`.

import blau_drill/ui/model.{
  type Fiducial, type Head, type HeadConfidence, type HeadPosOpt, type Hole,
  type PointResidual, type Tool, Active, Align, Captured, ConfAligned,
  ConfEstimate, ConfNone, ConfRough, Current, FidPending, HaveHeadPos, HoleDone,
  JumpTo, NoHeadPos, Pending, SetCurrentTarget,
}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute as a
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/element/svg
import lustre/event

// viewBox padding in board units (mm), so edge marks aren't clipped.
const pad = 8.0

const min_zoom = 1.0

const max_zoom = 12.0

// A stable palette assigned to tools in id order (cyan-ish first).
const palette = [
  "#00ffff", "#ffb300", "#40e56c", "#c792ea", "#ff6e6e", "#82aaff",
]

/// Everything the canvas needs to render. Built by the caller (`stages.gleam`)
/// from the model so the canvas stays a stateless view.
///
/// The canvas is ORIENTATION-AGNOSTIC: it draws the points it is given. Any
/// board flip (front/back, copper-up) is baked into the WORKING board upstream
/// (`bridge.working_board_model`), so there is no mirror logic here.
pub type CanvasData {
  CanvasData(
    holes: List(Hole),
    outline: List(#(Float, Float)),
    fiducials: List(Fiducial),
    tools: List(Tool),
    bbox: model.BBox,
    head: Head,
    head_pos: HeadPosOpt,
    head_confidence: HeadConfidence,
    stage: model.Screen,
    zoom: Float,
    /// Per-captured-fiducial residuals from the last fit, keyed by the
    /// fiducial's `index`. Empty before a fit (no annotations drawn). Populated
    /// from the `projection.fit_diag` projection by `stages.canvas_data`.
    point_residuals: List(PointResidual),
    /// The fiducial index of the WORST residual, or -1 when none (no fit yet).
    /// The marker at this index is highlighted distinctly.
    worst_index: Int,
  )
}

// ── residual lookup (pure; unit-tested) ──────────────────────────────────────

/// The residual error (mm) for the captured fiducial at `idx`, if the last fit
/// produced one. `None` means no annotation (uncaptured point, or pre-fit).
pub fn residual_for(residuals: List(PointResidual), idx: Int) -> Option(Float) {
  case list.find(residuals, fn(r) { r.index == idx }) {
    Ok(r) -> Some(r.error_mm)
    Error(_) -> None
  }
}

/// Whether the fiducial at `idx` is the worst-residual point. `worst_index` is
/// -1 when there is no fit, so no fiducial is ever flagged pre-fit.
pub fn is_worst_index(worst_index: Int, idx: Int) -> Bool {
  worst_index >= 0 && worst_index == idx
}

/// Resolve the worst fiducial index from a `WorstOpt`: the worst point's index,
/// or -1 when there is no worst (degenerate / no fit).
pub fn worst_index_of(worst: model.WorstOpt) -> Int {
  case worst {
    model.HaveWorst(w) -> w.index
    model.NoWorst -> -1
  }
}

// ── span / projection ───────────────────────────────────────────────────────

type Span {
  Span(w: Float, h: Float, minx: Float, miny: Float)
}

fn span(bbox: model.BBox) -> Span {
  let w = float.max(bbox.maxx -. bbox.minx, 0.001) +. 2.0 *. pad
  let h = float.max(bbox.maxy -. bbox.miny, 0.001) +. 2.0 *. pad
  Span(w:, h:, minx: bbox.minx, miny: bbox.miny)
}

// Board point -> viewBox point. Y is flipped (math→screen); X is a straight
// shift. Any board flip is applied upstream (working board), not here.
fn project(sp: Span, x: Float, y: Float) -> #(Float, Float) {
  let px = x -. sp.minx +. pad
  let py = sp.h -. { y -. sp.miny +. pad }
  #(px, py)
}

// Inverse of project: a viewBox point -> board coords.
fn unproject(sp: Span, sx: Float, sy: Float) -> #(Float, Float) {
  let bx = sx -. pad +. sp.minx
  let by = sp.miny +. { sp.h -. sy } -. pad
  #(bx, by)
}

/// Test seam: project a board point to the viewBox then unproject it back, for a
/// given bbox. MUST return the original point (within float epsilon) — that
/// round-trip is what guarantees click-to-jump lands on the right hole. The
/// canvas no longer mirrors (the flip lives in the working board), so this is a
/// straight projection round-trip.
pub fn roundtrip_board_point(
  bbox: model.BBox,
  x: Float,
  y: Float,
) -> #(Float, Float) {
  let sp = span(bbox)
  let #(sx, sy) = project(sp, x, y)
  unproject(sp, sx, sy)
}

// viewBox string, centred, clamped so the window stays inside the span.
fn view_box_str(sp: Span, zoom: Float) -> String {
  let z = float.min(float.max(zoom, min_zoom), max_zoom)
  let vw = sp.w /. z
  let vh = sp.h /. z
  // centred pan (0.5, 0.5); clamp so the window stays inside the board span.
  let cx = clamp(0.5, vw /. 2.0 /. sp.w, 1.0 -. vw /. 2.0 /. sp.w)
  let cy = clamp(0.5, vh /. 2.0 /. sp.h, 1.0 -. vh /. 2.0 /. sp.h)
  let x = cx *. sp.w -. vw /. 2.0
  let y = cy *. sp.h -. vh /. 2.0
  num(x) <> " " <> num(y) <> " " <> num(vw) <> " " <> num(vh)
}

fn clamp(v: Float, lo: Float, hi: Float) -> Float {
  // lo can exceed hi at zoom 1; guard so the centre stays valid.
  case lo >. hi {
    True -> 0.5
    False -> float.min(float.max(v, lo), hi)
  }
}

// A constant on-screen mark size regardless of zoom (divide by zoom).
fn mark(zoom: Float) -> Float {
  1.0 /. float.min(float.max(zoom, min_zoom), max_zoom)
}

// ── tool colours ────────────────────────────────────────────────────────────

fn tool_color(tools: List(Tool), id: String) -> String {
  let sorted = list.sort(tools, fn(x, y) { string.compare(x.id, y.id) })
  let idx =
    list.index_fold(sorted, Error(Nil), fn(acc, t, i) {
      case t.id == id {
        True -> Ok(i)
        False -> acc
      }
    })
  case idx {
    Ok(i) -> pick_palette(i)
    Error(_) -> "#00ffff"
  }
}

fn pick_palette(i: Int) -> String {
  let n = list.length(palette)
  case list.drop(palette, i % n) {
    [c, ..] -> c
    [] -> "#00ffff"
  }
}

fn tool_diameter(tools: List(Tool), id: String) -> Float {
  case list.find(tools, fn(t) { t.id == id }) {
    Ok(t) -> t.diameter
    Error(_) -> 0.8
  }
}

// ── the view ────────────────────────────────────────────────────────────────

pub fn view(data: CanvasData) -> Element(model.Msg) {
  let sp = span(data.bbox)
  let mk = mark(data.zoom)
  let interactive = data.stage == Align

  let board_svg =
    svg.svg(
      [
        a.attribute("viewBox", view_box_str(sp, data.zoom)),
        a.attribute("preserveAspectRatio", "xMidYMid meet"),
        a.attribute("role", case interactive {
          True -> "application"
          False -> "img"
        }),
        a.attribute("aria-label", "PCB board view"),
        a.class(case interactive {
          True -> "board-svg clickable"
          False -> "board-svg"
        }),
        // click-to-jump (only during alignment)
        ..case interactive {
          True -> [event.on("click", board_click_decoder(sp))]
          False -> []
        }
      ],
      list.flatten([
        substrate(sp, mk),
        outline_path(sp, data.outline, mk),
        list.map(data.holes, fn(hole) { hole_circle(sp, data.tools, hole, mk) }),
        list.map(data.fiducials, fn(fid) {
          fiducial(
            sp,
            fid,
            mk,
            data.point_residuals,
            data.worst_index,
            data.stage,
          )
        }),
        head_marker(sp, data.head_pos, data.head_confidence, mk),
      ]),
    )

  h.div([a.class("board-canvas")], [
    board_svg,
    head_confidence_caption(data.stage, data.head_confidence),
    zoom_controls(data.zoom),
    legend(data.tools),
  ])
}

// ── substrate + grid ────────────────────────────────────────────────────────

fn substrate(sp: Span, mk: Float) -> List(Element(model.Msg)) {
  [
    svg.defs([], [
      svg.pattern(
        [
          a.attribute("id", "grid"),
          a.attribute("width", "5"),
          a.attribute("height", "5"),
          a.attribute("patternUnits", "userSpaceOnUse"),
        ],
        [
          svg.path([
            a.attribute("d", "M5 0 L0 0 0 5"),
            a.attribute("fill", "none"),
            a.attribute("stroke", "#2a7a31"),
            a.attribute("stroke-width", num(0.15 *. mk)),
          ]),
        ],
      ),
    ]),
    svg.rect([
      a.attribute("x", "0"),
      a.attribute("y", "0"),
      a.attribute("width", num(sp.w)),
      a.attribute("height", num(sp.h)),
      a.attribute("fill", "#1b5e20"),
    ]),
    svg.rect([
      a.attribute("x", "0"),
      a.attribute("y", "0"),
      a.attribute("width", num(sp.w)),
      a.attribute("height", num(sp.h)),
      a.attribute("fill", "url(#grid)"),
    ]),
  ]
}

fn outline_path(
  sp: Span,
  outline: List(#(Float, Float)),
  mk: Float,
) -> List(Element(model.Msg)) {
  case outline {
    [] -> []
    pts -> {
      let d =
        pts
        |> list.index_map(fn(pt, i) {
          let #(px, py) = project(sp, pt.0, pt.1)
          let cmd = case i {
            0 -> "M"
            _ -> "L"
          }
          cmd <> num(px) <> "," <> num(py)
        })
        |> string.join(" ")
      [
        svg.path([
          a.attribute("d", d <> " Z"),
          a.attribute("fill", "none"),
          a.attribute("stroke", "#40e56c"),
          a.attribute("stroke-width", num(0.2 *. mk)),
          a.attribute("opacity", "0.5"),
        ]),
      ]
    }
  }
}

// ── holes ───────────────────────────────────────────────────────────────────

fn hole_circle(
  sp: Span,
  tools: List(Tool),
  hole: Hole,
  mk: Float,
) -> Element(model.Msg) {
  let #(px, py) = project(sp, hole.x, hole.y)
  let true_r = tool_diameter(tools, hole.tool) /. 2.0
  let base_r = float.max(true_r, 0.35 *. mk)
  let r = case hole.status {
    Active -> base_r *. 1.5
    _ -> base_r
  }
  let stroke = hole_fill(hole, tools)
  let fill = case hole.status {
    Pending -> "none"
    _ -> stroke
  }
  let cls = case hole.status {
    HoleDone -> "hole done"
    Active -> "hole active"
    Pending -> "hole"
  }
  svg.circle([
    a.attribute("cx", num(px)),
    a.attribute("cy", num(py)),
    a.attribute("r", num(r)),
    a.attribute("fill", fill),
    a.attribute("stroke", stroke),
    a.attribute("stroke-width", num(0.18 *. mk)),
    a.class(cls),
  ])
}

fn hole_fill(hole: Hole, tools: List(Tool)) -> String {
  case hole.status {
    HoleDone -> "#00c853"
    Active -> "#ffb4ab"
    Pending -> tool_color(tools, hole.tool)
  }
}

// ── fiducials ───────────────────────────────────────────────────────────────

fn fiducial(
  sp: Span,
  fid: Fiducial,
  mk: Float,
  residuals: List(PointResidual),
  worst_index: Int,
  stage: model.Screen,
) -> Element(model.Msg) {
  let #(px, py) = project(sp, fid.x, fid.y)
  // Gate marker selection on the Align stage — mirrors the board-level
  // `interactive = data.stage == Align`. A pending fiducial is rendered in every
  // stage (its canvas data persists), but `SetCurrentTarget` is meaningless
  // outside Align, so no marker is clickable elsewhere.
  let clickable =
    stage == Align && { fid.state == FidPending || fid.state == Current }
  // Only captured fiducials carry a residual; uncaptured points have no error.
  let residual = case fid.state {
    Captured -> residual_for(residuals, fid.index)
    _ -> None
  }
  let worst = is_worst_index(worst_index, fid.index)
  let cls = case worst {
    True -> "fid " <> fid_class(fid.state) <> " fid-worst"
    False -> "fid " <> fid_class(fid.state)
  }
  let attrs =
    list.flatten([
      [a.class(cls)],
      case clickable {
        True -> [
          a.attribute("role", "button"),
          a.tabindex(0),
          a.attribute("aria-label", fid_aria(fid)),
          // marker click selects + jumps; stop the board-level jump too.
          event.advanced("click", select_decoder(fid.index)),
          event.on("keydown", key_select_decoder(fid.index)),
        ]
        False -> [a.attribute("aria-label", fid_aria(fid))]
      },
    ])
  let shapes =
    list.append(
      fid_shapes(fid.state, px, py, mk),
      residual_label(residual, worst, px, py, mk),
    )
  svg.g(attrs, shapes)
}

// A small mono residual label (mm) drawn just up-and-right of a captured
// fiducial marker, so it doesn't sit on the crosshair. Worst point gets the
// error-colour class; others the neutral residual class. No residual → nothing.
fn residual_label(
  residual: Option(Float),
  worst: Bool,
  px: Float,
  py: Float,
  mk: Float,
) -> List(Element(model.Msg)) {
  case residual {
    None -> []
    Some(err) -> {
      let cls = case worst {
        True -> "fid-residual-label worst"
        False -> "fid-residual-label"
      }
      [
        svg.text(
          [
            a.attribute("x", num(px +. 2.0 *. mk)),
            a.attribute("y", num(py -. 1.6 *. mk)),
            a.attribute("font-size", num(1.6 *. mk)),
            a.attribute("font-family", "var(--font-data)"),
            a.class(cls),
          ],
          fmt_mm(err),
        ),
      ]
    }
  }
}

// Residual error formatted compactly (2dp) for the on-board label, e.g. "1.43".
fn fmt_mm(f: Float) -> String {
  float.to_string(round2(f))
}

fn fid_class(state: model.FiducialState) -> String {
  case state {
    Captured -> "captured"
    Current -> "current"
    FidPending -> "pending"
  }
}

fn fid_aria(fid: Fiducial) -> String {
  let n = int.to_string(fid.index + 1)
  case fid.state {
    Captured -> "Fiducial " <> n <> " captured"
    Current -> "Fiducial " <> n <> " — current target, select"
    FidPending -> "Fiducial " <> n <> " — pending, select as target"
  }
}

fn fid_shapes(
  state: model.FiducialState,
  px: Float,
  py: Float,
  mk: Float,
) -> List(Element(model.Msg)) {
  case state {
    Captured -> [
      svg.circle([
        a.attribute("cx", num(px)),
        a.attribute("cy", num(py)),
        a.attribute("r", num(1.6 *. mk)),
        a.attribute("fill", "none"),
        a.attribute("stroke-width", num(0.3 *. mk)),
      ]),
      svg.path([
        a.attribute(
          "d",
          "M"
            <> num(px -. 0.7 *. mk)
            <> ","
            <> num(py)
            <> " l"
            <> num(0.45 *. mk)
            <> ","
            <> num(0.55 *. mk)
            <> " l"
            <> num(0.8 *. mk)
            <> ","
            <> num(-1.1 *. mk),
        ),
        a.attribute("fill", "none"),
        a.attribute("stroke", "#40e56c"),
        a.attribute("stroke-width", num(0.3 *. mk)),
        a.attribute("stroke-linecap", "round"),
        a.attribute("stroke-linejoin", "round"),
      ]),
    ]
    Current ->
      list.flatten([
        [
          svg.circle([
            a.attribute("cx", num(px)),
            a.attribute("cy", num(py)),
            a.attribute("r", num(2.4 *. mk)),
            a.attribute("fill", "none"),
            a.attribute("stroke-width", num(0.4 *. mk)),
          ]),
        ],
        cross_ticks(px, py, mk, 1.6, 3.2, 0.3),
        [
          svg.circle([
            a.attribute("cx", num(px)),
            a.attribute("cy", num(py)),
            a.attribute("r", num(0.5 *. mk)),
            a.attribute("fill", "#ffb300"),
          ]),
        ],
      ])
    FidPending -> [
      svg.circle([
        a.attribute("cx", num(px)),
        a.attribute("cy", num(py)),
        a.attribute("r", num(1.3 *. mk)),
        a.attribute("fill", "none"),
        a.attribute("stroke-width", num(0.25 *. mk)),
      ]),
      svg.circle([
        a.attribute("cx", num(px)),
        a.attribute("cy", num(py)),
        a.attribute("r", num(0.35 *. mk)),
        a.attribute("fill", "#ffb300"),
      ]),
    ]
  }
}

// Four crosshair ticks with a centre gap: inner..outer arms, given stroke.
fn cross_ticks(
  px: Float,
  py: Float,
  mk: Float,
  inner: Float,
  outer: Float,
  sw: Float,
) -> List(Element(model.Msg)) {
  let inn = inner *. mk
  let out = outer *. mk
  let w = num(sw *. mk)
  [
    tick(px -. out, py, px -. inn, py, w),
    tick(px +. inn, py, px +. out, py, w),
    tick(px, py -. out, px, py -. inn, w),
    tick(px, py +. inn, px, py +. out, w),
  ]
}

fn tick(
  x1: Float,
  y1: Float,
  x2: Float,
  y2: Float,
  w: String,
) -> Element(model.Msg) {
  svg.line([
    a.attribute("x1", num(x1)),
    a.attribute("y1", num(y1)),
    a.attribute("x2", num(x2)),
    a.attribute("y2", num(y2)),
    a.attribute("stroke-width", w),
  ])
}

// ── live head crosshair ─────────────────────────────────────────────────────

fn head_marker(
  sp: Span,
  head_pos: HeadPosOpt,
  conf: HeadConfidence,
  mk: Float,
) -> List(Element(model.Msg)) {
  case head_pos {
    NoHeadPos -> []
    HaveHeadPos(#(bx, by)) -> {
      let #(px, py) = project(sp, bx, by)
      let arm = 2.4 *. mk
      let gap = 0.7 *. mk
      let sw = num(0.22 *. mk)
      let cls = case conf {
        ConfAligned -> "head"
        _ -> "head estimate"
      }
      [
        svg.g([a.class(cls)], [
          head_tick(px -. arm, py, px -. gap, py, sw),
          head_tick(px +. gap, py, px +. arm, py, sw),
          head_tick(px, py -. arm, px, py -. gap, sw),
          head_tick(px, py +. gap, px, py +. arm, sw),
          svg.circle([
            a.attribute("cx", num(px)),
            a.attribute("cy", num(py)),
            a.attribute("r", num(0.3 *. mk)),
            a.attribute("fill", "#22d3ee"),
          ]),
        ]),
      ]
    }
  }
}

fn head_tick(
  x1: Float,
  y1: Float,
  x2: Float,
  y2: Float,
  sw: String,
) -> Element(model.Msg) {
  svg.line([
    a.attribute("x1", num(x1)),
    a.attribute("y1", num(y1)),
    a.attribute("x2", num(x2)),
    a.attribute("y2", num(y2)),
    a.attribute("stroke", "#22d3ee"),
    a.attribute("stroke-width", sw),
    a.attribute("stroke-linecap", "round"),
  ])
}

// ── overlays: caption / zoom / legend ───────────────────────────────────────

fn head_confidence_caption(
  stage: model.Screen,
  conf: HeadConfidence,
) -> Element(model.Msg) {
  case stage {
    Align -> {
      let #(cls, text) = case conf {
        ConfNone -> #("none", "HEAD: not yet located — capture a point")
        ConfEstimate -> #("estimate", "HEAD: estimated (1 point)")
        ConfRough -> #("rough", "HEAD: rough (2 points)")
        ConfAligned -> #("aligned", "HEAD: aligned")
      }
      h.div([a.class("head-confidence " <> cls)], [h.text(text)])
    }
    _ -> element.none()
  }
}

fn zoom_controls(zoom: Float) -> Element(model.Msg) {
  let pct = int.to_string(float.round(zoom *. 100.0)) <> "%"
  h.div([a.class("zoom-controls")], [
    h.button(
      [
        a.attribute("type", "button"),
        a.attribute("aria-label", "Zoom in"),
        a.attribute("title", "Zoom in"),
        event.on_click(model.ZoomIn),
      ],
      [h.text("+")],
    ),
    h.button(
      [
        a.attribute("type", "button"),
        a.attribute("aria-label", "Zoom out"),
        a.attribute("title", "Zoom out"),
        event.on_click(model.ZoomOut),
      ],
      [h.text("−")],
    ),
    h.button(
      [
        a.attribute("type", "button"),
        a.class("reset"),
        a.attribute("aria-label", "Fit board"),
        a.attribute("title", "Fit board"),
        event.on_click(model.ResetView),
      ],
      [h.text("⤢")],
    ),
    h.span([a.class("zoom-level")], [h.text(pct)]),
  ])
}

fn legend(tools: List(Tool)) -> Element(model.Msg) {
  case tools {
    [] -> element.none()
    _ -> {
      let sorted = list.sort(tools, fn(x, y) { string.compare(x.id, y.id) })
      h.div(
        [a.class("legend")],
        [h.span([a.class("legend-title")], [h.text("Tool Legend")])]
          |> list.append(
            list.map(sorted, fn(t) {
              h.span([a.class("legend-row")], [
                h.span(
                  [
                    a.class("dot"),
                    a.style("background", tool_color(tools, t.id)),
                  ],
                  [],
                ),
                h.text(t.id <> " — " <> num(t.diameter) <> "mm"),
              ])
            }),
          ),
      )
    }
  }
}

// ── event decoders ──────────────────────────────────────────────────────────

// Decode an SVG board click into a JumpTo(board_point). The FFI gives us the
// SVG-user-space point (handling the CTM/letterbox); we unproject to board.
fn board_click_decoder(sp: Span) -> decode.Decoder(model.Msg) {
  decode.dynamic
  |> decode.map(fn(event) {
    let #(sx, sy) = svg_point_from_click(event)
    JumpTo(unproject(sp, sx, sy))
  })
}

// Fiducial click → select + jump, with stop_propagation so the board-level
// JumpTo doesn't also fire.
fn select_decoder(index: Int) -> decode.Decoder(event.Handler(model.Msg)) {
  decode.success(event.handler(SetCurrentTarget(index), True, True))
}

// Enter / Space on a focused fiducial selects it.
fn key_select_decoder(index: Int) -> decode.Decoder(model.Msg) {
  use key <- decode.field("key", decode.string)
  case key {
    "Enter" | " " -> decode.success(SetCurrentTarget(index))
    _ -> decode.failure(SetCurrentTarget(index), "key")
  }
}

@external(javascript, "./canvas_ffi.mjs", "svg_point_from_click")
fn svg_point_from_click(event: Dynamic) -> #(Float, Float)

// ── small helpers ───────────────────────────────────────────────────────────

// Format a float compactly for SVG attrs (2dp, trims trailing zeros lightly).
fn num(f: Float) -> String {
  float.to_string(round2(f))
}

fn round2(f: Float) -> Float {
  int.to_float(float.round(f *. 100.0)) /. 100.0
}
