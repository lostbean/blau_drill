defmodule BlauDrillWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  These are deliberately minimal building blocks for the early scaffold —
  flash notices, a gated button, a text input, and a header. They are styled
  with plain Tailwind utilities mapped onto the **Industrial Dark** design
  tokens (see `assets/css/app.css`). The full five-stage operator UI (jog
  controls, hazard-striped gated actions, status badges, PCB canvas) will be
  built out on top of these later.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-4 right-4 z-50 w-80 max-w-sm rounded-lg border p-4 font-sans text-sm shadow-lg",
        @kind == :info && "border-secondary/40 bg-surface-container text-on-surface",
        @kind == :error && "border-error/50 bg-surface-container text-error"
      ]}
      {@rest}
    >
      <p :if={@title} class="mb-1 font-semibold">{@title}</p>
      <p>{msg}</p>
      <button
        type="button"
        class="absolute top-2 right-2 opacity-50 hover:opacity-100"
        aria-label="close"
      >
        &times;
      </button>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="Connection lost"
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        Attempting to reconnect…
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong"
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        Attempting to reconnect…
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a button.

  Critical, machine-moving actions (jog, drill, spindle) must layer an explicit
  safety gate on top of this primitive — never auto-enable motion.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :variant, :string, default: nil, values: [nil, "primary", "danger"]
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      nil => "bg-surface-container-high text-on-surface hover:bg-surface-container-highest",
      "primary" => "bg-primary-container text-on-primary-container hover:brightness-110",
      "danger" => "bg-error-container text-on-error-container hover:brightness-110"
    }

    assigns = assign(assigns, :class, [variants[assigns[:variant]], assigns.class])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link
        class={[
          "inline-flex items-center justify-center rounded px-4 py-2 font-sans text-sm font-semibold transition",
          @class
        ]}
        {@rest}
      >
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button
        class={[
          "inline-flex items-center justify-center rounded px-4 py-2 font-sans text-sm font-semibold transition disabled:opacity-50 disabled:cursor-not-allowed",
          @class
        ]}
        {@rest}
      >
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders a simple text/number input with a label.

  Coordinate entry uses the monospaced (data) font per the design system.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField, doc: "a form field struct, e.g. @form[:name]"
  attr :errors, :list, default: []
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(autocomplete disabled max maxlength min minlength
                                    pattern placeholder readonly required step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <label
        :if={@label}
        for={@id}
        class="font-data text-xs font-bold uppercase tracking-wider text-on-surface-variant"
      >
        {@label}
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "rounded border border-outline-variant bg-surface-container-lowest px-3 py-2 font-data text-sm text-on-surface",
          "focus:border-primary-container focus:outline-none focus:ring-1 focus:ring-primary-container",
          @errors != [] && "border-error",
          @class
        ]}
        {@rest}
      />
      <p :for={msg <- @errors} class="font-sans text-xs text-error">{msg}</p>
    </div>
    """
  end

  @doc """
  Renders a header with a title and optional subtitle/actions.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={["flex items-center justify-between gap-6 pb-4", @class]}>
      <div>
        <h1 class="font-sans text-2xl font-semibold leading-8 text-on-surface">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 font-sans text-sm text-on-surface-variant">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  ## JS Commands

  @doc "Show an element via a JS transition."
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-out duration-200", "opacity-0 translate-y-2",
         "opacity-100 translate-y-0"}
    )
  end

  @doc "Hide an element via a JS transition."
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all ease-in duration-150", "opacity-100 translate-y-0",
         "opacity-0 translate-y-2"}
    )
  end

  @doc """
  Translates an error message using gettext, or falls back to plain
  interpolation. This scaffold ships without gettext, so we interpolate
  the raw options directly.
  """
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc "Translates the errors for a field from a keyword list of errors."
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
