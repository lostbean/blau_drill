defmodule BlauDrill.Transform2D do
  @moduledoc """
  An immutable 2×3 affine transform mapping **board coordinates → machine
  coordinates**.

  This is the foundation every other domain module builds on: a hole lives only
  in board space, and its machine coordinate is the *derived view*
  `apply(transform, hole)` (see `CONTEXT.md`). Being a full affine, one matrix
  absorbs translation, rotation, **mirror**, and skew at once — the back-side
  X-mirror, a board not square to the bed, and the fiducial offset all collapse
  into the same value rather than living as separate flags or offsets.

  ## Matrix convention

  The transform is the 2×3 affine matrix

      ┌             ┐
      │ a   b   tx  │
      │ c   d   ty  │
      └             ┘

  applied to a board point `{bx, by}` (treated as the homogeneous column
  `[bx, by, 1]ᵀ`) to produce a machine point `{mx, my}`:

      mx = a * bx + b * by + tx
      my = c * bx + d * by + ty

  Rotation follows the standard mathematical (counter-clockwise) convention:
  a rotation by θ is `a = cos θ, b = -sin θ, c = sin θ, d = cos θ`, so a +90°
  rotation maps `{1, 0} -> {0, 1}`.

  The **back-side X-mirror** is just `a = -1, d = 1` (and whatever translation
  the fit needs): it negates X, e.g. `{5, 7} -> {-5, 7}`. There is no separate
  mirror flag — the affine carries it.

  ## Composition

  `compose/2` is matrix multiplication ordered so that

      apply(compose(a, b), p) == apply(a, apply(b, p))

  i.e. `compose(a, b)` applies `b` first, then `a`. `identity/0` is the neutral
  element, and `compose/2` is associative, so transforms form a monoid under
  composition; invertible ones (det ≠ 0) form a group via `invert/1`.
  """

  # Relative tolerance for the singular-determinant check. The determinant
  # `a*d - b*c` has the units of the linear-part entries *squared*, so a fixed
  # absolute threshold would be too strict for large entries and too loose for
  # small ones. Instead we compare `|det|` against this fraction of the squared
  # entry scale (`max(|a|,|b|,|c|,|d|)²`): a mapping whose det is this much
  # smaller than its own entries is, numerically, a collinear (zero-area)
  # mapping and cannot be inverted.
  @epsilon 1.0e-9

  @enforce_keys [:a, :b, :c, :d, :tx, :ty]
  defstruct [:a, :b, :c, :d, :tx, :ty]

  @typedoc """
  A 2×3 affine transform `[[a, b, tx], [c, d, ty]]` mapping board → machine.

  All fields are plain floats. `a, b, c, d` are the linear part (rotation /
  scale / mirror / skew); `tx, ty` are the translation.
  """
  @type t :: %__MODULE__{
          a: float(),
          b: float(),
          c: float(),
          d: float(),
          tx: float(),
          ty: float()
        }

  @typedoc "A 2-D point `{x, y}` (board or machine space), as floats."
  @type point :: {number(), number()}

  @doc """
  The identity transform: `apply(identity(), p) == p` for every point `p`.

  It is the neutral element of `compose/2`.

  ## Examples

      iex> BlauDrill.Transform2D.apply(BlauDrill.Transform2D.identity(), {3.0, 4.0})
      {3.0, 4.0}
  """
  @spec identity() :: t()
  def identity do
    %__MODULE__{a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0}
  end

  @doc """
  Apply the transform to a board point, returning the machine point.

      mx = a * bx + b * by + tx
      my = c * bx + d * by + ty

  ## Examples

      iex> t = %BlauDrill.Transform2D{a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0}
      iex> BlauDrill.Transform2D.apply(t, {5.0, 7.0})
      {-5.0, 7.0}
  """
  @spec apply(t(), point()) :: {float(), float()}
  def apply(%__MODULE__{a: a, b: b, c: c, d: d, tx: tx, ty: ty}, {bx, by}) do
    {a * bx + b * by + tx, c * bx + d * by + ty}
  end

  @doc """
  Compose two transforms. `compose(a, b)` applies `b` first, then `a`:

      apply(compose(a, b), p) == apply(a, apply(b, p))

  This is the matrix product `a · b` (treating each as a 3×3 affine with bottom
  row `[0, 0, 1]`). Composition is associative and `identity/0` is neutral on
  both sides.

  ## Examples

      iex> a = %BlauDrill.Transform2D{a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 10.0, ty: 0.0}
      iex> b = %BlauDrill.Transform2D{a: 2.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0}
      iex> BlauDrill.Transform2D.apply(BlauDrill.Transform2D.compose(a, b), {3.0, 4.0})
      {16.0, 4.0}
  """
  @spec compose(t(), t()) :: t()
  def compose(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      a: a.a * b.a + a.b * b.c,
      b: a.a * b.b + a.b * b.d,
      c: a.c * b.a + a.d * b.c,
      d: a.c * b.b + a.d * b.d,
      tx: a.a * b.tx + a.b * b.ty + a.tx,
      ty: a.c * b.tx + a.d * b.ty + a.ty
    }
  end

  @doc """
  Invert the transform.

  Returns `{:ok, inverse}` for an invertible transform — one whose linear-part
  determinant `a*d - b*c` is non-zero (magnitude above the singular epsilon).
  The inverse satisfies, up to float tolerance:

      apply(invert(t)_ok, apply(t, p)) == p
      apply(t, apply(invert(t)_ok, p)) == p

  Returns `{:error, :singular}` when the determinant is ≈ 0 (a collinear or
  zero-area mapping that cannot be inverted) — for example an all-zero matrix or
  one whose rows are linearly dependent.

  ## Examples

      iex> t = %BlauDrill.Transform2D{a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 4.0, ty: -3.0}
      iex> {:ok, inv} = BlauDrill.Transform2D.invert(t)
      iex> BlauDrill.Transform2D.apply(inv, BlauDrill.Transform2D.apply(t, {5.0, 7.0}))
      {5.0, 7.0}

      iex> BlauDrill.Transform2D.invert(%BlauDrill.Transform2D{a: 0.0, b: 0.0, c: 0.0, d: 0.0, tx: 0.0, ty: 0.0})
      {:error, :singular}
  """
  @spec invert(t()) :: {:ok, t()} | {:error, :singular}
  def invert(%__MODULE__{a: a, b: b, c: c, d: d, tx: tx, ty: ty}) do
    det = a * d - b * c

    # Scale-relative singular test: compare |det| to the squared entry scale so
    # the threshold tracks the magnitude of the matrix (see @epsilon). The `+ 1`
    # floor keeps a near-zero matrix (tiny entries) from making the threshold
    # vanish.
    scale = max(max(abs(a), abs(b)), max(abs(c), abs(d)))
    threshold = @epsilon * (scale * scale + 1.0)

    if abs(det) <= threshold do
      {:error, :singular}
    else
      inv_det = 1.0 / det

      # Inverse of the linear 2×2 part.
      ia = d * inv_det
      ib = -b * inv_det
      ic = -c * inv_det
      id = a * inv_det

      # Inverse translation: -(L⁻¹ · translation).
      itx = -(ia * tx + ib * ty)
      ity = -(ic * tx + id * ty)

      {:ok, %__MODULE__{a: ia, b: ib, c: ic, d: id, tx: itx, ty: ity}}
    end
  end
end
