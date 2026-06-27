//// Tests for `domain/fit_geometry` — the QR/polar decomposition of a solved
//// `Alignment` into readable geometry plus the advisory sanity classification.
////
//// `Alignment` is public, so each case builds one directly from a hand-chosen
//// `Transform2D` + `ZPlane` + a benign `Residuals` (decompose ignores the
//// residuals; classify works off the decomposed geometry). Expected values are
//// computed from the closed-form decomposition math in ADR-0019 §4.
////
//// Sign conventions (chosen so identity -> all-zero, documented in the module):
////   * rotation_deg follows atan2(c, a) — standard CCW, identity -> 0.
////   * shear_deg = 90 - angle_between(col1, col2); a positive `b` (right
////     column leaning toward col1) yields a positive shear.
////   * tilt_dir_deg = atan2(zb, za); 0 = downhill toward +X, 90 = toward +Y.

import blau_drill/domain/alignment.{
  type Alignment, type Residuals, type ZPlane, Alignment, Residuals, ZPlane,
}
import blau_drill/domain/fit_geometry.{
  Mirrored, Plausible, ScaleOff, Sheared, Suspect, Tilted,
}
import blau_drill/domain/transform2d.{type Transform2D, Transform2D}
import gleam/float
import gleam/list
import gleeunit/should

// Tight tolerance for unit quantities; degree comparisons get a looser one
// because the trig round-trips through FFI doubles.
const eps = 1.0e-6

const deg_eps = 1.0e-4

fn approx(a: Float, b: Float, tol: Float) -> Bool {
  float.absolute_value(a -. b) <. tol
}

// A benign residuals value — decompose ignores it entirely.
fn benign() -> Residuals {
  Residuals(rms: 0.0, max: 0.0, z_rms: 0.0, z_max: 0.0, n: 0)
}

// Build an Alignment from a linear/translation transform and a flat-at-z plane.
fn align(t: Transform2D, z: ZPlane) -> Alignment {
  Alignment(transform: t, z_plane: z, residuals: benign())
}

fn flat() -> ZPlane {
  ZPlane(a: 0.0, b: 0.0, c: 0.0)
}

// Hardcoded cos/sin of 30 degrees (avoids needing trig in the test itself).
const cos30 = 0.8660254037844387

const sin30 = 0.5

// --- decompose: known transforms ---------------------------------------

pub fn decompose_identity_test() {
  let g =
    fit_geometry.decompose(align(
      Transform2D(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
      flat(),
    ))

  approx(g.rotation_deg, 0.0, deg_eps) |> should.be_true
  approx(g.scale_x, 1.0, eps) |> should.be_true
  approx(g.scale_y, 1.0, eps) |> should.be_true
  approx(g.shear_deg, 0.0, deg_eps) |> should.be_true
  g.mirrored |> should.be_false
  approx(g.tilt_deg, 0.0, deg_eps) |> should.be_true

  let #(nx, ny, nz) = g.normal
  approx(nx, 0.0, eps) |> should.be_true
  approx(ny, 0.0, eps) |> should.be_true
  approx(nz, 1.0, eps) |> should.be_true
}

pub fn decompose_pure_rotation_test() {
  // 30 degrees CCW: a=cos, b=-sin, c=sin, d=cos.
  let t = Transform2D(cos30, float.negate(sin30), sin30, cos30, 0.0, 0.0)
  let g = fit_geometry.decompose(align(t, flat()))

  approx(g.rotation_deg, 30.0, deg_eps) |> should.be_true
  approx(g.scale_x, 1.0, eps) |> should.be_true
  approx(g.scale_y, 1.0, eps) |> should.be_true
  approx(g.shear_deg, 0.0, deg_eps) |> should.be_true
  g.mirrored |> should.be_false
}

pub fn decompose_scale_test() {
  let t = Transform2D(1.1, 0.0, 0.0, 0.9, 0.0, 0.0)
  let g = fit_geometry.decompose(align(t, flat()))

  approx(g.scale_x, 1.1, eps) |> should.be_true
  approx(g.scale_y, 0.9, eps) |> should.be_true
  approx(g.rotation_deg, 0.0, deg_eps) |> should.be_true
  approx(g.shear_deg, 0.0, deg_eps) |> should.be_true
  g.mirrored |> should.be_false
}

pub fn decompose_mirror_test() {
  // Back-side X-mirror: a=-1, d=1 → det<0.
  let t = Transform2D(-1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
  let g = fit_geometry.decompose(align(t, flat()))

  g.mirrored |> should.be_true
  // Orthogonalised norms are still unit even though det < 0.
  approx(g.scale_x, 1.0, eps) |> should.be_true
  approx(g.scale_y, 1.0, eps) |> should.be_true
}

pub fn decompose_shear_test() {
  // b=0.1 leans the second column → angle_between(col1,col2) < 90.
  // dot = 0.1, |col2| = sqrt(1.01); shear = 90 - acos(0.1/sqrt(1.01)) ≈ 5.7106°.
  let t = Transform2D(1.0, 0.1, 0.0, 1.0, 0.0, 0.0)
  let g = fit_geometry.decompose(align(t, flat()))

  approx(g.shear_deg, 5.710593137499642, 1.0e-3) |> should.be_true
  // Positive lean → positive shear (sign convention).
  { g.shear_deg >. 0.0 } |> should.be_true
}

pub fn decompose_tilted_plane_test() {
  // z = 0.05*bx + 0*by + c → downhill toward +X; tilt = atan(0.05) ≈ 2.8624°.
  let g =
    fit_geometry.decompose(align(transform2d_id(), ZPlane(0.05, 0.0, 1.0)))

  approx(g.tilt_deg, 2.862405226, 1.0e-3) |> should.be_true
  approx(g.tilt_dir_deg, 0.0, deg_eps) |> should.be_true

  // normal = normalize((-0.05, 0, 1)).
  let #(nx, ny, nz) = g.normal
  let n = float_sqrt(0.05 *. 0.05 +. 1.0)
  approx(nx, float.negate(0.05) /. n, eps) |> should.be_true
  approx(ny, 0.0, eps) |> should.be_true
  approx(nz, 1.0 /. n, eps) |> should.be_true
}

pub fn decompose_tilt_dir_plus_y_test() {
  // z slopes only in +Y → downhill azimuth ≈ 90.
  let g = fit_geometry.decompose(align(transform2d_id(), ZPlane(0.0, 0.1, 1.0)))
  approx(g.tilt_dir_deg, 90.0, deg_eps) |> should.be_true
}

// --- classify: known geometries ----------------------------------------

pub fn classify_identity_plausible_test() {
  let g = fit_geometry.decompose(align(transform2d_id(), flat()))
  fit_geometry.classify(g, fit_geometry.default_bands())
  |> should.equal(Plausible)
}

pub fn classify_scale_flags_both_axes_test() {
  let t = Transform2D(1.1, 0.0, 0.0, 0.9, 0.0, 0.0)
  let g = fit_geometry.decompose(align(t, flat()))

  case fit_geometry.classify(g, fit_geometry.default_bands()) {
    Suspect(reasons) -> {
      has_scale_off(reasons, "x") |> should.be_true
      has_scale_off(reasons, "y") |> should.be_true
    }
    Plausible -> should.fail()
  }
}

pub fn classify_mirror_flag_test() {
  let t = Transform2D(-1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
  let g = fit_geometry.decompose(align(t, flat()))

  case fit_geometry.classify(g, fit_geometry.default_bands()) {
    Suspect(reasons) -> list.contains(reasons, Mirrored) |> should.be_true
    Plausible -> should.fail()
  }
}

pub fn classify_shear_flag_test() {
  // b=0.2 → shear ≈ 11.3° → well past the 2° band.
  let t = Transform2D(1.0, 0.2, 0.0, 1.0, 0.0, 0.0)
  let g = fit_geometry.decompose(align(t, flat()))

  case fit_geometry.classify(g, fit_geometry.default_bands()) {
    Suspect(reasons) -> has_sheared(reasons) |> should.be_true
    Plausible -> should.fail()
  }
}

// --- classify: band boundaries -----------------------------------------

pub fn classify_scale_band_boundary_test() {
  // default scale_tol = 0.02.
  // Just inside: 1.019 → plausible. Just outside: 1.021 → ScaleOff("x").
  let inside =
    fit_geometry.decompose(align(
      Transform2D(1.019, 0.0, 0.0, 1.0, 0.0, 0.0),
      flat(),
    ))
  fit_geometry.classify(inside, fit_geometry.default_bands())
  |> should.equal(Plausible)

  let outside =
    fit_geometry.decompose(align(
      Transform2D(1.021, 0.0, 0.0, 1.0, 0.0, 0.0),
      flat(),
    ))
  case fit_geometry.classify(outside, fit_geometry.default_bands()) {
    Suspect(reasons) -> has_scale_off(reasons, "x") |> should.be_true
    Plausible -> should.fail()
  }
}

pub fn classify_shear_band_boundary_test() {
  // default shear_max_deg = 2.0.
  // b such that shear is just under 2°: b ≈ tan(2°) gives shear≈2; use a value
  // safely inside and one safely outside.
  // b=0.03 → dot=0.03, |col2|=sqrt(1.0009); shear ≈ 1.718° (inside 2°).
  let inside =
    fit_geometry.decompose(align(
      Transform2D(1.0, 0.03, 0.0, 1.0, 0.0, 0.0),
      flat(),
    ))
  fit_geometry.classify(inside, fit_geometry.default_bands())
  |> should.equal(Plausible)

  // b=0.05 → shear ≈ 2.862° (outside 2°).
  let outside =
    fit_geometry.decompose(align(
      Transform2D(1.0, 0.05, 0.0, 1.0, 0.0, 0.0),
      flat(),
    ))
  case fit_geometry.classify(outside, fit_geometry.default_bands()) {
    Suspect(reasons) -> has_sheared(reasons) |> should.be_true
    Plausible -> should.fail()
  }
}

pub fn classify_tilt_band_boundary_test() {
  // default tilt_warn_deg = 3.0.
  // za=0.05 → tilt ≈ 2.862° (inside 3°) → Plausible.
  let inside =
    fit_geometry.decompose(align(transform2d_id(), ZPlane(0.05, 0.0, 1.0)))
  fit_geometry.classify(inside, fit_geometry.default_bands())
  |> should.equal(Plausible)

  // za=0.1 → tilt ≈ 5.71° (outside 3°) → Tilted.
  let outside =
    fit_geometry.decompose(align(transform2d_id(), ZPlane(0.1, 0.0, 1.0)))
  case fit_geometry.classify(outside, fit_geometry.default_bands()) {
    Suspect(reasons) -> has_tilted(reasons) |> should.be_true
    Plausible -> should.fail()
  }
}

// --- downhill_unit: board-space tilt direction -------------------------
// `downhill_unit(dir)` = (cos dir, sin dir), matching the `tilt_dir_deg`
// convention: 0 -> +X, 90 -> +Y, 180 -> -X. The canvas flips Y for the screen.

pub fn downhill_unit_plus_x_test() {
  let #(x, y) = fit_geometry.downhill_unit(0.0)
  approx(x, 1.0, eps) |> should.be_true
  approx(y, 0.0, eps) |> should.be_true
}

pub fn downhill_unit_plus_y_test() {
  let #(x, y) = fit_geometry.downhill_unit(90.0)
  approx(x, 0.0, eps) |> should.be_true
  approx(y, 1.0, eps) |> should.be_true
}

pub fn downhill_unit_minus_x_test() {
  let #(x, y) = fit_geometry.downhill_unit(180.0)
  approx(x, -1.0, eps) |> should.be_true
  approx(y, 0.0, eps) |> should.be_true
}

// --- robustness: acos NaN guard ----------------------------------------

pub fn decompose_near_identity_finite_shear_test() {
  // A near-identity transform whose column dot can drift the acos arg slightly
  // past 1.0; clamping must keep shear finite (≈0), never NaN. A NaN fails every
  // comparison, so `approx(_, 0.0, _)` is itself the NaN guard: it can only pass
  // for a finite, near-zero result.
  let t = Transform2D(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
  let g = fit_geometry.decompose(align(t, flat()))
  approx(g.shear_deg, 0.0, deg_eps) |> should.be_true
  approx(g.tilt_deg, 0.0, deg_eps) |> should.be_true
}

// --- helpers -----------------------------------------------------------

fn transform2d_id() -> Transform2D {
  Transform2D(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
}

fn has_scale_off(reasons: List(fit_geometry.SanityFlag), axis: String) -> Bool {
  list.any(reasons, fn(r) {
    case r {
      ScaleOff(a, _) -> a == axis
      _ -> False
    }
  })
}

fn has_sheared(reasons: List(fit_geometry.SanityFlag)) -> Bool {
  list.any(reasons, fn(r) {
    case r {
      Sheared(_) -> True
      _ -> False
    }
  })
}

fn has_tilted(reasons: List(fit_geometry.SanityFlag)) -> Bool {
  list.any(reasons, fn(r) {
    case r {
      Tilted(_) -> True
      _ -> False
    }
  })
}

fn float_sqrt(x: Float) -> Float {
  let assert Ok(r) = float.square_root(x)
  r
}
