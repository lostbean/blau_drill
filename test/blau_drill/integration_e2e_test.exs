defmodule BlauDrill.IntegrationE2ETest do
  @moduledoc """
  End-to-end **domain pipeline** smoke (the coordinator's final-review check).

  Composes the whole pure pipeline over the real `segby_v1.drl` fixture and
  asserts it holds together:

      parse → fit an X-mirror Alignment → drive the Job
      parsed → registering → (capture 3) → fit → aligned → dry_run → drilling → done
      → build both GcodeProgram modes

  with the load-bearing counts (130 plunges in :drill, 0 negative-Z in :dry_run,
  Job reaches :done) and the two SAFETY INVARIANTS asserted at the integration
  level over the actual built program:

    1. Every plunge in :drill is preceded by `M3 S255` with no intervening `M5`.
    2. No XY move occurs while Z < zsafe (travel only at a safe height).
  """
  use ExUnit.Case, async: true

  alias BlauDrill.{Alignment, BoardModel, Correspondence, GcodeProgram, Job}

  @fixture Path.expand("../support/fixtures/segby_v1.drl", __DIR__)
  @zsafe 5.0
  @z_tol 1.0e-6

  test "the whole domain pipeline composes parse → align → job → both programs" do
    # ── parse ────────────────────────────────────────────────────────────────
    {:ok, board} = BoardModel.parse_drl(File.read!(@fixture))
    assert length(board.holes) == 130
    assert map_size(board.tools) == 5

    # ── fit a back-side X-mirror Alignment from real board holes ──────────────
    # Three non-collinear board holes mapped through the canonical mirror
    # (machine = (-x, y)) solve to an exact a = -1 affine via Alignment.fit/1.
    corrs =
      [{-57.15, 80.01}, {-54.61, 80.01}, {-57.15, 77.47}]
      |> Enum.map(fn {bx, by} -> %Correspondence{board: {bx, by}, machine: {-bx, by}} end)

    {:ok, %Alignment{} = alignment} = Alignment.fit(corrs)
    assert alignment.residuals.max <= 1.0e-6

    # ── drive the Job through the only legal order ────────────────────────────
    job = Job.new(board)
    assert job.state == :parsed

    {:ok, job} = Job.transition(job, :start_registering)
    assert job.state == :registering

    job =
      Enum.reduce(corrs, job, fn corr, acc ->
        {:ok, acc} = Job.transition(acc, {:capture, corr})
        acc
      end)

    {:ok, job} = Job.transition(job, {:fit, job.tol})
    assert job.state == :aligned

    {:ok, job} = Job.transition(job, :run_dry_run)
    assert job.state == :dry_run

    {:ok, job} = Job.transition(job, :confirm_registration)
    assert job.state == :drilling

    {:ok, job} = Job.transition(job, :complete)
    assert job.state == :done

    # ── build both modes off the Job's solved alignment ───────────────────────
    drill = GcodeProgram.build(board, job.alignment, mode: :drill)
    dryrun = GcodeProgram.build(board, job.alignment, mode: :dry_run)

    assert drill.mode == :drill
    assert dryrun.mode == :dry_run

    # 130 plunges in :drill (one per hole, all at zdrill = -2.5).
    plunges = Enum.count(drill.lines, &(&1 == "G1 Z-2.50000"))
    assert plunges == 130

    # 0 negative-Z anywhere in :dry_run (spindle off, hover only).
    assert negative_z_count(dryrun.lines) == 0

    # ── SAFETY INVARIANT 1: spindle on before any plunge, no intervening M5 ───
    assert spindle_on_before_every_plunge?(drill.lines)

    # ── SAFETY INVARIANT 2: no XY move while Z < zsafe ────────────────────────
    assert no_xy_below_safe?(drill.lines)
    assert no_xy_below_safe?(dryrun.lines)
  end

  # ── invariant helpers (walk the actual emitted lines) ───────────────────────

  # Count G-code Z moves whose target Z is negative.
  defp negative_z_count(lines) do
    Enum.count(lines, fn line ->
      case parse_z(line) do
        {:ok, z} -> z < -@z_tol
        :none -> false
      end
    end)
  end

  # True iff, scanning the program top-to-bottom, the spindle is ON (last seen
  # M3 with no later M5) at the moment of every plunge (a negative-Z G1).
  defp spindle_on_before_every_plunge?(lines) do
    {ok?, _spindle_on} =
      Enum.reduce(lines, {true, false}, fn line, {ok?, spindle_on?} ->
        cond do
          String.starts_with?(line, "M3 S") -> {ok?, true}
          String.starts_with?(line, "M5") -> {ok?, false}
          plunge_line?(line) -> {ok? and spindle_on?, spindle_on?}
          true -> {ok?, spindle_on?}
        end
      end)

    ok?
  end

  # True iff no `G0/G1 X.. Y..` rapid ever occurs while the toolhead Z is below
  # zsafe. We track the current Z from every Z move and check XY moves against it.
  defp no_xy_below_safe?(lines) do
    {ok?, _z} =
      Enum.reduce(lines, {true, @zsafe}, fn line, {ok?, z} ->
        cond do
          xy_move?(line) ->
            {ok? and z >= @zsafe - @z_tol, z}

          match?({:ok, _}, parse_z(line)) ->
            {:ok, new_z} = parse_z(line)
            {ok?, new_z}

          true ->
            {ok?, z}
        end
      end)

    ok?
  end

  defp plunge_line?(line), do: match?({:ok, z} when z < -@z_tol, parse_z(line))

  defp xy_move?(line) do
    Regex.match?(~r/^G[01]\b/, line) and Regex.match?(~r/\bX-?\d/, line) and
      Regex.match?(~r/\bY-?\d/, line)
  end

  # Parse the Z target of a pure Z move line (no X/Y on it).
  defp parse_z(line) do
    if Regex.match?(~r/\b[XY]-?\d/, line) do
      :none
    else
      case Regex.run(~r/\bZ(-?\d+(?:\.\d+)?)/, line) do
        [_, v] ->
          {f, _} = Float.parse(v)
          {:ok, f}

        _ ->
          :none
      end
    end
  end
end
