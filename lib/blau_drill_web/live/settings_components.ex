defmodule BlauDrillWeb.SettingsComponents do
  @moduledoc """
  The HEEx render tree for `BlauDrillWeb.SettingsLive` — the Industrial Dark
  printer-configuration screen.

  Layout follows `docs/design_reference/printer_configuration_settings/code.html`:
  a top app bar (MAINTENANCE MODE), a fixed left category nav (Connection ·
  Motion Limits · Spindle Control · Defaults), a scrolling content canvas that
  shows the selected category's fields, and a fixed bottom action bar (Reset to
  Defaults · Apply Configuration).

  Stateless markup only; every value and validity flag is computed by
  `SettingsLive` from the working `BlauDrill.Config`.
  """
  use BlauDrillWeb, :html

  @doc "The whole settings page."
  attr :category, :string, required: true
  attr :categories, :list, required: true
  attr :form, :map, required: true
  attr :errors, :list, default: []
  attr :dirty, :boolean, default: false
  attr :config, :any, required: true
  attr :bauds, :list, required: true
  attr :pwm_maxes, :list, required: true
  attr :ports, :list, default: []
  attr :flash, :map, required: true

  def settings(assigns) do
    ~H"""
    <div class="flex h-screen flex-col overflow-hidden bg-background text-on-surface">
      <.top_bar />

      <div class="flex flex-1 overflow-hidden">
        <.category_nav category={@category} categories={@categories} />

        <form
          id="settings-form"
          phx-change="change"
          phx-submit="apply"
          class="flex flex-1 flex-col overflow-hidden bg-background"
        >
          <main class="relative flex-1 overflow-y-auto p-8">
            <div class="mx-auto max-w-4xl space-y-4 pb-32">
              <.category_panel
                category={@category}
                form={@form}
                errors={@errors}
                bauds={@bauds}
                pwm_maxes={@pwm_maxes}
                ports={@ports}
              />
            </div>
          </main>

          <.action_bar dirty={@dirty} valid={@errors == []} />
        </form>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  # ── Top app bar ─────────────────────────────────────────────────────────────

  defp top_bar(assigns) do
    ~H"""
    <header class="flex h-16 flex-none items-center justify-between border-b border-outline-variant bg-surface-container-high px-6">
      <div class="flex items-center gap-4">
        <BlauDrillWeb.SessionComponents.brand />
        <div class="h-6 w-px bg-outline-variant"></div>
        <span class="font-data text-sm text-on-surface-variant">SYSTEM CONFIGURATION</span>
      </div>

      <div class="flex items-center gap-4">
        <div class="flex items-center gap-2 rounded border border-outline-variant bg-surface-container px-3 py-1 font-data text-xs font-bold uppercase tracking-widest text-on-surface-variant">
          <span class="inline-block h-2 w-2 animate-pulse rounded-full bg-primary"></span>
          Maintenance Mode
        </div>
        <.link
          navigate={~p"/"}
          class="flex items-center gap-2 rounded border border-outline-variant px-3 py-2 font-data text-xs font-bold uppercase tracking-widest text-on-surface-variant hover:bg-surface-bright hover:text-on-surface"
          data-test="back-to-session"
        >
          ← Session
        </.link>
      </div>
    </header>
    """
  end

  # ── Left category nav ───────────────────────────────────────────────────────

  attr :category, :string, required: true
  attr :categories, :list, required: true

  defp category_nav(assigns) do
    ~H"""
    <nav class="flex w-80 flex-none flex-col border-r border-outline-variant bg-surface-container">
      <div class="border-b border-outline-variant p-6">
        <h2 class="font-sans text-2xl font-semibold text-primary">Printer Configuration</h2>
        <p class="mt-1 font-data text-sm text-on-surface-variant">Station Parameters</p>
      </div>

      <ul class="flex flex-1 flex-col gap-1 overflow-y-auto p-4">
        <li :for={{id, label, icon} <- @categories}>
          <button
            type="button"
            phx-click="select_category"
            phx-value-category={id}
            data-test={"nav-#{id}"}
            aria-current={id == @category && "page"}
            class={[
              "flex w-full items-center gap-3 rounded border-l-4 px-4 py-3 text-left transition-all",
              if(id == @category,
                do: "border-primary bg-primary-container text-on-primary-container",
                else:
                  "border-transparent text-on-surface-variant hover:bg-surface-container-highest hover:text-on-surface"
              )
            ]}
          >
            <span class="font-data text-xs font-bold uppercase tracking-widest">{label}</span>
          </button>
        </li>
      </ul>
    </nav>
    """
  end

  # ── Category panels ─────────────────────────────────────────────────────────

  attr :category, :string, required: true
  attr :form, :map, required: true
  attr :errors, :list, required: true
  attr :bauds, :list, required: true
  attr :pwm_maxes, :list, required: true
  attr :ports, :list, required: true

  defp category_panel(%{category: "connection"} = assigns) do
    ~H"""
    <.panel_header
      title="Connection Setup"
      subtitle="Configure serial communication parameters for the CNC controller."
    />

    <.card title="Serial Port">
      <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
        <.port_field form={@form} ports={@ports} errors={@errors} />

        <.select_field
          name="baud"
          label="Baud Rate"
          form={@form}
          errors={@errors}
          options={Enum.map(@bauds, &{Integer.to_string(&1), Integer.to_string(&1)})}
        />
      </div>

      <div class="mt-6 flex items-center gap-4 rounded border border-outline-variant bg-surface-container-lowest p-4">
        <.toggle
          name="auto_connect"
          on={truthy?(Map.get(@form, "auto_connect"))}
          event="toggle_auto_connect"
        />
        <div>
          <span class="block font-data text-sm text-on-surface">Auto-connect on startup</span>
          <span class="font-data text-xs uppercase tracking-widest text-on-surface-variant">
            Establish serial connection automatically when the system boots.
          </span>
        </div>
      </div>
    </.card>
    """
  end

  defp category_panel(%{category: "motion"} = assigns) do
    ~H"""
    <.panel_header
      title="Motion Limits"
      subtitle="Maximum travel per axis (mm). These prevent mechanical crashes — operator/hardware settings."
    />

    <.card title="Travel Envelope">
      <div class="grid grid-cols-1 gap-6 md:grid-cols-3">
        <.number_field name="max_x" label="X Max (mm)" form={@form} errors={@errors} step="0.01" />
        <.number_field name="max_y" label="Y Max (mm)" form={@form} errors={@errors} step="0.01" />
        <.number_field name="max_z" label="Z Max (mm)" form={@form} errors={@errors} step="0.01" />
      </div>
    </.card>
    """
  end

  defp category_panel(%{category: "spindle"} = assigns) do
    ~H"""
    <.panel_header
      title="Spindle Control"
      subtitle="G-code commands and PWM range to support varied spindle controllers."
    />

    <.card title="Spindle G-code">
      <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
        <.text_field
          name="spindle_on"
          label="Spindle-on Command"
          form={@form}
          errors={@errors}
          placeholder="M3 S255"
        />
        <.text_field
          name="spindle_off"
          label="Spindle-off Command"
          form={@form}
          errors={@errors}
          placeholder="M5"
        />
      </div>
    </.card>

    <.card title="PWM Range">
      <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
        <.select_field
          name="pwm_max"
          label="PWM Full Scale"
          form={@form}
          errors={@errors}
          options={Enum.map(@pwm_maxes, &{Integer.to_string(&1), "0–" <> Integer.to_string(&1)})}
        />
        <.number_field
          name="spindle_speed"
          label={"Spindle Speed (0–#{@form["pwm_max"]} duty)"}
          form={@form}
          errors={@errors}
          step="1"
        />
      </div>

      <%!-- Self-documenting summary so the operator can see, at a glance, exactly
            what will be sent and the valid range. --%>
      <div
        data-test="spindle-summary"
        class="mt-4 rounded border border-outline-variant bg-surface-container-lowest p-3 font-data text-xs text-on-surface-variant"
      >
        <div>
          Start: <span class="text-primary">{@form["spindle_on"]}</span>
          · Stop: <span class="text-primary">{@form["spindle_off"]}</span>
        </div>
        <div class="mt-1">
          Duty range: <span class="text-primary">0–{@form["pwm_max"]}</span>
          · Current: <span class="text-primary">{@form["spindle_speed"]}</span>
        </div>
        <p class="mt-2 text-on-surface-variant/70">
          Test the spindle from the Align stage (motors must be energized).
        </p>
      </div>
    </.card>
    """
  end

  defp category_panel(%{category: "defaults"} = assigns) do
    ~H"""
    <.panel_header
      title="Drilling Defaults"
      subtitle="Tuned Z heights and feeds the G-code generator uses (operator-tunable)."
    />

    <.card title="Z Reference Heights (mm)">
      <div class="grid grid-cols-1 gap-6 md:grid-cols-3">
        <.number_field name="zdrill" label="zdrill (plunge)" form={@form} errors={@errors} step="0.1" />
        <.number_field name="zsafe" label="zsafe (travel)" form={@form} errors={@errors} step="0.1" />
        <.number_field
          name="zchange"
          label="zchange (bit change)"
          form={@form}
          errors={@errors}
          step="0.1"
        />
      </div>
    </.card>

    <.card title="Feed & Hover">
      <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
        <.number_field
          name="drill_feed"
          label="Drill Feed (mm/min)"
          form={@form}
          errors={@errors}
          step="1"
        />
        <.number_field name="hover" label="Dry-run Hover (mm)" form={@form} errors={@errors} step="0.1" />
      </div>
    </.card>
    """
  end

  # ── Shared building blocks ──────────────────────────────────────────────────

  attr :title, :string, required: true
  attr :subtitle, :string, required: true

  defp panel_header(assigns) do
    ~H"""
    <div class="mb-8 border-b border-outline-variant pb-4">
      <h1 class="font-sans text-3xl font-bold text-on-surface">{@title}</h1>
      <p class="mt-2 font-sans text-base text-on-surface-variant">{@subtitle}</p>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <div class="rounded-lg border border-outline-variant bg-surface-container-high p-6">
      <h3 class="mb-4 font-data text-lg font-semibold uppercase tracking-widest text-primary">
        {@title}
      </h3>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :form, :map, required: true
  attr :errors, :list, required: true
  attr :step, :string, default: "any"

  defp number_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <.field_label label={@label} />
      <input
        type="number"
        step={@step}
        name={"config[#{@name}]"}
        value={Map.get(@form, @name)}
        data-test={"field-#{@name}"}
        class={input_class(@errors, @name)}
      />
      <.field_error errors={@errors} name={@name} />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :form, :map, required: true
  attr :errors, :list, required: true
  attr :placeholder, :string, default: nil

  defp text_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <.field_label label={@label} />
      <input
        type="text"
        name={"config[#{@name}]"}
        value={Map.get(@form, @name)}
        placeholder={@placeholder}
        data-test={"field-#{@name}"}
        class={input_class(@errors, @name)}
      />
      <.field_error errors={@errors} name={@name} />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :form, :map, required: true
  attr :errors, :list, required: true
  attr :options, :list, required: true

  defp select_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <.field_label label={@label} />
      <div class="relative">
        <select
          name={"config[#{@name}]"}
          data-test={"field-#{@name}"}
          class={[input_class(@errors, @name), "cursor-pointer appearance-none pr-10"]}
        >
          <option
            :for={{value, text} <- @options}
            value={value}
            selected={to_string(Map.get(@form, @name)) == value}
          >
            {text}
          </option>
        </select>
        <span class="pointer-events-none absolute right-3 top-3 text-on-surface-variant">▾</span>
      </div>
      <.field_error errors={@errors} name={@name} />
    </div>
    """
  end

  attr :form, :map, required: true
  attr :ports, :list, required: true
  attr :errors, :list, required: true

  # Port: a dropdown of enumerated ports when any are detected, else free-text.
  defp port_field(%{ports: []} = assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <.field_label label="Port Identifier" />
      <input
        type="text"
        name="config[port]"
        value={Map.get(@form, "port")}
        placeholder="/dev/ttyUSB0"
        data-test="field-port"
        class={input_class(@errors, "port")}
      />
      <.field_error errors={@errors} name="port" />
    </div>
    """
  end

  defp port_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <.field_label label="Port Identifier" />
      <div class="relative">
        <select
          name="config[port]"
          data-test="field-port"
          class={[input_class(@errors, "port"), "cursor-pointer appearance-none pr-10"]}
        >
          <option value="">— select port —</option>
          <option :for={port <- @ports} value={port} selected={Map.get(@form, "port") == port}>
            {port}
          </option>
        </select>
        <span class="pointer-events-none absolute right-3 top-3 text-on-surface-variant">▾</span>
      </div>
      <.field_error errors={@errors} name="port" />
    </div>
    """
  end

  attr :label, :string, required: true

  defp field_label(assigns) do
    ~H"""
    <label class="font-data text-xs font-bold uppercase tracking-widest text-on-surface-variant">
      {@label}
    </label>
    """
  end

  attr :errors, :list, required: true
  attr :name, :string, required: true

  defp field_error(assigns) do
    ~H"""
    <p
      :if={msg = error_for(@errors, @name)}
      data-test={"error-#{@name}"}
      class="font-data text-xs text-error"
    >
      {msg}
    </p>
    """
  end

  attr :name, :string, required: true
  attr :on, :boolean, required: true
  attr :event, :string, required: true

  defp toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      role="switch"
      aria-checked={to_string(@on)}
      data-test={"toggle-#{@name}"}
      class={[
        "relative inline-flex h-6 w-11 flex-none items-center rounded-full transition-colors",
        if(@on, do: "bg-primary", else: "bg-surface-variant")
      ]}
    >
      <input type="hidden" name={"config[#{@name}]"} value={to_string(@on)} />
      <span class={[
        "inline-block h-5 w-5 transform rounded-full bg-white transition-transform",
        if(@on, do: "translate-x-5", else: "translate-x-0.5")
      ]}>
      </span>
    </button>
    """
  end

  # ── Bottom action bar ───────────────────────────────────────────────────────

  attr :dirty, :boolean, required: true
  attr :valid, :boolean, required: true

  defp action_bar(assigns) do
    ~H"""
    <div class="flex flex-none items-center justify-between border-t border-outline-variant bg-surface-container-high p-6">
      <button
        type="button"
        phx-click="reset"
        data-test="reset-defaults"
        class="flex items-center gap-2 rounded border border-outline-variant px-6 py-3 font-data text-xs font-bold uppercase tracking-widest text-on-surface transition-colors hover:border-error-container hover:bg-error-container hover:text-on-error-container"
      >
        ⟲ Reset to Defaults
      </button>

      <div class="flex items-center gap-4">
        <span
          :if={@dirty}
          data-test="dirty-indicator"
          class="font-data text-sm text-on-surface-variant"
        >
          Unsaved changes detected
        </span>
        <button
          type="submit"
          disabled={not @valid}
          data-test="apply-config"
          class={[
            "flex items-center gap-2 rounded px-8 py-3 font-data text-xs font-bold uppercase tracking-widest transition-all",
            if(@valid,
              do: "bg-primary text-on-primary hover:bg-primary-fixed hover:text-on-primary-fixed",
              else: "cursor-not-allowed bg-surface-variant text-on-surface-variant opacity-60"
            )
          ]}
        >
          ⤓ Apply Configuration
        </button>
      </div>
    </div>
    """
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp input_class(errors, name) do
    [
      "w-full rounded border bg-surface-container-lowest px-4 py-3 font-data text-sm text-on-surface focus:outline-none",
      if(error_for(errors, name),
        do: "border-error focus:border-error",
        else: "border-outline-variant focus:border-primary"
      )
    ]
  end

  defp error_for(errors, name) do
    key = if is_atom(name), do: name, else: String.to_existing_atom(name)
    Keyword.get(errors, key)
  rescue
    ArgumentError -> nil
  end

  defp truthy?("true"), do: true
  defp truthy?(true), do: true
  defp truthy?("on"), do: true
  defp truthy?(_), do: false
end
