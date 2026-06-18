defmodule BlauDrill.AlignmentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlauDrill.Alignment
  alias BlauDrill.Correspondence
  alias BlauDrill.PendingAlignment
  alias BlauDrill.Transform2D

  @moduletag :alignment

  # Tight delta for hand-computed exact-fit assertions (a clean affine applied
  # to exact points solves back to the source transform to float precision).
  @delta 1.0e-9
  # Looser delta for property tests, which chain several float operations
  # (solve + apply) and so accumulate rounding error.
  @prop_delta 1.0e-6

  # Build a Correspondence from a board point and the machine point produced by
  # applying a known transform to it (the noise-free, exact-fit case).
  defp corr_from(t, {bx, by} = board) do
    %Correspondence{board: board, machine: Transform2D.apply(t, {bx, by})}
  end

  # --- fit/1 arity / too-few guard ---------------------------------------

  describe "Alignment.fit/1 with fewer than 3 correspondences" do
    test "zero correspondences -> {:error, :too_few}" do
      assert Alignment.fit([]) == {:error, :too_few}
    end

    test "one correspondence -> {:error, :too_few}" do
      corrs = [%Correspondence{board: {0.0, 0.0}, machine: {1.0, 1.0}}]
      assert Alignment.fit(corrs) == {:error, :too_few}
    end

    test "two correspondences -> {:error, :too_few}" do
      corrs = [
        %Correspondence{board: {0.0, 0.0}, machine: {1.0, 1.0}},
        %Correspondence{board: {1.0, 0.0}, machine: {2.0, 1.0}}
      ]

      assert Alignment.fit(corrs) == {:error, :too_few}
    end
  end

  # --- degeneracy --------------------------------------------------------

  describe "Alignment.fit/1 with degenerate board points" do
    test "three collinear board points -> {:error, :degenerate}" do
      # Board points (0,0), (1,1), (2,2) all lie on the line y = x. No matter
      # what machine points they map to, AᵀA is rank-deficient.
      corrs = [
        %Correspondence{board: {0.0, 0.0}, machine: {0.0, 0.0}},
        %Correspondence{board: {1.0, 1.0}, machine: {3.0, 7.0}},
        %Correspondence{board: {2.0, 2.0}, machine: {6.0, 14.0}}
      ]

      assert Alignment.fit(corrs) == {:error, :degenerate}
    end

    test "collinear with large coordinates still -> {:error, :degenerate}" do
      # Same line (y = x) but with large entries: a fixed absolute epsilon
      # would falsely pass this rank-deficient AᵀA. The scale-relative check
      # must still reject it.
      corrs = [
        %Correspondence{board: {100.0, 100.0}, machine: {1.0, 2.0}},
        %Correspondence{board: {150.0, 150.0}, machine: {3.0, 4.0}},
        %Correspondence{board: {200.0, 200.0}, machine: {5.0, 6.0}}
      ]

      assert Alignment.fit(corrs) == {:error, :degenerate}
    end

    test "two coincident board points among three -> {:error, :degenerate}" do
      # Two identical board points leave only two distinct points -> collinear,
      # so AᵀA is rank-deficient.
      corrs = [
        %Correspondence{board: {3.0, 5.0}, machine: {1.0, 1.0}},
        %Correspondence{board: {3.0, 5.0}, machine: {2.0, 9.0}},
        %Correspondence{board: {7.0, 1.0}, machine: {4.0, 4.0}}
      ]

      assert Alignment.fit(corrs) == {:error, :degenerate}
    end

    test "all three board points coincident -> {:error, :degenerate}" do
      corrs = [
        %Correspondence{board: {2.0, 2.0}, machine: {1.0, 1.0}},
        %Correspondence{board: {2.0, 2.0}, machine: {2.0, 2.0}},
        %Correspondence{board: {2.0, 2.0}, machine: {3.0, 3.0}}
      ]

      assert Alignment.fit(corrs) == {:error, :degenerate}
    end
  end

  # --- known-good exact fits (hand-computed) -----------------------------

  describe "Alignment.fit/1 recovers a known affine exactly (zero residual)" do
    test "X-mirror + translation (back-side drilling shape)" do
      # KNOWN CASE 1: pure back-side X-mirror with translation.
      #   a=-1, b=0, c=0, d=1, tx=10, ty=-5
      # mapping: mx = -bx + 10 ; my = by - 5.
      source = %Transform2D{a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 10.0, ty: -5.0}

      # Non-collinear board points.
      boards = [{0.0, 0.0}, {4.0, 0.0}, {0.0, 3.0}]
      corrs = Enum.map(boards, &corr_from(source, &1))

      assert {:ok, %Alignment{transform: t, residuals: r}} = Alignment.fit(corrs)

      assert_in_delta t.a, -1.0, @delta
      assert_in_delta t.b, 0.0, @delta
      assert_in_delta t.c, 0.0, @delta
      assert_in_delta t.d, 1.0, @delta
      assert_in_delta t.tx, 10.0, @delta
      assert_in_delta t.ty, -5.0, @delta

      # Exact data -> zero residual.
      assert_in_delta r.rms, 0.0, @delta
      assert_in_delta r.max, 0.0, @delta
    end

    test "90 degree CCW rotation + translation" do
      # KNOWN CASE 2: +90° CCW rotation then translation.
      #   a=cos90=0, b=-sin90=-1, c=sin90=1, d=cos90=0, tx=2, ty=3
      # mapping: mx = -by + 2 ; my = bx + 3.
      source = %Transform2D{a: 0.0, b: -1.0, c: 1.0, d: 0.0, tx: 2.0, ty: 3.0}

      boards = [{0.0, 0.0}, {1.0, 0.0}, {0.0, 1.0}]
      corrs = Enum.map(boards, &corr_from(source, &1))

      assert {:ok, %Alignment{transform: t, residuals: r}} = Alignment.fit(corrs)

      assert_in_delta t.a, 0.0, @delta
      assert_in_delta t.b, -1.0, @delta
      assert_in_delta t.c, 1.0, @delta
      assert_in_delta t.d, 0.0, @delta
      assert_in_delta t.tx, 2.0, @delta
      assert_in_delta t.ty, 3.0, @delta

      assert_in_delta r.rms, 0.0, @delta
      assert_in_delta r.max, 0.0, @delta

      # And the fitted transform reproduces each machine point.
      for %Correspondence{board: b, machine: {mx, my}} <- corrs do
        {fx, fy} = Transform2D.apply(t, b)
        assert_in_delta fx, mx, @delta
        assert_in_delta fy, my, @delta
      end
    end

    test "fit returns a genuine %Transform2D{} struct with all six fields" do
      source = %Transform2D{a: 2.0, b: 0.5, c: -0.5, d: 1.5, tx: -3.0, ty: 4.0}
      boards = [{0.0, 0.0}, {1.0, 0.0}, {0.0, 1.0}, {1.0, 1.0}]
      corrs = Enum.map(boards, &corr_from(source, &1))

      assert {:ok, %Alignment{transform: %Transform2D{} = t}} = Alignment.fit(corrs)

      for field <- [:a, :b, :c, :d, :tx, :ty] do
        assert is_float(Map.fetch!(t, field))
      end
    end
  end

  # --- overdetermined fit ------------------------------------------------

  describe "Alignment.fit/1 with 4 consistent correspondences" do
    test "overdetermined exact data still solves with ~0 residuals" do
      source = %Transform2D{a: 1.2, b: -0.3, c: 0.4, d: 0.9, tx: 5.0, ty: -2.0}
      boards = [{0.0, 0.0}, {10.0, 0.0}, {0.0, 8.0}, {6.0, 6.0}]
      corrs = Enum.map(boards, &corr_from(source, &1))

      assert {:ok, %Alignment{transform: t, residuals: r}} = Alignment.fit(corrs)

      assert_in_delta t.a, 1.2, @delta
      assert_in_delta t.b, -0.3, @delta
      assert_in_delta t.c, 0.4, @delta
      assert_in_delta t.d, 0.9, @delta
      assert_in_delta t.tx, 5.0, @delta
      assert_in_delta t.ty, -2.0, @delta

      assert_in_delta r.rms, 0.0, 1.0e-7
      assert_in_delta r.max, 0.0, 1.0e-7
    end
  end

  # --- residuals as the honesty signal -----------------------------------

  describe "Alignment.fit/1 residuals reflect noise" do
    test "perturbing one machine point by delta drives residuals.max ~ delta" do
      # Start from an exact 4-point set, then nudge ONE machine point by a known
      # Euclidean amount. With 4 points and one outlier, the least-squares fit
      # spreads the error but the perturbed point still dominates: residuals.max
      # is on the order of the perturbation, and rms < max.
      source = %Transform2D{a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0}
      boards = [{0.0, 0.0}, {10.0, 0.0}, {0.0, 10.0}, {10.0, 10.0}]
      exact = Enum.map(boards, &corr_from(source, &1))

      delta = 0.4
      [%Correspondence{machine: {fmx, fmy}} = first | rest] = exact
      perturbed = [%Correspondence{first | machine: {fmx + delta, fmy}} | rest]

      assert {:ok, %Alignment{residuals: r}} = Alignment.fit(perturbed)

      # The fit is no longer exact, so there is real residual.
      assert r.max > 0.0
      assert r.rms > 0.0
      # rms (averaged) is strictly smaller than the worst single point.
      assert r.rms < r.max
      # The worst residual is on the order of the injected perturbation: bounded
      # above by delta (least squares can only reduce the worst-case from the
      # raw delta) and a meaningful fraction of it (the outlier dominates).
      assert r.max <= delta + 1.0e-9
      assert r.max >= delta / 4.0
    end

    test "exact data has zero residuals (no false noise)" do
      source = %Transform2D{a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0}
      boards = [{1.0, 2.0}, {5.0, 2.0}, {1.0, 9.0}]
      corrs = Enum.map(boards, &corr_from(source, &1))

      assert {:ok, %Alignment{residuals: r}} = Alignment.fit(corrs)
      assert_in_delta r.rms, 0.0, @delta
      assert_in_delta r.max, 0.0, @delta
    end
  end

  # --- no public constructor for Alignment -------------------------------

  describe "Alignment has no constructor other than fit/1" do
    test "a bare %Alignment{} cannot be built without both enforced keys" do
      # @enforce_keys must make both fields mandatory; building an empty struct
      # is a compile-time error, so we assert it via a runtime eval.
      assert_raise ArgumentError, fn ->
        Code.eval_string("%BlauDrill.Alignment{}")
      end
    end
  end

  # --- PendingAlignment --------------------------------------------------

  describe "PendingAlignment" do
    test "new pending starts empty with count 0" do
      pending = %PendingAlignment{captured: []}
      assert PendingAlignment.count(pending) == 0
    end

    test "add/2 appends correspondences preserving order (append-only)" do
      c1 = %Correspondence{board: {0.0, 0.0}, machine: {1.0, 1.0}}
      c2 = %Correspondence{board: {1.0, 0.0}, machine: {2.0, 1.0}}
      c3 = %Correspondence{board: {0.0, 1.0}, machine: {1.0, 2.0}}

      pending =
        %PendingAlignment{captured: []}
        |> PendingAlignment.add(c1)
        |> PendingAlignment.add(c2)
        |> PendingAlignment.add(c3)

      assert PendingAlignment.count(pending) == 3
      assert pending.captured == [c1, c2, c3]
    end

    test "fit(pending.captured) with 2 captured -> {:error, :too_few}" do
      c1 = %Correspondence{board: {0.0, 0.0}, machine: {1.0, 1.0}}
      c2 = %Correspondence{board: {1.0, 0.0}, machine: {2.0, 1.0}}

      pending =
        %PendingAlignment{captured: []}
        |> PendingAlignment.add(c1)
        |> PendingAlignment.add(c2)

      assert PendingAlignment.count(pending) == 2
      assert Alignment.fit(pending.captured) == {:error, :too_few}
    end

    test "a promoted pending (3 non-collinear) fits to an Alignment" do
      source = %Transform2D{a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0}

      pending =
        %PendingAlignment{captured: []}
        |> PendingAlignment.add(corr_from(source, {0.0, 0.0}))
        |> PendingAlignment.add(corr_from(source, {4.0, 0.0}))
        |> PendingAlignment.add(corr_from(source, {0.0, 3.0}))

      assert {:ok, %Alignment{}} = Alignment.fit(pending.captured)
    end
  end

  # --- Correspondence ----------------------------------------------------

  describe "Correspondence" do
    test "carries a board point and a machine point" do
      c = %Correspondence{board: {1.0, 2.0}, machine: {3.0, 4.0}}
      assert c.board == {1.0, 2.0}
      assert c.machine == {3.0, 4.0}
    end

    test "both fields are enforced" do
      assert_raise ArgumentError, fn ->
        Code.eval_string("%BlauDrill.Correspondence{}")
      end
    end
  end

  # --- property test -----------------------------------------------------

  # A reasonable board-coordinate range (mm-ish).
  defp coord, do: float(min: -100.0, max: 100.0)

  # A non-degenerate affine: rotation ∘ non-zero, well-separated scale, plus
  # translation. Each factor is invertible and the linear part stays
  # comfortably away from singular, so the generated transform is always fittable.
  defp nondegenerate_transform do
    gen all(
          angle <- float(min: -:math.pi(), max: :math.pi()),
          sx <- one_of([float(min: 0.5, max: 4.0), float(min: -4.0, max: -0.5)]),
          sy <- one_of([float(min: 0.5, max: 4.0), float(min: -4.0, max: -0.5)]),
          tx <- coord(),
          ty <- coord()
        ) do
      %Transform2D{
        a: :math.cos(angle) * sx,
        b: -:math.sin(angle) * sy,
        c: :math.sin(angle) * sx,
        d: :math.cos(angle) * sy,
        tx: tx,
        ty: ty
      }
    end
  end

  # Three board points forming a triangle with a comfortably non-zero area: a
  # base point plus two well-separated edge vectors that are not parallel.
  defp triangle_boards do
    gen all(
          ox <- coord(),
          oy <- coord(),
          u <- float(min: 5.0, max: 50.0),
          v <- float(min: 5.0, max: 50.0),
          w <- float(min: 5.0, max: 50.0)
        ) do
      # Points: origin, origin + (u, 0), origin + (0, v) plus a fourth interior-ish
      # point. (u, 0) and (0, v) span a non-degenerate triangle (area = u*v/2 > 0).
      [
        {ox, oy},
        {ox + u, oy},
        {ox, oy + v},
        {ox + w, oy + w}
      ]
    end
  end

  property "fit recovers a random non-degenerate affine with ~0 residual" do
    check all(
            source <- nondegenerate_transform(),
            boards <- triangle_boards()
          ) do
      corrs = Enum.map(boards, &corr_from(source, &1))

      assert {:ok, %Alignment{transform: t, residuals: r}} = Alignment.fit(corrs)

      assert_in_delta t.a, source.a, @prop_delta
      assert_in_delta t.b, source.b, @prop_delta
      assert_in_delta t.c, source.c, @prop_delta
      assert_in_delta t.d, source.d, @prop_delta
      assert_in_delta t.tx, source.tx, @prop_delta
      assert_in_delta t.ty, source.ty, @prop_delta

      assert_in_delta r.rms, 0.0, @prop_delta
      assert_in_delta r.max, 0.0, @prop_delta
    end
  end
end
