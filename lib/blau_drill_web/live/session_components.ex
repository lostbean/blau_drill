defmodule BlauDrillWeb.SessionComponents do
  @moduledoc """
  The HEEx render tree for `BlauDrillWeb.SessionLive` — the Industrial Dark
  operator shell and the five stage views.

  Split out of the LiveView so the (stateful) orchestration and the (stateless)
  markup stay readable. Every gate-bearing control here is driven by assigns the
  LiveView computes from `BlauDrill.Job.can?/2` and the live
  `BlauDrill.PrinterConnection` state — the buttons are *real* gates, not
  cosmetic: a disabled control means the underlying domain transition is illegal
  or the motion safety gate is closed.

  Layout follows `docs/design_reference/` mockups: a 120px header with a 5-node
  stepper, a 320px left sidebar (Control Panel / Stages / Connection /
  hazard-striped EMERGENCY STOP), a central canvas (the live_svelte
  `BoardCanvas`), and a fixed 48px bottom data bar (machine status + live XYZ).
  """
  use BlauDrillWeb, :html

  alias BlauDrill.Job

  @hazard "repeating-linear-gradient(45deg, transparent, transparent 10px, rgba(0,0,0,0.18) 10px, rgba(0,0,0,0.18) 20px)"

  @doc "The whole session page for the current job/stage."
  attr :job, :any, required: true
  attr :stage, :string, required: true
  attr :stages, :list, required: true
  attr :conn, :any, default: nil
  attr :conn_status, :atom, default: :disconnected
  attr :printer_state, :atom, default: :disconnected
  attr :backend, :atom, default: :none
  attr :devices, :list, default: []
  attr :selected_device, :string, default: nil
  attr :upload_error, :string, default: nil
  attr :diagnostic, :any, default: nil
  attr :uploads, :any, required: true
  attr :jog_step, :float, default: 1.0
  attr :jog_steps, :list, default: []
  attr :head, :map, required: true
  attr :captured_fiducials, :list, default: []
  attr :current_target, :integer, default: 0
  attr :fiducial_target, :integer, default: 4
  attr :progress, :any, default: nil
  attr :bit_change, :any, default: nil
  attr :summary, :any, default: nil
  attr :telemetry, :map, default: %{}
  attr :flash, :map, required: true
  attr :socket, :any, required: true

  def session(assigns) do
    ~H"""
    <div class="flex h-screen flex-col overflow-hidden bg-background text-on-surface">
      <.fault_banner :if={faulted?(@job)} />

      <.app_header stages={@stages} stage={@stage} />

      <div class="flex flex-1 overflow-hidden">
        <.sidebar
          job={@job}
          stage={@stage}
          conn_status={@conn_status}
          printer_state={@printer_state}
          backend={@backend}
          devices={@devices}
          selected_device={@selected_device}
        />

        <main class="relative flex-1 overflow-hidden bg-surface-dim p-6 pb-16">
          <.stage_main
            job={@job}
            stage={@stage}
            upload_error={@upload_error}
            diagnostic={@diagnostic}
            uploads={@uploads}
            jog_step={@jog_step}
            jog_steps={@jog_steps}
            printer_state={@printer_state}
            head={@head}
            captured_fiducials={@captured_fiducials}
            current_target={@current_target}
            fiducial_target={@fiducial_target}
            progress={@progress}
            bit_change={@bit_change}
            summary={@summary}
            telemetry={@telemetry}
            socket={@socket}
          />
        </main>
      </div>

      <.bottom_bar printer_state={@printer_state} head={@head} diagnostic={@diagnostic} />
    </div>

    <.flash_group flash={@flash} />
    """
  end

  # ── Fault banner (Stage 5 fault path) ─────────────────────────────────────

  defp fault_banner(assigns) do
    ~H"""
    <div
      id="fault-banner"
      class="z-50 flex items-center justify-center gap-4 border-b-2 border-error bg-error-container px-6 py-2 font-data text-sm text-on-error-container"
    >
      <span class="inline-block h-2.5 w-2.5 animate-blink rounded-full bg-error"></span>
      <span class="font-bold uppercase tracking-wide">
        HARDWARE DISCONNECTED. Check USB cable and power.
      </span>
      <button
        type="button"
        phx-click="reconnect"
        data-test="reconnect"
        class="rounded border border-error px-3 py-1 font-data text-xs font-bold uppercase tracking-widest hover:bg-error hover:text-on-error"
      >
        Reconnect
      </button>
    </div>
    """
  end

  # ── Header + 5-node stepper ────────────────────────────────────────────────

  @doc """
  The shared brand lockup: the precision-manufacturing (robot-arm) logo glyph
  beside the "blau-drill" wordmark. Used in both the session header and the
  Settings top bar so branding is identical across screens.
  """
  attr :tagline, :boolean, default: false

  def brand(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5">
      <.logo_mark class="flex-none text-3xl text-primary" />
      <div>
        <span class="font-sans text-2xl font-bold leading-none text-primary">blau-drill</span>
        <p
          :if={@tagline}
          class="mt-0.5 font-data text-[0.625rem] uppercase tracking-widest text-on-surface-variant"
        >
          Precision PCB Drilling Control
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The `precision_manufacturing` (robot-arm) logo glyph — the exact Material
  Symbol the reference mockups use, rendered from the Material Symbols Outlined
  font (loaded in the root layout).
  """
  attr :class, :string, default: "text-2xl"

  def logo_mark(assigns) do
    ~H"""
    <span class={["material-symbols-outlined fill leading-none", @class]} aria-hidden="true">
      precision_manufacturing
    </span>
    """
  end

  attr :stages, :list, required: true
  attr :stage, :string, required: true

  defp app_header(assigns) do
    ~H"""
    <header class="flex h-16 flex-none items-center justify-between border-b border-outline-variant bg-surface-container-high px-6">
      <.brand />

      <ol class="hidden items-center gap-2 md:flex">
        <%= for {{id, label}, idx} <- Enum.with_index(@stages) do %>
          <li class="flex flex-col items-center">
            <div class={[
              "flex h-7 w-7 items-center justify-center rounded-full font-data text-xs font-bold",
              stepper_node_class(id, @stage, @stages)
            ]}>
              {idx + 1}
            </div>
            <span class={[
              "mt-0.5 font-data text-[0.5625rem] font-bold uppercase tracking-widest",
              if(id == @stage, do: "text-primary", else: "text-on-surface-variant")
            ]}>
              {label}
            </span>
          </li>
          <li :if={idx < length(@stages) - 1} class="h-px w-8 bg-outline-variant"></li>
        <% end %>
      </ol>

      <div class="flex items-center">
        <.link
          navigate="/settings"
          data-test="settings-link"
          title="Printer configuration"
          aria-label="Printer configuration"
          class="group flex items-center gap-2 rounded-md border border-outline-variant bg-surface-container-high px-3 py-1.5 font-data text-xs font-bold uppercase tracking-widest text-on-surface transition hover:border-primary hover:bg-primary-container hover:text-on-primary-container"
        >
          <span class="text-lg leading-none transition group-hover:rotate-90">⚙</span>
          <span class="hidden sm:inline">Config</span>
        </.link>
      </div>
    </header>
    """
  end

  # ── Sidebar (Control Panel / Stages / Connection / E-STOP) ─────────────────

  attr :job, :any, required: true
  attr :stage, :string, required: true
  attr :conn_status, :atom, required: true
  attr :printer_state, :atom, required: true
  attr :backend, :atom, required: true
  attr :devices, :list, default: []
  attr :selected_device, :string, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside class="flex w-80 flex-none flex-col overflow-y-auto border-r border-outline-variant bg-surface-container">
      <div class="border-b border-outline-variant p-6">
        <h2 class="font-sans text-2xl font-semibold text-primary">Control Panel</h2>
        <p class="mt-1 flex items-center gap-2 font-data text-sm font-bold uppercase tracking-widest text-secondary">
          <span class="inline-block h-2 w-2 animate-pulse rounded-full bg-secondary"></span>
          {control_status(@printer_state, @job)}
        </p>
      </div>

      <div class="flex flex-1 flex-col gap-6 overflow-y-auto p-6">
        <div>
          <p class="border-b border-outline-variant pb-1 font-data text-xs font-bold uppercase tracking-widest text-on-surface-variant">
            Stages
          </p>
        <ul class="mt-2 flex flex-col gap-1">
          <.stage_nav_item id="load" label="Load" active={@stage} done={stage_done?("load", @stage)} />
          <.stage_nav_item
            id="align"
            label="Align"
            active={@stage}
            done={stage_done?("align", @stage)}
          />
          <.stage_nav_item
            id="dryrun"
            label="Dry-run"
            active={@stage}
            done={stage_done?("dryrun", @stage)}
          />
          <.stage_nav_item
            id="drill"
            label="Drill"
            active={@stage}
            done={stage_done?("drill", @stage)}
          />
          <.stage_nav_item id="done" label="Done" active={@stage} done={false} />
        </ul>
      </div>

      <.connection_card
        conn_status={@conn_status}
        backend={@backend}
        printer_state={@printer_state}
        devices={@devices}
        selected_device={@selected_device}
      />

      <div class="mt-auto flex flex-col gap-4">
        <%!-- Emergency stop: present in every motion stage. Calls Printer.halt/1 (M112). --%>
        <button
          :if={motion_stage?(@stage)}
          type="button"
          phx-click="abort"
          data-test="emergency-stop"
          style={"background-image: #{hazard_bg()};"}
          class="flex w-full items-center justify-center gap-2 rounded border border-error bg-error-container px-4 py-4 font-sans text-lg font-bold uppercase tracking-wide text-on-error-container shadow-inner hover:brightness-110"
        >
          ⚠ Emergency Stop
        </button>
      </div>
      </div>
    </aside>
    """
  end

  attr :conn_status, :atom, required: true
  attr :backend, :atom, required: true
  attr :printer_state, :atom, required: true
  attr :devices, :list, default: []
  attr :selected_device, :string, default: nil

  defp connection_card(assigns) do
    assigns = assign(assigns, :connected?, assigns.conn_status == :connected)

    ~H"""
    <div class="rounded-lg border border-outline-variant bg-surface-container-highest p-4">
      <div class="flex items-center justify-between">
        <span class="font-data text-xs font-bold uppercase tracking-widest text-on-surface-variant">
          Connection
        </span>
        <span class={[
          "flex items-center gap-1.5 font-data text-xs font-bold uppercase",
          connection_color(@conn_status, @printer_state)
        ]}>
          <span class={[
            "inline-block h-2 w-2 rounded-full",
            connection_dot(@conn_status, @printer_state)
          ]}>
          </span>
          {printer_label(@printer_state, @conn_status)}
        </span>
      </div>

      <%!--
        Device picker: the operator chooses Simulator or a detected serial port.
        Selecting a device is NOT motion — it only changes which device a Connect
        opens. The select + refresh lock while connected (you disconnect first to
        switch devices); the picker reflects the active connection's device.
      --%>
      <form id="device-form" phx-change="select_device" class="mt-3 flex w-full items-center gap-2">
        <select
          name="device"
          disabled={@connected?}
          data-test="device-select"
          class="min-w-0 flex-1 truncate rounded border border-outline-variant bg-surface-container-lowest px-2 py-2 font-data text-xs text-on-surface disabled:opacity-60"
        >
          <option :for={device <- @devices} value={device.id} selected={device.id == @selected_device}>
            {device.label}
          </option>
        </select>
        <button
          type="button"
          phx-click="refresh_devices"
          disabled={@connected?}
          title="Refresh device list"
          data-test="refresh-devices"
          class="flex-none rounded border border-outline-variant bg-surface-container-high px-2 py-2 font-data text-xs text-on-surface-variant hover:brightness-110 disabled:opacity-50"
        >
          ⟳
        </button>
      </form>

      <button
        :if={!@connected?}
        type="button"
        phx-click="connect_device"
        data-test="connect-device"
        class="mt-3 w-full rounded border border-primary bg-primary-container px-3 py-2 font-data text-xs font-bold uppercase tracking-wider text-on-primary-container hover:brightness-110"
      >
        Connect
      </button>
      <button
        :if={@connected?}
        type="button"
        phx-click="disconnect_device"
        data-test="disconnect-device"
        class="mt-3 w-full rounded border border-outline-variant bg-surface-container-high px-3 py-2 font-data text-xs font-bold uppercase tracking-wider text-on-surface-variant hover:brightness-110"
      >
        Disconnect
      </button>

      <p class="mt-2 font-data text-[0.625rem] uppercase tracking-wider text-on-surface-variant">
        Backend: {@backend}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :active, :string, required: true
  attr :done, :boolean, default: false

  defp stage_nav_item(assigns) do
    ~H"""
    <li class={[
      "flex items-center gap-2 rounded px-3 py-2 font-data text-sm font-bold uppercase tracking-wide",
      cond do
        @id == @active -> "border-2 border-primary bg-primary-container text-on-primary-container"
        @done -> "text-secondary"
        true -> "text-on-surface-variant"
      end
    ]}>
      <span class="text-base">{if @done, do: "✓", else: "•"}</span>
      {@label}
    </li>
    """
  end

  # ── Bottom data bar ────────────────────────────────────────────────────────

  attr :printer_state, :atom, required: true
  attr :head, :map, required: true
  attr :diagnostic, :any, default: nil

  defp bottom_bar(assigns) do
    ~H"""
    <footer class="flex h-12 flex-none items-center justify-between border-t-2 border-outline bg-surface-container-lowest px-6 font-data text-sm">
      <span class={[
        "flex items-center gap-2 font-bold uppercase tracking-wide",
        if(@printer_state in [:idle, :jogging, :streaming], do: "text-secondary", else: "text-error")
      ]}>
        <span class={[
          "inline-block h-2 w-2 rounded-full",
          if(@printer_state in [:idle, :jogging, :streaming],
            do: "bg-secondary",
            else: "bg-error"
          )
        ]}>
        </span>
        {printer_label(@printer_state, :connected)}
      </span>

      <div class="flex items-center gap-6 font-bold text-secondary">
        <span data-test="coord-x">X: {fmt(@head.x)}</span>
        <span data-test="coord-y">Y: {fmt(@head.y)}</span>
        <span data-test="coord-z">Z: {fmt(@head.z)}</span>
        <span class="text-outline">|</span>
        <span class="text-on-surface-variant">
          Bit: {bit_label(@diagnostic)}
        </span>
      </div>
    </footer>
    """
  end

  # ── Stage main dispatch ────────────────────────────────────────────────────

  defp stage_main(%{job: nil} = assigns), do: stage_load(assigns)

  defp stage_main(%{job: %Job{state: :parsed}} = assigns), do: stage_load(assigns)

  defp stage_main(%{job: %Job{state: state}} = assigns)
       when state in [:registering, :aligned, :alignment_rejected],
       do: stage_align(assigns)

  defp stage_main(%{job: %Job{state: :dry_run}} = assigns), do: stage_dryrun(assigns)
  defp stage_main(%{job: %Job{state: :drilling}} = assigns), do: stage_drill(assigns)
  defp stage_main(%{job: %Job{state: :done}} = assigns), do: stage_done(assigns)
  defp stage_main(%{job: %Job{state: :faulted}} = assigns), do: stage_drill(assigns)

  # ── Stage 1: Load & Connect ────────────────────────────────────────────────

  defp stage_load(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <%= if @job do %>
        <.diagnostic_bar diagnostic={@diagnostic} />
        <div class="relative flex-1 overflow-hidden rounded-lg border border-outline-variant">
          <.svelte name="BoardCanvas" props={canvas_props(assigns)} socket={@socket} />
        </div>
        <div class="mt-4 flex justify-end">
          <button
            type="button"
            phx-click="start_registering"
            disabled={not can?(@job, :start_registering)}
            data-test="proceed-align"
            class="rounded bg-primary-container px-6 py-3 font-sans text-sm font-bold uppercase tracking-wide text-on-primary-container hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Proceed to Align →
          </button>
        </div>
      <% else %>
        <form
          id="upload-form"
          phx-submit="load_board"
          phx-change="validate_upload"
          class="flex h-full flex-col"
        >
          <label
            phx-drop-target={@uploads.drl.ref}
            class="flex flex-1 cursor-pointer flex-col items-center justify-center gap-4 rounded-lg border-2 border-dashed border-outline-variant bg-surface-container-lowest text-center hover:border-primary"
          >
            <span class="text-6xl text-on-surface-variant">⬆</span>
            <span class="font-sans text-2xl font-bold text-on-surface">Drop PCB files here</span>
            <span class="font-data text-sm text-on-surface-variant">
              Supports Gerber (.gbr) and Excellon (.drl)
            </span>
            <.live_file_input upload={@uploads.drl} class="hidden" />
            <span class="rounded bg-surface-container-high px-4 py-2 font-sans text-sm font-semibold text-on-surface">
              Browse Files
            </span>
          </label>

          <div
            :for={entry <- @uploads.drl.entries}
            class="mt-3 flex items-center justify-between rounded border border-outline-variant bg-surface-container px-4 py-2 font-data text-sm"
          >
            <span class="text-on-surface">{entry.client_name}</span>
            <button
              type="submit"
              data-test="parse-board"
              class="rounded bg-primary-container px-4 py-1.5 font-sans text-xs font-bold uppercase tracking-wide text-on-primary-container hover:brightness-110"
            >
              Parse &amp; Load
            </button>
          </div>

          <p
            :if={@upload_error}
            data-test="upload-error"
            class="mt-3 rounded border border-error/50 bg-surface-container px-4 py-3 font-sans text-sm text-error"
          >
            {@upload_error}
          </p>
        </form>
      <% end %>
    </div>
    """
  end

  attr :diagnostic, :any, required: true

  defp diagnostic_bar(assigns) do
    ~H"""
    <div
      :if={@diagnostic}
      data-test="diagnostic-bar"
      class="mb-4 flex flex-wrap items-center gap-6 rounded border border-outline-variant bg-surface-container-low px-4 py-3 font-data text-sm"
    >
      <span class="flex items-center gap-2 font-bold text-secondary">
        <span class="text-base">✓</span> FILE VALID
      </span>
      <span class="text-on-surface-variant">
        Holes: <span class="font-bold text-on-surface" data-test="hole-count">{@diagnostic.hole_count}</span>
      </span>
      <span class="text-on-surface-variant">
        Tools: <span class="font-bold text-on-surface" data-test="tool-count">{@diagnostic.tool_count}</span>
      </span>
      <span class="text-on-surface-variant">
        Dimensions:
        <span class="font-bold text-on-surface">
          {@diagnostic.width} × {@diagnostic.height} mm
        </span>
      </span>
    </div>
    """
  end

  # ── Stage 2: Physical Alignment ────────────────────────────────────────────

  defp stage_align(assigns) do
    assigns =
      assigns
      |> assign(:motors_online, motors_online?(assigns.printer_state))
      |> assign(:quality, quality_percent(assigns.job))
      |> assign(:rejected, match?(%Job{state: :alignment_rejected}, assigns.job))

    ~H"""
    <div class="flex h-full gap-4">
      <div class="relative flex-1 overflow-hidden rounded-lg border border-outline-variant">
        <%!-- The BoardCanvas renders its own head-confidence caption (top-left),
              which carries the live-position status plus how much to trust it. --%>
        <.svelte name="BoardCanvas" props={canvas_props(assigns)} socket={@socket} />
      </div>

      <aside class="flex w-[360px] flex-none flex-col gap-4 overflow-y-auto">
        <div>
          <h3 class="font-sans text-lg font-bold text-on-surface">Alignment Setup</h3>
          <p class="font-data text-xs text-on-surface-variant">
            Capture {@fiducial_target} fiducials to align the board.
          </p>
        </div>

        <%!-- Axis Motors gate: ONLINE only when PrinterConnection is :jogging. --%>
        <div class="rounded-lg border border-outline-variant bg-surface-container p-4">
          <div class="flex items-center justify-between">
            <span class="font-data text-xs font-bold uppercase tracking-widest text-on-surface-variant">
              Axis Motors
            </span>
            <span class={[
              "rounded border px-2 py-0.5 font-data text-xs font-bold uppercase",
              if(@motors_online,
                do: "border-primary/40 bg-primary-container/10 text-primary",
                else: "animate-blink border-error/30 bg-error/10 text-error"
              )
            ]}>
              {if @motors_online, do: "ONLINE", else: "OFFLINE"}
            </span>
          </div>
          <button
            type="button"
            phx-click={if @motors_online, do: "release", else: "energize"}
            data-test="motors-toggle"
            class={[
              "mt-3 w-full rounded px-4 py-3 font-sans text-sm font-bold uppercase tracking-wide",
              if(@motors_online,
                do: "bg-primary-container text-on-primary-container",
                else: "bg-surface-container-high text-on-surface hover:bg-surface-container-highest"
              )
            ]}
          >
            {if @motors_online, do: "Motors ON — Disable", else: "Enable Motors"}
          </button>
          <p class="mt-2 font-data text-[0.625rem] uppercase tracking-wider text-on-surface-variant">
            Enable motors to unlock jog controls.
          </p>
        </div>

        <%!-- Manual jog: locked (disabled) until motors are online. --%>
        <div
          data-test="jog-panel"
          class={[
            "rounded-lg border border-outline-variant bg-surface-container p-4",
            not @motors_online && "pointer-events-none opacity-50"
          ]}
        >
          <span class="font-data text-xs font-bold uppercase tracking-widest text-on-surface-variant">
            Manual Jog
          </span>

          <div class="mt-2 grid grid-cols-3 gap-1">
            <button
              :for={step <- @jog_steps}
              type="button"
              phx-click="set_jog_step"
              phx-value-step={step}
              disabled={not @motors_online}
              class={[
                "rounded px-2 py-1 font-data text-xs font-bold",
                if(@jog_step == step,
                  do: "bg-primary-container text-on-primary-container",
                  else: "bg-surface-container-high text-on-surface"
                )
              ]}
            >
              {fmt_step(step)}
            </button>
          </div>

          <div class="mt-3 grid grid-cols-3 grid-rows-3 gap-1">
            <span></span>
            <.jog_btn axis="y" dir="+" label="↑ +Y" enabled={@motors_online} />
            <span></span>
            <.jog_btn axis="x" dir="-" label="← -X" enabled={@motors_online} />
            <div class="flex items-center justify-center">
              <span class="h-2 w-2 rounded-full bg-primary-container"></span>
            </div>
            <.jog_btn axis="x" dir="+" label="+X →" enabled={@motors_online} />
            <span></span>
            <.jog_btn axis="y" dir="-" label="↓ -Y" enabled={@motors_online} />
            <span></span>
          </div>

          <div class="mt-3 grid grid-cols-2 gap-1">
            <.jog_btn axis="z" dir="+" label="+Z" enabled={@motors_online} />
            <.jog_btn axis="z" dir="-" label="-Z" enabled={@motors_online} />
          </div>

          <%!-- Test the configured spindle (pulse on→off). Real actuation, so
                it's gated on motors being energized, same as jog. --%>
          <button
            type="button"
            phx-click="test_spindle"
            disabled={not @motors_online}
            data-test="test-spindle"
            class="mt-3 w-full rounded border border-outline-variant px-3 py-2 font-data text-xs font-bold uppercase tracking-wide text-on-surface-variant hover:border-primary hover:text-primary disabled:cursor-not-allowed disabled:opacity-50"
          >
            ⟳ Test Spindle
          </button>
        </div>

        <%!-- Capture: legal only while :registering (Job.can?). --%>
        <button
          type="button"
          phx-click="capture_fiducial"
          disabled={not (@motors_online and can?(@job, :capture))}
          data-test="capture-fiducial"
          class="w-full rounded bg-primary-container px-4 py-3 font-sans text-sm font-bold uppercase tracking-wide text-on-primary-container hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
        >
          Capture Fiducial ({length(@captured_fiducials)}/{@fiducial_target})
        </button>

        <button
          type="button"
          phx-click="fit"
          disabled={not can?(@job, :fit)}
          data-test="fit-alignment"
          class="w-full rounded bg-surface-container-high px-4 py-2 font-sans text-sm font-bold uppercase tracking-wide text-on-surface hover:bg-surface-container-highest disabled:cursor-not-allowed disabled:opacity-50"
        >
          Fit Alignment
        </button>

        <%!-- Bail out and start the whole registration over (available from any
              align state: while capturing, after a fit, or when rejected). --%>
        <button
          :if={can?(@job, :restart_alignment)}
          type="button"
          phx-click="restart_alignment"
          data-test="restart-alignment"
          class="w-full rounded border border-outline-variant px-4 py-2 font-sans text-xs font-bold uppercase tracking-wide text-on-surface-variant hover:border-primary hover:text-primary"
        >
          ↺ Restart Alignment
        </button>

        <%!-- Quality / residual readout. --%>
        <div :if={@quality} data-test="quality" class="rounded-lg border border-outline-variant bg-surface-container p-4">
          <div class="flex items-center justify-between">
            <span class="font-data text-xs font-bold uppercase tracking-widest text-on-surface-variant">
              Est. Quality
            </span>
            <span class={["font-data text-lg font-bold", quality_color(@quality)]}>
              {@quality}% {quality_label(@quality)}
            </span>
          </div>
          <div class="mt-2 h-1 w-full overflow-hidden rounded bg-surface-container-highest">
            <div class={["h-full", quality_bar(@quality)]} style={"width: #{@quality}%;"}></div>
          </div>
          <p :if={@job.residuals} class="mt-2 font-data text-xs text-on-surface-variant" data-test="residuals">
            residual max {fmt(@job.residuals.max)} mm · rms {fmt(@job.residuals.rms)} mm
          </p>
        </div>

        <div
          :if={@rejected}
          data-test="alignment-rejected"
          class="rounded border border-error/50 bg-surface-container p-4 font-data text-sm text-error"
        >
          Alignment rejected — residual over tolerance. Recapture fiducials.
          <button
            type="button"
            phx-click="recapture"
            data-test="recapture"
            class="mt-3 w-full rounded bg-surface-container-high px-4 py-2 font-sans text-xs font-bold uppercase tracking-wide text-on-surface hover:bg-surface-container-highest"
          >
            Recapture
          </button>
        </div>

        <%!-- Proceed to dry-run: legal only while :aligned (Job.can?). NOT
             offered while merely registering/rejected — and there is no path
             that jumps straight to drilling. --%>
        <button
          type="button"
          phx-click="run_dry_run"
          disabled={not can?(@job, :run_dry_run)}
          data-test="proceed-dryrun"
          class="mt-auto w-full rounded bg-primary-container px-4 py-3 font-sans text-sm font-bold uppercase tracking-wide text-on-primary-container hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-50"
        >
          Proceed to Dry-run →
        </button>
      </aside>
    </div>
    """
  end

  attr :axis, :string, required: true
  attr :dir, :string, required: true
  attr :label, :string, required: true
  attr :enabled, :boolean, required: true

  defp jog_btn(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="jog"
      phx-value-axis={@axis}
      phx-value-dir={@dir}
      disabled={not @enabled}
      data-test={"jog-#{@axis}-#{@dir}"}
      class="rounded bg-surface-container-high px-2 py-2 font-data text-xs font-bold text-on-surface shadow-inner hover:bg-surface-container-highest disabled:cursor-not-allowed disabled:opacity-50"
    >
      {@label}
    </button>
    """
  end

  # ── Stage 3: Dry-run ───────────────────────────────────────────────────────

  defp stage_dryrun(assigns) do
    ~H"""
    <div class="flex h-full gap-4">
      <div class="relative flex-1 overflow-hidden rounded-lg border border-outline-variant">
        <.svelte name="BoardCanvas" props={canvas_props(assigns)} socket={@socket} />
        <span class="absolute left-4 top-4 rounded bg-surface-container/80 px-3 py-1 font-data text-xs font-bold uppercase tracking-widest text-primary">
          Dry-run · Spindle OFF
        </span>
      </div>

      <aside class="flex w-[360px] flex-none flex-col gap-4">
        <div>
          <h3 class="font-sans text-lg font-bold text-on-surface">Dry-run Rehearsal</h3>
          <p class="font-data text-xs text-on-surface-variant">
            The bit hovers over every hole, spindle off. Confirm the digital
            pattern lines up with the physical board before any real cut.
          </p>
        </div>

        <div :if={@progress} class="rounded-lg border border-outline-variant bg-surface-container p-4 font-data text-sm text-on-surface-variant">
          Traced {@progress.drilled}/{@progress.total} positions.
        </div>

        <button
          type="button"
          phx-click="redo_alignment"
          disabled={not can?(@job, :redo_alignment)}
          data-test="redo-alignment"
          class="w-full rounded bg-surface-container-high px-4 py-3 font-sans text-sm font-bold uppercase tracking-wide text-on-surface hover:bg-surface-container-highest disabled:opacity-50"
        >
          ← Redo Alignment
        </button>

        <%!-- The ONLY path to drilling. A two-step hazard-striped confirm. --%>
        <div
          class="mt-auto rounded-lg border border-error/40 bg-surface-container p-4"
          style={"background-image: #{hazard_bg()};"}
        >
          <p class="font-data text-xs font-bold uppercase tracking-widest text-on-surface-variant">
            Confirm registration
          </p>
          <p class="mt-1 font-data text-xs text-on-surface-variant">
            Starting the real run plunges the bit with the spindle on. This cannot
            be undone.
          </p>
          <button
            type="button"
            phx-click="confirm_registration"
            data-confirm="Start the REAL drill run? The spindle will engage."
            disabled={not can?(@job, :confirm_registration)}
            data-test="confirm-drill"
            class="mt-3 w-full rounded bg-error-container px-4 py-3 font-sans text-sm font-bold uppercase tracking-wide text-on-error-container hover:brightness-110 disabled:opacity-50"
          >
            Confirm Registration → Start Drilling
          </button>
        </div>
      </aside>
    </div>
    """
  end

  # ── Stage 4: Active Drilling ───────────────────────────────────────────────

  defp stage_drill(assigns) do
    assigns = assign(assigns, :pct, progress_pct(assigns.progress))

    ~H"""
    <div class="relative flex h-full gap-4">
      <div class="relative flex-1 overflow-hidden rounded-lg border border-outline-variant">
        <.svelte name="BoardCanvas" props={canvas_props(assigns)} socket={@socket} />

        <div class="pointer-events-none absolute inset-0 flex items-center justify-center">
          <div class="flex flex-col items-center gap-2 rounded-full bg-surface-container/80 p-10 backdrop-blur">
            <span class="font-sans text-4xl font-bold text-primary-container" data-test="progress-pct">
              {@pct}%
            </span>
            <span :if={@progress} class="font-data text-sm text-on-surface-variant" data-test="progress-count">
              {@progress.drilled} / {@progress.total}
            </span>
            <span class="animate-pulse font-data text-xs font-bold uppercase tracking-widest text-primary-container">
              Drilling in progress…
            </span>
          </div>
        </div>
      </div>

      <aside class="flex w-[280px] flex-none flex-col gap-4">
        <div class="rounded-lg border border-outline-variant bg-surface-container-high p-4">
          <p class="border-b border-outline-variant pb-1 font-data text-xs font-bold uppercase tracking-widest text-on-surface-variant">
            Telemetry
          </p>
          <.telemetry_row
            label="Current Bit"
            value={telemetry_value(@telemetry, :bit, bit_label(@diagnostic))}
            color="text-primary"
          />
          <.telemetry_row
            label="Est. Time Remaining"
            value={telemetry_value(@telemetry, :eta, "—")}
            color="text-secondary"
          />
          <.telemetry_row
            label="Spindle"
            value={telemetry_value(@telemetry, :spindle, "OFF · 0 RPM")}
            color="text-on-surface"
          />
        </div>

        <button
          type="button"
          phx-click="abort"
          data-test="abort-drilling"
          style={"background-image: #{hazard_bg()};"}
          class="w-full rounded border border-error bg-error-container px-4 py-4 font-sans text-sm font-bold uppercase tracking-wide text-on-error-container hover:brightness-110"
        >
          ⚠ Abort Drilling
        </button>

        <button
          :if={can?(@job, :complete) and is_nil(@bit_change)}
          type="button"
          phx-click="complete"
          data-test="complete-drilling"
          class="mt-auto w-full rounded bg-secondary-container px-4 py-3 font-sans text-sm font-bold uppercase tracking-wide text-on-secondary-container hover:brightness-110"
        >
          Mark Complete →
        </button>
      </aside>

      <%!-- Bit-change modal: the per-tool M0 pause surfaced as an overlay. --%>
      <div
        :if={@bit_change}
        data-test="bit-change-modal"
        class="absolute inset-0 z-[100] flex items-center justify-center bg-surface-dim/90 backdrop-blur-sm"
      >
        <div class="w-96 rounded-lg border-2 border-primary-container bg-surface-container p-8 text-center">
          <span class="text-5xl text-primary-container">⚠</span>
          <h3 class="mt-2 font-sans text-xl font-bold text-on-surface">Bit Change Required</h3>
          <p class="font-data text-xs font-bold uppercase tracking-widest text-primary-container">
            System Paused
          </p>
          <p class="mt-4 font-sans text-sm text-on-surface">
            Swap to <span class="font-bold">{@bit_change.diameter}mm</span> bit to continue.
          </p>
          <p class="mt-3 font-data text-xs text-error">
            Warning: do not move the board substrate during the change — alignment will be lost.
          </p>
          <button
            type="button"
            phx-click="resume_drilling"
            data-test="resume-drilling"
            class="mt-5 w-full rounded bg-primary-container px-4 py-3 font-sans text-sm font-bold uppercase tracking-wide text-on-primary-container hover:brightness-110"
          >
            ▶ Resume Drilling
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :color, :string, default: "text-on-surface"

  defp telemetry_row(assigns) do
    ~H"""
    <div class="mt-3">
      <p class="font-data text-[0.625rem] font-bold uppercase tracking-wider text-on-surface-variant">
        {@label}
      </p>
      <p class={["font-data text-lg font-bold", @color]}>{@value}</p>
    </div>
    """
  end

  # ── Stage 5: Completion ────────────────────────────────────────────────────

  defp stage_done(assigns) do
    ~H"""
    <div class="relative flex h-full items-center justify-center">
      <div class="absolute inset-0 opacity-40">
        <.svelte name="BoardCanvas" props={canvas_props(assigns)} socket={@socket} />
      </div>

      <div
        data-test="completion-card"
        class="relative z-10 w-[28rem] rounded-xl border border-outline-variant bg-surface-container p-8 text-center shadow-2xl"
      >
        <span class="text-6xl text-secondary">✓</span>
        <h2 class="mt-2 font-sans text-3xl font-bold text-primary">Drilling Complete</h2>

        <div :if={@summary} class="mt-6 grid grid-cols-2 gap-3 text-left">
          <.summary_cell label="Total Holes" value={@summary.total_holes} color="text-secondary" />
          <.summary_cell label="Total Time" value={@summary.total_time} color="text-on-surface" />
          <div class="col-span-2">
            <.summary_cell label="Bit Changes" value={@summary.bit_changes} color="text-on-surface" />
          </div>
        </div>

        <button
          type="button"
          phx-click="new_board"
          data-test="new-board"
          class="mt-6 w-full rounded bg-primary-container px-4 py-3 font-sans text-base font-bold uppercase tracking-wide text-on-primary-container hover:brightness-110"
        >
          + Start New Board
        </button>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :color, :string, default: "text-on-surface"

  defp summary_cell(assigns) do
    ~H"""
    <div class="rounded-lg border border-outline-variant bg-surface-dim p-3">
      <p class="font-data text-[0.625rem] font-bold uppercase tracking-wider text-on-surface-variant">
        {@label}
      </p>
      <p class={["font-data text-lg font-bold", @color]}>{@value}</p>
    </div>
    """
  end

  # ── Shared helpers / gate computations ─────────────────────────────────────

  # Build the live_svelte BoardCanvas props from the current job + capture state.
  # Holes are stored in board coords; the canvas fits them to view via the bbox.
  # The live head position is mapped back into board space (alignment inverse)
  # for the crosshair when a transform exists.
  defp canvas_props(%{job: %Job{} = job} = assigns) do
    %{
      holes: canvas_holes(job),
      outline: outline_pairs(job.board.outline),
      fiducials: assigns.captured_fiducials ++ pending_fiducials(assigns),
      tools: job.board.tools,
      bbox: bbox_list(job.board.bbox),
      head: head_in_board(assigns),
      head_confidence: head_confidence(assigns),
      stage: assigns.stage
    }
  end

  defp canvas_props(_assigns), do: %{holes: [], outline: nil, fiducials: [], tools: %{}}

  defp canvas_holes(%Job{} = job) do
    status = hole_status(job.state)
    Enum.map(job.board.holes, fn h -> %{x: h.x, y: h.y, tool: h.tool, status: status} end)
  end

  defp hole_status(state) when state in [:drilling, :done], do: "done"
  defp hole_status(_), do: "pending"

  # The un-captured candidates, each tagged by state: the operator's CURRENT
  # target (blinks) vs the rest (faded "pending"). Captured ones are carried
  # separately in `captured_fiducials`. Each carries its candidate index so the
  # canvas can emit click-to-select / click-to-jump events against it.
  defp pending_fiducials(%{job: %Job{} = job} = assigns) do
    captured_idx = MapSet.new(assigns.captured_fiducials, & &1.index)
    current = assigns.current_target

    job.board
    |> BlauDrillWeb.SessionLive.feature_candidates()
    |> Enum.with_index()
    |> Enum.reject(fn {_pt, i} -> MapSet.member?(captured_idx, i) end)
    |> Enum.map(fn {{x, y}, i} ->
      %{x: x, y: y, index: i, state: if(i == current, do: "current", else: "pending")}
    end)
  end

  defp outline_pairs(nil), do: nil
  defp outline_pairs(points), do: Enum.map(points, fn {x, y} -> [x, y] end)

  defp bbox_list({a, b, c, d}), do: [a, b, c, d]

  # The live head marker, mapped from machine space into board space — but the
  # mapping is only as trustworthy as the registration we have so far. We return
  # a `confidence` so the canvas can show HOW MUCH to trust the position:
  #
  #   nil          0 captures — machine ↔ board are unrelated, so a board
  #                position would be a fabrication. Show no in-board marker;
  #                the raw X/Y in the data bar is the honest readout.
  #   "estimate"   1 capture  — translation only (offset from the one pair).
  #   "rough"      2 captures — translation + rotation/scale (similarity fit).
  #   "aligned"    full %Alignment{} — the solved affine, fully trustworthy.
  #
  # The marker carries `confidence` for styling; head_confidence/1 surfaces it as
  # a top-level prop too.
  defp head_in_board(%{job: %Job{alignment: %BlauDrill.Alignment{transform: t}}, head: head}) do
    case BlauDrill.Transform2D.invert(t) do
      {:ok, inv} ->
        {bx, by} = BlauDrill.Transform2D.apply(inv, {head.x, head.y})
        %{x: bx, y: by, confidence: "aligned"}

      {:error, _} ->
        nil
    end
  end

  defp head_in_board(%{job: %Job{} = job, head: head}) do
    corrs = pending_correspondences(job)

    case estimate_board_point(corrs, {head.x, head.y}) do
      {bx, by, confidence} -> %{x: bx, y: by, confidence: confidence}
      :none -> nil
    end
  end

  defp head_in_board(_assigns), do: nil

  # Top-level confidence prop ("none" | "estimate" | "rough" | "aligned") for the
  # canvas to label/colour the marker even when head_in_board is nil.
  defp head_confidence(assigns) do
    case head_in_board(assigns) do
      %{confidence: c} -> c
      _ -> "none"
    end
  end

  defp pending_correspondences(%Job{pending: %BlauDrill.PendingAlignment{captured: c}}), do: c
  defp pending_correspondences(_), do: []

  # Build the best board-point estimate for a machine point from the captures so
  # far, returning {board_x, board_y, confidence} or :none.
  defp estimate_board_point([], _machine), do: :none

  # 1 capture → translation only: board ≈ machine + (board₁ − machine₁).
  defp estimate_board_point(
         [%BlauDrill.Correspondence{board: {bx, by}, machine: {mx, my}}],
         {hx, hy}
       ) do
    {hx + (bx - mx), hy + (by - my), "estimate"}
  end

  # 2+ captures (but no solved alignment yet) → similarity (translation + uniform
  # scale + rotation) from the first two pairs. Enough to confirm the board is
  # roughly where we think; full affine waits for the 3rd point and the fit.
  defp estimate_board_point([c1, c2 | _], {hx, hy}) do
    %{board: {b1x, b1y}, machine: {m1x, m1y}} = c1
    %{board: {b2x, b2y}, machine: {m2x, m2y}} = c2

    # Vector between the two machine points and the two board points.
    {mdx, mdy} = {m2x - m1x, m2y - m1y}
    {bdx, bdy} = {b2x - b1x, b2y - b1y}
    mlen2 = mdx * mdx + mdy * mdy

    if mlen2 < 1.0e-9 do
      # Degenerate (the two machine captures coincide) — fall back to translation.
      {hx + (b1x - m1x), hy + (b1y - m1y), "estimate"}
    else
      # Complex-number similarity: s = bd/md, applied to (head − m1) + b1.
      sr = (bdx * mdx + bdy * mdy) / mlen2
      si = (bdy * mdx - bdx * mdy) / mlen2
      {dx, dy} = {hx - m1x, hy - m1y}
      bx = b1x + (sr * dx - si * dy)
      by = b1y + (si * dx + sr * dy)
      {bx, by, "rough"}
    end
  end

  defp can?(nil, _event), do: false
  defp can?(%Job{} = job, event), do: Job.can?(job, event)

  defp faulted?(%Job{state: :faulted}), do: true
  defp faulted?(_), do: false

  defp motion_stage?(stage), do: stage in ["align", "dryrun", "drill"]

  defp motors_online?(:jogging), do: true
  defp motors_online?(_), do: false

  defp stepper_node_class(id, active, stages) do
    cond do
      id == active -> "bg-primary-container text-on-primary-container border-2 border-primary"
      stage_index(id, stages) < stage_index(active, stages) -> "bg-secondary text-on-secondary"
      true -> "border border-outline-variant bg-surface-container text-on-surface-variant"
    end
  end

  defp stage_index(id, stages) do
    Enum.find_index(stages, fn {sid, _} -> sid == id end) || 0
  end

  defp stage_done?(id, active) do
    order = ["load", "align", "dryrun", "drill", "done"]
    idx_id = Enum.find_index(order, &(&1 == id)) || 0
    idx_active = Enum.find_index(order, &(&1 == active)) || 0
    idx_id < idx_active
  end

  defp control_status(:jogging, _job), do: "Motors Live"
  defp control_status(:streaming, _job), do: "Streaming"
  defp control_status(:faulted, _job), do: "Faulted"
  defp control_status(_state, %Job{state: :drilling}), do: "Drilling…"
  defp control_status(_state, _job), do: "Machine Ready"

  defp connection_color(_status, :faulted), do: "text-error"
  defp connection_color(:connected, _), do: "text-secondary"
  defp connection_color(_, _), do: "text-on-surface-variant"

  defp connection_dot(_status, :faulted), do: "bg-error"
  defp connection_dot(:connected, _), do: "bg-secondary"
  defp connection_dot(_, _), do: "bg-outline"

  defp printer_label(:jogging, _), do: "MOTORS LIVE"
  defp printer_label(:streaming, _), do: "STREAMING"
  defp printer_label(:idle, _), do: "CONNECTED"
  defp printer_label(:faulted, _), do: "FAULTED"
  defp printer_label(:disconnected, _), do: "DISCONNECTED"
  defp printer_label(_, :connected), do: "CONNECTED"
  defp printer_label(_, _), do: "—"

  defp quality_percent(%Job{residuals: %{max: max}, tol: tol}) when is_number(max) and tol > 0 do
    pct = round(Kernel.max(0.0, 1.0 - max / (2 * tol)) * 100)
    pct |> Kernel.min(100) |> Kernel.max(0)
  end

  defp quality_percent(_), do: nil

  defp quality_label(pct) when pct >= 80, do: "GOOD"
  defp quality_label(pct) when pct >= 50, do: "FAIR"
  defp quality_label(_), do: "POOR"

  defp quality_color(pct) when pct >= 80, do: "text-secondary"
  defp quality_color(pct) when pct >= 50, do: "text-primary"
  defp quality_color(_), do: "text-error"

  defp quality_bar(pct) when pct >= 80, do: "bg-secondary"
  defp quality_bar(pct) when pct >= 50, do: "bg-primary-container"
  defp quality_bar(_), do: "bg-error"

  defp progress_pct(nil), do: 0
  defp progress_pct(%{drilled: d, total: t}) when t > 0, do: round(d / t * 100)
  defp progress_pct(_), do: 0

  defp bit_label(%{tools: tools}) when map_size(tools) > 0 do
    {_id, d} = Enum.min_by(tools, fn {_id, d} -> d end)
    "#{d}mm"
  end

  defp bit_label(_), do: "—"

  # Read a derived telemetry value (computed in SessionLive) with a fallback when
  # the panel renders before any telemetry is assigned.
  defp telemetry_value(telemetry, key, fallback) when is_map(telemetry) do
    case Map.get(telemetry, key) do
      v when is_binary(v) -> v
      _ -> fallback
    end
  end

  defp telemetry_value(_telemetry, _key, fallback), do: fallback

  defp fmt(v) when is_number(v), do: :erlang.float_to_binary(v * 1.0, decimals: 3)
  defp fmt(_), do: "0.000"

  defp fmt_step(1.0), do: "1.0"
  defp fmt_step(0.1), do: "0.1"
  defp fmt_step(10.0), do: "10"
  defp fmt_step(s), do: to_string(s)

  # Static hazard-stripe background, exposed to the templates via assign so the
  # E-STOP / ABORT / confirm controls share one definition.
  def hazard_bg, do: unquote(@hazard)
end
