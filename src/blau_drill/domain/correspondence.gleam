//// A single captured **board <-> machine** pair — the raw material of
//// alignment.
////
//// A `Correspondence` records that a particular board feature point (`board`,
//// in board coordinates) is physically located at a particular machine point
//// (`machine`, the printer-head XY read back via `M114`) at a particular
//// machine Z (`machine_z`, the height the bit was jogged down to onto the pad).
//// All fields are mandatory — a correspondence with a missing point is
//// unrepresentable here because the constructor takes them all.

import blau_drill/domain/transform2d.{type Point}

/// A captured registration pair.
///
/// * `board` — the feature's location in **board coordinates** `#(bx, by)`.
/// * `machine` — where the head was in **machine XY** `#(mx, my)` when the
///   operator located that feature.
/// * `machine_z` — the **machine Z** the bit was jogged down to onto the pad
///   during 2.5D alignment. Feeds the fitted board surface plane.
pub type Correspondence {
  Correspondence(board: Point, machine: Point, machine_z: Float)
}
