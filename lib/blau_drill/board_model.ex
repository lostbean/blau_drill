defmodule BlauDrill.BoardModel do
  @moduledoc """
  The immutable parse of the KiCad outputs — `holes`, `outline`, `fiducials`,
  `tools`, and a bounding box — entirely in **board coordinates**.

  `BoardModel` is produced **once at the parsing edge** by `parse/1` and is
  consumed by everything downstream; nothing past the edge ever touches a file
  again. It deliberately holds **no machine coordinates**: a hole's machine
  coordinate is a derived view, computed on demand by `Transform2D.apply/2`. In
  particular the **back-side X-mirror is NOT applied here** — negative X values
  from the drill file are preserved verbatim. Mirroring, rotation and offset are
  absorbed by the fitted `Transform2D`, never by the parser.

  ## Inputs

  `parse/1` takes a map with the raw KiCad exports:

      %{drl: drl_string, edge_cuts: svg_string_or_nil, copper: svg_string_or_nil}

  Only `:drl` is required. `parse_drl/1` is a convenience for the common
  `.drl`-only case.

  ## The Excellon `.drl` format

  The parser targets KiCad's metric, decimal, absolute Excellon export
  (`FMAT,2` / `METRIC` / `FORMAT={-:-/ absolute / metric / decimal}`):

    * `M48` opens the header (required — its absence is rejected).
    * `; ...` lines are comments and are ignored.
    * `TnC<diameter>` defines a tool, e.g. `T1C0.600` → tool `"T1"` is 0.6 mm.
    * `%` ends the header.
    * A bare `Tn` line selects the active tool.
    * `X<dec>Y<dec>` lines are holes drilled with the active tool; coordinates
      are decimal millimetres and X may be negative.
    * `M30` ends the program.

  Tool ids are kept as **strings** (`"T1"`) so they round-trip unchanged into
  the G-code that groups holes per tool.

  ## The X135/Y−149 absolute-page trap

  A correct KiCad export with the *Drill/Place File Origin* set on a fiducial
  produces small coordinates **centred near the origin** (segby_v1 ranges
  roughly X −81..0, Y −3.8..80 — one axis legitimately negative, but the box
  straddles the origin and is modest in span). A **broken** export, with the
  origin never set, emits absolute *page* coordinates that sit far *off* the
  origin (e.g. X135, Y−149). Such input is rejected at the edge with
  `{:error, {:absolute_page_coordinates, details}}` rather than being streamed
  and discovered as an out-of-bounds move mid-drill.

  Two complementary checks (either trips rejection):

    * **Magnitude:** any single coordinate beyond `@max_plausible_coord_mm`
      (250 mm) — larger than the ~235 mm bed, so impossible for a real board.
    * **Off-origin offset:** the nearest bbox corner to the origin lies more
      than `@max_origin_offset_mm` (100 mm) away — i.e. the whole hole cloud is
      pushed off into a far quadrant. A correctly-zeroed board always has holes
      bracketing the origin (its nearest corner is essentially at 0), so this
      never fires on a good export, but the X135/Y−149 cloud (nearest corner
      ≈ 135 mm out) trips it cleanly.

  The thresholds are intentionally generous so they never reject the legitimate
  near-origin negative coordinates of a correctly-zeroed board.

  ## Outline & fiducials

  When an Edge.Cuts SVG is supplied, `outline` is the board outline as a closed
  **polyline** — a list of `{x, y}` points in SVG/board millimetres, parsed from
  the single `<path d="...">` KiCad emits (absolute `M`/`L`-style coordinate
  pairs, `Z` ignored). This is a minimal hand-rolled parser for the small KiCad
  fixture (no curve/relative-command support); without an `:edge_cuts` input
  `outline` is `nil`.

  Fiducials are **not yet extracted** — `fiducials` is always `[]`. The provided
  SVGs do not reliably distinguish registration marks, so this is a documented
  TODO; the selectable registration set downstream is `fiducials ++ holes`, so
  holes remain usable in the meantime.
  """

  @typedoc "A tool identifier as it appears in the drill file, e.g. `\"T1\"`."
  @type tool_id :: String.t()

  @typedoc "The mapping of tool id to bit diameter in millimetres."
  @type tool_table :: %{tool_id() => float()}

  @typedoc "A single drill location in board space."
  @type hole :: %{x: float(), y: float(), tool: tool_id()}

  @typedoc "A registration-candidate reference mark, in board coordinates."
  @type fiducial :: %{x: float(), y: float(), kind: :cross | :hole}

  @typedoc "The board outline as a closed polyline of `{x, y}` points."
  @type outline :: [{float(), float()}]

  @typedoc "Axis-aligned bounding box over the holes: `{min_x, min_y, max_x, max_y}`."
  @type bbox :: {float(), float(), float(), float()}

  @type t :: %__MODULE__{
          holes: [hole()],
          outline: outline() | nil,
          fiducials: [fiducial()],
          tools: tool_table(),
          bbox: bbox()
        }

  defstruct holes: [], outline: nil, fiducials: [], tools: %{}, bbox: nil

  # Any hole coordinate beyond this (mm, absolute value) means the export is in
  # absolute page coordinates, not board coordinates centred near the origin.
  # See the "X135/Y−149 trap" section of the moduledoc.
  @max_plausible_coord_mm 250.0

  # If the bbox corner nearest the origin is farther than this (mm), the whole
  # hole cloud has been pushed off into a far quadrant — the page-coordinate
  # signature. A correctly-zeroed board brackets the origin, so its nearest
  # corner sits at ~0.
  @max_origin_offset_mm 100.0

  @doc """
  Parse the KiCad outputs into a `BoardModel`.

  Accepts `%{drl: drl, edge_cuts: svg_or_nil, copper: svg_or_nil}`; only `:drl`
  is required. Returns `{:ok, %BoardModel{}}` or `{:error, reason}`. Fails
  loudly at the edge — malformed drill files, holes with no selected tool, and
  the absolute-page-coordinate trap all return errors rather than crashing or
  passing bad data downstream.
  """
  @spec parse(%{
          optional(:drl) => String.t() | nil,
          optional(:edge_cuts) => String.t() | nil,
          optional(:copper) => String.t() | nil
        }) :: {:ok, t()} | {:error, term()}
  def parse(%{drl: drl} = inputs) when is_binary(drl) do
    with {:ok, tools, holes} <- parse_drl_body(drl),
         :ok <- check_page_coordinates(holes) do
      outline = parse_outline(Map.get(inputs, :edge_cuts))

      {:ok,
       %__MODULE__{
         holes: holes,
         outline: outline,
         fiducials: [],
         tools: tools,
         bbox: bbox(holes)
       }}
    end
  end

  def parse(%{drl: nil}), do: {:error, :missing_drl}
  def parse(_), do: {:error, :missing_drl}

  @doc """
  Convenience for the common `.drl`-only case. Equivalent to
  `parse(%{drl: drl})`.
  """
  @spec parse_drl(String.t()) :: {:ok, t()} | {:error, term()}
  def parse_drl(drl) when is_binary(drl), do: parse(%{drl: drl})

  # --- Excellon .drl parsing --------------------------------------------------

  @spec parse_drl_body(String.t()) :: {:ok, tool_table(), [hole()]} | {:error, term()}
  defp parse_drl_body(drl) do
    lines =
      drl
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim/1)

    cond do
      not Enum.member?(lines, "M48") ->
        {:error, :missing_m48_header}

      true ->
        scan(lines, %{tools: %{}, holes: [], active: nil})
    end
  end

  # Walk the lines, accumulating tool definitions and holes. Tool ids are kept
  # as strings; coordinates are parsed to floats.
  defp scan([], %{holes: []}), do: {:error, :no_holes}
  defp scan([], %{tools: tools, holes: holes}), do: {:ok, tools, Enum.reverse(holes)}

  defp scan([line | rest], state) do
    cond do
      comment?(line) or line == "" ->
        scan(rest, state)

      match = tool_def(line) ->
        {tool, diameter} = match
        scan(rest, put_in(state.tools[tool], diameter))

      tool = tool_select(line, state.tools) ->
        scan(rest, %{state | active: tool})

      coord = coordinate(line) ->
        case state.active do
          nil ->
            {:error, {:hole_with_no_tool, line}}

          tool ->
            {x, y} = coord
            hole = %{x: x, y: y, tool: tool}
            scan(rest, %{state | holes: [hole | state.holes]})
        end

      true ->
        # Header keywords (METRIC, FMAT,2, G90, G05, %), program end (M30), and
        # any other non-data directive are skipped.
        scan(rest, state)
    end
  end

  defp comment?(";" <> _), do: true
  defp comment?(_), do: false

  # `T1C0.600` -> {"T1", 0.6}
  defp tool_def(line) do
    case Regex.run(~r/^(T\d+)C([0-9]+(?:\.[0-9]+)?)$/, line) do
      [_, tool, diameter] -> {tool, to_float(diameter)}
      _ -> nil
    end
  end

  # A bare `T1` selects an already-defined tool.
  defp tool_select(line, tools) do
    case Regex.run(~r/^(T\d+)$/, line) do
      [_, tool] -> if Map.has_key?(tools, tool), do: tool, else: nil
      _ -> nil
    end
  end

  # `X-57.15Y80.01` -> {-57.15, 80.01}
  defp coordinate(line) do
    case Regex.run(~r/^X(-?[0-9]+(?:\.[0-9]+)?)Y(-?[0-9]+(?:\.[0-9]+)?)$/, line) do
      [_, x, y] -> {to_float(x), to_float(y)}
      _ -> nil
    end
  end

  defp to_float(str) do
    {f, ""} = Float.parse(str)
    f
  end

  # --- The absolute-page-coordinate trap -------------------------------------

  defp check_page_coordinates(holes) do
    {min_x, min_y, max_x, max_y} = bbox(holes)

    oversized =
      Enum.filter(holes, fn %{x: x, y: y} ->
        abs(x) > @max_plausible_coord_mm or abs(y) > @max_plausible_coord_mm
      end)

    # Distance from the origin to the bbox edge along each axis. Zero when the
    # box straddles the origin on that axis; positive when the whole box sits to
    # one side of it.
    off_x = max(min_x, 0.0) + max(-max_x, 0.0)
    off_y = max(min_y, 0.0) + max(-max_y, 0.0)
    origin_offset = :math.sqrt(off_x * off_x + off_y * off_y)

    cond do
      oversized != [] ->
        page_error(%{
          reason: :coordinate_over_bed_size,
          threshold_mm: @max_plausible_coord_mm,
          sample: Enum.take(oversized, 3)
        })

      origin_offset > @max_origin_offset_mm ->
        page_error(%{
          reason: :bbox_far_from_origin,
          threshold_mm: @max_origin_offset_mm,
          origin_offset_mm: Float.round(origin_offset, 3),
          bbox: {min_x, min_y, max_x, max_y}
        })

      true ->
        :ok
    end
  end

  defp page_error(details) do
    {:error,
     {:absolute_page_coordinates,
      Map.put(
        details,
        :hint,
        "Drill coordinates look like an absolute KiCad page export with no " <>
          "Drill/Place File Origin set. Re-export with the origin placed on a fiducial."
      )}}
  end

  # --- Bounding box -----------------------------------------------------------

  # Holes are guaranteed non-empty here: `parse_drl_body/1` rejects an empty
  # program with `:no_holes` before bbox is ever computed.
  @spec bbox([hole(), ...]) :: bbox()
  defp bbox(holes) do
    xs = Enum.map(holes, & &1.x)
    ys = Enum.map(holes, & &1.y)
    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  # --- Edge.Cuts SVG outline --------------------------------------------------

  @spec parse_outline(String.t() | nil) :: outline() | nil
  defp parse_outline(nil), do: nil

  defp parse_outline(svg) when is_binary(svg) do
    with [_, d] <- Regex.run(~r/<path[^>]*\bd="([^"]*)"/s, svg),
         points when points != [] <- coordinate_pairs(d) do
      points
    else
      _ -> nil
    end
  end

  # Pull every `x,y` numeric pair out of the path data, ignoring the command
  # letters (M/L/Z). KiCad's Edge.Cuts export for a rectangular board is a flat
  # list of absolute corner coordinates, which is all this needs to handle.
  defp coordinate_pairs(d) do
    ~r/(-?[0-9]+(?:\.[0-9]+)?)\s*,\s*(-?[0-9]+(?:\.[0-9]+)?)/
    |> Regex.scan(d)
    |> Enum.map(fn [_, x, y] -> {to_float(x), to_float(y)} end)
  end
end
