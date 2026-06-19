//// Transform2D tests, ported from `test/blau_drill/transform2d_test.exs`.
//// Example-based tests are exact ports; the StreamData property tests are
//// covered as concrete example cases that exercise the same invariants
//// (invert round-trips, compose associativity, identity neutrality, singular
//// rejection of zero-determinant matrices).

import blau_drill/domain/transform2d.{type Point, Transform2D} as t2d
import gleam/float
import gleeunit/should

// Tight delta for hand-computed example assertions.
const delta = 1.0e-9

// Looser delta for chained-op cases (compose, invert) that accumulate rounding.
const prop_delta = 1.0e-6

fn close(a: Float, b: Float, eps: Float) -> Bool {
  float.absolute_value(a -. b) <. eps
}

fn assert_point(got: Point, want: Point, eps: Float) {
  let #(gx, gy) = got
  let #(wx, wy) = want
  close(gx, wx, eps) |> should.be_true
  close(gy, wy, eps) |> should.be_true
}

// --- identity / apply -------------------------------------------------------

pub fn identity_maps_points_to_themselves_test() {
  let pts = [#(0.0, 0.0), #(3.0, 4.0), #(-12.5, 7.25), #(200.0, -200.0)]
  pts
  |> assert_each(fn(p) {
    assert_point(t2d.apply(t2d.identity(), p), p, delta)
  })
}

pub fn pure_translation_test() {
  let t = Transform2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 10.0, ty: -5.0)
  assert_point(t2d.apply(t, #(0.0, 0.0)), #(10.0, -5.0), delta)
  assert_point(t2d.apply(t, #(3.0, 4.0)), #(13.0, -1.0), delta)
}

pub fn rotation_90_ccw_test() {
  // a=cos90=0, b=-sin90=-1, c=sin90=1, d=cos90=0.
  let t = Transform2D(a: 0.0, b: -1.0, c: 1.0, d: 0.0, tx: 0.0, ty: 0.0)
  assert_point(t2d.apply(t, #(1.0, 0.0)), #(0.0, 1.0), delta)
  assert_point(t2d.apply(t, #(0.0, 1.0)), #(-1.0, 0.0), delta)
}

pub fn x_mirror_negates_x_test() {
  let mirror = Transform2D(a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0)
  assert_point(t2d.apply(mirror, #(5.0, 7.0)), #(-5.0, 7.0), delta)
}

pub fn mirror_translation_segby_shape_test() {
  let t = Transform2D(a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0)
  assert_point(t2d.apply(t, #(-57.15, 80.01)), #(57.15, 80.01), delta)
}

// --- compose ----------------------------------------------------------------

pub fn compose_applies_b_first_then_a_test() {
  // a: translate by (10, 0). b: scale x by 2.
  let a = Transform2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 10.0, ty: 0.0)
  let b = Transform2D(a: 2.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0)
  let composed = t2d.compose(a, b)
  // {3,4}: scale -> {6,4}, then translate -> {16,4}.
  assert_point(t2d.apply(composed, #(3.0, 4.0)), #(16.0, 4.0), delta)
  // Equivalence: apply(compose(a,b),p) == apply(a, apply(b, p)).
  let nested = t2d.apply(a, t2d.apply(b, #(3.0, 4.0)))
  assert_point(t2d.apply(composed, #(3.0, 4.0)), nested, delta)
}

// --- invert -----------------------------------------------------------------

pub fn invert_known_translation_mirror_test() {
  let t = Transform2D(a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 4.0, ty: -3.0)
  let assert Ok(inv) = t2d.invert(t)
  let m = t2d.apply(t, #(5.0, 7.0))
  assert_point(t2d.apply(inv, m), #(5.0, 7.0), delta)
}

pub fn invert_all_zero_is_singular_test() {
  let singular = Transform2D(a: 0.0, b: 0.0, c: 0.0, d: 0.0, tx: 0.0, ty: 0.0)
  t2d.invert(singular) |> should.equal(Error(t2d.Singular))
}

pub fn invert_collinear_is_singular_test() {
  // det = a*d - b*c = 1*2 - 1*2 = 0.
  let singular = Transform2D(a: 1.0, b: 1.0, c: 2.0, d: 2.0, tx: 5.0, ty: 9.0)
  t2d.invert(singular) |> should.equal(Error(t2d.Singular))
}

// --- property-equivalent example cases --------------------------------------

// Build an invertible transform (rotation . scale . translation), as the
// StreamData generator does.
fn invertible(angle: Float, sx: Float, sy: Float, tx: Float, ty: Float) {
  let cos = cos_(angle)
  let sin = sin_(angle)
  let rotation = Transform2D(a: cos, b: float.negate(sin), c: sin, d: cos, tx: 0.0, ty: 0.0)
  let scale = Transform2D(a: sx, b: 0.0, c: 0.0, d: sy, tx: 0.0, ty: 0.0)
  let translation = Transform2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: tx, ty: ty)
  t2d.compose(rotation, t2d.compose(scale, translation))
}

pub fn invert_round_trips_both_directions_test() {
  // A spread of invertible transforms + points.
  let cases = [
    #(invertible(0.5, 2.0, 3.0, 10.0, -5.0), #(7.0, -3.0)),
    #(invertible(-1.2, -1.5, 2.0, -20.0, 40.0), #(-50.0, 12.5)),
    #(invertible(2.9, 0.5, -4.0, 100.0, -100.0), #(33.0, 33.0)),
  ]
  cases
  |> assert_each(fn(c) {
    let #(t, p) = c
    let assert Ok(inv) = t2d.invert(t)
    // apply(t, apply(inv, p)) ~ p
    assert_point(t2d.apply(t, t2d.apply(inv, p)), p, prop_delta)
    // apply(inv, apply(t, p)) ~ p
    assert_point(t2d.apply(inv, t2d.apply(t, p)), p, prop_delta)
  })
}

pub fn compose_is_associative_test() {
  let a = invertible(0.3, 2.0, -1.5, 5.0, 7.0)
  let b = invertible(-0.7, -2.0, 1.2, -3.0, 4.0)
  let c = invertible(1.1, 0.8, 3.0, 11.0, -9.0)
  let p = #(13.0, -21.0)
  let left = t2d.compose(t2d.compose(a, b), c)
  let right = t2d.compose(a, t2d.compose(b, c))
  assert_point(t2d.apply(left, p), t2d.apply(right, p), prop_delta)
}

pub fn identity_is_neutral_for_compose_test() {
  let id = t2d.identity()
  let t = invertible(0.9, 1.7, -2.3, -15.0, 25.0)
  let p = #(4.0, 9.0)
  let direct = t2d.apply(t, p)
  assert_point(t2d.apply(t2d.compose(id, t), p), direct, prop_delta)
  assert_point(t2d.apply(t2d.compose(t, id), p), direct, prop_delta)
}

pub fn zero_determinant_transforms_are_singular_test() {
  // Second row a scalar multiple of the first -> det = 0, even with rounding.
  let cases = [
    Transform2D(a: 3.0, b: -2.0, c: 3.0 *. 4.0, d: -2.0 *. 4.0, tx: 1.0, ty: 2.0),
    Transform2D(a: -7.5, b: 5.5, c: -7.5 *. -2.0, d: 5.5 *. -2.0, tx: 9.0, ty: -3.0),
    Transform2D(a: 100.0, b: 100.0, c: 100.0 *. 1.5, d: 100.0 *. 1.5, tx: 0.0, ty: 0.0),
  ]
  cases
  |> assert_each(fn(t) {
    t2d.invert(t) |> should.equal(Error(t2d.Singular))
  })
}

// --- tiny helpers -----------------------------------------------------------

fn assert_each(xs: List(a), f: fn(a) -> b) -> Nil {
  case xs {
    [] -> Nil
    [first, ..rest] -> {
      f(first)
      assert_each(rest, f)
    }
  }
}

@external(javascript, "../math_ffi.mjs", "cos")
fn cos_(x: Float) -> Float

@external(javascript, "../math_ffi.mjs", "sin")
fn sin_(x: Float) -> Float
