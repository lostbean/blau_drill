defmodule BlauDrill.PrinterConnection.UART.Sim do
  @moduledoc """
  A **dev** `BlauDrill.PrinterConnection.UART` simulator — the moral twin of the
  test-only `BlauDrill.PrinterConnection.UART.Fake`, but compiled into the
  `:dev` build so the operator UI can be exercised end-to-end with **no
  hardware** plugged in.

  It is the "other end of the wire": when the owning `PrinterConnection` statem
  writes a line, this `GenServer` records it and synthesises the inbound Marlin
  reply (`{:circuits_uart, port, line}` — the same shape `Circuits.UART` uses in
  active mode), so:

    * an `M114` write is answered with a live position line followed by `ok`;
    * any other write is answered with a bare `ok` (the streaming handshake).

  Unlike the test fake, this sim keeps a **simulated head position** and updates
  it from the relative `G0`/`G1` jog moves it sees, so `where/1` (M114) reflects
  the jogs the operator makes — that is what drives the live crosshair in the
  alignment canvas without a real printer.

  ## Incremental acks (so dev progress animates)

  The `ok` for a streamed line is scheduled `ack_delay_ms` (default 10 ms in dev)
  in the future via `Process.send_after`, rather than replied synchronously. A
  400-line program therefore emits ~400 acks spread over time, so the drilling
  progress ring genuinely fills in real time instead of jumping to done. Set
  `ack_delay_ms: 0` to ack on the next message turn with no wall-clock delay
  (still one-in-flight, just instant) — the test fake uses 0 for determinism.

  This is a dev affordance only. It moves nothing physical and is never wired in
  `:prod` (prod uses `BlauDrill.PrinterConnection.UART.Circuits` against the
  configured serial port). It does NOT auto-enable motion: it still sits behind
  the `PrinterConnection` energize-before-jog gate exactly like the real port.
  """
  use GenServer

  @behaviour BlauDrill.PrinterConnection.UART

  # ── lifecycle ──────────────────────────────────────────────────────────────

  @doc "Start the simulator handle."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Convenience: start a handle, mirroring `UART.Circuits.start_handle/0`."
  def start_handle(opts \\ []), do: start_link(opts)

  # ── UART behaviour (called by PrinterConnection) ────────────────────────────

  @impl BlauDrill.PrinterConnection.UART
  def open(pid, port, _opts), do: GenServer.call(pid, {:open, self(), port})

  @impl BlauDrill.PrinterConnection.UART
  def configure(pid, opts), do: GenServer.call(pid, {:configure, opts})

  @impl BlauDrill.PrinterConnection.UART
  def write(pid, data), do: GenServer.call(pid, {:write, data})

  @impl BlauDrill.PrinterConnection.UART
  def close(pid), do: GenServer.call(pid, :close)

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       owner: nil,
       port: nil,
       x: 0.0,
       y: 0.0,
       z: 0.0,
       abs: true,
       # Per-line ack delay (ms) for streamed lines, so dev progress animates.
       ack_delay_ms: Keyword.get(opts, :ack_delay_ms, 10)
     }}
  end

  @impl GenServer
  def handle_call({:open, owner, port}, _from, state),
    do: {:reply, :ok, %{state | owner: owner, port: port}}

  def handle_call({:configure, _opts}, _from, state), do: {:reply, :ok, state}
  def handle_call(:close, _from, state), do: {:reply, :ok, state}

  def handle_call({:write, data}, _from, state) do
    line = data |> to_string() |> String.trim()
    state = apply_move(state, line)
    state = synth_reply(state, line)
    {:reply, :ok, state}
  end

  # ── simulated motion ───────────────────────────────────────────────────────

  # Track G90/G91 mode and integrate jog/move lines so M114 reflects them.
  # Streamed/jog lines are line-numbered and checksummed (`N<n> G0 X..*<cs>`), so
  # we match the G-word anywhere in the (de-framed) line rather than at the start.
  defp apply_move(state, line) do
    cond do
      contains_word?(line, "G91") -> %{state | abs: false}
      contains_word?(line, "G90") -> %{state | abs: true}
      contains_word?(line, "G0") or contains_word?(line, "G1") -> integrate(state, line)
      true -> state
    end
  end

  # Whether the gcode word appears as a token (so "G0"/"G1" don't match "G04" or
  # "G90"; "G91" doesn't match "G91.1"). A token ends at whitespace, the checksum
  # `*`, end-of-line, or an axis letter — but never a `.` or another digit.
  defp contains_word?(line, word) do
    Regex.match?(~r/(?:^|\s)#{Regex.escape(word)}(?![.\d])/, line)
  end

  defp integrate(state, line) do
    dx = axis_value(line, "X")
    dy = axis_value(line, "Y")
    dz = axis_value(line, "Z")

    if state.abs do
      %{state | x: dx || state.x, y: dy || state.y, z: dz || state.z}
    else
      %{state | x: state.x + (dx || 0.0), y: state.y + (dy || 0.0), z: state.z + (dz || 0.0)}
    end
  end

  defp axis_value(line, axis) do
    case Regex.run(~r/#{axis}(-?\d+(?:\.\d+)?)/, line) do
      [_, v] -> elem(Float.parse(v), 0)
      _ -> nil
    end
  end

  # Deliver a scheduled streaming ack to the owner. The statem advances the
  # handshake exactly as for an immediate ack — the delay only spaces the acks
  # out in time so the UI animates; one line is still in flight at a time.
  @impl GenServer
  def handle_info({:deliver_ack, line}, state) do
    send_line(state, line)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── reply synthesis ─────────────────────────────────────────────────────────

  # M114 (position) is answered immediately — `where/1` blocks on it and is not a
  # stream line. A streamed line's `ok` is scheduled `ack_delay_ms` ahead so a
  # long program acks incrementally; with delay 0 it fires on the next turn.
  defp synth_reply(state, line) do
    if String.contains?(line, "M114") do
      send_line(state, position_line(state))
      send_line(state, "ok")
    else
      schedule_ack(state, "ok")
    end

    state
  end

  defp schedule_ack(%{ack_delay_ms: delay} = state, line) when delay > 0 do
    Process.send_after(self(), {:deliver_ack, line}, delay)
    state
  end

  defp schedule_ack(state, line) do
    send(self(), {:deliver_ack, line})
    state
  end

  defp position_line(%{x: x, y: y, z: z}) do
    "X:#{f(x)} Y:#{f(y)} Z:#{f(z)} E:0.00 Count X:0 Y:0 Z:0"
  end

  defp f(v), do: :erlang.float_to_binary(v * 1.0, decimals: 2)

  defp send_line(%{owner: owner, port: port}, line) when is_pid(owner) do
    send(owner, {:circuits_uart, port, line})
  end

  defp send_line(_state, _line), do: :ok
end
