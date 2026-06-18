defmodule BlauDrillWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use BlauDrillWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout: a high-contrast industrial shell wrapping page content.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main class="min-h-screen bg-background text-on-surface">
      <div class="mx-auto max-w-5xl px-6 py-8">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end
end
