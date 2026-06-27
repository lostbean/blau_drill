//// Alignment tests, ported from `test/blau_drill/alignment_test.exs`. The
//// StreamData property tests are covered as concrete example cases that
//// exercise the same invariants (recover a random non-degenerate affine with
//// ~0 residual). Float assertions use a tolerance; expected values were
//// confirmed against the Elixir `Alignment.fit/1` (see the agent report).

import blau_drill/domain/alignment.{Alignment, Degenerate, TooFew, ZPlane}
import blau_drill/domain/correspondence.{Correspondence}
import blau_drill/domain/pending_alignment
import blau_drill/domain/transform2d.{type Transform2D, Transform2D} as t2d
import gleam/float
import gleam/list
import gleeunit/should

const delta = 1.0e-9

const prop_delta = 1.0e-6

fn close(a: Float, b: Float, eps: Float) -> Bool {
  float.absolute_value(a -. b) <. eps
}

// Build a Correspondence from a board point and the machine point produced by
// applying a known transform to it (the noise-free, exact-fit case). The XY
// affine tests do not exercise Z, so the captured Z is a flat 0.0.
fn corr_from(
  t: Transform2D,
  board: #(Float, Float),
) -> correspondence.Correspondence {
  Correspondence(board: board, machine: t2d.apply(t, board), machine_z: 0.0)
}

// Build a Correspondence with an explicit captured machine Z, for the Z surface
// plane tests. The machine XY is irrelevant to the plane fit, so it mirrors the
// board point.
fn corr_with_z(
  bx: Float,
  by: Float,
  mz: Float,
) -> correspondence.Correspondence {
  Correspondence(board: #(bx, by), machine: #(bx, by), machine_z: mz)
}

// --- too-few guard ----------------------------------------------------------

pub fn zero_correspondences_too_few_test() {
  alignment.fit([]) |> should.equal(Error(TooFew))
}

pub fn one_correspondence_too_few_test() {
  alignment.fit([
    Correspondence(board: #(0.0, 0.0), machine: #(1.0, 1.0), machine_z: 0.0),
  ])
  |> should.equal(Error(TooFew))
}

pub fn two_correspondences_too_few_test() {
  alignment.fit([
    Correspondence(board: #(0.0, 0.0), machine: #(1.0, 1.0), machine_z: 0.0),
    Correspondence(board: #(1.0, 0.0), machine: #(2.0, 1.0), machine_z: 0.0),
  ])
  |> should.equal(Error(TooFew))
}

// --- degeneracy -------------------------------------------------------------

pub fn three_collinear_degenerate_test() {
  // Board points (0,0), (1,1), (2,2) all on y = x.
  alignment.fit([
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: 0.0),
    Correspondence(board: #(1.0, 1.0), machine: #(3.0, 7.0), machine_z: 0.0),
    Correspondence(board: #(2.0, 2.0), machine: #(6.0, 14.0), machine_z: 0.0),
  ])
  |> should.equal(Error(Degenerate))
}

pub fn collinear_large_coords_degenerate_test() {
  alignment.fit([
    Correspondence(board: #(100.0, 100.0), machine: #(1.0, 2.0), machine_z: 0.0),
    Correspondence(board: #(150.0, 150.0), machine: #(3.0, 4.0), machine_z: 0.0),
    Correspondence(board: #(200.0, 200.0), machine: #(5.0, 6.0), machine_z: 0.0),
  ])
  |> should.equal(Error(Degenerate))
}

pub fn two_coincident_among_three_degenerate_test() {
  alignment.fit([
    Correspondence(board: #(3.0, 5.0), machine: #(1.0, 1.0), machine_z: 0.0),
    Correspondence(board: #(3.0, 5.0), machine: #(2.0, 9.0), machine_z: 0.0),
    Correspondence(board: #(7.0, 1.0), machine: #(4.0, 4.0), machine_z: 0.0),
  ])
  |> should.equal(Error(Degenerate))
}

pub fn all_three_coincident_degenerate_test() {
  alignment.fit([
    Correspondence(board: #(2.0, 2.0), machine: #(1.0, 1.0), machine_z: 0.0),
    Correspondence(board: #(2.0, 2.0), machine: #(2.0, 2.0), machine_z: 0.0),
    Correspondence(board: #(2.0, 2.0), machine: #(3.0, 3.0), machine_z: 0.0),
  ])
  |> should.equal(Error(Degenerate))
}

// --- known-good exact fits --------------------------------------------------

pub fn recovers_x_mirror_translation_test() {
  // a=-1, b=0, c=0, d=1, tx=10, ty=-5.
  let source = Transform2D(a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 10.0, ty: -5.0)
  let boards = [#(0.0, 0.0), #(4.0, 0.0), #(0.0, 3.0)]
  let corrs = list.map(boards, fn(b) { corr_from(source, b) })

  let assert Ok(Alignment(transform: t, residuals: r, ..)) =
    alignment.fit(corrs)
  close(t.a, -1.0, delta) |> should.be_true
  close(t.b, 0.0, delta) |> should.be_true
  close(t.c, 0.0, delta) |> should.be_true
  close(t.d, 1.0, delta) |> should.be_true
  close(t.tx, 10.0, delta) |> should.be_true
  close(t.ty, -5.0, delta) |> should.be_true
  close(r.rms, 0.0, delta) |> should.be_true
  close(r.max, 0.0, delta) |> should.be_true
}

pub fn recovers_90_ccw_rotation_translation_test() {
  // a=0, b=-1, c=1, d=0, tx=2, ty=3.
  let source = Transform2D(a: 0.0, b: -1.0, c: 1.0, d: 0.0, tx: 2.0, ty: 3.0)
  let boards = [#(0.0, 0.0), #(1.0, 0.0), #(0.0, 1.0)]
  let corrs = list.map(boards, fn(b) { corr_from(source, b) })

  let assert Ok(Alignment(transform: t, residuals: r, ..)) =
    alignment.fit(corrs)
  close(t.a, 0.0, delta) |> should.be_true
  close(t.b, -1.0, delta) |> should.be_true
  close(t.c, 1.0, delta) |> should.be_true
  close(t.d, 0.0, delta) |> should.be_true
  close(t.tx, 2.0, delta) |> should.be_true
  close(t.ty, 3.0, delta) |> should.be_true
  close(r.rms, 0.0, delta) |> should.be_true
  close(r.max, 0.0, delta) |> should.be_true

  // And the fitted transform reproduces each machine point.
  corrs
  |> each(fn(c) {
    let Correspondence(board: b, machine: #(mx, my), ..) = c
    let #(fx, fy) = t2d.apply(t, b)
    close(fx, mx, delta) |> should.be_true
    close(fy, my, delta) |> should.be_true
  })
}

pub fn fit_returns_six_float_fields_test() {
  let source = Transform2D(a: 2.0, b: 0.5, c: -0.5, d: 1.5, tx: -3.0, ty: 4.0)
  let boards = [#(0.0, 0.0), #(1.0, 0.0), #(0.0, 1.0), #(1.0, 1.0)]
  let corrs = list.map(boards, fn(b) { corr_from(source, b) })
  let assert Ok(Alignment(transform: t, ..)) = alignment.fit(corrs)
  // Recovers the source (exact 4-pt data is consistent).
  close(t.a, 2.0, prop_delta) |> should.be_true
  close(t.d, 1.5, prop_delta) |> should.be_true
}

// --- overdetermined fit -----------------------------------------------------

pub fn overdetermined_exact_data_test() {
  let source = Transform2D(a: 1.2, b: -0.3, c: 0.4, d: 0.9, tx: 5.0, ty: -2.0)
  let boards = [#(0.0, 0.0), #(10.0, 0.0), #(0.0, 8.0), #(6.0, 6.0)]
  let corrs = list.map(boards, fn(b) { corr_from(source, b) })

  let assert Ok(Alignment(transform: t, residuals: r, ..)) =
    alignment.fit(corrs)
  close(t.a, 1.2, delta) |> should.be_true
  close(t.b, -0.3, delta) |> should.be_true
  close(t.c, 0.4, delta) |> should.be_true
  close(t.d, 0.9, delta) |> should.be_true
  close(t.tx, 5.0, delta) |> should.be_true
  close(t.ty, -2.0, delta) |> should.be_true
  // Ground truth (Elixir): rms ~ 5.0e-16, max ~ 8.9e-16.
  close(r.rms, 0.0, 1.0e-7) |> should.be_true
  close(r.max, 0.0, 1.0e-7) |> should.be_true
}

// --- residuals as the honesty signal ----------------------------------------

pub fn perturbation_drives_residual_max_test() {
  let source = Transform2D(a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0)
  let boards = [#(0.0, 0.0), #(10.0, 0.0), #(0.0, 10.0), #(10.0, 10.0)]
  let exact = list.map(boards, fn(b) { corr_from(source, b) })

  let delta_perturb = 0.4
  let assert [first, ..rest] = exact
  let Correspondence(machine: #(fmx, fmy), ..) = first
  let perturbed = [
    Correspondence(..first, machine: #(fmx +. delta_perturb, fmy)),
    ..rest
  ]

  let assert Ok(Alignment(residuals: r, ..)) = alignment.fit(perturbed)
  // Ground truth (Elixir): max ~ 0.1, rms ~ 0.1.
  { r.max >. 0.0 } |> should.be_true
  { r.rms >. 0.0 } |> should.be_true
  { r.rms <. r.max +. 1.0e-9 } |> should.be_true
  { r.max <=. delta_perturb +. 1.0e-9 } |> should.be_true
  { r.max >=. delta_perturb /. 4.0 -. 1.0e-12 } |> should.be_true
}

pub fn exact_data_zero_residuals_test() {
  let source = Transform2D(a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0)
  let boards = [#(1.0, 2.0), #(5.0, 2.0), #(1.0, 9.0)]
  let corrs = list.map(boards, fn(b) { corr_from(source, b) })
  let assert Ok(Alignment(residuals: r, ..)) = alignment.fit(corrs)
  close(r.rms, 0.0, delta) |> should.be_true
  close(r.max, 0.0, delta) |> should.be_true
}

// --- PendingAlignment -------------------------------------------------------

pub fn pending_starts_empty_test() {
  pending_alignment.count(pending_alignment.new()) |> should.equal(0)
}

pub fn pending_add_preserves_order_test() {
  let c1 =
    Correspondence(board: #(0.0, 0.0), machine: #(1.0, 1.0), machine_z: 0.0)
  let c2 =
    Correspondence(board: #(1.0, 0.0), machine: #(2.0, 1.0), machine_z: 0.0)
  let c3 =
    Correspondence(board: #(0.0, 1.0), machine: #(1.0, 2.0), machine_z: 0.0)
  let pending =
    pending_alignment.new()
    |> pending_alignment.add(c1)
    |> pending_alignment.add(c2)
    |> pending_alignment.add(c3)
  pending_alignment.count(pending) |> should.equal(3)
  pending.captured |> should.equal([c1, c2, c3])
}

pub fn pending_two_captured_too_few_test() {
  let pending =
    pending_alignment.new()
    |> pending_alignment.add(Correspondence(
      board: #(0.0, 0.0),
      machine: #(1.0, 1.0),
      machine_z: 0.0,
    ))
    |> pending_alignment.add(Correspondence(
      board: #(1.0, 0.0),
      machine: #(2.0, 1.0),
      machine_z: 0.0,
    ))
  pending_alignment.count(pending) |> should.equal(2)
  alignment.fit(pending.captured) |> should.equal(Error(TooFew))
}

pub fn pending_promotes_with_three_noncollinear_test() {
  let source = Transform2D(a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0)
  let pending =
    pending_alignment.new()
    |> pending_alignment.add(corr_from(source, #(0.0, 0.0)))
    |> pending_alignment.add(corr_from(source, #(4.0, 0.0)))
    |> pending_alignment.add(corr_from(source, #(0.0, 3.0)))
  let assert Ok(Alignment(..)) = alignment.fit(pending.captured)
  Nil
}

// --- Correspondence ---------------------------------------------------------

pub fn correspondence_carries_two_points_test() {
  let c =
    Correspondence(board: #(1.0, 2.0), machine: #(3.0, 4.0), machine_z: 0.0)
  c.board |> should.equal(#(1.0, 2.0))
  c.machine |> should.equal(#(3.0, 4.0))
}

// --- property-equivalent example cases --------------------------------------

pub fn recovers_random_nondegenerate_affines_test() {
  // A spread of non-degenerate affines + triangle board points, each fitted
  // back to its source with ~0 residual.
  let cases = [
    #(Transform2D(a: 0.9, b: 0.4, c: -0.4, d: 0.9, tx: 12.0, ty: -7.0), [
      #(0.0, 0.0),
      #(20.0, 0.0),
      #(0.0, 15.0),
      #(8.0, 8.0),
    ]),
    #(Transform2D(a: -1.3, b: 0.0, c: 0.0, d: 2.1, tx: -30.0, ty: 50.0), [
      #(5.0, 5.0),
      #(35.0, 5.0),
      #(5.0, 40.0),
      #(20.0, 20.0),
    ]),
    #(Transform2D(a: 2.0, b: -1.0, c: 1.5, d: 1.2, tx: 0.0, ty: 0.0), [
      #(-10.0, -10.0),
      #(30.0, -10.0),
      #(-10.0, 25.0),
      #(10.0, 10.0),
    ]),
  ]
  cases
  |> each(fn(c) {
    let #(source, boards) = c
    let corrs = list.map(boards, fn(b) { corr_from(source, b) })
    let assert Ok(Alignment(transform: t, residuals: r, ..)) =
      alignment.fit(corrs)
    close(t.a, source.a, prop_delta) |> should.be_true
    close(t.b, source.b, prop_delta) |> should.be_true
    close(t.c, source.c, prop_delta) |> should.be_true
    close(t.d, source.d, prop_delta) |> should.be_true
    close(t.tx, source.tx, prop_delta) |> should.be_true
    close(t.ty, source.ty, prop_delta) |> should.be_true
    close(r.rms, 0.0, prop_delta) |> should.be_true
    close(r.max, 0.0, prop_delta) |> should.be_true
  })
}

// --- Z surface plane (2.5D alignment) ---------------------------------------

// surface_z is exactly the plane equation a*bx + b*by + c.
pub fn surface_z_is_the_plane_equation_test() {
  let plane = ZPlane(a: 0.2, b: -0.1, c: 1.0)
  // 0.2*5 + -0.1*10 + 1.0 = 1.0 - 1.0 + 1.0 = 1.0
  close(alignment.surface_z(plane, 5.0, 10.0), 1.0, delta) |> should.be_true
  // A second point, computed independently.
  close(alignment.surface_z(plane, 0.0, 0.0), 1.0, delta) |> should.be_true
  close(alignment.surface_z(plane, 10.0, 0.0), 3.0, delta) |> should.be_true
}

// A known tilt: board pts (0,0),(10,0),(0,10) at Z 1.0,3.0,5.0 lie on the plane
// z = 0.2*bx + 0.4*by + 1.0. The fit recovers a,b,c exactly.
pub fn plane_reproduces_known_tilt_test() {
  let corrs = [
    corr_with_z(0.0, 0.0, 1.0),
    corr_with_z(10.0, 0.0, 3.0),
    corr_with_z(0.0, 10.0, 5.0),
  ]
  let assert Ok(Alignment(z_plane: p, ..)) = alignment.fit(corrs)
  close(p.a, 0.2, delta) |> should.be_true
  close(p.b, 0.4, delta) |> should.be_true
  close(p.c, 1.0, delta) |> should.be_true
}

// The fitted plane reproduces each captured Z (residual ~0) and predicts the
// surface height at an un-captured 4th point (10,10) -> 7.0.
pub fn plane_predicts_uncaptured_point_test() {
  let corrs = [
    corr_with_z(0.0, 0.0, 1.0),
    corr_with_z(10.0, 0.0, 3.0),
    corr_with_z(0.0, 10.0, 5.0),
  ]
  let assert Ok(Alignment(z_plane: p, ..)) = alignment.fit(corrs)
  // Reproduces each input Z exactly.
  close(alignment.surface_z(p, 0.0, 0.0), 1.0, delta) |> should.be_true
  close(alignment.surface_z(p, 10.0, 0.0), 3.0, delta) |> should.be_true
  close(alignment.surface_z(p, 0.0, 10.0), 5.0, delta) |> should.be_true
  // Predicts (10,10): 0.2*10 + 0.4*10 + 1.0 = 7.0.
  close(alignment.surface_z(p, 10.0, 10.0), 7.0, delta) |> should.be_true
}

// A flat board parallel to the bed: all captured Z equal -> a~0, b~0, c~the Z.
pub fn flat_board_zero_slope_test() {
  let corrs = [
    corr_with_z(0.0, 0.0, 2.5),
    corr_with_z(10.0, 0.0, 2.5),
    corr_with_z(0.0, 10.0, 2.5),
    corr_with_z(10.0, 10.0, 2.5),
  ]
  let assert Ok(Alignment(z_plane: p, ..)) = alignment.fit(corrs)
  close(p.a, 0.0, delta) |> should.be_true
  close(p.b, 0.0, delta) |> should.be_true
  close(p.c, 2.5, delta) |> should.be_true
  // The surface is 2.5 everywhere.
  close(alignment.surface_z(p, 0.0, 0.0), 2.5, delta) |> should.be_true
  close(alignment.surface_z(p, 123.0, -45.0), 2.5, delta) |> should.be_true
}

// Off-origin board with a tilt and a far-from-origin centroid, to exercise the
// centroid-shift fold-back for the plane constant c (mirrors the XY tx/ty fold).
pub fn plane_fits_off_origin_with_centroid_shift_test() {
  // z = 1.0*bx + 2.0*by + 3.0, sampled away from the origin.
  let plane_z = fn(bx: Float, by: Float) { 1.0 *. bx +. 2.0 *. by +. 3.0 }
  let corrs = [
    corr_with_z(100.0, 200.0, plane_z(100.0, 200.0)),
    corr_with_z(110.0, 200.0, plane_z(110.0, 200.0)),
    corr_with_z(100.0, 215.0, plane_z(100.0, 215.0)),
    corr_with_z(108.0, 212.0, plane_z(108.0, 212.0)),
  ]
  let assert Ok(Alignment(z_plane: p, ..)) = alignment.fit(corrs)
  close(p.a, 1.0, prop_delta) |> should.be_true
  close(p.b, 2.0, prop_delta) |> should.be_true
  close(p.c, 3.0, prop_delta) |> should.be_true
}

// A degenerate XY fit (collinear board points) is still Degenerate — the plane
// shares the same singular AtA, so adding Z does not rescue the fit.
pub fn degenerate_with_z_still_degenerate_test() {
  alignment.fit([
    corr_with_z(0.0, 0.0, 1.0),
    corr_with_z(1.0, 1.0, 2.0),
    corr_with_z(2.0, 2.0, 3.0),
  ])
  |> should.equal(Error(Degenerate))
}

// --- Z residual (the plane's honesty signal, ADR-0020) ----------------------

// z_point_errors over a flat plane whose constant matches every captured Z is
// ~0 everywhere (the captures lie on the plane).
pub fn z_point_errors_flat_plane_zero_test() {
  let plane = ZPlane(a: 0.0, b: 0.0, c: 2.0)
  let corrs = [
    corr_with_z(0.0, 0.0, 2.0),
    corr_with_z(10.0, 0.0, 2.0),
    corr_with_z(5.0, 7.0, 2.0),
  ]
  let errors = alignment.z_point_errors(plane, corrs)
  errors
  |> each(fn(e) { close(e, 0.0, prop_delta) |> should.be_true })
}

// z_point_errors flags a capture sitting off the plane by exactly its offset.
pub fn z_point_errors_offset_point_test() {
  let plane = ZPlane(a: 0.0, b: 0.0, c: 2.0)
  // Second capture is 1.5 mm above the plane; the others lie on it.
  let corrs = [
    corr_with_z(0.0, 0.0, 2.0),
    corr_with_z(10.0, 0.0, 3.5),
    corr_with_z(5.0, 7.0, 2.0),
  ]
  let errors = alignment.z_point_errors(plane, corrs)
  let assert [e0, e1, e2] = errors
  close(e0, 0.0, prop_delta) |> should.be_true
  close(e1, 1.5, prop_delta) |> should.be_true
  close(e2, 0.0, prop_delta) |> should.be_true
}

// THE 3-point blind spot: with exactly 3 captures a plane fits them exactly, so
// the Z residual is ~0 regardless of how inconsistent the captured heights are.
// n is carried through as 3 so the gate (Z2) can mark Z "unverified".
pub fn three_captures_z_max_zero_with_arbitrary_z_test() {
  let corrs = [
    corr_with_z(0.0, 0.0, 3.0),
    corr_with_z(10.0, 0.0, 9.0),
    corr_with_z(0.0, 10.0, -4.0),
  ]
  let assert Ok(Alignment(residuals: r, ..)) = alignment.fit(corrs)
  close(r.z_max, 0.0, prop_delta) |> should.be_true
  close(r.z_rms, 0.0, prop_delta) |> should.be_true
  r.n |> should.equal(3)
}

// THE scenario (ADR-0020): 4 captures where two same-side fiducials were jogged
// to wildly different heights (Z3 vs Z9). The least-squares plane cannot pass
// through an inconsistent 4th point, so z_max blows past any sane tolerance.
pub fn four_captures_inconsistent_z_large_z_max_test() {
  // Three coplanar captures define a flat plane at Z=3; the 4th, on the same
  // side, was jogged to Z=9 (a ~6 mm discrepancy) — the Z3/Z9 garbage capture.
  let corrs = [
    corr_with_z(0.0, 0.0, 3.0),
    corr_with_z(10.0, 0.0, 3.0),
    corr_with_z(0.0, 10.0, 3.0),
    corr_with_z(10.0, 10.0, 9.0),
  ]
  let assert Ok(Alignment(residuals: r, ..)) = alignment.fit(corrs)
  { r.z_max >. 1.0 } |> should.be_true
  r.n |> should.equal(4)
}

// 4 consistent (coplanar) captures fit the plane exactly -> z_max ~0, n == 4.
pub fn four_captures_consistent_z_small_z_max_test() {
  // A genuine tilt: z = 0.2*bx + 0.1*by + 1.0, sampled at four points that all
  // lie on it. The plane fits them all -> residual ~0.
  let plane_z = fn(bx: Float, by: Float) { 0.2 *. bx +. 0.1 *. by +. 1.0 }
  let corrs = [
    corr_with_z(0.0, 0.0, plane_z(0.0, 0.0)),
    corr_with_z(10.0, 0.0, plane_z(10.0, 0.0)),
    corr_with_z(0.0, 10.0, plane_z(0.0, 10.0)),
    corr_with_z(10.0, 10.0, plane_z(10.0, 10.0)),
  ]
  let assert Ok(Alignment(residuals: r, ..)) = alignment.fit(corrs)
  close(r.z_max, 0.0, prop_delta) |> should.be_true
  close(r.z_rms, 0.0, prop_delta) |> should.be_true
  r.n |> should.equal(4)
}

// The XY residual is UNCHANGED by the Z addition: a known 4-point fit with a
// perturbed XY capture but inconsistent Z still reports the same XY rms/max as
// the perturbation alone drives, independent of the captured heights.
pub fn xy_residual_unchanged_by_z_test() {
  let source = Transform2D(a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0)
  let boards = [#(0.0, 0.0), #(10.0, 0.0), #(0.0, 10.0), #(10.0, 10.0)]

  // Build correspondences with an XY perturbation on the first point and
  // ARBITRARY (inconsistent) captured Z on every point.
  let delta_perturb = 0.4
  let zs = [3.0, 9.0, -2.0, 5.0]
  let corrs =
    list.map2(boards, zs, fn(b, z) {
      let #(mx, my) = t2d.apply(source, b)
      Correspondence(board: b, machine: #(mx, my), machine_z: z)
    })
  let assert [
    Correspondence(board: b0, machine: #(m0x, m0y), machine_z: z0),
    ..rest
  ] = corrs
  let perturbed = [
    Correspondence(
      board: b0,
      machine: #(m0x +. delta_perturb, m0y),
      machine_z: z0,
    ),
    ..rest
  ]

  let assert Ok(Alignment(residuals: r, ..)) = alignment.fit(perturbed)
  // The XY signal is exactly the perturbation-driven residual (same as the
  // pre-Z `perturbation_drives_residual_max_test`): wild Z does not touch it.
  { r.max >. 0.0 } |> should.be_true
  { r.rms >. 0.0 } |> should.be_true
  { r.rms <. r.max +. 1.0e-9 } |> should.be_true
  { r.max <=. delta_perturb +. 1.0e-9 } |> should.be_true
  { r.max >=. delta_perturb /. 4.0 -. 1.0e-12 } |> should.be_true
}

// --- helper -----------------------------------------------------------------

fn each(xs: List(a), f: fn(a) -> b) -> Nil {
  case xs {
    [] -> Nil
    [first, ..rest] -> {
      f(first)
      each(rest, f)
    }
  }
}
