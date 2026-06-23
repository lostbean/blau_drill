//// Unit tests for `bridge.board_xform` and `bridge.working_board` — the pure
//// core of the board-transform pipeline. `working_board` applies ONE transform
//// (identity for `Front`, an X-mirror about the board centre for `Back`) to
//// every coordinate of the parsed board, recomputing the bbox from the
//// transformed holes. These guard the two key invariants:
////   * Front is a no-op: `working_board(bm, Front) == board_of(bm)`.
////   * Back mirrors X about centre while preserving the footprint (width) and
////     the hole count / tool tags.

import blau_drill/domain/board_model
import blau_drill/domain/transform2d
import blau_drill/ui/bridge
import blau_drill/ui/model
import gleam/dict
import gleam/float
import gleam/list
import gleeunit/should

import blau_drill/fixtures

const eps = 1.0e-9

fn close(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. eps
}

fn point_close(a: #(Float, Float), b: #(Float, Float)) -> Bool {
  close(a.0, b.0) && close(a.1, b.1)
}

// Parse the real segby fixture into a domain BoardModel.
fn board() -> board_model.BoardModel {
  let assert Ok(bm) = board_model.parse_drl(fixtures.segby_drl())
  bm
}

fn assert_each(xs: List(a), f: fn(a) -> b) -> Nil {
  case xs {
    [] -> Nil
    [first, ..rest] -> {
      f(first)
      assert_each(rest, f)
    }
  }
}

// ── board_xform ───────────────────────────────────────────────────────────────

pub fn board_xform_front_is_identity_test() {
  let bm = board()
  bridge.board_xform(model.Front, bm.bbox)
  |> should.equal(transform2d.identity())
}

pub fn board_xform_back_mirrors_about_centre_test() {
  let bm = board()
  let #(minx, _miny, maxx, _maxy) = bm.bbox
  let cx = { minx +. maxx } /. 2.0
  let m = bridge.board_xform(model.Back, bm.bbox)
  // A point at the centre is fixed; an arbitrary point flips to 2*cx - x.
  assert point_close(transform2d.apply(m, #(cx, 3.0)), #(cx, 3.0))
  assert point_close(transform2d.apply(m, #(minx, 9.0)), #(maxx, 9.0))
  assert point_close(transform2d.apply(m, #(maxx, 9.0)), #(minx, 9.0))
}

pub fn board_xform_back_is_an_involution_test() {
  // compose(Back, Back) ≈ identity (mirror about centre twice = identity).
  let bm = board()
  let m = bridge.board_xform(model.Back, bm.bbox)
  let twice = transform2d.compose(m, m)
  [#(0.0, 0.0), #(-57.15, 80.01), #(-7.616, 6.35), #(0.0, 10.668)]
  |> assert_each(fn(p) {
    assert point_close(
      transform2d.apply(twice, p),
      transform2d.apply(transform2d.identity(), p),
    )
  })
}

// ── working_board: Front is a no-op ───────────────────────────────────────────

pub fn working_board_front_equals_board_of_test() {
  let bm = board()
  bridge.working_board(bm, model.Front)
  |> should.equal(bridge.board_of(bm))
}

// ── working_board: Back flips X about centre ──────────────────────────────────

pub fn working_board_back_flips_x_keeps_y_test() {
  let bm = board()
  let #(minx, _miny, maxx, _maxy) = bm.bbox
  let cx = { minx +. maxx } /. 2.0

  let front = bridge.board_of(bm)
  let back = bridge.working_board(bm, model.Back)

  // Same number of holes, in the same order; each Back hole is the Front hole
  // mirrored in X about cx, with Y and the tool tag unchanged.
  list.zip(front.holes, back.holes)
  |> assert_each(fn(pair) {
    let #(f, b) = pair
    close(b.x, 2.0 *. cx -. f.x) |> should.be_true
    close(b.y, f.y) |> should.be_true
    should.equal(b.tool, f.tool)
    should.equal(b.status, f.status)
  })
}

pub fn working_board_back_preserves_hole_and_tool_count_test() {
  let bm = board()
  let back = bridge.working_board(bm, model.Back)
  // segby: 130 holes, 5 tools.
  list.length(back.holes) |> should.equal(130)
  list.length(back.tools) |> should.equal(5)
}

pub fn working_board_back_tools_unchanged_test() {
  let bm = board()
  bridge.working_board(bm, model.Back).tools
  |> should.equal(bridge.board_of(bm).tools)
}

// ── working_board: Back preserves the footprint ───────────────────────────────

pub fn working_board_back_preserves_width_test() {
  let bm = board()
  let #(minx, _miny, maxx, _maxy) = bm.bbox
  let raw_width = maxx -. minx

  let back = bridge.working_board(bm, model.Back)
  let work_width = back.bbox.maxx -. back.bbox.minx

  // Mirroring about centre keeps the width.
  close(work_width, raw_width) |> should.be_true
  // The bbox is recomputed (not corners-transformed), so minx < maxx still.
  { back.bbox.minx <. back.bbox.maxx } |> should.be_true
  { back.bbox.miny <. back.bbox.maxy } |> should.be_true
}

pub fn working_board_back_bbox_from_transformed_holes_test() {
  // The recomputed bbox X-range equals the mirror of the front's X-range:
  // back.minx = 2*cx - front.maxx, back.maxx = 2*cx - front.minx; Y unchanged.
  let bm = board()
  let #(minx, miny, maxx, maxy) = bm.bbox
  let cx = { minx +. maxx } /. 2.0

  let back = bridge.working_board(bm, model.Back)
  close(back.bbox.minx, 2.0 *. cx -. maxx) |> should.be_true
  close(back.bbox.maxx, 2.0 *. cx -. minx) |> should.be_true
  close(back.bbox.miny, miny) |> should.be_true
  close(back.bbox.maxy, maxy) |> should.be_true
}

// ── working_board: candidates / outline live in the transformed space ─────────

pub fn working_board_back_candidates_are_transformed_holes_test() {
  let bm = board()
  let back = bridge.working_board(bm, model.Back)
  let hole_points = list.map(back.holes, fn(h) { #(h.x, h.y) })
  // Every candidate sits on an actual (transformed) hole in the working board.
  list.all(back.candidates, fn(c) {
    list.any(hole_points, fn(hp) { point_close(hp, c) })
  })
  |> should.be_true
}

// ── working_board_model: the single transformed source ────────────────────────
// The g-code is built from the JOB's BoardModel, and `job.new` takes a
// BoardModel; the working transform therefore produces a transformed BoardModel
// the canvas AND the job (hence the g-code) both derive from. The flip lives in
// exactly one place.

pub fn working_board_model_front_is_a_no_op_test() {
  // Front MUST be the identity: the working model equals the parsed model.
  let bm = board()
  bridge.working_board_model(bm, model.Front)
  |> should.equal(bm)
}

pub fn working_board_model_back_mirrors_x_keeps_y_and_tool_test() {
  let bm = board()
  let #(minx, _miny, maxx, _maxy) = bm.bbox
  let cx = { minx +. maxx } /. 2.0
  let back = bridge.working_board_model(bm, model.Back)

  // Same number of holes in the same order; each Back hole is the Front hole
  // mirrored in X about cx, with Y and the tool tag unchanged.
  list.zip(bm.holes, back.holes)
  |> assert_each(fn(pair) {
    let #(f, b) = pair
    close(b.x, 2.0 *. cx -. f.x) |> should.be_true
    close(b.y, f.y) |> should.be_true
    should.equal(b.tool, f.tool)
  })
}

pub fn working_board_model_back_preserves_counts_test() {
  // segby: 130 holes, 5 tools.
  let bm = board()
  let back = bridge.working_board_model(bm, model.Back)
  list.length(back.holes) |> should.equal(130)
  dict.size(back.tools) |> should.equal(5)
}

pub fn working_board_model_back_preserves_width_test() {
  let bm = board()
  let #(minx, _miny, maxx, _maxy) = bm.bbox
  let raw_width = maxx -. minx

  let back = bridge.working_board_model(bm, model.Back)
  let #(bminx, bminy, bmaxx, bmaxy) = back.bbox
  // Mirroring about centre keeps the width; the bbox is recomputed fresh.
  close(bmaxx -. bminx, raw_width) |> should.be_true
  { bminx <. bmaxx } |> should.be_true
  { bminy <. bmaxy } |> should.be_true
}

pub fn working_board_model_back_tools_pass_through_test() {
  let bm = board()
  bridge.working_board_model(bm, model.Back).tools
  |> should.equal(bm.tools)
}

// ── working_board_model: the fix direction (consistency of click-to-jump) ─────
// The bug: in Back view, a screen click drove the head the OPPOSITE machine X.
// The fix flips the geometry ONCE, so a hole that was at small board-X is now at
// large board-X. Since the canvas no longer inverts, the machine mapping (and
// thus click-to-jump) is consistent in both orientations. This pins the flip
// direction on the working model — the single source the g-code derives from.

pub fn working_board_model_back_flips_small_x_to_large_x_test() {
  let bm = board()
  let #(minx, _miny, maxx, _maxy) = bm.bbox
  let cx = { minx +. maxx } /. 2.0

  // The hole with the smallest board-X in the parsed model.
  let assert [first, ..rest] = bm.holes
  let leftmost =
    list.fold(rest, first, fn(acc, h) {
      case h.x <. acc.x {
        True -> h
        False -> acc
      }
    })

  let back = bridge.working_board_model(bm, model.Back)
  // Its mirror in the working model lands on the far (large-X) side of centre.
  let assert Ok(mirrored) =
    list.find(back.holes, fn(h) {
      close(h.y, leftmost.y) && close(h.x, 2.0 *. cx -. leftmost.x)
    })

  // Was left of centre; is now right of centre — the flip went the right way.
  { leftmost.x <. cx } |> should.be_true
  { mirrored.x >. cx } |> should.be_true
}
