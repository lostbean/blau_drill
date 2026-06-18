defmodule BlauDrillWeb.SessionTelemetryTest do
  @moduledoc """
  Telemetry-derivation tests for the drilling stage. These assert that the
  Spindle and Est. Time Remaining readouts are **derived from the session's
  Config snapshot** — not the retired hardcoded "12,000" / "—" placeholders.

  Run `async: false` because they apply a custom `BlauDrill.Config` into the
  global application environment (which a session snapshots at mount); exclusive
  access keeps the snapshot deterministic regardless of other config-touching
  tests.
  """
  use BlauDrillWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BlauDrill.Config
  alias BlauDrill.PrinterConnection
  alias BlauDrill.PrinterConnection.UART.Sim

  @fixture Path.expand("../../support/fixtures/segby_v1.drl", __DIR__)
  @candidates [{-81.28, 16.256}, {-0.254, 2.54}, {-8.89, 80.01}, {-81.28, 64.77}]

  setup do
    saved = Application.get_env(:blau_drill, Config)
    on_exit(fn -> restore(saved) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:blau_drill, Config)
  defp restore(v), do: Application.put_env(:blau_drill, Config, v)

  defp with_printer(conn) do
    {:ok, sim} = Sim.start_handle(ack_delay_ms: 0)
    name = :"telem_printer_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PrinterConnection.start_link(
        uart: Sim,
        handle: sim,
        port: "sim",
        settle_ms: 0,
        name: name
      )

    {Phoenix.LiveViewTest.put_connect_params(conn, %{"conn_name" => Atom.to_string(name)}), name}
  end

  defp upload_fixture(view) do
    drl =
      file_input(view, "#upload-form", :drl, [
        %{name: "segby_v1.drl", content: File.read!(@fixture), type: "text/plain"}
      ])

    render_upload(drl, "segby_v1.drl")
    render_submit(element(view, "#upload-form"))
  end

  defp jog_to(view, name, {tx, ty}) do
    {:ok, {x, y, _z}} = PrinterConnection.where(name)
    jog_axis(view, "x", tx - x)
    jog_axis(view, "y", ty - y)
  end

  defp jog_axis(view, axis, delta) do
    if Float.round(delta * 1.0, 3) != 0.0 do
      dir = if delta >= 0, do: "+", else: "-"
      step = Float.round(abs(delta) * 1.0, 3)
      render_hook(view, "set_jog_step", %{"step" => Float.to_string(step)})
      render_hook(view, "jog", %{"axis" => axis, "dir" => dir})
    end

    :ok
  end

  defp to_drilling(view, name) do
    upload_fixture(view)
    render_click(element(view, "[data-test='proceed-align']"))
    render_click(element(view, "[data-test='motors-toggle']"))

    Enum.each(@candidates, fn target ->
      jog_to(view, name, target)
      render_click(element(view, "[data-test='capture-fiducial']"))
    end)

    render_click(element(view, "[data-test='fit-alignment']"))
    render_click(element(view, "[data-test='proceed-dryrun']"))
    render_click(element(view, "[data-test='confirm-drill']"))
  end

  test "drilling spindle telemetry is config-derived (PWM duty + mapped RPM), not 12,000",
       %{conn: conn} do
    # A NON-default spindle speed must appear verbatim, proving config-derivation.
    {:ok, custom} =
      Config.new(%{
        "spindle_speed" => "200",
        "pwm_max" => "255",
        "spindle_max_rpm" => "10000"
      })

    :ok = Config.apply(custom)

    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_drilling(view, name)
    html = render(view)

    # rpm = round(200/255 * 10000) = 7843; PWM duty shown as commanded.
    assert html =~ "PWM 200/255"
    assert html =~ "7,843 RPM"
    refute html =~ "12,000"
  end

  test "drilling Est. Time Remaining is a derived mm:ss, not the '—' placeholder",
       %{conn: conn} do
    {:ok, custom} = Config.new(%{"drill_feed" => "120", "zdrill" => "-3.0", "zsafe" => "5.0"})
    :ok = Config.apply(custom)

    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_drilling(view, name)
    html = render(view)

    assert html =~ "Est. Time Remaining"

    # The value is a real mm:ss (remaining holes × per-hole time): find the
    # mm:ss-shaped value rendered after the label, asserting it exists (the old
    # placeholder was a bare "—", which has no mm:ss form).
    {label, value} =
      html
      |> String.split("Est. Time Remaining", parts: 2)
      |> then(fn [before, rest] -> {before, String.slice(rest, 0, 400)} end)

    assert label =~ "Telemetry"
    assert value =~ ~r/\d+:\d\d/, "expected a mm:ss ETA next to the label"
  end

  test "estimate_remaining_seconds/2 scales with remaining holes and per-hole time" do
    # Pure derivation: linear in both inputs, clamps negative holes to zero.
    assert BlauDrillWeb.SessionLive.estimate_remaining_seconds(0, 2.0) == 0.0
    assert BlauDrillWeb.SessionLive.estimate_remaining_seconds(10, 2.0) == 20.0
    # Twice the holes → twice the time.
    assert BlauDrillWeb.SessionLive.estimate_remaining_seconds(20, 2.0) == 40.0
    # Twice the per-hole time → twice the time.
    assert BlauDrillWeb.SessionLive.estimate_remaining_seconds(10, 4.0) == 40.0
    # Negative remaining clamps to 0.
    assert BlauDrillWeb.SessionLive.estimate_remaining_seconds(-5, 2.0) == 0.0
  end
end
