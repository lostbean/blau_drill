defmodule BlauDrill.Transform2DTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlauDrill.Transform2D

  @moduletag :transform2d

  # Tight delta for hand-computed example assertions.
  @delta 1.0e-9
  # Looser delta for property tests that chain several float operations
  # (compose, invert) and so accumulate rounding error.
  @prop_delta 1.0e-6

  # --- StreamData generators ---------------------------------------------

  # A reasonable coordinate range for board/machine points (mm-ish).
  defp coord, do: float(min: -200.0, max: 200.0)

  defp point, do: {coord(), coord()}

  # An *invertible* transform built as rotation ∘ (non-zero) scale ∘
  # translation. Each factor is invertible (scale factors are bounded away
  # from zero and rotation/translation are always invertible), so the
  # composite always has a non-zero determinant.
  defp invertible_transform do
    gen all(
          angle <- float(min: -:math.pi(), max: :math.pi()),
          sx <- one_of([float(min: 0.2, max: 5.0), float(min: -5.0, max: -0.2)]),
          sy <- one_of([float(min: 0.2, max: 5.0), float(min: -5.0, max: -0.2)]),
          tx <- coord(),
          ty <- coord()
        ) do
      rotation =
        %Transform2D{
          a: :math.cos(angle),
          b: -:math.sin(angle),
          c: :math.sin(angle),
          d: :math.cos(angle),
          tx: 0.0,
          ty: 0.0
        }

      scale = %Transform2D{a: sx, b: 0.0, c: 0.0, d: sy, tx: 0.0, ty: 0.0}
      translation = %Transform2D{a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: tx, ty: ty}

      Transform2D.compose(rotation, Transform2D.compose(scale, translation))
    end
  end

  # --- Example-based tests -----------------------------------------------

  describe "identity/0 and apply/2" do
    test "identity maps every point to itself" do
      for {x, y} <- [{0.0, 0.0}, {3.0, 4.0}, {-12.5, 7.25}, {200.0, -200.0}] do
        {mx, my} = Transform2D.apply(Transform2D.identity(), {x, y})
        assert_in_delta mx, x, @delta
        assert_in_delta my, y, @delta
      end
    end

    test "pure translation tx=10, ty=-5 shifts points" do
      t = %Transform2D{a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 10.0, ty: -5.0}

      {mx0, my0} = Transform2D.apply(t, {0.0, 0.0})
      assert_in_delta mx0, 10.0, @delta
      assert_in_delta my0, -5.0, @delta

      {mx1, my1} = Transform2D.apply(t, {3.0, 4.0})
      assert_in_delta mx1, 13.0, @delta
      assert_in_delta my1, -1.0, @delta
    end

    test "pure 90° CCW rotation about origin maps {1,0} -> {0,1}" do
      # Convention (documented in the module): standard math, counter-clockwise.
      # a=cos θ, b=-sin θ, c=sin θ, d=cos θ. For θ=90°: a=0, b=-1, c=1, d=0.
      t = %Transform2D{a: 0.0, b: -1.0, c: 1.0, d: 0.0, tx: 0.0, ty: 0.0}

      {mx, my} = Transform2D.apply(t, {1.0, 0.0})
      assert_in_delta mx, 0.0, @delta
      assert_in_delta my, 1.0, @delta

      # ...and {0,1} -> {-1,0}, completing the CCW quarter turn.
      {mx2, my2} = Transform2D.apply(t, {0.0, 1.0})
      assert_in_delta mx2, -1.0, @delta
      assert_in_delta my2, 0.0, @delta
    end

    test "X-mirror (back-side drilling) negates X via a=-1, d=1" do
      # LOAD-BEARING: the back-side X-mirror is NOT a flag in blau-drill — the
      # affine Transform2D absorbs it directly (CONTEXT.md: "Back-side
      # X-mirror"). A transform with a=-1, d=1 mirrors X about the machine Y
      # axis: {5, 7} -> {-5, 7}.
      mirror = %Transform2D{a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0}

      {mx, my} = Transform2D.apply(mirror, {5.0, 7.0})
      assert_in_delta mx, -5.0, @delta
      assert_in_delta my, 7.0, @delta
    end

    test "mirror+translation reproduces the segby_v1 case shape" do
      # The segby_v1 fixture's first drilled hole is board {-57.15, 80.01}.
      # Under the back-side X-mirror (a=-1, d=1, tx=0, ty=0) the X is negated,
      # putting the hole at machine {57.15, 80.01}.
      t = %Transform2D{a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0}

      {mx, my} = Transform2D.apply(t, {-57.15, 80.01})
      assert_in_delta mx, 57.15, @delta
      assert_in_delta my, 80.01, @delta
    end
  end

  describe "compose/2" do
    test "compose(a, b) applies b first, then a" do
      # a: translate by (10, 0). b: scale x by 2.
      a = %Transform2D{a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 10.0, ty: 0.0}
      b = %Transform2D{a: 2.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0}

      composed = Transform2D.compose(a, b)
      # Point {3, 4}: scale -> {6, 4}, then translate -> {16, 4}.
      {mx, my} = Transform2D.apply(composed, {3.0, 4.0})
      assert_in_delta mx, 16.0, @delta
      assert_in_delta my, 4.0, @delta

      # Equivalence: apply(compose(a,b), p) == apply(a, apply(b, p)).
      {ax, ay} = Transform2D.apply(a, Transform2D.apply(b, {3.0, 4.0}))
      assert_in_delta mx, ax, @delta
      assert_in_delta my, ay, @delta
    end
  end

  describe "invert/1" do
    test "inverse of a known translation+mirror" do
      t = %Transform2D{a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 4.0, ty: -3.0}
      assert {:ok, inv} = Transform2D.invert(t)

      # t maps {5, 7} -> {-1, 4}; inv must map it back.
      {mx, my} = Transform2D.apply(t, {5.0, 7.0})
      {bx, by} = Transform2D.apply(inv, {mx, my})
      assert_in_delta bx, 5.0, @delta
      assert_in_delta by, 7.0, @delta
    end

    test "invert of an all-zero (singular) matrix returns {:error, :singular}" do
      singular = %Transform2D{a: 0.0, b: 0.0, c: 0.0, d: 0.0, tx: 0.0, ty: 0.0}
      assert Transform2D.invert(singular) == {:error, :singular}
    end

    test "invert of a collinear/zero-determinant matrix returns {:error, :singular}" do
      # det = a*d - b*c = 1*2 - 1*2 = 0.
      singular = %Transform2D{a: 1.0, b: 1.0, c: 2.0, d: 2.0, tx: 5.0, ty: 9.0}
      assert Transform2D.invert(singular) == {:error, :singular}
    end
  end

  # --- Property-based tests ----------------------------------------------

  property "invert round-trips a point in both directions" do
    check all(t <- invertible_transform(), p <- point()) do
      assert {:ok, inv} = Transform2D.invert(t)

      # apply(t, apply(inv, p)) ≈ p
      {rx, ry} = Transform2D.apply(t, Transform2D.apply(inv, p))
      {px, py} = p
      assert_in_delta rx, px, @prop_delta
      assert_in_delta ry, py, @prop_delta

      # apply(inv, apply(t, p)) ≈ p
      {sx, sy} = Transform2D.apply(inv, Transform2D.apply(t, p))
      assert_in_delta sx, px, @prop_delta
      assert_in_delta sy, py, @prop_delta
    end
  end

  property "compose is associative" do
    check all(
            a <- invertible_transform(),
            b <- invertible_transform(),
            c <- invertible_transform(),
            p <- point()
          ) do
      left = Transform2D.compose(Transform2D.compose(a, b), c)
      right = Transform2D.compose(a, Transform2D.compose(b, c))

      {lx, ly} = Transform2D.apply(left, p)
      {rx, ry} = Transform2D.apply(right, p)
      assert_in_delta lx, rx, @prop_delta
      assert_in_delta ly, ry, @prop_delta
    end
  end

  property "identity is a neutral element for compose" do
    id = Transform2D.identity()

    check all(t <- invertible_transform(), p <- point()) do
      {tx, ty} = Transform2D.apply(t, p)

      {lx, ly} = Transform2D.apply(Transform2D.compose(id, t), p)
      assert_in_delta lx, tx, @prop_delta
      assert_in_delta ly, ty, @prop_delta

      {rx, ry} = Transform2D.apply(Transform2D.compose(t, id), p)
      assert_in_delta rx, tx, @prop_delta
      assert_in_delta ry, ty, @prop_delta
    end
  end

  property "invert of a zero-determinant transform returns {:error, :singular}" do
    # Build deliberately singular transforms: the second row is a scalar
    # multiple of the first, forcing det = a*d - b*c = 0. The singular check is
    # scale-relative (see Transform2D.invert/1), so even when float rounding
    # leaves a tiny non-zero det, it stays far below the matrix-scaled
    # threshold and is correctly reported singular.
    singular =
      gen all(
            a <- coord(),
            b <- coord(),
            k <- float(min: -10.0, max: 10.0),
            tx <- coord(),
            ty <- coord()
          ) do
        %Transform2D{a: a, b: b, c: a * k, d: b * k, tx: tx, ty: ty}
      end

    check all(t <- singular) do
      assert Transform2D.invert(t) == {:error, :singular}
    end
  end
end
