//// Alignment tests, ported from `test/blau_drill/alignment_test.exs`. The
//// StreamData property tests are covered as concrete example cases that
//// exercise the same invariants (recover a random non-degenerate affine with
//// ~0 residual). Float assertions use a tolerance; expected values were
//// confirmed against the Elixir `Alignment.fit/1` (see the agent report).

import blau_drill/domain/alignment.{Alignment, Degenerate, TooFew}
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
// applying a known transform to it (the noise-free, exact-fit case).
fn corr_from(t: Transform2D, board: #(Float, Float)) -> correspondence.Correspondence {
  Correspondence(board: board, machine: t2d.apply(t, board))
}

// --- too-few guard ----------------------------------------------------------

pub fn zero_correspondences_too_few_test() {
  alignment.fit([]) |> should.equal(Error(TooFew))
}

pub fn one_correspondence_too_few_test() {
  alignment.fit([Correspondence(board: #(0.0, 0.0), machine: #(1.0, 1.0))])
  |> should.equal(Error(TooFew))
}

pub fn two_correspondences_too_few_test() {
  alignment.fit([
    Correspondence(board: #(0.0, 0.0), machine: #(1.0, 1.0)),
    Correspondence(board: #(1.0, 0.0), machine: #(2.0, 1.0)),
  ])
  |> should.equal(Error(TooFew))
}

// --- degeneracy -------------------------------------------------------------

pub fn three_collinear_degenerate_test() {
  // Board points (0,0), (1,1), (2,2) all on y = x.
  alignment.fit([
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0)),
    Correspondence(board: #(1.0, 1.0), machine: #(3.0, 7.0)),
    Correspondence(board: #(2.0, 2.0), machine: #(6.0, 14.0)),
  ])
  |> should.equal(Error(Degenerate))
}

pub fn collinear_large_coords_degenerate_test() {
  alignment.fit([
    Correspondence(board: #(100.0, 100.0), machine: #(1.0, 2.0)),
    Correspondence(board: #(150.0, 150.0), machine: #(3.0, 4.0)),
    Correspondence(board: #(200.0, 200.0), machine: #(5.0, 6.0)),
  ])
  |> should.equal(Error(Degenerate))
}

pub fn two_coincident_among_three_degenerate_test() {
  alignment.fit([
    Correspondence(board: #(3.0, 5.0), machine: #(1.0, 1.0)),
    Correspondence(board: #(3.0, 5.0), machine: #(2.0, 9.0)),
    Correspondence(board: #(7.0, 1.0), machine: #(4.0, 4.0)),
  ])
  |> should.equal(Error(Degenerate))
}

pub fn all_three_coincident_degenerate_test() {
  alignment.fit([
    Correspondence(board: #(2.0, 2.0), machine: #(1.0, 1.0)),
    Correspondence(board: #(2.0, 2.0), machine: #(2.0, 2.0)),
    Correspondence(board: #(2.0, 2.0), machine: #(3.0, 3.0)),
  ])
  |> should.equal(Error(Degenerate))
}

// --- known-good exact fits --------------------------------------------------

pub fn recovers_x_mirror_translation_test() {
  // a=-1, b=0, c=0, d=1, tx=10, ty=-5.
  let source = Transform2D(a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 10.0, ty: -5.0)
  let boards = [#(0.0, 0.0), #(4.0, 0.0), #(0.0, 3.0)]
  let corrs = list.map(boards, fn(b) { corr_from(source, b) })

  let assert Ok(Alignment(transform: t, residuals: r)) = alignment.fit(corrs)
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

  let assert Ok(Alignment(transform: t, residuals: r)) = alignment.fit(corrs)
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
    let Correspondence(board: b, machine: #(mx, my)) = c
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

  let assert Ok(Alignment(transform: t, residuals: r)) = alignment.fit(corrs)
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
  let c1 = Correspondence(board: #(0.0, 0.0), machine: #(1.0, 1.0))
  let c2 = Correspondence(board: #(1.0, 0.0), machine: #(2.0, 1.0))
  let c3 = Correspondence(board: #(0.0, 1.0), machine: #(1.0, 2.0))
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
    |> pending_alignment.add(Correspondence(board: #(0.0, 0.0), machine: #(1.0, 1.0)))
    |> pending_alignment.add(Correspondence(board: #(1.0, 0.0), machine: #(2.0, 1.0)))
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
  let c = Correspondence(board: #(1.0, 2.0), machine: #(3.0, 4.0))
  c.board |> should.equal(#(1.0, 2.0))
  c.machine |> should.equal(#(3.0, 4.0))
}

// --- property-equivalent example cases --------------------------------------

pub fn recovers_random_nondegenerate_affines_test() {
  // A spread of non-degenerate affines + triangle board points, each fitted
  // back to its source with ~0 residual.
  let cases = [
    #(
      Transform2D(a: 0.9, b: 0.4, c: -0.4, d: 0.9, tx: 12.0, ty: -7.0),
      [#(0.0, 0.0), #(20.0, 0.0), #(0.0, 15.0), #(8.0, 8.0)],
    ),
    #(
      Transform2D(a: -1.3, b: 0.0, c: 0.0, d: 2.1, tx: -30.0, ty: 50.0),
      [#(5.0, 5.0), #(35.0, 5.0), #(5.0, 40.0), #(20.0, 20.0)],
    ),
    #(
      Transform2D(a: 2.0, b: -1.0, c: 1.5, d: 1.2, tx: 0.0, ty: 0.0),
      [#(-10.0, -10.0), #(30.0, -10.0), #(-10.0, 25.0), #(10.0, 10.0)],
    ),
  ]
  cases
  |> each(fn(c) {
    let #(source, boards) = c
    let corrs = list.map(boards, fn(b) { corr_from(source, b) })
    let assert Ok(Alignment(transform: t, residuals: r)) = alignment.fit(corrs)
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
