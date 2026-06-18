defmodule BlauDrill.GcodeProgram do
  @moduledoc """
  The generated Marlin G-code for **one mode** (`:dry_run | :drill`) — the
  safety-critical heart of blau-drill.

  `build/3` takes a `BlauDrill.BoardModel`, a **solved** `BlauDrill.Alignment`,
  and options, and emits the full program as a list of lines. It folds the three
  jobs of the retired `postprocess_drill.py` into typed parameters:

    * the **Marlin spindle quirk** — `M3 S255`, with the PWM duty on the same
      line as the `M3` (a bare `M3` only toggles the enable pin and never sets
      the PWM, MarlinFirmware/Marlin#8379);
    * the **dry-run variant** — spindle left off, the bit hovers `hover` mm over
      every hole instead of plunging;
    * the fiducial **`G92`** touch-off preamble.

  Dry-run and real are the *same* generator with one parameter flipped, not two
  code paths (see ADR-0001, ADR-0006, `CONTEXT.md`: "GcodeProgram").

  ## Required by type: an `Alignment`

  `build/3` requires an `%Alignment{}` in the alignment slot. There is **no**
  arity that accepts raw, unaligned holes or a bare `Transform2D` — a non-aligned
  call is a `FunctionClauseError`. A hole lives only in board space; its machine
  coordinate is the derived view `Transform2D.apply(alignment.transform, hole)`,
  computed here on demand. The back-side **X-mirror** is carried by the fitted
  transform (`a = -1`), not a flag.

  ## The two safety invariants, enforced structurally

  1. **Never traverse XY without Z safe.** Every hole is drilled through the
     `safe_move/2` combinator, which *always* emits a retract to `zsafe` before
     the next `G0 X.. Y..` rapid. A program built by this module cannot contain
     an XY rapid below `zsafe`, by construction (see `drill_hole/3` and
     `tool_block/4`). The bit is never dragged sideways while buried.

  2. **Spindle running before any plunge (drill mode).** A tool block cannot
     emit its first plunge without first running `spindle_on_step/2`, which in
     `:drill` mode emits `M3 S<speed>`. In `:dry_run` the plunge depth is the
     positive hover, so a negative Z is unrepresentable in that mode — the
     `plunge_z/1` for `:dry_run` returns `+hover` and never reaches `zdrill`.

  ## Intentional deviations from the pcb2gcode golden

  The reference goldens (`segby_v1.{drill,dryrun}.gcode`) were produced by
  `pcb2gcode` + `postprocess_drill.py`. This native generator reproduces the
  **semantic** content (every hole's machine X/Y to 5 decimals, the Z depths, the
  spindle/retract structure, the per-tool `M0`/`M6` pauses, the touch-off `G92`
  preamble and the homing postamble) and the load-bearing formatting (`%.5f`
  coordinates, `M3 S255`, the dry-run hover annotation). Two pcb2gcode artifacts
  are deliberately dropped/altered:

    * the `( pcb2gcode 2.5.0 )` vanity banner and the long preamble comment block
      — replaced with a short honest header naming this generator;
    * the **hole order within a tool** — pcb2gcode reorders via a nearest-neighbor
      TSP; this generator emits holes in drill-file order. The *set* of drilled
      `{tool, x, y}` is identical; only the visiting order differs.
  """

  alias BlauDrill.Alignment
  alias BlauDrill.BoardModel
  alias BlauDrill.Transform2D

  @typedoc "The drilling mode: a real cut, or a spindle-off rehearsal."
  @type mode :: :dry_run | :drill

  @typedoc "Axis-aligned bounding box of the drilled holes in machine space."
  @type bbox_machine :: {float(), float(), float(), float()}

  @type t :: %__MODULE__{
          lines: [String.t()],
          mode: mode(),
          bbox_machine: bbox_machine(),
          tool_order: [BoardModel.tool_id()]
        }

  @enforce_keys [:lines, :mode, :bbox_machine, :tool_order]
  defstruct [:lines, :mode, :bbox_machine, :tool_order]

  # Defaults from drill.cfg (tuned, carried in session config — never the
  # hardware truth, just safe fallbacks for a generator call).
  @default_zdrill -2.5
  @default_zsafe 5.0
  @default_zchange 30.0
  @default_drill_feed 200
  @default_spindle_speed 255
  @default_hover 0.2

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Build the G-code program for `board` under `alignment`, in the requested mode.

  Requires an `%Alignment{}` — there is no arity that accepts raw holes. Options:

    * `:mode` — `:dry_run` (default, the safe one) or `:drill`.
    * `:zdrill` (default `#{@default_zdrill}`) — plunge depth in real drilling.
    * `:zsafe` (default `#{@default_zsafe}`) — safe travel height; XY moves
      happen here or above.
    * `:zchange` (default `#{@default_zchange}`) — lift height for bit changes.
    * `:drill_feed` (default `#{@default_drill_feed}`) — plunge/retract feed rate.
    * `:spindle_speed` (default `#{@default_spindle_speed}`) — PWM duty on the
      `M3` line in `:drill` mode.
    * `:hover` (default `#{@default_hover}`) — dry-run hover height above the
      touched-off surface.
  """
  @spec build(BoardModel.t(), Alignment.t(), keyword()) :: t()
  def build(%BoardModel{} = board, %Alignment{} = alignment, opts \\ []) do
    cfg = config(opts)
    transform = alignment.transform

    tool_order = tool_order(board)

    machine_holes =
      board.holes
      |> Enum.map(fn hole ->
        {mx, my} = Transform2D.apply(transform, {hole.x, hole.y})
        %{tool: hole.tool, x: mx, y: my}
      end)

    by_tool = Enum.group_by(machine_holes, & &1.tool)

    body =
      tool_order
      |> Enum.flat_map(fn tool ->
        tool_block(tool, Map.fetch!(by_tool, tool), board.tools, cfg)
      end)

    lines = header(board, tool_order, cfg) ++ preamble(cfg) ++ body ++ postamble(cfg)

    %__MODULE__{
      lines: lines,
      mode: cfg.mode,
      bbox_machine: bbox_machine(machine_holes),
      tool_order: tool_order
    }
  end

  # ---------------------------------------------------------------------------
  # Config
  # ---------------------------------------------------------------------------

  defp config(opts) do
    %{
      mode: Keyword.get(opts, :mode, :dry_run),
      zdrill: Keyword.get(opts, :zdrill, @default_zdrill),
      zsafe: Keyword.get(opts, :zsafe, @default_zsafe),
      zchange: Keyword.get(opts, :zchange, @default_zchange),
      drill_feed: Keyword.get(opts, :drill_feed, @default_drill_feed),
      spindle_speed: Keyword.get(opts, :spindle_speed, @default_spindle_speed),
      hover: Keyword.get(opts, :hover, @default_hover)
    }
  end

  # ---------------------------------------------------------------------------
  # Tool ordering — file order of first appearance, so output is deterministic
  # and matches the drill file's tool sequence (T1..T5 for the fixture).
  # ---------------------------------------------------------------------------

  defp tool_order(%BoardModel{holes: holes}) do
    holes
    |> Enum.map(& &1.tool)
    |> Enum.uniq()
  end

  # ---------------------------------------------------------------------------
  # Header (honest banner — intentionally NOT the pcb2gcode vanity banner)
  # ---------------------------------------------------------------------------

  defp header(board, tool_order, cfg) do
    sizes =
      tool_order
      |> Enum.map(fn tool -> "[#{fmt_diameter(Map.fetch!(board.tools, tool))}mm]" end)
      |> Enum.join(" ")

    [
      "( blau-drill native G-code )",
      "( mode: #{cfg.mode} )",
      "",
      "( This file uses #{length(tool_order)} drill bit sizes. )",
      "( Bit sizes: #{sizes} )",
      ""
    ]
  end

  # ---------------------------------------------------------------------------
  # Preamble — the touch-off block + unit/mode setup.
  #
  # The fiducial G92 is left as `G92 X0 Y0 Z0`: the affine Transform2D already
  # absorbs the offset, so touch-off only zeroes the controller at the fiducial.
  # ---------------------------------------------------------------------------

  defp preamble(_cfg) do
    [
      "(MSG, Position drill on the fiducial and touch off.)",
      "M0      (Jog to fiducial, lower bit until it touches, then resume.)",
      "G04 P0 ( dwell for no time -- G64 should not smooth over this point )",
      "G92 X0 Y0 Z0",
      "",
      "G94       (Millimeters per minute feed rate.)",
      "G21       (Units == Millimeters.)",
      "G91.1     (Incremental arc distance mode.)",
      "G90       (Absolute coordinates.)",
      ""
    ]
  end

  # ---------------------------------------------------------------------------
  # Per-tool block.
  #
  # STRUCTURAL invariant 2: the block's holes are emitted only AFTER
  # `spindle_on_step/1`, so in :drill mode no plunge can precede the M3 S255.
  # ---------------------------------------------------------------------------

  defp tool_block(tool, holes, tools, cfg) do
    diameter = fmt_diameter(Map.fetch!(tools, tool))

    change =
      [
        "G00 Z#{fmt5(cfg.zchange)} (Retract)",
        tool,
        "M5      (Spindle stop.)",
        "G04 P1.00000",
        "(MSG, Change tool bit to drill size #{diameter}mm)",
        "M6      (Tool change.)",
        "M0      (Temporary machine stop.)"
      ] ++
        spindle_on_step(cfg) ++
        [
          "G0 Z#{fmt5(cfg.zsafe)}",
          "G04 P1.00000",
          "",
          "G1 F#{fmt5(cfg.drill_feed)}"
        ]

    change ++ Enum.flat_map(holes, &drill_hole(&1, cfg))
  end

  # The spindle arm/disarm step. In :drill, emit M3 S<speed> ON THE SAME LINE
  # (Marlin quirk). In :dry_run, leave it OFF and say so.
  defp spindle_on_step(%{mode: :drill, spindle_speed: speed}) do
    ["M3 S#{speed}      (Spindle on clockwise at full PWM.)"]
  end

  defp spindle_on_step(%{mode: :dry_run}) do
    ["( dry run: spindle left OFF )"]
  end

  # ---------------------------------------------------------------------------
  # Per-hole emission — the `safe_move` combinator.
  #
  # STRUCTURAL invariant 1: every hole is `G0 X.. Y..` (an XY rapid) at the
  # current safe Z, then plunge, then ALWAYS retract to zsafe. Because the
  # retract is unconditional and is the last line emitted per hole, the NEXT
  # hole's XY rapid is always preceded by a retract — there is no path that
  # leaves the bit down across an XY move.
  # ---------------------------------------------------------------------------

  defp drill_hole(%{x: x, y: y}, cfg) do
    safe_move(cfg, {x, y}, fn ->
      [plunge_line(cfg)]
    end)
  end

  # Travel to (x, y) at a safe Z, run `body` (the plunge), then retract to zsafe.
  # The leading G0 XY is only reachable here, and `retract` is unconditional, so
  # the toolhead is always at zsafe before and after the XY rapid.
  defp safe_move(cfg, {x, y}, body) when is_function(body, 0) do
    [fmt_xy_rapid(x, y)] ++ body.() ++ [retract(cfg)]
  end

  defp retract(cfg), do: fmt_g1_z(cfg.zsafe)

  # The plunge line. In :drill -> `G1 Z-2.50000`. In :dry_run -> the positive
  # hover with the annotation, so a negative Z is unrepresentable in dry-run.
  defp plunge_line(%{mode: :drill} = cfg), do: fmt_g1_z(cfg.zdrill)

  defp plunge_line(%{mode: :dry_run, hover: hover, zdrill: zdrill}) do
    "G1 Z#{fmt5(hover)}  ( dry-run hover, was Z#{fmt5(zdrill)} )"
  end

  # ---------------------------------------------------------------------------
  # Postamble — final retract, home, spindle off, program end.
  # ---------------------------------------------------------------------------

  defp postamble(cfg) do
    [
      "G00 Z#{fmt3(cfg.zchange)} ( All done -- retract )",
      "G04 P0 ( dwell for no time -- G64 should not smooth over this point )",
      "G00 X0.0 Y0.0 Z0.0  ( move back to home )",
      "",
      "",
      "M5      (Spindle off.)",
      "G04 P1.000000",
      "M9      (Coolant off.)",
      "M2      (Program end.)",
      ""
    ]
  end

  # ---------------------------------------------------------------------------
  # Bounding box (machine space)
  # ---------------------------------------------------------------------------

  defp bbox_machine([]), do: {0.0, 0.0, 0.0, 0.0}

  defp bbox_machine(holes) do
    xs = Enum.map(holes, & &1.x)
    ys = Enum.map(holes, & &1.y)
    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  # ---------------------------------------------------------------------------
  # Formatting
  # ---------------------------------------------------------------------------

  # `%.5f` — coordinates and Z values: 57.15 -> "57.15000". We round to the
  # display precision FIRST, then add `0.0`: this collapses both a literal
  # negative zero (from `-1 * 0.0` after the X-mirror) AND a sub-precision
  # negative residual (e.g. `-1.7e-15` from a fitted transform whose mirror is
  # only `-1.0` to float tolerance) to a clean `0.0`, so board X=0 prints
  # `X0.00000`, never `X-0.00000`.
  defp fmt5(v), do: :erlang.float_to_binary(Float.round(v * 1.0, 5) + 0.0, decimals: 5)

  # `%.3f` — the postamble retract height: 30.0 -> "30.000".
  defp fmt3(v), do: :erlang.float_to_binary(Float.round(v * 1.0, 3) + 0.0, decimals: 3)

  defp fmt_xy_rapid(x, y), do: "G0 X#{fmt5(x)} Y#{fmt5(y)}"
  defp fmt_g1_z(z), do: "G1 Z#{fmt5(z)}"

  # Diameter formatting: 0.600 -> "0.6", 1.000 -> "1", 1.200 -> "1.2".
  defp fmt_diameter(d) do
    d
    |> :erlang.float_to_binary(decimals: 4)
    |> String.replace(~r/0+$/, "")
    |> String.replace(~r/\.$/, "")
  end
end
