defmodule BlauDrill.PrinterConnection.UART.Circuits do
  @moduledoc """
  Real `BlauDrill.PrinterConnection.UART` adapter backed by `Circuits.UART`.

  Thin pass-through: `Circuits.UART` already delivers inbound data to the process
  that called `open/3` (its `controlling_process`) as `{:circuits_uart, port,
  data}` active-mode messages, which is exactly the contract the behaviour
  promises. The `handle` is the `Circuits.UART` GenServer pid; the owning
  `PrinterConnection` statem starts it and calls `open/3` itself so it becomes
  the controlling process.

  Not unit-tested against hardware — `PrinterConnection` is exercised via the
  fake adapter. This module is the live wire it swaps in for at runtime.
  """

  @behaviour BlauDrill.PrinterConnection.UART

  @default_open_opts [
    speed: 115_200,
    active: true,
    framing: {Circuits.UART.Framing.Line, separator: "\n"}
  ]

  @impl BlauDrill.PrinterConnection.UART
  def open(handle, port, opts) do
    Circuits.UART.open(handle, port, Keyword.merge(@default_open_opts, opts))
  end

  @impl BlauDrill.PrinterConnection.UART
  def configure(handle, opts) do
    Circuits.UART.configure(handle, opts)
  end

  @impl BlauDrill.PrinterConnection.UART
  def write(handle, data) do
    Circuits.UART.write(handle, data)
  end

  @impl BlauDrill.PrinterConnection.UART
  def close(handle) do
    Circuits.UART.close(handle)
  end

  @doc """
  Start the backing `Circuits.UART` GenServer. The statem calls this to obtain
  the handle it then passes to `open/3` (so the statem is the controlling
  process that receives active-mode messages).
  """
  def start_handle do
    Circuits.UART.start_link()
  end
end
