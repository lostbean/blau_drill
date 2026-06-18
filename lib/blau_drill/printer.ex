defmodule BlauDrill.Printer do
  @moduledoc """
  The UI-facing **wiring** around `BlauDrill.PrinterConnection`.

  `PrinterConnection` is the safety-critical `:gen_statem` that owns the serial
  port; it is started opt-in (default disabled) so a fresh checkout, `mix test`
  and `mix phx.server` all boot with no hardware. This module is the thin seam
  the LiveView uses to obtain a connection and talk to it, while letting dev/test
  run end-to-end against a **simulated** wire instead of a real printer.

  ## Backends (config `:blau_drill, BlauDrill.Printer`)

    * `backend: :sim` (dev default) — start a fresh `PrinterConnection` per
      session backed by `BlauDrill.PrinterConnection.UART.Sim`, an in-memory
      fake that tracks a simulated head position so the live crosshair moves with
      the operator's jogs. No hardware.
    * `backend: :fake, uart: Module, handle: pid` (tests) — start a
      `PrinterConnection` against a caller-supplied fake UART + handle (the test
      passes `BlauDrill.PrinterConnection.UART.Fake`). Lets LiveView tests drive
      the gate behaviour with no hardware.
    * `backend: :real, port: "ttyUSB0"` (prod) — start a `PrinterConnection`
      against the real `Circuits.UART` adapter on the configured port. Motion is
      physical; it is still behind every `PrinterConnection` safety gate.
    * `backend: :none` — no connection (`connect/1` returns `{:error,
      :no_backend}`); the UI renders the connection card but cannot energize.

  None of this auto-enables motion: every path still routes through
  `PrinterConnection`'s energize-before-jog gate and `halt/1` abort. The
  connection is **per-session** — the LiveView starts one at mount and it dies
  with the LiveView process (it is linked), matching the "owns the port only for
  the session" non-goal.

  The verbs (`energize/1`, `release/1`, `jog/3`, `where/1`, `stream/2`,
  `halt/1`, `reconnect/1`, `state/1`) proxy straight through to
  `PrinterConnection`, so the LiveView never needs to know the backend.
  """

  alias BlauDrill.PrinterConnection

  @type conn :: PrinterConnection.t() | pid() | nil

  @doc """
  Start a per-session `PrinterConnection` for the configured backend.

  Returns `{:ok, conn}` (a `:gen_statem` ref to use with the verbs below) or
  `{:error, reason}`. `opts` may override config (`:backend`, `:uart`, `:handle`,
  `:port`, `:settle_ms`) — tests pass their fake handle here.
  """
  @spec connect(keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(opts \\ []) do
    cfg = Keyword.merge(config(), opts)

    case Keyword.get(cfg, :backend, :none) do
      :none ->
        {:error, :no_backend}

      :sim ->
        start_sim(cfg)

      :fake ->
        start_fake(cfg)

      :real ->
        start_real(cfg)
    end
  end

  @doc "The configured backend atom, for the UI to label the connection card."
  @spec backend() :: :sim | :fake | :real | :none
  def backend, do: Keyword.get(config(), :backend, :none)

  @doc "Whether a backend is wired (the Connect button does anything)."
  @spec connectable?() :: boolean()
  def connectable?, do: backend() != :none

  @doc """
  Whether `connect/1` with these opts would have a real backend to start —
  either the merged config names a non-`:none` backend, or the caller passed a
  `:backend` override (e.g. a test passing `:fake`).
  """
  @spec connectable_with?(keyword()) :: boolean()
  def connectable_with?(opts) do
    Keyword.get(Keyword.merge(config(), opts), :backend, :none) != :none
  end

  # ── verbs (pass-through) ────────────────────────────────────────────────────

  @doc "Current connection mode: `:idle | :jogging | :streaming | :faulted`."
  def state(nil), do: :disconnected
  def state(conn), do: safe(fn -> PrinterConnection.state(conn) end, :disconnected)

  @doc "Energize steppers: `:idle -> :jogging` (the only path to jogging)."
  def energize(nil), do: {:error, :disconnected}
  def energize(conn), do: safe(fn -> PrinterConnection.energize(conn) end)

  @doc "Release steppers: `:jogging -> :idle`."
  def release(nil), do: {:error, :disconnected}
  def release(conn), do: safe(fn -> PrinterConnection.release(conn) end)

  @doc "Relative jog (only legal in `:jogging`; `{:error, :idle}` otherwise)."
  def jog(nil, _axis, _mm), do: {:error, :disconnected}
  def jog(conn, axis, mm), do: safe(fn -> PrinterConnection.jog(conn, axis, mm) end)

  @doc "Live position via M114: `{:ok, {x, y, z}}`."
  def where(nil), do: {:error, :disconnected}
  def where(conn), do: safe(fn -> PrinterConnection.where(conn) end)

  @doc """
  Stream a `GcodeProgram` (or its lines) over the handshake.

  `opts` are forwarded to `PrinterConnection.stream/3` — notably
  `:progress_topic`, the per-session PubSub topic the LiveView subscribes to for
  live per-line progress.
  """
  def stream(conn, program, opts \\ [])
  def stream(nil, _program, _opts), do: {:error, :disconnected}

  def stream(conn, %BlauDrill.GcodeProgram{lines: lines}, opts),
    do: safe(fn -> PrinterConnection.stream(conn, lines, opts) end)

  def stream(conn, lines, opts) when is_list(lines),
    do: safe(fn -> PrinterConnection.stream(conn, lines, opts) end)

  @doc "Emergency abort (M112): any active state -> `:faulted`."
  def halt(nil), do: {:error, :disconnected}
  def halt(conn), do: safe(fn -> PrinterConnection.halt(conn) end)

  @doc "Recover after a fault: `:faulted -> :idle`."
  def reconnect(nil), do: {:error, :disconnected}
  def reconnect(conn), do: safe(fn -> PrinterConnection.reconnect(conn) end)

  # ── backends ────────────────────────────────────────────────────────────────

  defp start_sim(cfg) do
    settle_ms = Keyword.get(cfg, :settle_ms, 0)
    # Per-line ack delay (ms) for the sim wire, so dev streaming progress
    # animates incrementally. Defaults to the Sim's own default when unset.
    sim_opts =
      case Keyword.get(cfg, :ack_delay_ms) do
        nil -> []
        ms -> [ack_delay_ms: ms]
      end

    with {:ok, handle} <- BlauDrill.PrinterConnection.UART.Sim.start_handle(sim_opts) do
      PrinterConnection.start_link(
        uart: BlauDrill.PrinterConnection.UART.Sim,
        handle: handle,
        port: "sim",
        settle_ms: settle_ms
      )
    end
  end

  defp start_fake(cfg) do
    uart = Keyword.fetch!(cfg, :uart)
    handle = Keyword.fetch!(cfg, :handle)
    settle_ms = Keyword.get(cfg, :settle_ms, 0)

    PrinterConnection.start_link(
      uart: uart,
      handle: handle,
      port: Keyword.get(cfg, :port, "fake"),
      settle_ms: settle_ms
    )
  end

  defp start_real(cfg) do
    PrinterConnection.start_link(
      uart: BlauDrill.PrinterConnection.UART.Circuits,
      port: Keyword.get(cfg, :port, "ttyUSB0"),
      settle_ms: Keyword.get(cfg, :settle_ms, 250)
    )
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp config, do: Application.get_env(:blau_drill, __MODULE__, [])

  # A connection that has died (e.g. the session ending) must never crash the
  # LiveView; degrade to a typed error / a sentinel state instead.
  defp safe(fun, on_error \\ {:error, :disconnected}) do
    fun.()
  catch
    :exit, _ -> on_error
  end
end
