defmodule BlauDrill.Config do
  @moduledoc """
  The operator/hardware **configuration value** for a blau-drill station.

  A `Config` carries the machine-specific and tuned parameters the rest of the
  app reads — serial connection, motion limits, spindle G-code, and the tuned Z
  heights / feeds the `GcodeProgram` generator consumes. It is a **plain,
  immutable value**, not a process and not a database row (this app has no DB —
  see ADR-0004).

  ## The "resolve once" rule (architecture §02, the State lens)

  Config resolves **once** into an immutable snapshot at session start and is
  **never re-read mid-run**. The settings screen (`BlauDrillWeb.SettingsLive`)
  edits a working `Config`; a drilling session captures a snapshot of it when the
  board is loaded and uses *that* snapshot for the whole run, so changing a
  setting can never alter a stream that is already in flight. Concretely:

    * `BlauDrillWeb.SettingsLive` holds a working `Config` and, on **Apply**,
      writes the validated value into the application environment
      (`:blau_drill, BlauDrill.Config`). This is the "what a NEW session will
      use" slot.
    * `BlauDrillWeb.SessionLive` calls `current/0` **at mount** to snapshot the
      applied config into `Session.config`, and threads *that* snapshot into
      `GcodeProgram.build/3` opts and the `PrinterConnection` connect params for
      the life of the session.

  ## Defaults are safe, generic, operator-tunable

  The defaults here are the safe generic fallbacks already encoded in the domain
  (the `GcodeProgram` Z/feed defaults, baud 115200, motion limits sized for a
  typical small bed). They are **not** the truth of any one machine — per
  `CLAUDE.md` we do not commit machine-specific values as hardcoded defaults.
  Every field is overridable through the settings screen; the serial port has
  **no** committed default (it is `nil` until the operator picks one), since a
  device path is the most machine-specific value of all.

  ## Validation

  `new/1` is the smart constructor: it returns `{:ok, %Config{}}` only for a
  valid combination, and `{:error, reasons}` (a keyword list of `field ->
  reason`) otherwise. The validated invariants:

    * `baud` is one of `#{inspect(__MODULE__)}.bauds/0` (`9600 | 57600 | 115200
      | 250000`).
    * `max_x`, `max_y`, `max_z` are **strictly positive** — a non-positive travel
      limit cannot guard against a crash.
    * `pwm_max` is one of `#{inspect(__MODULE__)}.pwm_maxes/0` (`255 | 1000`) and
      `spindle_speed` is within `0..pwm_max` — the spindle PWM duty must fit the
      controller's range.
    * `spindle_max_rpm` is a **positive** spindle speed (RPM) at full PWM duty,
      used only to map the commanded PWM to a human-readable RPM in the drilling
      telemetry (`rpm = spindle_speed / pwm_max * spindle_max_rpm`). It models
      nothing physical — it is the operator's labelled full-scale speed.
    * `spindle_on` / `spindle_off` are non-empty G-code commands.
    * `zsafe > zdrill` (the safe travel height is above the plunge depth) and
      `zchange >= zsafe` (the bit-change lift clears the travel height), so the
      "never traverse XY below zsafe" invariant has a coherent set of heights.
    * `drill_feed > 0` and `hover >= 0`.
  """

  @bauds [9600, 57600, 115_200, 250_000]
  @pwm_maxes [255, 1000]

  @typedoc "An allowed serial baud rate."
  @type baud :: 9600 | 57600 | 115_200 | 250_000

  @typedoc "An allowed spindle PWM full-scale range."
  @type pwm_max :: 255 | 1000

  @type t :: %__MODULE__{
          # Connection
          port: String.t() | nil,
          baud: baud(),
          auto_connect: boolean(),
          # Motion limits (mm) — prevent mechanical crashes.
          max_x: float(),
          max_y: float(),
          max_z: float(),
          # Spindle control
          spindle_on: String.t(),
          spindle_off: String.t(),
          pwm_max: pwm_max(),
          spindle_speed: non_neg_integer(),
          spindle_max_rpm: pos_integer(),
          # Drilling defaults (GcodeProgram tunables)
          zdrill: float(),
          zsafe: float(),
          zchange: float(),
          drill_feed: number(),
          hover: float()
        }

  defstruct port: nil,
            baud: 115_200,
            auto_connect: false,
            max_x: 300.0,
            max_y: 200.0,
            max_z: 50.0,
            spindle_on: "M3 S255",
            spindle_off: "M5",
            pwm_max: 255,
            spindle_speed: 255,
            spindle_max_rpm: 12_000,
            zdrill: -2.5,
            zsafe: 5.0,
            zchange: 30.0,
            drill_feed: 200,
            hover: 0.2

  @doc "The allowed serial baud rates, for the settings dropdown."
  @spec bauds() :: [baud()]
  def bauds, do: @bauds

  @doc "The allowed spindle PWM full-scale ranges, for the settings dropdown."
  @spec pwm_maxes() :: [pwm_max()]
  def pwm_maxes, do: @pwm_maxes

  @doc """
  The default config — the safe generic fallbacks, before any operator override.

  This always validates; it is the value `Reset to Defaults` restores to.
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Smart constructor. Builds a `Config` from a map/keyword of fields, applying
  defaults for anything omitted, and validates the result.

  Returns `{:ok, %Config{}}` or `{:error, [field: reason, ...]}`. String keys
  (as they arrive from a form submit) and atom keys are both accepted; numeric
  string values for the numeric fields are coerced.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, keyword()}
  def new(attrs \\ %{}) do
    attrs = normalize(attrs)
    base = %__MODULE__{}

    config = %__MODULE__{
      port: get(attrs, :port, base.port) |> blank_to_nil(),
      baud: to_int(get(attrs, :baud, base.baud), base.baud),
      auto_connect: to_bool(get(attrs, :auto_connect, base.auto_connect)),
      max_x: to_float(get(attrs, :max_x, base.max_x), base.max_x),
      max_y: to_float(get(attrs, :max_y, base.max_y), base.max_y),
      max_z: to_float(get(attrs, :max_z, base.max_z), base.max_z),
      spindle_on: get(attrs, :spindle_on, base.spindle_on) |> trim(),
      spindle_off: get(attrs, :spindle_off, base.spindle_off) |> trim(),
      pwm_max: to_int(get(attrs, :pwm_max, base.pwm_max), base.pwm_max),
      spindle_speed: to_int(get(attrs, :spindle_speed, base.spindle_speed), base.spindle_speed),
      spindle_max_rpm:
        to_int(get(attrs, :spindle_max_rpm, base.spindle_max_rpm), base.spindle_max_rpm),
      zdrill: to_float(get(attrs, :zdrill, base.zdrill), base.zdrill),
      zsafe: to_float(get(attrs, :zsafe, base.zsafe), base.zsafe),
      zchange: to_float(get(attrs, :zchange, base.zchange), base.zchange),
      drill_feed: to_number(get(attrs, :drill_feed, base.drill_feed), base.drill_feed),
      hover: to_float(get(attrs, :hover, base.hover), base.hover)
    }

    case validate(config) do
      [] -> {:ok, config}
      errors -> {:error, errors}
    end
  end

  @doc """
  The currently-applied config — the snapshot a NEW session should use.

  Reads `:blau_drill, BlauDrill.Config` from the application environment, falling
  back to `default/0` when nothing has been applied yet. A `SessionLive` calls
  this **once at mount** and never again (the "resolve once" rule).
  """
  @spec current() :: t()
  def current do
    case Application.get_env(:blau_drill, __MODULE__) do
      %__MODULE__{} = config -> config
      _ -> default()
    end
  end

  @doc """
  Persist `config` as the applied config for subsequent sessions (in-memory, for
  the lifetime of the VM — there is no DB).

  This is what the settings screen's **Apply** writes. It does not touch any
  session already in flight; those captured their snapshot at mount.
  """
  @spec apply(t()) :: :ok
  def apply(%__MODULE__{} = config) do
    Application.put_env(:blau_drill, __MODULE__, config)
  end

  @doc """
  The `GcodeProgram.build/3` options carried by this config — the tuned Z
  heights, feed, spindle speed and hover. The settings screen's spindle/defaults
  values flow into a generated program through exactly this list.
  """
  @spec gcode_opts(t()) :: keyword()
  def gcode_opts(%__MODULE__{} = c) do
    [
      zdrill: c.zdrill,
      zsafe: c.zsafe,
      zchange: c.zchange,
      drill_feed: c.drill_feed,
      spindle_speed: c.spindle_speed,
      hover: c.hover
    ]
  end

  @doc """
  The `BlauDrill.Printer.connect/1` options carried by this config — the serial
  `:port` (when the operator has chosen one). Baud is included for the real
  adapter to consume; `nil`/absent values are dropped so the configured backend
  defaults still apply.
  """
  @spec connect_opts(t()) :: keyword()
  def connect_opts(%__MODULE__{} = c) do
    [port: c.port, baud: c.baud]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # ── validation ──────────────────────────────────────────────────────────────

  defp validate(%__MODULE__{} = c) do
    []
    |> check(c.baud in @bauds, :baud, "must be one of #{inspect(@bauds)}")
    |> check(positive?(c.max_x), :max_x, "must be a positive travel limit (mm)")
    |> check(positive?(c.max_y), :max_y, "must be a positive travel limit (mm)")
    |> check(positive?(c.max_z), :max_z, "must be a positive travel limit (mm)")
    |> check(c.pwm_max in @pwm_maxes, :pwm_max, "must be one of #{inspect(@pwm_maxes)}")
    |> check(
      is_integer(c.spindle_speed) and c.spindle_speed >= 0 and c.spindle_speed <= c.pwm_max,
      :spindle_speed,
      "must be within 0..#{c.pwm_max} (the PWM range)"
    )
    |> check(
      is_integer(c.spindle_max_rpm) and c.spindle_max_rpm > 0,
      :spindle_max_rpm,
      "must be a positive spindle speed (RPM) at full PWM"
    )
    |> check(present?(c.spindle_on), :spindle_on, "must be a non-empty G-code command")
    |> check(present?(c.spindle_off), :spindle_off, "must be a non-empty G-code command")
    |> check(c.zsafe > c.zdrill, :zsafe, "safe height must be above the plunge depth (zdrill)")
    |> check(c.zchange >= c.zsafe, :zchange, "bit-change lift must clear the safe height (zsafe)")
    |> check(number?(c.drill_feed) and c.drill_feed > 0, :drill_feed, "must be a positive feed")
    |> check(number?(c.hover) and c.hover >= 0, :hover, "must be a non-negative hover height")
    |> Enum.reverse()
  end

  defp check(errors, true, _field, _msg), do: errors
  defp check(errors, false, field, msg), do: [{field, msg} | errors]

  defp positive?(v), do: number?(v) and v > 0
  defp number?(v), do: is_number(v)
  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  # ── coercion helpers (forms arrive as string-keyed string values) ────────────

  defp normalize(attrs) when is_list(attrs), do: Map.new(attrs)
  defp normalize(attrs) when is_map(attrs), do: attrs

  # Read a field by atom OR string key.
  defp get(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, v} ->
        v

      :error ->
        case Map.fetch(attrs, Atom.to_string(key)) do
          {:ok, v} -> v
          :error -> default
        end
    end
  end

  defp to_int(v, _default) when is_integer(v), do: v

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int(_v, default), do: default

  defp to_float(v, _default) when is_float(v), do: v
  defp to_float(v, _default) when is_integer(v), do: v * 1.0

  defp to_float(v, default) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {f, _} -> f
      :error -> default
    end
  end

  defp to_float(_v, default), do: default

  # Feed may be int or float; keep an int as an int, parse strings leniently.
  defp to_number(v, _default) when is_number(v), do: v

  defp to_number(v, default) when is_binary(v) do
    s = String.trim(v)

    case Integer.parse(s) do
      {n, ""} -> n
      _ -> to_float(s, default)
    end
  end

  defp to_number(_v, default), do: default

  defp to_bool(true), do: true
  defp to_bool("true"), do: true
  defp to_bool("on"), do: true
  defp to_bool(_), do: false

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end

  defp blank_to_nil(v), do: v

  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(v), do: v
end
