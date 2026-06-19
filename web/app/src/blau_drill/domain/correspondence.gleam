//// A single captured **board <-> machine** pair — the raw material of
//// alignment. Ported from `BlauDrill.Correspondence`.
////
//// A `Correspondence` records that a particular board feature point (`board`,
//// in board coordinates) is physically located at a particular machine point
//// (`machine`, the printer-head position read back via `M114`). Both fields are
//// mandatory — a correspondence with only one point is unrepresentable here
//// because the constructor takes both.

import blau_drill/domain/transform2d.{type Point}

/// A captured registration pair.
///
/// * `board` — the feature's location in **board coordinates** `#(bx, by)`.
/// * `machine` — where the head was when the operator located that feature, in
///   **machine coordinates** `#(mx, my)`.
pub type Correspondence {
  Correspondence(board: Point, machine: Point)
}
