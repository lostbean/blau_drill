defmodule BlauDrill.Printer.Devices do
  @moduledoc """
  The operator-selectable **printer device** list for the Stage 1 connection card.

  A *device* is one concrete thing the operator can connect to: either the
  built-in **Simulator** (always available, no hardware) or a **real USB serial
  port** detected on the computer. This module turns "what can I connect to right
  now?" into a small, render-friendly value the connection card iterates over,
  and maps a chosen device back to the `BlauDrill.Printer.connect/1` opts
  (`:backend` + `:port`) that open it.

  ## Always-available simulator, best-effort ports

  The Simulator is always listed first and never fails — a fresh checkout, dev,
  and tests can all pick it with no hardware. Real ports are enumerated
  best-effort from `Circuits.UART.enumerate/0` (a map of `port => info`); if the
  NIF/module is unavailable or the call errors, we simply offer only the
  Simulator. Plugging in a printer and re-calling `list/0` (the card's refresh
  button) surfaces the new port.

  Selecting or connecting a device is **not** motion: opening a real port does
  not move the machine. Every downstream verb (energize/jog/drill) still routes
  through `BlauDrill.PrinterConnection`'s gates.
  """

  @typedoc """
  A selectable printer device.

    * `:id` — a stable string used as the `<select>` option value and the
      `@selected_device` assign (`"sim"` for the simulator, the port name for a
      real port).
    * `:label` — the human-readable name shown in the dropdown.
    * `:kind` — `:sim` (the simulator) or `:real` (a serial port).
    * `:port` — the serial port path for a real device, `nil` for the simulator.
  """
  @type t :: %{
          id: String.t(),
          label: String.t(),
          kind: :sim | :real,
          port: String.t() | nil
        }

  @sim_id "sim"

  @doc "The stable id of the always-available Simulator device."
  @spec sim_id() :: String.t()
  def sim_id, do: @sim_id

  @doc """
  List the connectable devices: the Simulator first, then every detected serial
  port (label = port name + description when the enumeration provides one).

  Always returns at least the Simulator. Safe to call repeatedly (the refresh
  button re-enumerates), and never raises if `Circuits.UART` is missing.
  """
  @spec list() :: [t()]
  def list do
    [simulator() | real_ports()]
  end

  @doc "The Simulator device value (always available, no hardware)."
  @spec simulator() :: t()
  def simulator do
    %{id: @sim_id, label: "Simulator (no hardware)", kind: :sim, port: nil}
  end

  @doc """
  Look a device up by its `:id` in a given device list, falling back to the
  Simulator when the id is unknown (e.g. a port was unplugged since it was
  selected). Never returns `nil`.
  """
  @spec find(String.t(), [t()]) :: t()
  def find(id, devices) do
    Enum.find(devices, simulator(), &(&1.id == id))
  end

  @doc """
  The default device for a configured `BlauDrill.Printer` backend, optionally
  honouring a configured serial `port`. Used at mount to pre-select the card to
  match what dev/prod is wired to (`:sim` in dev → Simulator).

    * `:sim` / `:fake` / `:none` → the Simulator (the hardware-free default).
    * `:real` → a real device for `port` (defaults to the configured/standard
      port name when none is given).
  """
  @spec default_device(atom(), String.t() | nil) :: t()
  def default_device(backend, port \\ nil)

  def default_device(:real, port) when is_binary(port) do
    %{id: port, label: port, kind: :real, port: port}
  end

  def default_device(:real, _port) do
    %{id: "ttyUSB0", label: "ttyUSB0", kind: :real, port: "ttyUSB0"}
  end

  def default_device(_backend, _port), do: simulator()

  @doc """
  The `BlauDrill.Printer.connect/1` opts that open `device`:

    * a `:sim` device → `[backend: :sim]`
    * a `:real` device → `[backend: :real, port: device.port]`
  """
  @spec connect_opts(t()) :: keyword()
  def connect_opts(%{kind: :sim}), do: [backend: :sim]
  def connect_opts(%{kind: :real, port: port}), do: [backend: :real, port: port]

  # ── port enumeration ────────────────────────────────────────────────────────

  # Best-effort: Circuits.UART.enumerate/0 returns %{port => info}; if the NIF
  # isn't available (or it errors) we degrade to "no real ports" so the operator
  # is still offered the Simulator. Mirrors SettingsLive.available_ports/0.
  defp real_ports do
    if Code.ensure_loaded?(Circuits.UART) and function_exported?(Circuits.UART, :enumerate, 0) do
      try do
        Circuits.UART.enumerate()
        |> Enum.sort_by(fn {port, _info} -> port end)
        |> Enum.map(&port_device/1)
      rescue
        _ -> []
      catch
        _, _ -> []
      end
    else
      []
    end
  end

  defp port_device({port, info}) do
    %{id: port, label: port_label(port, info), kind: :real, port: port}
  end

  # Label a real port with its name plus a description when the enumeration
  # carries one (e.g. "ttyUSB0 — USB Serial"), else just the port name.
  defp port_label(port, info) when is_map(info) do
    case description(info) do
      nil -> port
      desc -> "#{port} — #{desc}"
    end
  end

  defp port_label(port, _info), do: port

  defp description(info) do
    info[:description] || info["description"] || info[:manufacturer] || info["manufacturer"]
  end
end
