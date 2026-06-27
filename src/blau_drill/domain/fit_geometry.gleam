//// Decomposes a **solved** `Alignment` into human-readable geometry
//// (`FitGeometry`) and classifies its physical plausibility (`FitSanity`).
////
//// This is a pure projection over an already-solved fit — **no new solver
//// math**, nothing stored (ADR-0018). It answers a question orthogonal to the
//// `Residuals`: residuals say whether the fit is *self-consistent*; this says
//// whether it is *physically plausible* (a mirrored Front/Back mismatch, a
//// wrong-units scale, or a bad-capture shear can all fit with tiny residual).
//// See ADR-0019.
////
//// `FitGeometry` is constructible **only** via `decompose(Alignment)`, and
//// `Alignment` only via `Alignment.fit/1`, so "decomposition of an unsolved
//// fit" is unrepresentable.
////
//// ## The decomposition (ADR-0019 §4)
////
//// The 2x2 linear part `[[a, b], [c, d]]` of the transform — columns `(a, c)`
//// and `(b, d)` — is reduced QR/polar-style:
////
////   * `scale_x = ‖col1‖ = sqrt(a² + c²)`
////   * `scale_y = |det| / scale_x` (the orthogonalised second-column norm)
////   * `rotation_deg = atan2(c, a)` (the col-1 angle)
////   * `shear_deg = 90 - angle_between(col1, col2)` (departure from square)
////   * `mirrored = det < 0`
////
//// The `ZPlane` slopes `(za, zb)` reduce to the surface normal:
////
////   * `normal = normalize((-za, -zb, 1))`
////   * `tilt_deg = acos(normal.z)` (normal vs vertical)
////   * `tilt_dir_deg = atan2(zb, za)` (downhill azimuth; 0 = +X, 90 = +Y)
////
//// ## Sign conventions (chosen so identity decomposes to all-zero)
////
////   * `rotation_deg` is `atan2(c, a)` — standard CCW; identity -> 0.
////   * `shear_deg` is `90 - angle_between(col1, col2)`, so a second column that
////     leans *toward* the first (positive `b` for an upright col1) gives a
////     positive shear; identity (orthogonal columns) -> 0.
////   * `tilt_dir_deg` is `atan2(zb, za)`: 0 points downhill toward +X, 90
////     toward +Y.
////
//// ## Robustness
////
//// Every `acos` argument is clamped to `[-1, 1]` before the call: float
//// round-off can push a cosine a hair out of range and `Math.acos` returns NaN
//// for out-of-domain inputs. Divisions are guarded with a tiny floor so the
//// function is total for any input, even though a solved `Alignment` always has
//// a non-singular linear part (`Alignment.fit` rejects degenerate solves).

import blau_drill/domain/alignment.{type Alignment, ZPlane}
import blau_drill/domain/transform2d.{Transform2D}
import gleam/float

const pi = 3.141592653589793

// Tiny floor for denominators so divisions stay total even for a (theoretically
// impossible) singular linear part. A solved Alignment never hits this.
const tiny = 1.0e-12

/// The decomposition of a solved `Alignment` into readable geometry.
///
/// * `rotation_deg` — in-plane rotation of the board vs the bed (CCW).
/// * `scale_x` / `scale_y` — per-axis scale; `1.0` is exact.
/// * `shear_deg` — departure from 90 degrees between the X/Y basis.
/// * `mirrored` — determinant `< 0` (a board-side Front/Back mismatch).
/// * `tilt_deg` — surface normal vs vertical.
/// * `tilt_dir_deg` — downhill azimuth of the tilt (0 = +X, 90 = +Y).
/// * `normal` — the unit normal `#(x, y, z)` of the fitted surface plane.
pub type FitGeometry {
  FitGeometry(
    rotation_deg: Float,
    scale_x: Float,
    scale_y: Float,
    shear_deg: Float,
    mirrored: Bool,
    tilt_deg: Float,
    tilt_dir_deg: Float,
    normal: #(Float, Float, Float),
  )
}

/// One advisory reason a fit is implausible.
///
/// * `ScaleOff(axis, value)` — `axis` is `"x"` or `"y"`; `value` is the scale
///   factor that drifted outside tolerance.
/// * `Sheared(deg)` — the basis is non-square by `deg`.
/// * `Mirrored` — the determinant is negative (no threshold; the sign is binary).
/// * `Tilted(deg)` — the surface tilts from vertical by `deg`.
pub type SanityFlag {
  ScaleOff(axis: String, value: Float)
  Sheared(deg: Float)
  Mirrored
  Tilted(deg: Float)
}

/// An **advisory** plausibility verdict over a `FitGeometry`. Display-only — it
/// warns but never gates (the `Residuals` stay the sole hard gate; ADR-0019).
pub type FitSanity {
  Plausible
  Suspect(reasons: List(SanityFlag))
}

/// The tunable thresholds for `classify`. Thresholds are data (ADR-0019) so the
/// math need not change to retune.
///
/// * `scale_tol` — max `|scale - 1.0|` before a `ScaleOff` flag.
/// * `shear_max_deg` — max `|shear_deg|` before a `Sheared` flag.
/// * `tilt_warn_deg` — max `tilt_deg` before a `Tilted` flag.
pub type Bands {
  Bands(scale_tol: Float, shear_max_deg: Float, tilt_warn_deg: Float)
}

/// The tight, operator-chosen default bands.
pub fn default_bands() -> Bands {
  Bands(scale_tol: 0.02, shear_max_deg: 2.0, tilt_warn_deg: 3.0)
}

/// Decompose a solved `Alignment` into readable geometry. Pure and total.
pub fn decompose(a: Alignment) -> FitGeometry {
  let Transform2D(a: la, b: lb, c: lc, d: ld, ..) = a.transform
  let ZPlane(a: za, b: zb, ..) = a.z_plane

  let det = la *. ld -. lb *. lc

  // QR/polar of the 2x2 linear part. col1 = (la, lc), col2 = (lb, ld).
  let scale_x = float_sqrt(la *. la +. lc *. lc)
  // Orthogonalised second-column norm; guard the division defensively.
  let scale_y = float.absolute_value(det) /. float.max(scale_x, tiny)

  let rotation_deg = atan2(lc, la) *. 180.0 /. pi

  // shear = 90 - angle_between(col1, col2).
  let shear_deg = 90.0 -. angle_between_deg(la, lc, lb, ld)

  let mirrored = det <. 0.0

  // Surface normal of z = za*x + zb*y + c is normalize((-za, -zb, 1)).
  let nlen = float_sqrt(za *. za +. zb *. zb +. 1.0)
  let nx = float.negate(za) /. nlen
  let ny = float.negate(zb) /. nlen
  let nz = 1.0 /. nlen

  let tilt_deg = acos(clamp(nz, -1.0, 1.0)) *. 180.0 /. pi
  let tilt_dir_deg = atan2(zb, za) *. 180.0 /. pi

  FitGeometry(
    rotation_deg: rotation_deg,
    scale_x: scale_x,
    scale_y: scale_y,
    shear_deg: shear_deg,
    mirrored: mirrored,
    tilt_deg: tilt_deg,
    tilt_dir_deg: tilt_dir_deg,
    normal: #(nx, ny, nz),
  )
}

/// Classify a `FitGeometry` against `Bands` into an advisory verdict.
///
/// Flags accumulate in a fixed order — scale (x then y), shear, mirror, tilt.
/// Rotation is intentionally never a flag (square-to-bed is the exception, not
/// the rule; ADR-0019). An empty flag list is `Plausible`.
pub fn classify(g: FitGeometry, b: Bands) -> FitSanity {
  let reasons =
    []
    |> append_if(g.tilt_deg >. b.tilt_warn_deg, Tilted(g.tilt_deg))
    |> append_if(g.mirrored, Mirrored)
    |> append_if(
      float.absolute_value(g.shear_deg) >. b.shear_max_deg,
      Sheared(g.shear_deg),
    )
    |> append_if(
      float.absolute_value(g.scale_y -. 1.0) >. b.scale_tol,
      ScaleOff("y", g.scale_y),
    )
    |> append_if(
      float.absolute_value(g.scale_x -. 1.0) >. b.scale_tol,
      ScaleOff("x", g.scale_x),
    )

  case reasons {
    [] -> Plausible
    _ -> Suspect(reasons)
  }
}

/// The board-space unit vector pointing DOWNHILL for a `tilt_dir_deg` azimuth:
/// `#(cos(dir_deg), sin(dir_deg))`. Matches the `tilt_dir_deg` convention from
/// `decompose` — 0 points toward board +X, 90 toward board +Y. Pure helper so
/// the canvas view (`board_canvas.tilt_arrow`) stays trig-free and this is
/// unit-testable. Reuses the same trig FFI as the decomposition.
///
/// Note the canvas Y is FLIPPED (board +Y is up, SVG +Y down), so a caller
/// drawing in screen space negates the returned `.1`:
/// `(cos, sin)` board → `(cos, -sin)` screen.
pub fn downhill_unit(dir_deg: Float) -> #(Float, Float) {
  let r = dir_deg *. pi /. 180.0
  #(cos(r), sin(r))
}

// --- internals ---------------------------------------------------------

// angle_between(u, v) in degrees, where u = (ux, uy) and v = (vx, vy):
//   acos( dot(u, v) / (‖u‖ · ‖v‖) ) · 180/pi
// The acos argument is clamped to [-1, 1] so float round-off can never produce
// NaN.
fn angle_between_deg(ux: Float, uy: Float, vx: Float, vy: Float) -> Float {
  let dot = ux *. vx +. uy *. vy
  let un = float_sqrt(ux *. ux +. uy *. uy)
  let vn = float_sqrt(vx *. vx +. vy *. vy)
  let cos = dot /. float.max(un *. vn, tiny)
  acos(clamp(cos, -1.0, 1.0)) *. 180.0 /. pi
}

// Prepend a flag onto the accumulator when the condition holds. Building the
// list back-to-front (tilt..scale) keeps the final order scale, shear, mirror,
// tilt.
fn append_if(
  acc: List(SanityFlag),
  condition: Bool,
  flag: SanityFlag,
) -> List(SanityFlag) {
  case condition {
    True -> [flag, ..acc]
    False -> acc
  }
}

fn clamp(x: Float, lo: Float, hi: Float) -> Float {
  float.min(float.max(x, lo), hi)
}

fn float_sqrt(x: Float) -> Float {
  // x is a sum of squares (+1 for the normal) here, so always >= 0.
  let assert Ok(r) = float.square_root(x)
  r
}

@external(javascript, "./fit_geometry_ffi.mjs", "atan2")
fn atan2(y: Float, x: Float) -> Float

@external(javascript, "./fit_geometry_ffi.mjs", "acos")
fn acos(x: Float) -> Float

@external(javascript, "./fit_geometry_ffi.mjs", "cos")
fn cos(x: Float) -> Float

@external(javascript, "./fit_geometry_ffi.mjs", "sin")
fn sin(x: Float) -> Float
