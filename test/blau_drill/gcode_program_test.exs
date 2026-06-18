defmodule BlauDrill.GcodeProgramTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BlauDrill.Alignment
  alias BlauDrill.BoardModel
  alias BlauDrill.Correspondence
  alias BlauDrill.GcodeProgram
  alias BlauDrill.Transform2D

  @moduletag :gcode

  # Tuned reference values (drill.cfg). Used throughout the assertions.
  @zdrill -2.5
  @zsafe 5.0
  @zchange 30.0
  @hover 0.2
  @drill_feed 200
  @spindle_speed 255

  # Float tolerance for parsing emitted Z values back out for the invariant
  # walks. The emitter formats to 5 decimals, so this is generous.
  @z_tol 1.0e-6

  @fixtures Path.expand("../support/fixtures", __DIR__)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # The back-side X-mirror transform, obtained through the REAL constructor
  # `Alignment.fit/1` (no public Alignment constructor exists). Three
  # non-collinear board points map to their X-mirrored images, so the fit
  # solves to exactly a = -1, b = 0, c = 0, d = 1, tx = 0, ty = 0 — i.e. board
  # `X-57.15` -> machine `X57.15`, matching the goldens.
  defp xmirror_alignment do
    correspondences =
      for {bx, by} <- [{0.0, 0.0}, {1.0, 0.0}, {0.0, 1.0}] do
        %Correspondence{board: {bx, by}, machine: {-bx, by}}
      end

    {:ok, alignment} = Alignment.fit(correspondences)
    alignment
  end

  defp board_from_fixture do
    drl = File.read!(Path.join(@fixtures, "segby_v1.drl"))
    {:ok, board} = BoardModel.parse_drl(drl)
    board
  end

  # Parse an `X..` / `Y..` value out of a G0/G1 move line, if present.
  defp parse_axis(line, axis) do
    case Regex.run(~r/\b#{axis}(-?\d+(?:\.\d+)?)/, line) do
      [_, v] ->
        {f, ""} = Float.parse(v)
        f

      _ ->
        nil
    end
  end

  defp move_line?(line) do
    String.match?(line, ~r/^\s*G0?[0-3]\b/i)
  end

  defp commands_xy?(line) do
    move_line?(line) and
      (parse_axis(line, "X") != nil or parse_axis(line, "Y") != nil)
  end

  defp commands_z?(line) do
    move_line?(line) and parse_axis(line, "Z") != nil
  end

  # ---------------------------------------------------------------------------
  # Invariant 1 — never traverse XY without Z safe.
  #
  # Walk the emitted program tracking current Z. For every line that commands an
  # X or Y move, the toolhead must already be at a safe Z (>= zsafe). A bit
  # dragged sideways while buried snaps.
  # ---------------------------------------------------------------------------

  defp assert_xy_only_when_safe(%GcodeProgram{lines: lines}, zsafe) do
    Enum.reduce(lines, :unknown, fn line, current_z ->
      cond do
        commands_xy?(line) ->
          # Pure-Z lines never carry X/Y, so an XY move means travel: must be
          # safe. `:unknown` (start of program, before any Z command) is treated
          # as unsafe — every XY move must be preceded by a retract.
          assert current_z != :unknown,
                 "XY move before any Z was established (no retract): #{inspect(line)}"

          assert current_z >= zsafe - @z_tol,
                 "XY move at unsafe Z=#{current_z} (< zsafe #{zsafe}): #{inspect(line)}"

          # An XY move line in this generator never also changes Z, but be
          # defensive and update if it did.
          parse_axis(line, "Z") || current_z

        commands_z?(line) ->
          parse_axis(line, "Z")

        true ->
          current_z
      end
    end)

    :ok
  end

  describe "Invariant 1 — XY travel only at a safe Z (example)" do
    test "drill mode never commands XY below zsafe" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :drill)
      assert :ok == assert_xy_only_when_safe(program, @zsafe)
    end

    test "dry-run mode never commands XY below zsafe" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :dry_run)
      assert :ok == assert_xy_only_when_safe(program, @zsafe)
    end

    test "there is no XY rapid immediately following a plunge without a retract" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :drill)

      # Walk pairs: a plunge (G1 Z negative) must be followed by a retract before
      # any XY move. Track Z and look for the offending transition directly.
      program.lines
      |> Enum.reduce({:unknown, nil}, fn line, {z, prev} ->
        cond do
          commands_z?(line) ->
            new_z = parse_axis(line, "Z")
            {new_z, line}

          commands_xy?(line) ->
            refute prev != nil and z < @zsafe - @z_tol,
                   "XY rapid #{inspect(line)} followed plunge #{inspect(prev)} with no retract"

            {z, prev}

          true ->
            {z, prev}
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Invariant 2 — spindle running before any plunge (drill); off in dry-run.
  # ---------------------------------------------------------------------------

  # Returns :on / :off depending on the latest M3 S<n>/M5 seen.
  defp spindle_state_walk(lines, on_plunge) do
    Enum.reduce(lines, :off, fn line, spindle ->
      cond do
        Regex.match?(~r/^\s*M3\s+S(\d+)/i, line) ->
          [_, s] = Regex.run(~r/^\s*M3\s+S(\d+)/i, line)
          if String.to_integer(s) > 0, do: :on, else: spindle

        Regex.match?(~r/^\s*M5\b/i, line) ->
          :off

        plunge_line?(line) ->
          on_plunge.(spindle, line)
          spindle

        true ->
          spindle
      end
    end)
  end

  # A real plunge is `G1 Z<negative>`.
  defp plunge_line?(line) do
    case parse_z_of_g1(line) do
      {:ok, z} -> z < 0.0
      :no -> false
    end
  end

  defp parse_z_of_g1(line) do
    case Regex.run(~r/^\s*G0?1\s+Z(-?\d+(?:\.\d+)?)/i, line) do
      [_, z] ->
        {f, ""} = Float.parse(z)
        {:ok, f}

      _ ->
        :no
    end
  end

  describe "Invariant 2 — spindle armed before plunge in :drill (example)" do
    test "every plunge is preceded by M3 S255 with no intervening M5" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :drill)

      spindle_state_walk(program.lines, fn spindle, line ->
        assert spindle == :on,
               "plunge #{inspect(line)} reached with spindle off (missing M3 S#{@spindle_speed} re-arm)"
      end)
    end

    test "M3 carries the speed on the same line (Marlin quirk), never a bare M3" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :drill)

      m3_lines = Enum.filter(program.lines, &String.match?(&1, ~r/^\s*M3\b/i))
      assert m3_lines != []

      for line <- m3_lines do
        assert String.match?(line, ~r/^\s*M3\s+S\d+/i),
               "bare M3 without S on the same line: #{inspect(line)}"
      end
    end

    test "the spindle is re-armed after every tool change (M5 then M3 S255)" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :drill)

      # 5 tool blocks: each emits an M5 (spindle stop) then re-arms with M3 S255
      # before its first plunge. Count the re-arms.
      m3_count = Enum.count(program.lines, &String.match?(&1, ~r/^\s*M3\s+S#{@spindle_speed}\b/))

      assert m3_count == 5,
             "expected 5 M3 S#{@spindle_speed} re-arms (one per tool), got #{m3_count}"
    end
  end

  describe "Invariant 2 — dry-run leaves the spindle OFF and never plunges" do
    test "no M3 with a positive speed appears in dry-run output" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :dry_run)

      refute Enum.any?(program.lines, &String.match?(&1, ~r/^\s*M3\s+S[1-9]/)),
             "dry-run must not arm the spindle"

      assert Enum.any?(program.lines, &String.contains?(&1, "( dry run: spindle left OFF )"))
    end

    test "Z never goes negative in dry-run (hover at +0.2 instead of plunge)" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :dry_run)

      for line <- program.lines, z = parse_axis(line, "Z"), is_number(z) do
        assert z >= 0.0 - @z_tol, "dry-run commanded a negative Z: #{inspect(line)}"
      end

      hover_lines = Enum.filter(program.lines, &String.contains?(&1, "dry-run hover"))
      assert length(hover_lines) == 130

      hover_str = :erlang.float_to_binary(@hover, decimals: 5)
      zdrill_str = :erlang.float_to_binary(@zdrill, decimals: 5)

      for line <- hover_lines do
        assert String.contains?(line, "G1 Z" <> hover_str)
        assert String.contains?(line, "was Z" <> zdrill_str)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # PROPERTY tests — both invariants over random boards + random alignments.
  # ---------------------------------------------------------------------------

  # A random board model: random holes (board coords near origin), random tool
  # assignment from the 5-tool table. Built by hand (not through parse) so we can
  # exercise arbitrary geometry. The struct fields we need are holes + tools.
  defp gen_board do
    gen all(
          n <- integer(1..40),
          holes <-
            list_of(
              gen all(
                    x <- float(min: -80.0, max: 80.0),
                    y <- float(min: -80.0, max: 80.0),
                    t <- member_of(["T1", "T2", "T3", "T4", "T5"])
                  ) do
                %{x: x, y: y, tool: t}
              end,
              length: n
            )
        ) do
      tools = %{"T1" => 0.6, "T2" => 0.7, "T3" => 0.8, "T4" => 1.0, "T5" => 1.2}
      used_tools = holes |> Enum.map(& &1.tool) |> Enum.uniq()

      %BoardModel{
        holes: holes,
        tools: Map.take(tools, used_tools),
        bbox: {0.0, 0.0, 0.0, 0.0},
        outline: nil,
        fiducials: []
      }
    end
  end

  # A random NON-DEGENERATE alignment, obtained through the real constructor.
  # We fit three correspondences whose board points are a right triangle (never
  # collinear), with random but bounded linear part + translation, so the fit
  # always succeeds.
  defp gen_alignment do
    gen all(
          # Keep the linear part away from 0 WITHOUT a filter: generate a
          # magnitude in [0.5, 2.0] and a random sign, so the matrix is never
          # near-singular (no shrinking-into-a-filtered-hole problem).
          a_mag <- float(min: 0.5, max: 2.0),
          a_sign <- member_of([-1.0, 1.0]),
          d_mag <- float(min: 0.5, max: 2.0),
          d_sign <- member_of([-1.0, 1.0]),
          tx <- float(min: -50.0, max: 50.0),
          ty <- float(min: -50.0, max: 50.0)
        ) do
      src = %Transform2D{
        a: a_mag * a_sign,
        b: 0.0,
        c: 0.0,
        d: d_mag * d_sign,
        tx: tx,
        ty: ty
      }

      corrs =
        for board <- [{0.0, 0.0}, {1.0, 0.0}, {0.0, 1.0}] do
          %Correspondence{board: board, machine: Transform2D.apply(src, board)}
        end

      {:ok, alignment} = Alignment.fit(corrs)
      alignment
    end
  end

  property "Invariant 1 holds for every emitted program (both modes)" do
    check all(
            board <- gen_board(),
            alignment <- gen_alignment(),
            mode <- member_of([:drill, :dry_run])
          ) do
      program = GcodeProgram.build(board, alignment, mode: mode)
      assert :ok == assert_xy_only_when_safe(program, @zsafe)
    end
  end

  property "Invariant 2 holds for every emitted program" do
    check all(
            board <- gen_board(),
            alignment <- gen_alignment()
          ) do
      # :drill — spindle armed before each plunge.
      drill = GcodeProgram.build(board, alignment, mode: :drill)

      spindle_state_walk(drill.lines, fn spindle, line ->
        assert spindle == :on, "plunge with spindle off: #{inspect(line)}"
      end)

      # :dry_run — no positive-speed M3, no negative Z.
      dry = GcodeProgram.build(board, alignment, mode: :dry_run)
      refute Enum.any?(dry.lines, &String.match?(&1, ~r/^\s*M3\s+S[1-9]/))

      for line <- dry.lines, z = parse_axis(line, "Z"), is_number(z) do
        assert z >= 0.0 - @z_tol, "dry-run negative Z: #{inspect(line)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Type requirement — build needs an %Alignment{}; no holes-only arity.
  # ---------------------------------------------------------------------------

  describe "type requirement" do
    # Defeat Elixir 1.20's set-theoretic type narrowing for the negative cases:
    # the whole POINT here is to pass an ill-typed value into the alignment slot
    # and prove it is rejected at runtime. Routing the bad value through a
    # `term()`-returning identity hides its concrete type from the static checker
    # (which would otherwise flag the deliberately-wrong call) while leaving the
    # runtime FunctionClauseError assertion intact.
    @spec opaque(term()) :: term()
    defp opaque(x), do: x

    test "build/3 requires an %Alignment{} struct (no raw-holes arity)" do
      board = board_from_fixture()
      alignment = xmirror_alignment()

      # The legal call works.
      assert %GcodeProgram{} = GcodeProgram.build(board, alignment, mode: :drill)

      # Passing something that is not an %Alignment{} in the alignment slot must
      # fail (FunctionClauseError) — there is no arity that accepts raw holes or
      # a bare transform.
      raw_holes = opaque(board.holes)
      bare_transform = opaque(%Transform2D{a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0})

      assert_raise FunctionClauseError, fn ->
        GcodeProgram.build(board, raw_holes, mode: :drill)
      end

      assert_raise FunctionClauseError, fn ->
        GcodeProgram.build(board, bare_transform, mode: :drill)
      end
    end

    test "build/2 (opts defaulted) still requires an %Alignment{} in slot 2" do
      board = board_from_fixture()

      # build/2 exists only as build(board, alignment) with opts defaulted — it
      # does NOT accept raw holes. The alignment slot is typed either way.
      assert %GcodeProgram{} = GcodeProgram.build(board, xmirror_alignment())

      raw_holes = opaque(board.holes)

      assert_raise FunctionClauseError, fn ->
        GcodeProgram.build(board, raw_holes)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Structural counts.
  # ---------------------------------------------------------------------------

  describe "structural counts (drill mode)" do
    setup do
      {:ok, program: GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :drill)}
    end

    test "total plunges == 130 (one per hole)", %{program: program} do
      plunges = Enum.count(program.lines, &plunge_line?/1)
      assert plunges == 130
    end

    test "exactly 5 tool blocks", %{program: program} do
      tool_lines = Enum.filter(program.lines, &String.match?(&1, ~r/^T[1-5]$/))
      assert tool_lines == ["T1", "T2", "T3", "T4", "T5"]
      assert program.tool_order == ["T1", "T2", "T3", "T4", "T5"]
    end

    test "per-tool plunge counts are [40, 4, 38, 42, 6]", %{program: program} do
      assert per_tool_plunge_counts(program.lines) == [40, 4, 38, 42, 6]
    end

    test "5 per-tool M0 + M6 tool-change pauses", %{program: program} do
      assert Enum.count(program.lines, &String.match?(&1, ~r/^M6\b/)) == 5
      # Touch-off M0 + 5 tool-change M0 = 6 M0 lines total.
      assert Enum.count(program.lines, &String.match?(&1, ~r/^M0\b/)) == 6
    end
  end

  # Count negative-Z plunges between each `T<n>` header.
  defp per_tool_plunge_counts(lines) do
    lines
    |> Enum.reduce({[], nil}, fn line, {acc, current} ->
      cond do
        String.match?(line, ~r/^T[1-5]$/) ->
          {[{line, 0} | acc], line}

        plunge_line?(line) and current != nil ->
          [{tool, count} | rest] = acc
          {[{tool, count + 1} | rest], current}

        true ->
          {acc, current}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.map(&elem(&1, 1))
  end

  # ---------------------------------------------------------------------------
  # GOLDEN semantic diff — the risk-retirement test.
  # ---------------------------------------------------------------------------

  # Reduce a normalized line to its SEMANTIC core: strip inline `( ... )`
  # comments and collapse whitespace, then canonicalise G-code word spacing. We
  # also canonicalise G00<->G0 and G01<->G1 (both goldens mix them).
  defp semantic_core(line) do
    line
    |> String.replace(~r/\(.*?\)/, "")
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  describe "golden semantic diff" do
    test "drill mode reproduces the golden's drilled set, depths and structure" do
      golden =
        Path.join(@fixtures, "segby_v1.drill.gcode")
        |> File.read!()
        |> String.split("\n")

      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :drill)

      assert_same_drilled_set(program, golden, :drill)
      assert_same_zdepths(program, :drill)
      assert_same_tool_structure(program, golden)
    end

    test "dry-run mode reproduces the golden's drilled set and hover structure" do
      golden =
        Path.join(@fixtures, "segby_v1.dryrun.gcode")
        |> File.read!()
        |> String.split("\n")

      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :dry_run)

      assert_same_drilled_set(program, golden, :dry_run)
      assert_same_tool_structure(program, golden)
    end

    test "preamble touch-off + G92 + unit setup matches the goldens" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :drill)
      core = Enum.map(program.lines, &semantic_core/1)

      assert "M0" in core or Enum.any?(program.lines, &String.match?(&1, ~r/^M0\b/))
      assert "G92 X0 Y0 Z0" in core
      assert "G94" in core
      assert "G21" in core
      assert "G91.1" in core
      assert "G90" in core
    end

    test "postamble homes, stops spindle and ends the program" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :drill)
      core = Enum.map(program.lines, &semantic_core/1)

      assert "G00 Z30.000" in core
      assert "G00 X0.0 Y0.0 Z0.0" in core
      assert "M5" in core
      assert "M9" in core
      assert "M2" in core
    end
  end

  # The set of {tool, machine_x, machine_y} drilled must match the golden, to 5
  # decimals. The golden reorders holes within a tool (TSP); we compare as SETS.
  defp assert_same_drilled_set(program, golden, _mode) do
    emitted = drilled_set(program.lines)
    expected = drilled_set(golden)

    only_emitted = MapSet.difference(emitted, expected)
    only_golden = MapSet.difference(expected, emitted)

    assert MapSet.size(only_emitted) == 0 and MapSet.size(only_golden) == 0,
           """
           drilled set mismatch.
           in emitted but not golden (first 5): #{inspect(Enum.take(only_emitted, 5))}
           in golden but not emitted (first 5): #{inspect(Enum.take(only_golden, 5))}
           """

    assert MapSet.size(emitted) == 130
  end

  # Build the set of {tool, x, y} from a line list: track current tool via
  # `T<n>` headers, and each `G0 X.. Y..` move that precedes a plunge/hover is a
  # drilled hole. Simpler: each XY move under a tool is a hole (both goldens emit
  # exactly one XY move per hole).
  defp drilled_set(lines) do
    indexed = Enum.with_index(lines)

    # A line is a "hole" XY move only when a following line within the next 2 is
    # a G1 Z (plunge in drill, hover in dry-run) — this excludes the postamble
    # homing `G00 X0.0 Y0.0 Z0.0` move, which has no following plunge.
    line_array = lines

    indexed
    |> Enum.reduce({MapSet.new(), nil}, fn {line, i}, {set, tool} ->
      cond do
        m = Regex.run(~r/^T([1-5])$/, String.trim(line)) ->
          [_, n] = m
          {set, "T" <> n}

        tool != nil and commands_xy?(line) and followed_by_z_move?(line_array, i) ->
          x = parse_axis(line, "X")
          y = parse_axis(line, "Y")

          if is_number(x) and is_number(y) do
            key = {tool, Float.round(x, 5), Float.round(y, 5)}
            {MapSet.put(set, key), tool}
          else
            {set, tool}
          end

        true ->
          {set, tool}
      end
    end)
    |> elem(0)
  end

  defp followed_by_z_move?(lines, i) do
    lines
    |> Enum.slice((i + 1)..(i + 2))
    |> Enum.any?(&String.match?(&1, ~r/^\s*G0?1\s+Z/i))
  end

  # Every plunge in drill mode is exactly zdrill, every travel retract exactly
  # zsafe, every tool-change retract exactly zchange.
  defp assert_same_zdepths(program, :drill) do
    plunge_zs =
      program.lines
      |> Enum.filter(&plunge_line?/1)
      |> Enum.map(fn line ->
        {:ok, z} = parse_z_of_g1(line)
        z
      end)

    assert plunge_zs != []
    assert Enum.all?(plunge_zs, &(abs(&1 - @zdrill) < @z_tol))

    # Travel retracts: G1 Z5.00000
    retracts = Enum.count(program.lines, &String.match?(&1, ~r/^G1 Z5\.00000\b/))
    assert retracts == 130, "expected 130 travel retracts at zsafe, got #{retracts}"

    # Tool-change retracts to zchange (@zchange == 30.0): G00 Z30.00000 (5, one
    # per tool) plus the postamble G00 Z30.000.
    zchange_str = :erlang.float_to_binary(@zchange, decimals: 5)
    zchange = Enum.count(program.lines, &String.contains?(&1, "Z" <> zchange_str))
    assert zchange >= 5
  end

  # The per-tool block structure: each tool has its retract-to-zchange, T<n>,
  # M5, dwell, MSG change, M6, M0, spindle step, G0 Z5, dwell, G1 F200.
  defp assert_same_tool_structure(program, _golden) do
    core = Enum.map(program.lines, &semantic_core/1)

    assert Enum.count(core, &(&1 == "T1")) == 1
    assert Enum.count(core, &(&1 == "T5")) == 1

    # Feed lines: one per tool block.
    feed = Enum.count(program.lines, &String.match?(&1, ~r/^G1 F#{@drill_feed}\.0+\b/))
    assert feed == 5

    # Per-tool dwell G04 P1.00000 appears (>= 5).
    dwell = Enum.count(program.lines, &String.match?(&1, ~r/^G04 P1\.0+\b/))
    assert dwell >= 5
  end

  # ---------------------------------------------------------------------------
  # The %GcodeProgram{} value itself.
  # ---------------------------------------------------------------------------

  describe "GcodeProgram value" do
    test "carries mode, tool_order and bbox_machine" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), mode: :drill)

      assert program.mode == :drill
      assert program.tool_order == ["T1", "T2", "T3", "T4", "T5"]

      {minx, miny, maxx, maxy} = program.bbox_machine
      assert minx <= maxx
      assert miny <= maxy
      # Post-mirror, board X in [-81.28, 0] -> machine X in [0, 81.28].
      assert_in_delta minx, 0.0, 1.0e-6
      assert_in_delta maxx, 81.28, 1.0e-6
    end

    test "defaults to the safe :dry_run mode when no mode is given" do
      program = GcodeProgram.build(board_from_fixture(), xmirror_alignment(), [])
      assert program.mode == :dry_run
      refute Enum.any?(program.lines, &String.match?(&1, ~r/^\s*M3\s+S[1-9]/))
    end
  end
end
