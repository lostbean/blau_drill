//// A **solved** board -> machine affine `Transform2D` together with its fit
//// `residuals`. Ported 1:1 from `BlauDrill.Alignment`.
////
//// An `Alignment` is the least-squares affine fit of 3+ human-captured
//// `Correspondence`s. The only constructor is `fit/1`. Fewer than 3 points is a
//// `Error(TooFew)`; collinear/coincident board points are `Error(Degenerate)`.
////
//// The fit centers the board points on their centroid before forming the 3x3
//// normal equations (conditioning the solve), folds the centroid shift back
//// into the translation afterwards, and solves the shared `AtA` matrix once for
//// both the X unknowns `[a, b, tx]` and the Y unknowns `[c, d, ty]` via
//// Cramer's rule with a scale-relative singular check.

import blau_drill/domain/correspondence.{type Correspondence, Correspondence}
import blau_drill/domain/transform2d.{type Transform2D, Transform2D}
import gleam/float
import gleam/int
import gleam/list

// Scale-relative singular threshold for the 3x3 normal matrix AtA, mirroring
// the rationale in transform2d.invert: |det(AtA)| is compared against this
// fraction of the cube of the matrix's entry scale.
const epsilon = 1.0e-9

/// The per-point fit error, in millimetres.
///
/// * `rms` — root-mean-square of the per-correspondence Euclidean errors.
/// * `max` — the largest single-correspondence error.
pub type Residuals {
  Residuals(rms: Float, max: Float)
}

/// A solved alignment: a fitted `Transform2D` plus its residuals.
/// Only `fit/1` constructs this value.
pub type Alignment {
  Alignment(transform: Transform2D, residuals: Residuals)
}

/// A fit failure.
///
/// * `TooFew` — fewer than 3 correspondences.
/// * `Degenerate` — board points are collinear or coincident (AtA singular).
pub type FitError {
  TooFew
  Degenerate
}

/// The shared 3x3 normal matrix `AtA`, held by its upper triangle:
/// `s_xx, s_xy, s_x, s_yy, s_y, n`.
type Ata =
  #(Float, Float, Float, Float, Float, Float)

/// A right-hand side `At*m`: `t_xm, t_ym, t_m`.
type Rhs =
  #(Float, Float, Float)

/// Least-squares-fit correspondences into an `Alignment` — the **only**
/// constructor.
///
/// Returns `Ok(Alignment)` for 3+ non-collinear correspondences; `Error(TooFew)`
/// for fewer than 3; `Error(Degenerate)` when the board points are
/// collinear/coincident.
pub fn fit(correspondences: List(Correspondence)) -> Result(Alignment, FitError) {
  case list.length(correspondences) < 3 {
    True -> Error(TooFew)
    False -> fit_nonempty(correspondences)
  }
}

fn fit_nonempty(
  correspondences: List(Correspondence),
) -> Result(Alignment, FitError) {
  // Center the board points on their centroid before forming the normal
  // equations, then fold the centroid shift back into the translation.
  let #(cx, cy) = board_centroid(correspondences)
  let #(ata, atmx, atmy) = normal_equations(correspondences, cx, cy)

  case solve3(ata, atmx) {
    Error(Degenerate) -> Error(Degenerate)
    Ok(#(a, b, tx_c)) -> {
      // AtA is non-singular for X, so it is for Y too (same matrix).
      let assert Ok(#(c, d, ty_c)) = solve3(ata, atmy)

      // Fold the centroid shift back into the translation:
      //   m = L.(b - c) + t_c = L.b + (t_c - L.c).
      let tx = tx_c -. { a *. cx +. b *. cy }
      let ty = ty_c -. { c *. cx +. d *. cy }

      let transform = Transform2D(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
      Ok(Alignment(
        transform: transform,
        residuals: residuals(transform, correspondences),
      ))
    }
    // solve3 only returns Degenerate or Ok, but the compiler wants exhaustive
    // matching against the FitError variants used elsewhere; TooFew can't occur
    // here. Re-route defensively as Degenerate (unreachable).
    Error(_) -> Error(Degenerate)
  }
}

// --- normal equations --------------------------------------------------

// The centroid of the board points — the shift that conditions the solve.
fn board_centroid(correspondences: List(Correspondence)) -> #(Float, Float) {
  let #(sx, sy, n) =
    list.fold(correspondences, #(0.0, 0.0, 0.0), fn(acc, corr) {
      let #(sx, sy, n) = acc
      let Correspondence(board: #(bx, by), ..) = corr
      #(sx +. bx, sy +. by, n +. 1.0)
    })
  #(sx /. n, sy /. n)
}

// Build AtA (symmetric 3x3) and the right-hand sides Atmx, Atmy, where each row
// of A is `[bx - cx, by - cy, 1]`. Accumulated in a single pass.
fn normal_equations(
  correspondences: List(Correspondence),
  cx: Float,
  cy: Float,
) -> #(Ata, Rhs, Rhs) {
  let init = #(
    // AtA upper triangle: s_xx, s_xy, s_x, s_yy, s_y, n
    #(0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
    // Atmx: t_xmx, t_ymx, t_mx
    #(0.0, 0.0, 0.0),
    // Atmy: t_xmy, t_ymy, t_my
    #(0.0, 0.0, 0.0),
  )

  list.fold(correspondences, init, fn(acc, corr) {
    let #(
      #(s_xx, s_xy, s_x, s_yy, s_y, n),
      #(t_xmx, t_ymx, t_mx),
      #(t_xmy, t_ymy, t_my),
    ) = acc
    let Correspondence(board: #(raw_bx, raw_by), machine: #(mx, my)) = corr
    let bx = raw_bx -. cx
    let by = raw_by -. cy

    #(
      #(
        s_xx +. bx *. bx,
        s_xy +. bx *. by,
        s_x +. bx,
        s_yy +. by *. by,
        s_y +. by,
        n +. 1.0,
      ),
      #(t_xmx +. bx *. mx, t_ymx +. by *. mx, t_mx +. mx),
      #(t_xmy +. bx *. my, t_ymy +. by *. my, t_my +. my),
    )
  })
}

// --- 3x3 solver --------------------------------------------------------

// Solve the 3x3 symmetric system `M . x = rhs`, where M is given by its upper
// triangle. Cramer's rule with a scale-relative singular check on the
// determinant. Returns `Error(Degenerate)` when M is rank-deficient.
fn solve3(ata: Ata, rhs: Rhs) -> Result(#(Float, Float, Float), FitError) {
  let #(s_xx, s_xy, s_x, s_yy, s_y, n) = ata
  let #(r0, r1, r2) = rhs

  // Full symmetric 3x3 row-major (lower triangle mirrored).
  let m = #(s_xx, s_xy, s_x, s_xy, s_yy, s_y, s_x, s_y, n)
  let det = det3(m)

  // Scale-relative threshold: |det| compared to eps*(scale^3 + 1).
  let scale = max_abs9(m)
  let threshold = epsilon *. { scale *. scale *. scale +. 1.0 }

  case float.absolute_value(det) <=. threshold {
    True -> Error(Degenerate)
    False -> {
      let #(a0, a1, a2, a3, a4, a5, a6, a7, a8) = m
      let inv_det = 1.0 /. det

      let x0 = det3(#(r0, a1, a2, r1, a4, a5, r2, a7, a8)) *. inv_det
      let x1 = det3(#(a0, r0, a2, a3, r1, a5, a6, r2, a8)) *. inv_det
      let x2 = det3(#(a0, a1, r0, a3, a4, r1, a6, a7, r2)) *. inv_det

      Ok(#(x0, x1, x2))
    }
  }
}

// Determinant of a 3x3 matrix given row-major as a 9-tuple.
fn det3(
  m: #(Float, Float, Float, Float, Float, Float, Float, Float, Float),
) -> Float {
  let #(a, b, c, d, e, f, g, h, i) = m
  a
  *. { e *. i -. f *. h }
  -. b
  *. { d *. i -. f *. g }
  +. c
  *. { d *. h -. e *. g }
}

// The largest-magnitude entry of a row-major 9-tuple.
fn max_abs9(
  m: #(Float, Float, Float, Float, Float, Float, Float, Float, Float),
) -> Float {
  let #(a, b, c, d, e, f, g, h, i) = m
  [a, b, c, d, e, f, g, h, i]
  |> list.map(float.absolute_value)
  |> list.fold(0.0, float.max)
}

// --- residuals ---------------------------------------------------------

// Apply the fitted transform to each board point and measure the Euclidean
// error to the captured machine point; report rms and max (mm).
fn residuals(
  transform: Transform2D,
  correspondences: List(Correspondence),
) -> Residuals {
  let errors =
    list.map(correspondences, fn(corr) {
      let Correspondence(board: board, machine: #(mx, my)) = corr
      let #(px, py) = transform2d.apply(transform, board)
      let dx = px -. mx
      let dy = py -. my
      float_sqrt(dx *. dx +. dy *. dy)
    })

  let n = int.to_float(list.length(errors))
  let sum_sq = list.fold(errors, 0.0, fn(acc, e) { acc +. e *. e })

  Residuals(rms: float_sqrt(sum_sq /. n), max: max_list(errors))
}

fn max_list(xs: List(Float)) -> Float {
  // errors is always non-empty here (>= 3 correspondences); fall back to 0.0.
  case xs {
    [first, ..rest] -> list.fold(rest, first, float.max)
    [] -> 0.0
  }
}

fn float_sqrt(x: Float) -> Float {
  let assert Ok(r) = float.square_root(x)
  r
}
