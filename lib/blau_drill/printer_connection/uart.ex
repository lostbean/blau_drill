defmodule BlauDrill.PrinterConnection.UART do
  @moduledoc """
  The narrow serial-port surface `PrinterConnection` depends on.

  This behaviour wraps only the parts of `Circuits.UART` the statem uses, so the
  statem can be driven by a fake in tests (no hardware). The first argument of
  every callback is an opaque port handle (`Circuits.UART`'s GenServer pid, or
  the fake's pid).

  ## Inbound data contract

  Implementations MUST operate the port in **active mode** and deliver inbound
  serial data to the *owning process* (the process that called `open/3`) as

      {:circuits_uart, port_name, line}

  messages, where `line` is a binary for a received line, or `{:error, reason}`
  for a disconnect / read error. This matches `Circuits.UART`'s active-mode
  message shape, so the real adapter is a thin pass-through and the statem's
  `handle_event/4` for `:info` works against both.
  """

  @typedoc "Opaque serial handle (a pid for both the real and fake adapters)."
  @type handle :: pid()

  @doc """
  Open `port` (e.g. `"ttyUSB0"`) with `opts`. Called from the process that
  should receive inbound `{:circuits_uart, _, _}` messages.
  """
  @callback open(handle(), port :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Reconfigure the open port (framing, speed, active mode)."
  @callback configure(handle(), opts :: keyword()) :: :ok | {:error, term()}

  @doc "Write a single payload (the caller appends framing/newlines as needed)."
  @callback write(handle(), data :: iodata()) :: :ok | {:error, term()}

  @doc "Close the port."
  @callback close(handle()) :: :ok
end
