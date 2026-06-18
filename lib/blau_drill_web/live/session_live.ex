defmodule BlauDrillWeb.SessionLive do
  @moduledoc """
  The single orchestrating LiveView for the blau-drill operator flow.

  It holds the `%BlauDrill.Job{}` (the pure session FSM) in assigns and renders
  the stage UI that matches `job.state`, mapping:

      nil / :parsed     → Stage 1  Load & Connect
      :registering      → Stage 2  Physical Alignment
      :aligned          → Stage 2/3 boundary (Proceed to Dry-run)
      :alignment_rejected → Stage 2  (rejected — recapture)
      :dry_run          → Stage 3  Dry-run
      :drilling         → Stage 4  Active Drilling
      :done             → Stage 5  Completion
      :faulted          → fault banner over the relevant stage

  ## Safety gates surface as real gates

    * **No illegal transition is ever offered.** Every action button is enabled
      only when `BlauDrill.Job.can?/2` says the event is legal from the current
      state — so e.g. there is no "Start Drilling" button while merely `:aligned`
      (drilling must route through `:dry_run`).
    * **Motors-before-jog.** The jog d-pad is disabled unless the per-session
      `BlauDrill.PrinterConnection` is in `:jogging` (energized). "Enable Motors"
      calls `BlauDrill.Printer.energize/1`; jogging in `:idle` is rejected by the
      statem (`{:error, :idle}`) and surfaced as a flash.
    * **Abort / E-stop.** Present in every motion stage; calls
      `BlauDrill.Printer.halt/1` (M112) and drives the Job toward a safe state.

  The printer is a per-session connection started at mount via
  `BlauDrill.Printer.connect/1` — `:sim` in dev (no hardware), a caller-supplied
  fake in tests, the real serial adapter in prod. It is linked to the LiveView
  and dies with the session.
  """
  use BlauDrillWeb, :live_view

  require Logger

  alias BlauDrill.{Alignment, BoardModel, Config, Correspondence, GcodeProgram, Job, Printer}

  @stages [
    {"load", "Load"},
    {"align", "Align"},
    {"dryrun", "Dry-run"},
    {"drill", "Drill"},
    {"done", "Done"}
  ]

  @fiducial_target 4
  @jog_steps [0.1, 1.0, 10.0]

  @impl true
  def mount(params, _session, socket) do
    # Resolve the operator config ONCE, here at mount, into an immutable
    # snapshot for the life of this session (architecture §02, the State lens).
    # Nothing past this point re-reads the applied config — changing a setting
    # while this session runs cannot alter a stream already in flight.
    config = Config.current()

    {conn, conn_status} = connect_printer(socket, params, config)

    # A per-session progress topic, unique to THIS LiveView process, so two
    # concurrent operator sessions streaming at once never see each other's
    # progress. We subscribe here at mount and pass the same topic into every
    # `Printer.stream/3` so the PrinterConnection broadcasts back to us alone.
    progress_topic = "printer_progress:#{:erlang.pid_to_list(self()) |> List.to_string()}"
    if connected?(socket), do: Phoenix.PubSub.subscribe(BlauDrill.PubSub, progress_topic)

    socket =
      socket
      |> assign(:page_title, "Session")
      |> assign(:progress_topic, progress_topic)
      |> assign(:config, config)
      |> assign(:stages, @stages)
      |> assign(:job, nil)
      |> assign(:conn, conn)
      |> assign(:conn_status, conn_status)
      |> assign(:printer_state, Printer.state(conn))
      |> assign(:backend, Printer.backend())
      |> assign(:upload_error, nil)
      |> assign(:diagnostic, nil)
      |> assign(:jog_step, 1.0)
      |> assign(:jog_steps, @jog_steps)
      |> assign(:head, %{x: 0.0, y: 0.0, z: 0.0})
      |> assign(:captured_fiducials, [])
      # Which registration candidate the operator is currently aligning to
      # (index into feature_candidates/1). Only this one blinks; the rest fade.
      |> assign(:current_target, 0)
      |> assign(:fiducial_target, @fiducial_target)
      |> assign(:progress, nil)
      |> assign(:bit_change, nil)
      |> assign(:summary, nil)
      |> allow_upload(:drl,
        accept: ~w(.drl .gbr),
        max_entries: 1,
        max_file_size: 8_000_000,
        auto_upload: false
      )

    {:ok, socket}
  end

  # ── Printer wiring ──────────────────────────────────────────────────────────
  #
  # Tests inject a fake wire through the session map (so the suite needs no
  # hardware); dev/prod read the configured backend. Either way the connection
  # is per-session and linked to this LiveView.
  defp connect_printer(socket, _params, config) do
    if connected?(socket) do
      case get_connect_params(socket) do
        # Test harness: a pre-started connection is registered under this name.
        # Use it directly (the test owns its lifecycle) — no hardware.
        %{"conn_name" => name} when is_binary(name) ->
          resolve_named_conn(name)

        _ ->
          # Dev/prod: start a per-session connection for the configured backend,
          # threading the session's config snapshot (serial port/baud) into the
          # connect params so the operator's chosen port is used.
          connect_opts = Config.connect_opts(config)

          if Printer.connectable_with?(connect_opts) do
            case Printer.connect(connect_opts) do
              {:ok, conn} -> {conn, :connected}
              {:error, _reason} -> {nil, :disconnected}
            end
          else
            {nil, :disconnected}
          end
      end
    else
      {nil, :disconnected}
    end
  end

  defp resolve_named_conn(name) do
    atom = String.to_existing_atom(name)

    case Process.whereis(atom) do
      pid when is_pid(pid) -> {pid, :connected}
      _ -> {nil, :disconnected}
    end
  rescue
    ArgumentError -> {nil, :disconnected}
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, assign(socket, :upload_error, nil)}
  end

  def handle_event("load_board", _params, socket) do
    case consume_board(socket) do
      {:ok, board, diagnostic} ->
        job = Job.new(board)

        {:noreply,
         socket
         |> assign(:job, job)
         |> assign(:diagnostic, diagnostic)
         |> assign(:upload_error, nil)}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:upload_error, message)
         |> assign(:diagnostic, nil)}

      :no_file ->
        {:noreply, assign(socket, :upload_error, "Select a .drl file first.")}
    end
  end

  # Stage 1 → 2: begin registration.
  def handle_event("start_registering", _params, socket) do
    {:noreply, advance(socket, :start_registering)}
  end

  # Stage 2: energize the steppers (the only path to jogging).
  def handle_event("energize", _params, socket) do
    case Printer.energize(socket.assigns.conn) do
      :ok ->
        {:noreply,
         socket |> assign(:printer_state, Printer.state(socket.assigns.conn)) |> refresh_head()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot energize motors: #{inspect(reason)}")}
    end
  end

  def handle_event("release", _params, socket) do
    _ = Printer.release(socket.assigns.conn)
    {:noreply, assign(socket, :printer_state, Printer.state(socket.assigns.conn))}
  end

  def handle_event("set_jog_step", %{"step" => step}, socket) do
    {:noreply, assign(socket, :jog_step, parse_step(step))}
  end

  # Stage 2: relative jog. The PrinterConnection rejects this in :idle, so the
  # energize-before-jog gate holds even if the UI somehow offered it.
  def handle_event("jog", %{"axis" => axis, "dir" => dir}, socket) do
    mm = parse_dir(dir) * socket.assigns.jog_step
    axis_atom = String.to_existing_atom(axis)

    case Printer.jog(socket.assigns.conn, axis_atom, mm) do
      :ok ->
        {:noreply, refresh_head(socket)}

      {:error, :idle} ->
        {:noreply, put_flash(socket, :error, "Enable motors before jogging.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Jog failed: #{inspect(reason)}")}
    end
  end

  # Stage 2: the operator clicks a registration candidate to make it the CURRENT
  # target (the one being aligned). Only the current one blinks; the others fade.
  # Capture order is operator-driven, not forced.
  def handle_event("set_current_target", %{"index" => index}, socket) do
    idx = to_int(index)
    candidates = feature_candidates(socket.assigns.job.board)

    if idx >= 0 and idx < length(candidates) do
      {:noreply, assign(socket, :current_target, idx)}
    else
      {:noreply, socket}
    end
  end

  # Stage 2: capture the current head position against the CURRENT target board
  # feature as a Correspondence, feed it to the Job's pending alignment, then
  # auto-advance the current target to the next not-yet-captured candidate.
  def handle_event("capture_fiducial", _params, socket) do
    job = socket.assigns.job
    idx = socket.assigns.current_target
    candidates = feature_candidates(job.board)

    with true <- Job.can?(job, :capture),
         {x, y} when not is_nil(x) <- Enum.at(candidates, idx) || {nil, nil},
         {:ok, {mx, my, _mz}} <- Printer.where(socket.assigns.conn) do
      corr = %Correspondence{board: {x, y}, machine: {mx, my}}
      {:ok, job} = Job.transition(job, {:capture, corr})

      captured =
        socket.assigns.captured_fiducials ++
          [%{index: idx, x: x, y: y, state: "captured"}]

      {:noreply,
       socket
       |> assign(:job, job)
       |> assign(:captured_fiducials, captured)
       |> assign(:current_target, next_uncaptured(candidates, captured))}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Capture is not available right now.")}

      {nil, nil} ->
        {:noreply, put_flash(socket, :error, "No registration target selected.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not read head position: #{inspect(reason)}")}
    end
  end

  # Stage 2: fit the captured correspondences. Branches via the residual gate to
  # :aligned or :alignment_rejected, or stays :registering on a failed fit.
  def handle_event("fit", _params, socket) do
    job = socket.assigns.job

    case Job.transition(job, {:fit, job.tol}) do
      {:ok, fitted} ->
        socket = assign(socket, :job, fitted)

        socket =
          case fitted.state do
            :alignment_rejected ->
              put_flash(socket, :error, "Alignment rejected: residual over tolerance. Recapture.")

            _ ->
              socket
          end

        {:noreply, socket}

      {:error, :too_few} ->
        {:noreply, put_flash(socket, :error, "Capture at least 3 fiducials before fitting.")}

      {:error, :degenerate} ->
        {:noreply,
         put_flash(socket, :error, "Fiducials are collinear — capture non-collinear points.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Fit failed: #{inspect(reason)}")}
    end
  end

  # alignment_rejected → registering.
  def handle_event("recapture", _params, socket) do
    {:noreply,
     socket
     |> advance(:recapture)
     |> assign(:captured_fiducials, [])
     |> assign(:current_target, 0)}
  end

  # aligned → dry_run, then stream the dry-run program (spindle off, hover).
  def handle_event("run_dry_run", _params, socket) do
    socket = advance(socket, :run_dry_run)
    {:noreply, run_program(socket, :dry_run)}
  end

  # dry_run → aligned (operator wants to redo the alignment).
  def handle_event("redo_alignment", _params, socket) do
    {:noreply, advance(socket, :redo_alignment)}
  end

  # dry_run → drilling (the ONLY path to drilling), then stream the real program.
  def handle_event("confirm_registration", _params, socket) do
    socket = advance(socket, :confirm_registration)
    {:noreply, run_program(socket, :drill)}
  end

  # Resume after the bit-change pause. Clearing the modal re-exposes the "Mark
  # Complete" action; the background stream keeps animating progress underneath.
  # Completion stays an explicit operator step.
  def handle_event("resume_drilling", _params, socket) do
    {:noreply, assign(socket, :bit_change, nil)}
  end

  # drilling → done. Assemble the completion summary (real total time derived
  # from the run's holes × per-hole estimate) as we settle into :done.
  def handle_event("complete", _params, socket) do
    socket = advance(socket, :complete)

    socket =
      case socket.assigns.job do
        %Job{state: :done} -> assign(socket, :summary, build_summary(socket))
        _ -> socket
      end

    {:noreply, socket}
  end

  # Emergency abort / E-stop: halt the printer (M112) and fault the job if it is
  # mid-drill. Present in every motion stage.
  def handle_event("abort", _params, socket) do
    _ = Printer.halt(socket.assigns.conn)
    job = socket.assigns.job

    job =
      if job && Job.can?(job, :serial_loss) do
        {:ok, faulted} = Job.transition(job, {:serial_loss, :operator_abort})
        faulted
      else
        job
      end

    {:noreply,
     socket
     |> assign(:job, job)
     |> assign(:printer_state, Printer.state(socket.assigns.conn))
     |> assign(:bit_change, nil)
     |> put_flash(:error, "ABORTED — machine halted.")}
  end

  # faulted → aligned (reconnect and resume from the solved alignment).
  def handle_event("reconnect", _params, socket) do
    _ = Printer.reconnect(socket.assigns.conn)

    # faulted → aligned. A fault discards the interrupted drilling run: the FSM
    # routes back to :aligned (not :drilling), so resuming requires a fresh
    # dry-run before the real run — the operator re-validates registration
    # before any bit touches copper again. Clear the stale drilling progress and
    # any open bit-change modal so the :aligned UI doesn't show a half-finished
    # "X / Y" from the aborted run.
    {:noreply,
     socket
     |> advance(:reconnect)
     |> assign(:progress, nil)
     |> assign(:bit_change, nil)}
  end

  # Start a fresh board (Stage 5 → Stage 1).
  def handle_event("new_board", _params, socket) do
    {:noreply,
     socket
     |> assign(:job, nil)
     |> assign(:diagnostic, nil)
     |> assign(:captured_fiducials, [])
     |> assign(:current_target, 0)
     |> assign(:progress, nil)
     |> assign(:summary, nil)
     |> assign(:bit_change, nil)
     |> assign(:upload_error, nil)}
  end

  # ── Live progress (PubSub from PrinterConnection) ────────────────────────────

  # A confirmed-line progress event from the streaming PrinterConnection. We fold
  # it into the drilling/dry-run progress (holes-done, current bit, ring %). This
  # is the live per-`ok` feed — no transition semantics, just UI assigns.
  @impl true
  def handle_info({:stream_progress, payload}, socket) do
    {:noreply, apply_progress(socket, payload)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Internal helpers ─────────────────────────────────────────────────────────

  # Apply a Job event and assign the new job; log illegal transitions (should
  # never happen because the UI only offers legal ones, but be defensive).
  defp advance(socket, event) do
    case Job.transition(socket.assigns.job, event) do
      {:ok, job} ->
        assign(socket, :job, job)

      {:error, reason} ->
        Logger.warning("SessionLive illegal transition #{inspect(event)}: #{inspect(reason)}")
        put_flash(socket, :error, "Action not available in this stage.")
    end
  end

  defp consume_board(socket) do
    results =
      consume_uploaded_entries(socket, :drl, fn %{path: path}, _entry ->
        case File.read(path) do
          {:ok, contents} -> {:ok, BoardModel.parse_drl(contents)}
          {:error, reason} -> {:ok, {:error, {:read_failed, reason}}}
        end
      end)

    case results do
      [{:ok, %BoardModel{} = board}] -> {:ok, board, diagnostic(board)}
      [{:error, reason}] -> {:error, error_message(reason)}
      [] -> :no_file
    end
  end

  defp diagnostic(%BoardModel{} = board) do
    {minx, miny, maxx, maxy} = board.bbox

    %{
      hole_count: length(board.holes),
      tool_count: map_size(board.tools),
      width: Float.round(maxx - minx, 2),
      height: Float.round(maxy - miny, 2),
      tools: board.tools
    }
  end

  # Translate domain parse errors into operator-facing copy. The
  # absolute-page-coordinate trap gets a clear "drill origin not set" message.
  defp error_message({:absolute_page_coordinates, details}) do
    Map.get(
      details,
      :hint,
      "Drill origin not set: coordinates look like an absolute KiCad page export. " <>
        "Re-export with the Drill/Place File Origin placed on a fiducial."
    )
  end

  defp error_message(:missing_m48_header), do: "Not a valid Excellon drill file (no M48 header)."
  defp error_message(:no_holes), do: "Drill file contains no holes."
  defp error_message({:hole_with_no_tool, line}), do: "Hole with no selected tool: #{line}"
  defp error_message({:read_failed, reason}), do: "Could not read upload: #{inspect(reason)}"
  defp error_message(other), do: "Could not parse drill file: #{inspect(other)}"

  # The next board feature to register against, in capture order. The selectable
  # set is `fiducials ++ holes`; the fixture has no extracted fiducials, so we
  # walk distinctive holes (corners of the hole cloud) deterministically.

  # The next candidate index not yet captured (so capture auto-advances to fresh
  # work). Falls back to the just-captured index when everything is captured.
  defp next_uncaptured(candidates, captured) do
    done = MapSet.new(captured, & &1.index)

    0..(length(candidates) - 1)
    |> Enum.find(&(not MapSet.member?(done, &1)))
    |> case do
      nil -> length(candidates) - 1
      idx -> idx
    end
  end

  defp to_int(i) when is_integer(i), do: i

  defp to_int(i) when is_binary(i) do
    case Integer.parse(i) do
      {n, _} -> n
      :error -> -1
    end
  end

  # Pick spread-out registration candidates: the four bbox-corner-nearest holes,
  # so captures are well-conditioned (non-collinear) for the fit. Public so the
  # render components can show pending fiducial targets on the canvas.
  @doc false
  def feature_candidates(%BoardModel{holes: holes, bbox: {minx, miny, maxx, maxy}}) do
    corners = [{minx, miny}, {maxx, miny}, {maxx, maxy}, {minx, maxy}]

    Enum.map(corners, fn corner ->
      hole = Enum.min_by(holes, fn h -> dist2({h.x, h.y}, corner) end)
      {hole.x, hole.y}
    end)
    |> Enum.uniq()
  end

  defp dist2({x1, y1}, {x2, y2}), do: (x1 - x2) ** 2 + (y1 - y2) ** 2

  # Build and stream a program for the given mode. Streaming runs ASYNCHRONOUSLY
  # (in a linked Task) so the LiveView stays responsive and can fold the live
  # per-line progress events the PrinterConnection broadcasts — the progress ring
  # fills as each `ok` arrives, instead of jumping straight to done. The
  # per-session topic (subscribed at mount) carries the events back to us alone.
  defp run_program(socket, mode) do
    job = socket.assigns.job

    # Server-side safety gate: only stream motion when the Job FSM has actually
    # entered the state this program belongs to. `advance/2` leaves the job
    # unchanged when a transition is illegal (e.g. a forged or raced
    # `confirm_registration` arriving while still `:aligned`), so without this
    # guard a stale/forged event could start a real drill that skipped dry-run.
    # The mode→required-state map mirrors the only legal streaming states; a
    # mismatch streams nothing. This enforces the architecture's "illegal
    # sequencing is unrepresentable" invariant at the LiveView seam, not just in
    # the (cosmetic, client-side) disabled button.
    required_state = %{dry_run: :dry_run, drill: :drilling}[mode]

    case {job.state, job.alignment} do
      {^required_state, %Alignment{} = alignment} ->
        # Use the session's config snapshot (taken at mount) for the generator
        # tunables: zdrill/zsafe/zchange/drill_feed/spindle_speed/hover.
        opts = [mode: mode] ++ Config.gcode_opts(socket.assigns.config)
        program = GcodeProgram.build(job.board, alignment, opts)
        total_holes = length(job.board.holes)

        # Stream over the wire asynchronously, threading the per-session progress
        # topic so each confirmed line broadcasts back here. The Task is linked to
        # the LiveView, so it dies with the session; an abort (M112) replies to
        # the stream caller and the Task ends.
        conn = socket.assigns.conn
        topic = socket.assigns.progress_topic
        start_async_stream(conn, program, topic)

        # Progress starts at 0/total; it fills as {:stream_progress, ...} events
        # arrive. holes_done / current_tool are derived from the confirmed-line
        # prefix against this program.
        progress = %{
          mode: mode,
          program: program,
          tool_order: program.tool_order,
          total_lines: length(program.lines),
          sent: 0,
          # Holes-based counters the drilling UI shows ("X / Y").
          drilled: 0,
          total: total_holes,
          total_holes: total_holes,
          holes_done: 0,
          current_tool: List.first(program.tool_order)
        }

        socket = assign(socket, :progress, progress)

        # In :drill mode with more than one bit, surface the first per-tool M0
        # bit-change pause as the modal (the program carries M0 lines per tool).
        # The modal holds completion: while it is up the run will not settle to
        # :done, so the operator must acknowledge the bit change. Progress keeps
        # animating behind it as acks arrive.
        if mode == :drill and length(program.tool_order) > 1 do
          [_first, second | _] = program.tool_order
          diameter = Map.get(job.board.tools, second)
          assign(socket, :bit_change, %{to_tool: second, diameter: diameter})
        else
          socket
        end

      _ ->
        # Either no solved alignment, or the Job is not in the required
        # streaming state for this mode (the safety gate above). Stream nothing.
        Logger.warning(
          "SessionLive refused to stream #{mode}: job state #{inspect(job.state)}, " <>
            "alignment? #{match?(%Alignment{}, job.alignment)}"
        )

        put_flash(socket, :error, "Cannot stream #{mode} from the current stage.")
    end
  end

  # Stream in a linked Task so `run_program/2` returns immediately. The Task only
  # drives the wire; all UI state flows back via the progress topic + PubSub.
  defp start_async_stream(conn, program, topic) do
    Task.start_link(fn -> Printer.stream(conn, program, progress_topic: topic) end)
  end

  # Fold a per-line progress event into the drilling progress: derive holes-done
  # and the current tool/bit from the confirmed-line prefix of the program.
  defp apply_progress(socket, %{sent: sent}) do
    case socket.assigns.progress do
      %{program: %GcodeProgram{lines: lines}} = progress ->
        confirmed = Enum.take(lines, sent)
        holes_done = count_holes(confirmed)
        current_tool = current_tool(lines, sent, progress.tool_order)

        progress = %{
          progress
          | sent: sent,
            holes_done: holes_done,
            drilled: holes_done,
            current_tool: current_tool
        }

        # Folding progress never transitions the Job — completion stays an
        # explicit operator action ("Mark Complete"), keeping the flow linear and
        # gated. We only update the live counters/bit; the drilling stage shows
        # holes_done reaching total when the stream finishes.
        assign(socket, :progress, progress)

      _ ->
        socket
    end
  end

  # Count drilled/visited holes in a confirmed prefix: every hole emits exactly
  # one per-hole XY rapid `G0 X.. Y..` (see GcodeProgram.fmt_xy_rapid/2), in both
  # :drill and :dry_run mode. The postamble home is `G00 X..` (two zeros) and the
  # tool-block lift is `G0 Z..`, so neither is miscounted.
  @doc false
  def count_holes(lines) do
    Enum.count(lines, &String.starts_with?(&1, "G0 X"))
  end

  # The tool whose block the current line falls in: the last tool-change marker
  # (a bare tool id like "T1") at or before the current index. Falls back to the
  # first tool before any marker is seen.
  defp current_tool(lines, sent, tool_order) do
    idx = max(sent - 1, 0)

    lines
    |> Enum.take(idx + 1)
    |> Enum.reduce(List.first(tool_order), fn line, acc ->
      if line in tool_order, do: line, else: acc
    end)
  end

  defp build_summary(socket) do
    board = socket.assigns.job.board
    tool_count = map_size(board.tools)
    elapsed = elapsed_label(socket)

    %{
      total_holes: length(board.holes),
      total_time: elapsed,
      bit_changes: max(tool_count - 1, 0)
    }
  end

  # The completion-card "Total Time": the full-run estimate (all holes) from the
  # same derivation as Est. Time Remaining, since the run just finished.
  defp elapsed_label(socket), do: elapsed_label_from(socket.assigns)

  defp elapsed_label_from(assigns) do
    case assigns.progress do
      %{total_holes: total} = progress ->
        seconds = estimate_remaining_seconds(total, per_hole_seconds(assigns, progress))
        format_mmss(seconds)

      _ ->
        "—"
    end
  end

  # ── Telemetry derivations (real, config-derived — no placeholders) ───────────
  #
  # All of this is DERIVED from the session's Config snapshot and the live
  # progress; nothing is a constant.

  # The per-hole time model. One hole, at feed `drill_feed` mm/min, is:
  #
  #     plunge (zsafe → zdrill)  + retract (zdrill → zsafe)  + a fixed dwell
  #
  # i.e. `2 * (zsafe - zdrill)` mm of Z travel at the feed, plus a small fixed
  # per-hole dwell for the XY rapid + settle. In :dry_run the bit only hovers, so
  # the Z travel is `2 * (hover - 0)`; we use the real plunge depth for :drill.
  # This is an ESTIMATE, but every input is a real Config/program value.
  @per_hole_dwell_s 0.5

  defp per_hole_seconds(assigns, %{mode: mode}) do
    c = assigns.config
    feed_mm_per_s = c.drill_feed / 60.0

    z_travel_mm =
      case mode do
        :drill -> 2.0 * (c.zsafe - c.zdrill)
        :dry_run -> 2.0 * max(c.hover, 0.0)
      end

    z_travel_mm / max(feed_mm_per_s, 1.0e-6) + @per_hole_dwell_s
  end

  defp per_hole_seconds(_assigns, _progress), do: @per_hole_dwell_s

  @doc """
  Estimate remaining drill time in seconds: `remaining_holes * per_hole_seconds`.

  Pure and monotone — it scales linearly with the remaining hole count and with
  the per-hole time, so a slower feed (larger `per_hole_seconds`) or more holes
  left yields a larger estimate. Negative hole counts clamp to zero.
  """
  @spec estimate_remaining_seconds(integer(), number()) :: float()
  def estimate_remaining_seconds(remaining_holes, per_hole_s)
      when is_number(per_hole_s) do
    max(remaining_holes, 0) * (per_hole_s * 1.0)
  end

  # The Est. Time Remaining label for the drilling telemetry: remaining holes
  # (total - holes_done) times the per-hole estimate, as mm:ss.
  defp eta_label(assigns) do
    case assigns.progress do
      %{total_holes: total, holes_done: done} = progress ->
        remaining = total - done
        seconds = estimate_remaining_seconds(remaining, per_hole_seconds(assigns, progress))
        format_mmss(seconds)

      _ ->
        "—"
    end
  end

  # The spindle telemetry value. In :drill the spindle is commanded ON at the
  # config PWM duty; we map that to RPM via the configured full-scale RPM:
  #
  #     rpm = round(spindle_speed / pwm_max * spindle_max_rpm)
  #
  # In :dry_run (spindle left OFF) or before any stream, it reads OFF / 0 RPM.
  defp spindle_label(assigns) do
    c = assigns.config

    case assigns.progress do
      %{mode: :drill} ->
        rpm = round(c.spindle_speed / c.pwm_max * c.spindle_max_rpm)
        "#{format_thousands(rpm)} RPM (PWM #{c.spindle_speed}/#{c.pwm_max})"

      _ ->
        "OFF · 0 RPM"
    end
  end

  # Seconds → "M:SS" (or "MM:SS"). Rounds to whole seconds.
  defp format_mmss(seconds) when is_number(seconds) do
    total = round(seconds)
    mins = div(total, 60)
    secs = rem(total, 60)
    "#{mins}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp format_thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  # Re-read the live head position from the printer (M114) for the crosshair and
  # the bottom-bar XYZ readout.
  defp refresh_head(socket) do
    case Printer.where(socket.assigns.conn) do
      {:ok, {x, y, z}} -> assign(socket, :head, %{x: x, y: y, z: z})
      _ -> socket
    end
  end

  defp parse_step(step) do
    case Float.parse(step) do
      {f, _} -> f
      :error -> 1.0
    end
  end

  defp parse_dir("+"), do: 1.0
  defp parse_dir("-"), do: -1.0
  defp parse_dir(_), do: 1.0

  # ── Stage mapping (job.state → stepper stage id) ─────────────────────────────

  @doc false
  def stage_id(nil), do: "load"
  def stage_id(%Job{state: :parsed}), do: "load"

  def stage_id(%Job{state: state}) when state in [:registering, :aligned, :alignment_rejected],
    do: "align"

  def stage_id(%Job{state: :dry_run}), do: "dryrun"
  def stage_id(%Job{state: :drilling}), do: "drill"
  def stage_id(%Job{state: :done}), do: "done"
  def stage_id(%Job{state: :faulted}), do: "drill"

  # ── Render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:stage, stage_id(assigns.job))
      |> assign(:telemetry, telemetry(assigns))

    BlauDrillWeb.SessionComponents.session(assigns)
  end

  # Build the real, config-derived telemetry the drilling panel renders. Current
  # Bit comes from the live current tool while drilling (else the smallest tool);
  # ETA and Spindle are derived above. Computed in the LiveView (NOT hardcoded in
  # the component) so it tracks the Config snapshot and live progress.
  defp telemetry(%{job: %Job{} = job} = assigns) do
    %{
      bit: current_bit_label(job, assigns.progress),
      eta: eta_label(assigns),
      spindle: spindle_label(assigns)
    }
  end

  defp telemetry(_assigns), do: %{bit: "—", eta: "—", spindle: "OFF · 0 RPM"}

  # The diameter of the live current tool (from progress) while drilling, else
  # the smallest tool on the board.
  defp current_bit_label(%Job{board: board}, %{current_tool: tool})
       when is_binary(tool) do
    case Map.get(board.tools, tool) do
      d when is_number(d) -> "#{fmt_diameter(d)}mm"
      _ -> smallest_bit_label(board)
    end
  end

  defp current_bit_label(%Job{board: board}, _progress), do: smallest_bit_label(board)

  defp smallest_bit_label(%BoardModel{tools: tools}) when map_size(tools) > 0 do
    {_id, d} = Enum.min_by(tools, fn {_id, d} -> d end)
    "#{fmt_diameter(d)}mm"
  end

  defp smallest_bit_label(_board), do: "—"

  # Trim trailing zeros from a diameter: 0.600 -> "0.6", 1.000 -> "1".
  defp fmt_diameter(d) do
    d
    |> :erlang.float_to_binary(decimals: 4)
    |> String.replace(~r/0+$/, "")
    |> String.replace(~r/\.$/, "")
  end
end
