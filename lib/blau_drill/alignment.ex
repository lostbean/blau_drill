defmodule BlauDrill.Alignment do
  @moduledoc """
  A **solved** board → machine affine `BlauDrill.Transform2D` together with its
  fit `residuals` — the trust gate before any drilling.

  An `Alignment` is the least-squares affine fit of 3–4 human-captured
  `BlauDrill.Correspondence`s (see `CONTEXT.md`: "Alignment", and ADR-0002).
  Being a full affine, the one fitted matrix absorbs translation, rotation, the
  back-side **X-mirror**, and skew at once — there is no separate mirror flag or
  baked `G92`. Every `Alignment` carries its **residuals** (`%{rms, max}` in
  millimetres), the *honesty signal*: `residuals.max` gates the real run (the
  **residual gate**) so a bad fit is caught before the bit touches copper.

  ## The only constructor is `fit/1`

  > #### No public constructor {: .warning}
  >
  > **Callers must never build `%Alignment{}` directly.** `fit/1` is the *only*
  > way to obtain one. The `@enforce_keys` make a bare `%Alignment{}` impossible
  > to construct (both fields are mandatory), and even a fully-populated literal
  > bypasses the validity guarantee — a hand-built struct could carry a
  > transform that was never actually fitted to correspondences, with residuals
  > that lie. Always go through `fit/1`; it is what couples the transform to the
  > data it was solved from. Fewer than 3 points is a *different type*,
  > `BlauDrill.PendingAlignment`, which has no transform field at all.

  ## The fit

  An affine fit solves 6 unknowns as two independent 3-unknown problems that
  share the same coefficient matrix. For each correspondence `i` with board
  point `(bxᵢ, byᵢ)` and machine point `(mxᵢ, myᵢ)`:

      [bxᵢ, byᵢ, 1] · [a, b, tx]ᵀ = mxᵢ        (the X rows)
      [bxᵢ, byᵢ, 1] · [c, d, ty]ᵀ = myᵢ        (the Y rows)

  Stacking all rows into `A` (N×3, built from board points only) and forming the
  3×3 normal equations `AᵀA x = Aᵀ rhs` gives the least-squares solution. `AᵀA`
  depends only on the board points, so it is built and solved once for both the
  X unknowns `[a, b, tx]` (RHS `Aᵀ mx`) and the Y unknowns `[c, d, ty]`
  (RHS `Aᵀ my`).

  ## Degeneracy

  If the board points are collinear or coincident, `AᵀA` is rank-deficient
  (singular) and the fit is rejected with `{:error, :degenerate}` rather than
  silently producing a bad transform. The singularity test is **scale-relative**
  (same rationale as `BlauDrill.Transform2D.invert/1`): the determinant is
  compared against a threshold proportional to the matrix's own magnitude, so a
  rank-deficient `AᵀA` with large entries is not falsely accepted by a fixed
  absolute epsilon.

  ## Residuals

  After solving, the fitted transform is applied to each board point and the
  Euclidean distance to the captured machine point is the per-point error.
  `residuals.rms` is the root-mean-square of those errors; `residuals.max` is
  the worst single-point error. Exact (noise-free) data yields ≈ 0 residuals; a
  slipped board or a mis-clicked point shows up as a large `max`.
  """

  alias BlauDrill.Correspondence
  alias BlauDrill.Transform2D

  # Scale-relative singular threshold for the 3×3 normal matrix AᵀA, mirroring
  # the rationale in Transform2D.invert/1: a fixed absolute epsilon is too
  # strict for large-entry matrices and too loose for small ones, so a
  # rank-deficient AᵀA built from large board coordinates would falsely pass.
  # We compare |det(AᵀA)| against this fraction of the cube of the matrix's
  # entry scale (det of a 3×3 has the units of its entries cubed). The `+ 1`
  # floor keeps a near-zero matrix from collapsing the threshold to 0.
  @epsilon 1.0e-9

  @enforce_keys [:transform, :residuals]
  defstruct [:transform, :residuals]

  @typedoc """
  The per-point fit error, in millimetres.

  * `rms` — root-mean-square of the per-correspondence Euclidean errors.
  * `max` — the largest single-correspondence error.
  """
  @type residuals :: %{rms: float(), max: float()}

  @typedoc """
  A solved alignment: a fitted `Transform2D` plus its residuals.

  Only `fit/1` constructs this value.
  """
  @type t :: %__MODULE__{
          transform: Transform2D.t(),
          residuals: residuals()
        }

  @doc """
  Least-squares-fit correspondences into an `Alignment` — the **only**
  constructor.

  Returns:

    * `{:ok, %Alignment{transform: %Transform2D{}, residuals: %{rms, max}}}`
      for ≥3 non-collinear correspondences;
    * `{:error, :too_few}` for fewer than 3 correspondences (the caller keeps
      its `BlauDrill.PendingAlignment`);
    * `{:error, :degenerate}` when the board points are collinear or coincident
      (the normal matrix is rank-deficient).

  ## Examples

      iex> alias BlauDrill.{Alignment, Correspondence, Transform2D}
      iex> # A back-side X-mirror with translation, sampled at 3 non-collinear points.
      iex> src = %Transform2D{a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 10.0, ty: -5.0}
      iex> corrs =
      ...>   for b <- [{0.0, 0.0}, {4.0, 0.0}, {0.0, 3.0}] do
      ...>     %Correspondence{board: b, machine: Transform2D.apply(src, b)}
      ...>   end
      iex> {:ok, %Alignment{transform: t}} = Alignment.fit(corrs)
      iex> {Float.round(t.a, 6), Float.round(t.tx, 6), Float.round(t.ty, 6)}
      {-1.0, 10.0, -5.0}

      iex> BlauDrill.Alignment.fit([])
      {:error, :too_few}
  """
  @spec fit([Correspondence.t()]) ::
          {:ok, t()} | {:error, :too_few} | {:error, :degenerate}
  def fit(correspondences) when is_list(correspondences) and length(correspondences) < 3 do
    {:error, :too_few}
  end

  def fit(correspondences) when is_list(correspondences) do
    # Center the board points on their centroid before forming the normal
    # equations. With board coordinates clustered far from the origin (a small
    # board offset hundreds of mm out), AᵀA's quadratic entries (~Σbx²) dwarf
    # the part that actually carries the points' *spread*, so the matrix is
    # severely ill-conditioned and the normal-equations solve loses precision —
    # to the point that a perfectly non-degenerate point set can read as
    # singular. Shifting the board origin to the centroid removes the large
    # common offset, conditioning the solve, and the centroid shift is folded
    # back into the translation afterwards (mathematically exact, not an
    # approximation).
    {cx, cy} = board_centroid(correspondences)

    # Build the shared 3×3 normal matrix AᵀA from the centered board points,
    # plus the two right-hand sides Aᵀmx and Aᵀmy.
    {ata, atmx, atmy} = normal_equations(correspondences, cx, cy)

    case solve3(ata, atmx) do
      {:error, :degenerate} ->
        {:error, :degenerate}

      {:ok, {a, b, tx_c}} ->
        # AᵀA is non-singular for X, so it is for Y too (same matrix); the Y
        # solve cannot fail here, but we pattern-match defensively.
        {:ok, {c, d, ty_c}} = solve3(ata, atmy)

        # The solve found the transform for centered board points
        # `(bx - cx, by - cy)`. Fold the centroid shift back into the
        # translation so the transform applies to raw board coordinates:
        #   m = L·(b - c) + t_c = L·b + (t_c - L·c).
        tx = tx_c - (a * cx + b * cy)
        ty = ty_c - (c * cx + d * cy)

        transform = %Transform2D{a: a, b: b, c: c, d: d, tx: tx, ty: ty}
        {:ok, %__MODULE__{transform: transform, residuals: residuals(transform, correspondences)}}
    end
  end

  # --- normal equations --------------------------------------------------

  # The centroid of the board points — the shift that conditions the solve.
  @spec board_centroid([Correspondence.t()]) :: {float(), float()}
  defp board_centroid(correspondences) do
    {sx, sy, n} =
      Enum.reduce(correspondences, {0.0, 0.0, 0.0}, fn
        %Correspondence{board: {bx, by}}, {sx, sy, n} -> {sx + bx, sy + by, n + 1.0}
      end)

    {sx / n, sy / n}
  end

  # Build AᵀA (symmetric 3×3) and the right-hand sides Aᵀmx, Aᵀmy, where each
  # row of A is `[bx - cx, by - cy, 1]` (board points centered on the centroid
  # `{cx, cy}`). Accumulated in a single pass over the correspondences.
  @spec normal_equations([Correspondence.t()], float(), float()) ::
          {{float(), float(), float(), float(), float(), float()}, {float(), float(), float()},
           {float(), float(), float()}}
  defp normal_equations(correspondences, cx, cy) do
    init = {
      # AᵀA upper triangle: s_xx, s_xy, s_x, s_yy, s_y, n
      {0.0, 0.0, 0.0, 0.0, 0.0, 0.0},
      # Aᵀmx: t_xmx, t_ymx, t_mx
      {0.0, 0.0, 0.0},
      # Aᵀmy: t_xmy, t_ymy, t_my
      {0.0, 0.0, 0.0}
    }

    Enum.reduce(correspondences, init, fn
      %Correspondence{board: {raw_bx, raw_by}, machine: {mx, my}},
      {{s_xx, s_xy, s_x, s_yy, s_y, n}, {t_xmx, t_ymx, t_mx}, {t_xmy, t_ymy, t_my}} ->
        bx = raw_bx - cx
        by = raw_by - cy

        {
          {
            s_xx + bx * bx,
            s_xy + bx * by,
            s_x + bx,
            s_yy + by * by,
            s_y + by,
            n + 1.0
          },
          {
            t_xmx + bx * mx,
            t_ymx + by * mx,
            t_mx + mx
          },
          {
            t_xmy + bx * my,
            t_ymy + by * my,
            t_my + my
          }
        }
    end)
  end

  # --- 3×3 solver --------------------------------------------------------

  # Solve the 3×3 symmetric system `M · x = rhs`, where M is given by its upper
  # triangle (s_xx, s_xy, s_x, s_yy, s_y, n):
  #
  #     | s_xx  s_xy  s_x | | x0 |   | r0 |
  #     | s_xy  s_yy  s_y | | x1 | = | r1 |
  #     | s_x   s_y   n   | | x2 |   | r2 |
  #
  # Solved by Cramer's rule with a scale-relative singular check on the
  # determinant. Returns `{:error, :degenerate}` when M is rank-deficient
  # (collinear/coincident board points).
  @spec solve3(
          {float(), float(), float(), float(), float(), float()},
          {float(), float(), float()}
        ) :: {:ok, {float(), float(), float()}} | {:error, :degenerate}
  defp solve3({s_xx, s_xy, s_x, s_yy, s_y, n}, {r0, r1, r2}) do
    # Full symmetric 3×3 with the lower triangle mirrored.
    m = {
      s_xx,
      s_xy,
      s_x,
      s_xy,
      s_yy,
      s_y,
      s_x,
      s_y,
      n
    }

    det = det3(m)

    # Scale-relative threshold: |det| is compared to ε·(scale³ + 1), where scale
    # is the largest-magnitude entry. det of a 3×3 scales as the cube of its
    # entries, so this tracks the matrix magnitude instead of using a fixed
    # epsilon (which would falsely accept a large-entry rank-deficient AᵀA).
    scale = m |> Tuple.to_list() |> Enum.map(&abs/1) |> Enum.max()
    threshold = @epsilon * (scale * scale * scale + 1.0)

    if abs(det) <= threshold do
      {:error, :degenerate}
    else
      # Cramer's rule: replace each column with the RHS in turn.
      {a0, a1, a2, a3, a4, a5, a6, a7, a8} = m
      inv_det = 1.0 / det

      x0 = det3({r0, a1, a2, r1, a4, a5, r2, a7, a8}) * inv_det
      x1 = det3({a0, r0, a2, a3, r1, a5, a6, r2, a8}) * inv_det
      x2 = det3({a0, a1, r0, a3, a4, r1, a6, a7, r2}) * inv_det

      {:ok, {x0, x1, x2}}
    end
  end

  # Determinant of a 3×3 matrix given row-major as a 9-tuple.
  @spec det3({
          float(),
          float(),
          float(),
          float(),
          float(),
          float(),
          float(),
          float(),
          float()
        }) :: float()
  defp det3({a, b, c, d, e, f, g, h, i}) do
    a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
  end

  # --- residuals ---------------------------------------------------------

  # Apply the fitted transform to each board point and measure the Euclidean
  # error to the captured machine point; report rms and max (mm).
  @spec residuals(Transform2D.t(), [Correspondence.t()]) :: residuals()
  defp residuals(transform, correspondences) do
    errors =
      Enum.map(correspondences, fn %Correspondence{board: board, machine: {mx, my}} ->
        {px, py} = Transform2D.apply(transform, board)
        dx = px - mx
        dy = py - my
        :math.sqrt(dx * dx + dy * dy)
      end)

    n = length(errors)
    sum_sq = Enum.reduce(errors, 0.0, fn e, acc -> acc + e * e end)

    %{
      rms: :math.sqrt(sum_sq / n),
      max: Enum.max(errors)
    }
  end
end
