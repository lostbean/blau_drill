//// An immutable 2x3 affine transform mapping **board coordinates -> machine
//// coordinates**.
////
//// The transform is the 2x3 affine matrix
////
////     | a  b  tx |
////     | c  d  ty |
////
//// applied to a board point `#(bx, by)` to produce a machine point `#(mx, my)`:
////
////     mx = a * bx + b * by + tx
////     my = c * bx + d * by + ty
////
//// Rotation follows the standard mathematical (counter-clockwise) convention.
//// The back-side X-mirror is `a = -1, d = 1`. `compose/2` is matrix
//// multiplication ordered so that `apply(compose(a, b), p) == apply(a, apply(b,
//// p))` (b applied first). `identity/0` is the neutral element. `invert/1`
//// returns `Error(Singular)` for a determinant ~ 0 (scale-relative test).

import gleam/float

/// A 2x3 affine transform `[[a, b, tx], [c, d, ty]]` mapping board -> machine.
/// All fields are floats. `a, b, c, d` are the linear part (rotation / scale /
/// mirror / skew); `tx, ty` are the translation.
pub type Transform2D {
  Transform2D(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float)
}

/// A 2-D point `#(x, y)` (board or machine space), as floats.
pub type Point =
  #(Float, Float)

/// The error returned by `invert/1` when the linear-part determinant is ~ 0.
pub type InvertError {
  Singular
}

// Relative tolerance for the singular-determinant check: `|det|` is compared
// against this fraction of the squared entry scale.
const epsilon = 1.0e-9

/// The identity transform: `apply(identity(), p) == p` for every point `p`.
pub fn identity() -> Transform2D {
  Transform2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0)
}

/// A reflection about the vertical line `x = cx`, leaving Y unchanged:
///
///     x' = 2 * cx - x
///     y' = y
///
/// As a matrix this is `a = -1, d = 1` with `tx = 2 * cx`. It is a reflection
/// (negative determinant) and an involution: `apply(m, apply(m, p)) == p`.
pub fn mirror_x_about(cx: Float) -> Transform2D {
  Transform2D(a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 2.0 *. cx, ty: 0.0)
}

/// Apply the transform to a board point, returning the machine point.
///
///     mx = a * bx + b * by + tx
///     my = c * bx + d * by + ty
pub fn apply(t: Transform2D, p: Point) -> Point {
  let #(bx, by) = p
  #(t.a *. bx +. t.b *. by +. t.tx, t.c *. bx +. t.d *. by +. t.ty)
}

/// Compose two transforms. `compose(a, b)` applies `b` first, then `a`:
///
///     apply(compose(a, b), p) == apply(a, apply(b, p))
///
/// This is the matrix product `a . b`. Composition is associative and
/// `identity/0` is neutral on both sides.
pub fn compose(a: Transform2D, b: Transform2D) -> Transform2D {
  Transform2D(
    a: a.a *. b.a +. a.b *. b.c,
    b: a.a *. b.b +. a.b *. b.d,
    c: a.c *. b.a +. a.d *. b.c,
    d: a.c *. b.b +. a.d *. b.d,
    tx: a.a *. b.tx +. a.b *. b.ty +. a.tx,
    ty: a.c *. b.tx +. a.d *. b.ty +. a.ty,
  )
}

/// Invert the transform.
///
/// Returns `Ok(inverse)` for an invertible transform (determinant `a*d - b*c`
/// magnitude above the scale-relative singular epsilon). Returns
/// `Error(Singular)` when the determinant is ~ 0 (a collinear / zero-area
/// mapping that cannot be inverted).
pub fn invert(t: Transform2D) -> Result(Transform2D, InvertError) {
  let det = t.a *. t.d -. t.b *. t.c

  // Scale-relative singular test: compare |det| to the squared entry scale.
  let scale =
    float.max(
      float.max(float.absolute_value(t.a), float.absolute_value(t.b)),
      float.max(float.absolute_value(t.c), float.absolute_value(t.d)),
    )
  let threshold = epsilon *. { scale *. scale +. 1.0 }

  case float.absolute_value(det) <=. threshold {
    True -> Error(Singular)
    False -> {
      let inv_det = 1.0 /. det

      // Inverse of the linear 2x2 part.
      let ia = t.d *. inv_det
      let ib = float.negate(t.b) *. inv_det
      let ic = float.negate(t.c) *. inv_det
      let id = t.a *. inv_det

      // Inverse translation: -(L^-1 . translation).
      let itx = float.negate(ia *. t.tx +. ib *. t.ty)
      let ity = float.negate(ic *. t.tx +. id *. t.ty)

      Ok(Transform2D(a: ia, b: ib, c: ic, d: id, tx: itx, ty: ity))
    }
  }
}
