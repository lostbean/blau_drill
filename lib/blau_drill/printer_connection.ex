defmodule BlauDrill.PrinterConnection do
  @moduledoc """
  The system's single stateful identity: a supervised `:gen_statem` owning the
  serial port to a Marlin controller and hiding the entire wire protocol behind
  four verbs.

  Per ADR-0007 this is raw `:gen_statem` in callback mode
  `[:state_functions, :state_enter]` — *not* a plain `GenServer`. Each mode's
  logic is co-located in its own state callback (`idle/3`, `jogging/3`,
  `streaming/3`, `faulted/3`), and the energize+settle step is the **entry
  action** of `:jogging`, so it cannot be skipped.

  ## States

      idle ──energize──▶ jogging ──release──▶ idle
      idle/jogging ──stream──▶ streaming ──done──▶ idle
      idle/jogging/streaming ──halt | serial-loss──▶ faulted ──reconnect──▶ idle

  ## Invariants (structural, per CONTEXT.md / ADR-0006)

    1. **Energize-before-jog.** `jog/3` in `:idle` returns `{:error, :idle}` and
       writes nothing — `jog` is simply not actioned outside `:jogging`. The only
       path to `:jogging` runs the energize (`M17`) + settle entry action first,
       designing out the 1–2 mm de-energized stepper snap.
    2. **Faulted is loud and reachable from any active state.** `halt/1` (M112)
       and a serial-loss message both drive to `:faulted`, aborting any stream.
    3. **Streaming uses the Marlin `ok`-handshake** with optional line
       numbering + checksum and `Resend: N` handling — one line in flight at a
       time.

  ## Marlin protocol

    * `M17` energize steppers, `M18`/`M84` release, `M112` emergency abort.
    * `M114` → `X:.. Y:.. Z:.. ... ok`; `where/1` parses the X/Y/Z floats.
    * Streaming: send a line, await `ok`; a `Resend: N` (or `Error`) re-sends the
      current line instead of advancing.
  """
  @behaviour :gen_statem

  require Logger

  # ── Data carried across states ────────────────────────────────────────────
  #
  # uart        — the UART behaviour module (real Circuits or test Fake).
  # handle      — opaque port handle the UART module operates on.
  # port        — the port name (string), echoed back in inbound messages.
  # settle_ms   — energize settle delay (state-timeout); ~0 in tests.
  # line_no     — Marlin line counter for checksummed streaming.
  # pending     — per-state work-in-flight (a `where` caller, or a stream job).
  # progress_topic — Phoenix.PubSub topic for per-line stream progress events, or
  #                  nil (no broadcast). Set per stream via `stream/3` opts so
  #                  multiple sessions never cross-talk.
  defstruct uart: nil,
            handle: nil,
            port: nil,
            settle_ms: 250,
            line_no: 0,
            pending: nil,
            progress_topic: nil

  @type axis :: :x | :y | :z
  @type t :: %__MODULE__{}

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Start the statem. Options:

    * `:uart` — the UART behaviour module (default
      `BlauDrill.PrinterConnection.UART.Circuits`).
    * `:uart_pid` / `:handle` — an existing handle to use (tests pass the fake).
    * `:port` — serial port name (e.g. `"ttyUSB0"`).
    * `:settle_ms` — energize settle delay in ms (default 250; 0 in tests).
    * `:name` — optional registered name.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
    else
      :gen_statem.start_link(__MODULE__, opts, [])
    end
  end

  @doc "Child spec so the statem can sit in a supervision tree."
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @doc "Current mode: `:idle | :jogging | :streaming | :faulted`."
  @spec state(:gen_statem.server_ref()) :: atom()
  def state(conn), do: :gen_statem.call(conn, :state)

  @doc "Energize steppers and settle: `:idle -> :jogging`."
  @spec energize(:gen_statem.server_ref()) :: :ok
  def energize(conn), do: :gen_statem.call(conn, :energize)

  @doc "Release steppers: `:jogging -> :idle`."
  @spec release(:gen_statem.server_ref()) :: :ok
  def release(conn), do: :gen_statem.call(conn, :release)

  @doc """
  Relative jog of `axis` by `mm`. Only valid in `:jogging`; in `:idle` returns
  `{:error, :idle}` and writes nothing (the energize-before-jog invariant).
  """
  @spec jog(:gen_statem.server_ref(), axis(), number()) :: :ok | {:error, :idle}
  def jog(conn, axis, mm), do: :gen_statem.call(conn, {:jog, axis, mm})

  @doc "Query live position via `M114`; parses `{:ok, {x, y, z}}`."
  @spec where(:gen_statem.server_ref()) :: {:ok, {float(), float(), float()}} | {:error, term()}
  def where(conn), do: :gen_statem.call(conn, :where)

  @doc """
  Stream a G-code program (a list of lines) with the `ok`-handshake. Returns
  `:ok` when the program completes (or when an abort/fault interrupts it).

  Options:

    * `:progress_topic` — a `Phoenix.PubSub` topic (string) on `BlauDrill.PubSub`
      to broadcast a `{:stream_progress, %{sent, total, line}}` event on, once per
      line *confirmed* by its `ok`. Defaults to `nil` (no broadcast). The topic is
      caller-supplied per stream so concurrent sessions never cross-talk — the
      statem stays generic and knows nothing about "holes".
  """
  @spec stream(:gen_statem.server_ref(), [String.t()], keyword()) :: :ok
  def stream(conn, program, opts \\ []),
    do: :gen_statem.call(conn, {:stream, program, opts}, 30_000)

  @doc "Emergency abort (`M112`): any active state -> `:faulted`."
  @spec halt(:gen_statem.server_ref()) :: :ok
  def halt(conn), do: :gen_statem.call(conn, :halt)

  @doc "Recover after a fault: `:faulted -> :idle`."
  @spec reconnect(:gen_statem.server_ref()) :: :ok
  def reconnect(conn), do: :gen_statem.call(conn, :reconnect)

  # ── :gen_statem callbacks ──────────────────────────────────────────────────

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  def init(opts) do
    uart = Keyword.get(opts, :uart, BlauDrill.PrinterConnection.UART.Circuits)
    port = Keyword.get(opts, :port, "ttyUSB0")
    settle_ms = Keyword.get(opts, :settle_ms, 250)
    handle = Keyword.get(opts, :uart_pid) || Keyword.get(opts, :handle)

    data = %__MODULE__{uart: uart, handle: handle, port: port, settle_ms: settle_ms}

    case open_port(data) do
      {:ok, data} ->
        {:ok, :idle, data}

      # No serial port present (e.g. boot without hardware): start anyway in a
      # not-connected fault state. The supervisor stays up; the operator can
      # `reconnect/1` once a port appears.
      {:error, reason} ->
        Logger.warning("PrinterConnection: serial port unavailable (#{inspect(reason)})")
        {:ok, :faulted, %{data | handle: nil}}
    end
  end

  # Open the port via the configured UART module. For the real adapter we may
  # need to start the backing Circuits.UART handle first.
  defp open_port(%__MODULE__{handle: nil, uart: BlauDrill.PrinterConnection.UART.Circuits} = data) do
    with {:ok, handle} <- BlauDrill.PrinterConnection.UART.Circuits.start_handle(),
         :ok <- data.uart.open(handle, data.port, []) do
      {:ok, %{data | handle: handle}}
    end
  end

  defp open_port(%__MODULE__{handle: nil} = _data), do: {:error, :no_handle}

  defp open_port(%__MODULE__{handle: handle} = data) when is_pid(handle) do
    case data.uart.open(handle, data.port, []) do
      :ok -> {:ok, data}
      {:ok, _} -> {:ok, data}
      other -> other
    end
  end

  @impl :gen_statem
  def terminate(_reason, _state, %__MODULE__{handle: handle, uart: uart})
      when is_pid(handle) and not is_nil(uart) do
    try do
      uart.close(handle)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state, _data), do: :ok

  # ── idle/3 ──────────────────────────────────────────────────────────────────

  def idle(:enter, _old, data), do: {:keep_state, %{data | pending: nil}}

  def idle({:call, from}, :state, _data), do: {:keep_state_and_data, [{:reply, from, :idle}]}

  def idle({:call, from}, :energize, data) do
    # Transition into :jogging; the energize+settle work is the entry action of
    # :jogging (see jogging/3 :enter), so it cannot be bypassed.
    {:next_state, :jogging, data, [{:reply, from, :ok}]}
  end

  # The energize-before-jog snap: jog from :idle is rejected and writes nothing.
  def idle({:call, from}, {:jog, _axis, _mm}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :idle}}]}
  end

  def idle({:call, from}, :where, data) do
    do_where(from, data, :keep_state)
  end

  def idle({:call, from}, {:stream, program, opts}, data) do
    start_stream(from, program, opts, data)
  end

  def idle({:call, from}, :halt, data) do
    to_faulted(from, data)
  end

  def idle(:info, msg, data), do: handle_serial_info(msg, data, :idle)

  def idle(event_type, event, data), do: passthrough(event_type, event, data)

  # ── jogging/3 ────────────────────────────────────────────────────────────────

  # Entry action: energize + settle. This is the ONLY way into :jogging, so a
  # de-energized jog is structurally impossible.
  def jogging(:enter, _old, data) do
    data = write_line(data, "M17")
    {:keep_state, data, [{:state_timeout, data.settle_ms, :settled}]}
  end

  def jogging(:state_timeout, :settled, _data), do: :keep_state_and_data

  def jogging({:call, from}, :state, _data),
    do: {:keep_state_and_data, [{:reply, from, :jogging}]}

  def jogging({:call, from}, :release, data) do
    data = write_line(data, "M18")
    {:next_state, :idle, data, [{:reply, from, :ok}]}
  end

  def jogging({:call, from}, {:jog, axis, mm}, data) do
    # Relative move: switch to relative positioning, move, restore absolute.
    a = axis |> Atom.to_string() |> String.upcase()
    data = write_line(data, "G91")
    data = write_line(data, "G0 #{a}#{format_mm(mm)}")
    data = write_line(data, "G90")
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  def jogging({:call, from}, :where, data) do
    do_where(from, data, :keep_state)
  end

  def jogging({:call, from}, {:stream, program, opts}, data) do
    start_stream(from, program, opts, data)
  end

  def jogging({:call, from}, :halt, data) do
    to_faulted(from, data)
  end

  def jogging(:info, msg, data), do: handle_serial_info(msg, data, :jogging)

  def jogging(event_type, event, data), do: passthrough(event_type, event, data)

  # ── streaming/3 ──────────────────────────────────────────────────────────────

  # Entry action: send the first line of the program. `pending` holds the job.
  def streaming(:enter, _old, %__MODULE__{pending: {:stream, _from, _lines, _idx}} = data) do
    {:keep_state, send_current_line(data)}
  end

  def streaming({:call, from}, :state, _data),
    do: {:keep_state_and_data, [{:reply, from, :streaming}]}

  def streaming({:call, from}, :halt, data) do
    # Abort mid-stream: reply to the blocked stream caller (the abort completed),
    # then fault.
    data = reply_to_stream_caller(data, :ok)
    to_faulted(from, data)
  end

  # Inbound serial during a stream drives the handshake.
  def streaming(:info, {:circuits_uart, _port, {:error, reason}}, data) do
    # Serial loss mid-stream: abort the stream and fault loudly.
    data = reply_to_stream_caller(data, :ok)
    Logger.error("PrinterConnection: serial loss during stream (#{inspect(reason)})")
    {:next_state, :faulted, data}
  end

  def streaming(:info, {:circuits_uart, _port, line}, data) when is_binary(line) do
    handle_stream_reply(String.trim(line), data)
  end

  def streaming(:info, _other, _data), do: :keep_state_and_data

  # Reject a second stream / jog while streaming.
  def streaming({:call, from}, {:stream, _program, _opts}, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :streaming}}]}

  def streaming({:call, from}, {:jog, _axis, _mm}, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :streaming}}]}

  def streaming(event_type, event, data), do: passthrough(event_type, event, data)

  # ── faulted/3 ────────────────────────────────────────────────────────────────

  def faulted(:enter, _old, data), do: {:keep_state, %{data | pending: nil}}

  def faulted({:call, from}, :state, _data),
    do: {:keep_state_and_data, [{:reply, from, :faulted}]}

  def faulted({:call, from}, :reconnect, data) do
    # Recover: re-open the port if we have a handle, then return to :idle.
    case reopen(data) do
      {:ok, data} -> {:next_state, :idle, data, [{:reply, from, :ok}]}
      {:error, _reason} -> {:keep_state_and_data, [{:reply, from, {:error, :no_port}}]}
    end
  end

  # Halt while already faulted is a no-op success.
  def faulted({:call, from}, :halt, _data), do: {:keep_state_and_data, [{:reply, from, :ok}]}

  # Motion/stream commands are rejected while faulted.
  def faulted({:call, from}, {:jog, _a, _m}, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :faulted}}]}

  def faulted({:call, from}, :where, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :faulted}}]}

  def faulted({:call, from}, {:stream, _p}, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :faulted}}]}

  def faulted({:call, from}, :energize, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :faulted}}]}

  def faulted(:info, _msg, _data), do: :keep_state_and_data

  def faulted(event_type, event, data), do: passthrough(event_type, event, data)

  # ── Shared helpers ───────────────────────────────────────────────────────────

  # `do_where`: send M114 and stash the caller; the position line is matched in
  # handle_serial_info. `keep` is the state-keeping tag for the current state.
  defp do_where(from, data, _keep) do
    data = write_line(data, "M114")
    {:keep_state, %{data | pending: {:where, from}}}
  end

  defp start_stream(from, program, opts, data) do
    topic = Keyword.get(opts, :progress_topic)

    case Enum.map(program, &to_string/1) do
      [] ->
        # Empty program: nothing to stream, stay put and reply immediately.
        {:keep_state_and_data, [{:reply, from, :ok}]}

      lines ->
        {:next_state, :streaming,
         %{data | pending: {:stream, from, lines, 0}, progress_topic: topic}}
    end
  end

  # Send the line at the current index. Only ever called with a valid index —
  # completion is detected in handle_stream_reply before this is reached.
  defp send_current_line(%__MODULE__{pending: {:stream, _from, lines, idx}} = data) do
    write_line(data, Enum.at(lines, idx))
  end

  # Handle a Marlin reply line while streaming.
  #
  # The `ok` confirms the line at `idx`; `next = idx + 1` is the count of lines
  # CONFIRMED so far. We advance the handshake FIRST (the transition decision is
  # made purely on the index, exactly as before), and only THEN broadcast a
  # progress event for the just-confirmed line — a side effect that cannot alter
  # ok/resend semantics or the one-line-in-flight invariant.
  defp handle_stream_reply(
         "ok" <> _rest,
         %__MODULE__{pending: {:stream, from, lines, idx}} = data
       ) do
    next = idx + 1
    total = length(lines)
    confirmed_line = Enum.at(lines, idx)

    broadcast_progress(data, %{sent: next, total: total, line: confirmed_line})

    if next >= total do
      # All lines accepted: reply and go idle.
      :gen_statem.reply(from, :ok)
      {:next_state, :idle, %{data | pending: nil, progress_topic: nil}}
    else
      data = %{data | pending: {:stream, from, lines, next}}
      {:keep_state, send_current_line(data)}
    end
  end

  defp handle_stream_reply("Resend:" <> _rest, %__MODULE__{pending: {:stream, _f, _l, _i}} = data) do
    # NAK: re-send the current line without advancing the index.
    {:keep_state, send_current_line(data)}
  end

  defp handle_stream_reply("Error" <> _rest, %__MODULE__{pending: {:stream, _f, _l, _i}} = data) do
    # Treat a recoverable error like a resend of the current line.
    {:keep_state, send_current_line(data)}
  end

  # Position lines / busy / echo during streaming are informational; ignore.
  defp handle_stream_reply(_line, _data), do: :keep_state_and_data

  defp reply_to_stream_caller(%__MODULE__{pending: {:stream, from, _l, _i}} = data, reply) do
    :gen_statem.reply(from, reply)
    %{data | pending: nil, progress_topic: nil}
  end

  defp reply_to_stream_caller(data, _reply), do: data

  # Broadcast a per-line stream-progress event on the caller-supplied topic, if
  # any. A pure side effect: it never touches `data` or the transition, so the
  # ok/resend handshake is unaffected whether or not a topic is set.
  defp broadcast_progress(%__MODULE__{progress_topic: nil}, _payload), do: :ok

  defp broadcast_progress(%__MODULE__{progress_topic: topic}, payload)
       when is_binary(topic) do
    Phoenix.PubSub.broadcast(BlauDrill.PubSub, topic, {:stream_progress, payload})
  end

  defp to_faulted(from, data) do
    data = write_line(data, "M112")
    {:next_state, :faulted, data, [{:reply, from, :ok}]}
  end

  # Inbound serial in idle/jogging: a position line completes a pending `where`;
  # an error means serial loss -> fault.
  defp handle_serial_info({:circuits_uart, _port, {:error, reason}}, data, _state) do
    Logger.error("PrinterConnection: serial loss (#{inspect(reason)})")
    {:next_state, :faulted, %{data | pending: nil}}
  end

  defp handle_serial_info({:circuits_uart, _port, line}, data, _state) when is_binary(line) do
    case data.pending do
      {:where, from} ->
        case parse_m114(line) do
          {:ok, xyz} ->
            :gen_statem.reply(from, {:ok, xyz})
            {:keep_state, %{data | pending: nil}}

          :no_match ->
            # Probably the trailing `ok`; keep waiting for the position line.
            :keep_state_and_data
        end

      _ ->
        :keep_state_and_data
    end
  end

  defp handle_serial_info(_msg, _data, _state), do: :keep_state_and_data

  defp passthrough({:call, from}, _event, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :unsupported}}]}

  defp passthrough(_type, _event, _data), do: :keep_state_and_data

  # Re-open the port on reconnect.
  defp reopen(%__MODULE__{handle: handle, uart: uart, port: port} = data)
       when is_pid(handle) and not is_nil(uart) do
    case uart.open(handle, port, []) do
      :ok -> {:ok, %{data | line_no: 0}}
      {:ok, _} -> {:ok, %{data | line_no: 0}}
      other -> other
    end
  end

  defp reopen(%__MODULE__{} = data), do: {:ok, %{data | line_no: 0}}

  # ── Wire helpers ─────────────────────────────────────────────────────────────

  # Write a checksummed, line-numbered gcode line and bump the counter. M112 and
  # M114 are sent raw (no numbering) like a real host's out-of-band commands.
  defp write_line(data, raw) do
    {payload, data} = framed(data, raw)

    if is_pid(data.handle) and not is_nil(data.uart) do
      _ = data.uart.write(data.handle, payload <> "\n")
    end

    data
  end

  # Out-of-band commands bypass line numbering; movement/program lines get
  # `N<n> <line>*<checksum>`.
  defp framed(data, raw) do
    if oob?(raw) do
      {raw, data}
    else
      n = data.line_no + 1
      body = "N#{n} #{raw}"
      {"#{body}*#{checksum(body)}", %{data | line_no: n}}
    end
  end

  defp oob?(raw), do: String.starts_with?(raw, "M112") or String.starts_with?(raw, "M114")

  # Marlin XOR checksum over the `N<n> <line>` string.
  defp checksum(body) do
    body
    |> :binary.bin_to_list()
    |> Enum.reduce(0, &Bitwise.bxor(&1, &2))
  end

  defp format_mm(mm) when is_float(mm), do: :erlang.float_to_binary(mm, decimals: 3)
  defp format_mm(mm) when is_integer(mm), do: Integer.to_string(mm)

  # Parse `X:.. Y:.. Z:..` floats from an M114 reply. Returns :no_match if the
  # line is not a position line (e.g. a bare `ok`).
  defp parse_m114(line) do
    with [_, xs] <- Regex.run(~r/X:(-?\d+(?:\.\d+)?)/, line),
         [_, ys] <- Regex.run(~r/Y:(-?\d+(?:\.\d+)?)/, line),
         [_, zs] <- Regex.run(~r/Z:(-?\d+(?:\.\d+)?)/, line) do
      {:ok, {to_float(xs), to_float(ys), to_float(zs)}}
    else
      _ -> :no_match
    end
  end

  defp to_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
