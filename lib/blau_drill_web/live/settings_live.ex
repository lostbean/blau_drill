defmodule BlauDrillWeb.SettingsLive do
  @moduledoc """
  The printer **configuration / settings** screen (route `/settings`).

  A separate route from the five-stage `SessionLive`: a left category nav
  (Connection · Motion Limits · Spindle Control · Defaults), a main content area
  that renders the selected category's fields, and a fixed bottom action bar
  (Reset to Defaults · Apply Configuration). Industrial Dark theme, matching
  `docs/design_reference/printer_configuration_settings/code.html`.

  ## What this screen edits, and what "Apply" means

  This LiveView holds a **working** `%BlauDrill.Config{}` in assigns and edits it
  live (validating on every change). It does **not** mutate any running drilling
  session. On **Apply Configuration**, the working config is validated and, if
  valid, written via `BlauDrill.Config.apply/1` into the application environment
  — the slot that `SessionLive.mount/3` snapshots from. So:

    * **Apply updates what a *new* session will use.** The next time the operator
      loads a board on `/`, that session snapshots this config (the "resolve
      once" rule, architecture §02) and threads it into `GcodeProgram.build/3`
      opts and the `PrinterConnection` connect params for the whole run.
    * **A session already in flight is untouched** — it captured its own
      immutable snapshot at mount, so changing a setting here can never alter a
      stream that is already streaming.

  ## Reset to Defaults

  Restores the working config to `BlauDrill.Config.default/0` (the safe generic
  fallbacks). It does not itself apply — the operator still presses Apply to make
  it the next session's config.

  No motion happens here; this is a pure form. The serial port list is best-effort
  enumerated from `Circuits.UART.enumerate/0` when available, falling back to a
  free-text input so an operator can always type a device path.
  """
  use BlauDrillWeb, :live_view

  alias BlauDrill.Config

  @categories [
    {"connection", "Connection", "usb"},
    {"motion", "Motion Limits", "open_with"},
    {"spindle", "Spindle Control", "manufacturing"},
    {"defaults", "Defaults", "restore_page"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    config = Config.current()

    {:ok,
     socket
     |> assign(:page_title, "Printer Configuration")
     |> assign(:categories, @categories)
     |> assign(:category, "connection")
     |> assign(:bauds, Config.bauds())
     |> assign(:pwm_maxes, Config.pwm_maxes())
     |> assign(:ports, available_ports())
     |> set_config(config, dirty: false)}
  end

  # ── Events ──────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_category", %{"category" => category}, socket) do
    {:noreply, assign(socket, :category, category)}
  end

  # Live edit of any field. The form posts the whole working config as strings;
  # we re-coerce + re-validate, keeping the (string) form values for the inputs
  # and the typed errors for inline feedback.
  def handle_event("change", %{"config" => params}, socket) do
    {:noreply, set_form(socket, params)}
  end

  # Toggle (the checkbox doesn't always round-trip through "change" cleanly with
  # the rest of the form, so give it its own event).
  def handle_event("toggle_auto_connect", _params, socket) do
    params = Map.update(socket.assigns.form, "auto_connect", "true", &flip_bool/1)
    {:noreply, set_form(socket, params)}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, set_config(socket, Config.default(), dirty: true)}
  end

  def handle_event("apply", %{"config" => params}, socket) do
    case Config.new(params) do
      {:ok, config} ->
        :ok = Config.apply(config)

        {:noreply,
         socket
         |> set_config(config, dirty: false)
         |> put_flash(:info, "Configuration applied. New sessions will use these settings.")}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:form, params |> stringify() |> Map.merge(socket.assigns.form))
         |> assign(:errors, errors)
         |> assign(:dirty, true)
         |> put_flash(:error, "Cannot apply: fix the highlighted fields.")}
    end
  end

  # ── Internal ────────────────────────────────────────────────────────────────

  # Set both the typed working config (for the action-bar validity) and the
  # string form map (for the inputs), from a known-good Config.
  defp set_config(socket, %Config{} = config, opts) do
    socket
    |> assign(:config, config)
    |> assign(:form, to_form_map(config))
    |> assign(:errors, [])
    |> assign(:dirty, Keyword.get(opts, :dirty, true))
  end

  # Re-coerce + re-validate from raw form params; keep the raw strings in the
  # inputs so the operator sees exactly what they typed, surface typed errors.
  defp set_form(socket, params) do
    params = stringify(params)

    {config, errors} =
      case Config.new(params) do
        {:ok, config} -> {config, []}
        {:error, errors} -> {socket.assigns.config, errors}
      end

    socket
    |> assign(:config, config)
    |> assign(:form, params)
    |> assign(:errors, errors)
    |> assign(:dirty, true)
  end

  # A Config -> string-keyed form map for the HTML inputs.
  defp to_form_map(%Config{} = c) do
    %{
      "port" => c.port || "",
      "baud" => Integer.to_string(c.baud),
      "auto_connect" => to_string(c.auto_connect),
      "max_x" => num(c.max_x),
      "max_y" => num(c.max_y),
      "max_z" => num(c.max_z),
      "spindle_on" => c.spindle_on,
      "spindle_off" => c.spindle_off,
      "pwm_max" => Integer.to_string(c.pwm_max),
      "spindle_speed" => Integer.to_string(c.spindle_speed),
      "zdrill" => num(c.zdrill),
      "zsafe" => num(c.zsafe),
      "zchange" => num(c.zchange),
      "drill_feed" => num(c.drill_feed),
      "hover" => num(c.hover)
    }
  end

  defp stringify(params) do
    Map.new(params, fn {k, v} -> {to_string(k), v} end)
  end

  defp num(v) when is_integer(v), do: Integer.to_string(v)
  defp num(v) when is_float(v), do: :erlang.float_to_binary(v, [:compact, decimals: 2])
  defp num(v), do: to_string(v)

  defp flip_bool("true"), do: "false"
  defp flip_bool(_), do: "true"

  # Best-effort serial port enumeration. Circuits.UART.enumerate/0 returns a map
  # of port => info; if the NIF isn't available (or errors), fall back to nil so
  # the UI offers a free-text input instead.
  defp available_ports do
    if Code.ensure_loaded?(Circuits.UART) and function_exported?(Circuits.UART, :enumerate, 0) do
      try do
        Circuits.UART.enumerate() |> Map.keys() |> Enum.sort()
      rescue
        _ -> []
      catch
        _, _ -> []
      end
    else
      []
    end
  end

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    BlauDrillWeb.SettingsComponents.settings(assigns)
  end
end
