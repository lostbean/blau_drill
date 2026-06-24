//// Mock data for the Phase 3 UI demo. Everything here is a stand-in for what
//// the `domain` / `control` layers will provide in Phase 4:
////
////   * `board()` — a small synthetic PCB: a grid of holes across 3 tools, a
////     bounding box, an outline, and 4 corner registration candidates. Replace
////     with a parsed `BoardModel` (domain) in Phase 4.
////   * `diagnostic()` — the parse summary derived from the mock board.
////   * `default_config()` — the working printer config seed (matches the
////     reference defaults). Phase 4 reads `Config.current()`.
////
//// Keeping all mock data in one module makes the Phase 4 swap a single-file
//// change: delete this, point the model at real domain/control.

import blau_drill/ui/model.{
  type Board, type Config, type Diagnostic, type Fiducial, type Hole, type Tool,
  BBox, Board, Config, Diagnostic, FidPending, Fiducial, Hole, Pending, Tool,
}
import gleam/int
import gleam/list

// The three tools on the mock board, in id order. Diameters in mm.
pub fn tools() -> List(Tool) {
  [Tool("T1", 0.6), Tool("T2", 0.8), Tool("T3", 1.2)]
}

// A grid of holes, plus a few off-grid ones, spread across the three tools so
// the legend and per-tool colouring are exercised. Board coords in mm.
pub fn holes() -> List(Hole) {
  let grid =
    list.flat_map([0, 1, 2, 3, 4, 5], fn(col) {
      list.map([0, 1, 2, 3], fn(row) {
        let x = 12.0 +. int.to_float(col) *. 14.0
        let y = 12.0 +. int.to_float(row) *. 18.0
        // Alternate the tool by position so colours interleave.
        let tool = case { col + row } % 3 {
          0 -> "T1"
          1 -> "T2"
          _ -> "T3"
        }
        Hole(x, y, tool, Pending)
      })
    })
  // A couple of larger mounting holes near corners (tool T3).
  let mounts = [
    Hole(6.0, 6.0, "T3", Pending),
    Hole(94.0, 6.0, "T3", Pending),
    Hole(6.0, 80.0, "T3", Pending),
    Hole(94.0, 80.0, "T3", Pending),
  ]
  list.append(grid, mounts)
}

// The board bounding box (mm).
pub fn bbox() -> model.BBox {
  BBox(0.0, 0.0, 100.0, 86.0)
}

// A rectangular outline tracing the board edge (Edge.Cuts equivalent), with a
// clipped corner so it reads as a real outline rather than just the bbox.
pub fn outline() -> List(#(Float, Float)) {
  [
    #(0.0, 0.0),
    #(100.0, 0.0),
    #(100.0, 72.0),
    #(86.0, 86.0),
    #(0.0, 86.0),
  ]
}

// The four corner registration candidates (board coords) the operator aligns
// to — the nearest distinctive holes to each bbox corner.
pub fn candidates() -> List(#(Float, Float)) {
  [#(6.0, 6.0), #(94.0, 6.0), #(94.0, 80.0), #(6.0, 80.0)]
}

pub fn board() -> Board {
  Board(
    holes: holes(),
    tools: tools(),
    bbox: bbox(),
    outline: outline(),
    candidates: candidates(),
  )
}

pub fn diagnostic() -> Diagnostic {
  let b = bbox()
  Diagnostic(
    hole_count: list.length(holes()),
    tool_count: list.length(tools()),
    width: b.maxx -. b.minx,
    height: b.maxy -. b.miny,
  )
}

// The pending (un-captured) fiducials built from the candidate list, with the
// first one marked Current. Captured ones are carried separately in the model.
pub fn pending_fiducials(current_target: Int) -> List(Fiducial) {
  candidates()
  |> list.index_map(fn(pt, i) {
    let #(x, y) = pt
    let state = case i == current_target {
      True -> model.Current
      False -> FidPending
    }
    Fiducial(x, y, i, state)
  })
}

pub fn default_config() -> Config {
  Config(
    baud: "115200",
    auto_connect: False,
    app_pause: True,
    max_x: "300.00",
    max_y: "200.00",
    max_z: "50.00",
    spindle_on: "M3 S255",
    spindle_off: "M5",
    pwm_max: "255",
    spindle_speed: "200",
    zdrill: "-1.5",
    zsafe: "3.0",
    zchange: "15.0",
    drill_feed: "120",
    hover: "1.0",
  )
}
