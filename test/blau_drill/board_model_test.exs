defmodule BlauDrill.BoardModelTest do
  use ExUnit.Case, async: true

  alias BlauDrill.BoardModel

  # The canonical KiCad export fixture. A correct export with the Drill/Place
  # File Origin set on a fiducial: small coordinates centred near origin, one
  # axis legitimately negative (board space, never machine space).
  @drl File.read!(Path.join([__DIR__, "..", "support", "fixtures", "segby_v1.drl"]))
  @edge_cuts File.read!(
               Path.join([__DIR__, "..", "support", "fixtures", "segby_v1-Edge_Cuts.svg"])
             )

  # A minimal but well-formed header reused by the malformed/synthetic tests so
  # the only variable under test is the bit that is meant to fail.
  defp drl(body) do
    """
    M48
    METRIC
    T1C0.600
    %
    G90
    G05
    T1
    #{body}
    M30
    """
  end

  describe "parse/1 — tool table" do
    test "parses all 5 tools with correct diameters" do
      assert {:ok, %BoardModel{tools: tools}} = BoardModel.parse(%{drl: @drl})

      assert tools == %{
               "T1" => 0.6,
               "T2" => 0.7,
               "T3" => 0.8,
               "T4" => 1.0,
               "T5" => 1.2
             }
    end

    test "diameters are floats" do
      assert {:ok, %BoardModel{tools: tools}} = BoardModel.parse(%{drl: @drl})
      assert Enum.all?(Map.values(tools), &is_float/1)
    end
  end

  describe "parse/1 — holes" do
    test "parses the correct total hole count" do
      assert {:ok, %BoardModel{holes: holes}} = BoardModel.parse(%{drl: @drl})
      assert length(holes) == 130
    end

    test "parses the correct per-tool hole counts" do
      assert {:ok, %BoardModel{holes: holes}} = BoardModel.parse(%{drl: @drl})

      counts =
        holes
        |> Enum.frequencies_by(& &1.tool)

      assert counts == %{
               "T1" => 40,
               "T2" => 4,
               "T3" => 38,
               "T4" => 42,
               "T5" => 6
             }
    end

    test "each hole has float x/y and a tool ref" do
      assert {:ok, %BoardModel{holes: holes}} = BoardModel.parse(%{drl: @drl})

      assert Enum.all?(holes, fn h ->
               is_float(h.x) and is_float(h.y) and is_binary(h.tool)
             end)
    end

    test "spot-checks the first T1 hole (X-57.15Y80.01)" do
      assert {:ok, %BoardModel{holes: [first | _]}} = BoardModel.parse(%{drl: @drl})
      assert first == %{x: -57.15, y: 80.01, tool: "T1"}
    end

    test "spot-checks an integer-form coordinate (X0.0Y49.53 on T4)" do
      assert {:ok, %BoardModel{holes: holes}} = BoardModel.parse(%{drl: @drl})
      assert Enum.any?(holes, &(&1 == %{x: 0.0, y: 49.53, tool: "T4"}))
    end

    test "preserves negative X — holes are in board coords, NOT mirrored" do
      # Mirroring board->machine is Transform2D's job, never the parser's.
      assert {:ok, %BoardModel{holes: holes}} = BoardModel.parse(%{drl: @drl})
      assert Enum.any?(holes, &(&1.x == -57.15))
      refute Enum.any?(holes, &(&1.x == 57.15))
    end
  end

  describe "parse/1 — bbox" do
    test "computes bbox as {min_x, min_y, max_x, max_y} over all holes" do
      assert {:ok, %BoardModel{bbox: bbox}} = BoardModel.parse(%{drl: @drl})
      assert bbox == {-81.28, -3.81, 0.0, 80.01}
    end
  end

  describe "parse/1 — the X135/Y−149 absolute-page trap" do
    test "rejects a broken export with large absolute page coordinates" do
      # Origin never set in KiCad -> large absolute page coordinates.
      body = "X135.0Y-149.0\nX140.0Y-152.0"

      assert {:error, {:absolute_page_coordinates, _details}} =
               BoardModel.parse(%{drl: drl(body)})
    end

    test "does NOT reject the legitimate negative coords in segby_v1" do
      assert {:ok, %BoardModel{}} = BoardModel.parse(%{drl: @drl})
    end

    test "accepts a board sitting near origin with one negative axis" do
      body = "X-80.0Y80.0\nX0.0Y-3.0"
      assert {:ok, %BoardModel{}} = BoardModel.parse(%{drl: drl(body)})
    end
  end

  describe "parse/1 — malformed input" do
    test "missing M48 header returns an error, does not crash" do
      no_header = String.replace(@drl, "M48\n", "")
      assert {:error, _reason} = BoardModel.parse(%{drl: no_header})
    end

    test "garbage input returns an error, does not crash" do
      assert {:error, _reason} = BoardModel.parse(%{drl: "this is not a drill file"})
    end

    test "empty input returns an error" do
      assert {:error, _reason} = BoardModel.parse(%{drl: ""})
    end

    test "a hole referencing an undefined tool is rejected" do
      no_select = """
      M48
      METRIC
      T1C0.600
      %
      G90
      G05
      X1.0Y1.0
      M30
      """

      assert {:error, _reason} = BoardModel.parse(%{drl: no_select})
    end
  end

  describe "parse/1 — outline (Edge.Cuts)" do
    test "parses the board outline polyline from the Edge_Cuts SVG" do
      assert {:ok, %BoardModel{outline: outline}} =
               BoardModel.parse(%{drl: @drl, edge_cuts: @edge_cuts})

      # Documented representation: a closed polyline as a list of {x, y} points.
      assert is_list(outline)
      assert {0.0, 0.0} in outline
      assert {89.5799, 0.0} in outline
      assert {89.5799, 89.7874} in outline
      assert {0.0, 89.7874} in outline
    end

    test "outline is nil when no edge_cuts is supplied" do
      assert {:ok, %BoardModel{outline: nil}} = BoardModel.parse(%{drl: @drl})
    end
  end

  describe "parse/1 — fiducials" do
    test "fiducials default to an empty list (documented TODO)" do
      assert {:ok, %BoardModel{fiducials: []}} = BoardModel.parse(%{drl: @drl})
    end
  end

  describe "parse_drl/1 convenience" do
    test "is equivalent to parse/1 with only :drl" do
      assert BoardModel.parse_drl(@drl) == BoardModel.parse(%{drl: @drl})
    end
  end
end
