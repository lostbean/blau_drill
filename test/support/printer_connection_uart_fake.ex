defmodule BlauDrill.PrinterConnection.UART.Fake do
  @moduledoc """
  In-test double for the `BlauDrill.PrinterConnection.UART` behaviour. No
  hardware: a `GenServer` that records every write and replies to the owning
  `PrinterConnection` statem with simulated Marlin lines.

  ## How it injects replies

  The fake is the "other end of the wire". When the statem calls `write/2`, the
  fake records the payload and then synthesises an inbound Marlin reply, which it
  delivers to the owner as a `{:circuits_uart, port, line}` message (the same
  shape `Circuits.UART` uses in active mode). By default:

    * an `M114` write is answered with the configured `:m114_reply` position
      line followed by `ok`;
    * any other write is answered with a bare `ok` (the streaming handshake).

  Behaviours can be overridden per start to exercise edge cases:

    * `:resend_once_on_index` — on the Nth accepted write, reply `Resend: <n>`
      once instead of `ok`, then ack normally on the resend.
    * `:disconnect_after_index` — after the Nth accepted write, deliver a
      `{:circuits_uart, port, {:error, :eio}}` disconnect message instead of an
      ack, simulating serial loss.
    * `:m114_reply` — the position payload answered to `M114` (default a sane
      `X:0.00 Y:0.00 Z:0.00` line).

  Tests can also drive replies manually via `deliver/2`, and read the recorded
  writes via `writes/1`.
  """
  use GenServer

  @behaviour BlauDrill.PrinterConnection.UART

  # ── Test-facing API ──────────────────────────────────────────────────────

  @doc "Start the fake. See module doc for options."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Return the list of written payloads (oldest first)."
  def writes(pid), do: GenServer.call(pid, :writes)

  @doc "Manually deliver a raw line to the owner as an inbound serial message."
  def deliver(pid, line), do: GenServer.call(pid, {:deliver, line})

  # ── UART behaviour callbacks (called by PrinterConnection) ───────────────

  @impl BlauDrill.PrinterConnection.UART
  def open(pid, port, _opts) do
    GenServer.call(pid, {:open, self(), port})
  end

  @impl BlauDrill.PrinterConnection.UART
  def configure(pid, opts) do
    GenServer.call(pid, {:configure, opts})
  end

  @impl BlauDrill.PrinterConnection.UART
  def write(pid, data) do
    GenServer.call(pid, {:write, data})
  end

  @impl BlauDrill.PrinterConnection.UART
  def close(pid) do
    GenServer.call(pid, :close)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    state = %{
      owner: nil,
      port: nil,
      writes: [],
      # Number of writes accepted so far (drives index-based behaviours).
      count: 0,
      m114_reply: Keyword.get(opts, :m114_reply, "X:0.00 Y:0.00 Z:0.00 E:0.00 Count X:0 Y:0 Z:0"),
      resend_once_on_index: Keyword.get(opts, :resend_once_on_index),
      resend_fired: false,
      disconnect_after_index: Keyword.get(opts, :disconnect_after_index)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:open, owner, port}, _from, state) do
    {:reply, :ok, %{state | owner: owner, port: port}}
  end

  def handle_call({:configure, _opts}, _from, state), do: {:reply, :ok, state}

  def handle_call(:close, _from, state), do: {:reply, :ok, state}

  def handle_call(:writes, _from, state) do
    {:reply, Enum.reverse(state.writes), state}
  end

  def handle_call({:deliver, line}, _from, state) do
    send_line(state, line)
    {:reply, :ok, state}
  end

  def handle_call({:write, data}, _from, state) do
    state = %{state | writes: [data | state.writes], count: state.count + 1}
    state = synth_reply(state, data)
    {:reply, :ok, state}
  end

  # ── Reply synthesis ───────────────────────────────────────────────────────

  defp synth_reply(state, data) do
    cond do
      String.contains?(data, "M114") ->
        send_line(state, state.m114_reply)
        send_line(state, "ok")
        state

      disconnect_now?(state) ->
        send_disconnect(state)
        state

      resend_now?(state) ->
        # NAK this line once: ask Marlin to resend the current line number.
        send_line(state, "Resend: #{state.count}")
        %{state | resend_fired: true}

      true ->
        send_line(state, "ok")
        state
    end
  end

  defp disconnect_now?(%{disconnect_after_index: nil}), do: false
  defp disconnect_now?(%{disconnect_after_index: n, count: n}), do: true
  defp disconnect_now?(_), do: false

  defp resend_now?(%{resend_once_on_index: nil}), do: false
  defp resend_now?(%{resend_fired: true}), do: false
  defp resend_now?(%{resend_once_on_index: n, count: n}), do: true
  defp resend_now?(_), do: false

  defp send_line(%{owner: owner, port: port}, line) when is_pid(owner) do
    send(owner, {:circuits_uart, port, line})
  end

  defp send_disconnect(%{owner: owner, port: port}) when is_pid(owner) do
    send(owner, {:circuits_uart, port, {:error, :eio}})
  end
end
