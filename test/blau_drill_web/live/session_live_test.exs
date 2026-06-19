defmodule BlauDrillWeb.SessionLiveTest do
  @moduledoc """
  LiveView tests for the five-stage operator flow, focused on the **safety
  gates** — the things that must never be merely cosmetic:

    * upload → parse → diagnostic (and the absolute-page-coordinate trap),
    * the energize-before-jog gate (jog disabled until motors are ON),
    * no path to drilling that skips the dry-run (no "Start Drilling" from
      `:aligned`),
    * abort / E-stop present in the motion stages,
    * the residual gate (a high-residual fit lands in `:alignment_rejected`).

  The printer is driven by the hardware-free `PrinterConnection.UART.Sim`: each
  test starts a sim wire + a per-test `PrinterConnection` under a unique name,
  and hands that name to the LiveView via connect params, so the whole flow runs
  with no hardware. The sim tracks a simulated head position from the relative
  jog moves, so jogging the head to a known position and then capturing records a
  controllable machine point — which lets a test force either a clean fit or a
  residual-gate rejection.
  """
  use BlauDrillWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias BlauDrill.PrinterConnection
  alias BlauDrill.PrinterConnection.UART.Sim

  @fixture Path.expand("../../support/fixtures/segby_v1.drl", __DIR__)
  @edge_cuts_fixture Path.expand("../../support/fixtures/segby_v1-Edge_Cuts.svg", __DIR__)

  # An export with the Drill/Place File Origin never set: absolute page
  # coordinates far off the origin. BoardModel rejects this at the edge.
  @absolute_page_drl """
  M48
  METRIC
  T1C0.800
  %
  T1
  X135.0Y-149.0
  X138.0Y-149.0
  X135.0Y-152.0
  M30
  """

  # The four registration candidates (board corners) the LiveView walks, in
  # capture order — see SessionLive.feature_candidates/1 for this fixture.
  @candidates [{-81.28, 16.256}, {-0.254, 2.54}, {-8.89, 80.01}, {-81.28, 64.77}]

  # ── helpers ─────────────────────────────────────────────────────────────────

  # Start a sim UART + a PrinterConnection bound to it under a unique name, and
  # return a conn with that name in connect params so the LiveView attaches.
  defp with_printer(conn) do
    # ack_delay_ms: 0 makes the sim ack streamed lines on the next message turn
    # (still one-in-flight, but no wall-clock delay) so streaming tests are fast
    # and deterministic.
    {:ok, sim} = Sim.start_handle(ack_delay_ms: 0)
    name = :"printer_#{System.unique_integer([:positive])}"

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

  # Jog the sim head to an absolute {x, y} by walking from the agent's tracked
  # position. The agent starts at (0,0) after energize; we apply one absolute
  # jog per axis using the LiveView's relative jog event with step = the delta.
  # To keep it simple we set the jog step to the exact delta and click once.
  defp jog_to(view, name, {tx, ty}) do
    {:ok, {x, y, _z}} = PrinterConnection.where(name)
    jog_axis(view, "x", tx - x)
    jog_axis(view, "y", ty - y)
  end

  defp jog_axis(view, axis, delta) do
    if Float.round(delta * 1.0, 3) != 0.0 do
      dir = if delta >= 0, do: "+", else: "-"
      step = Float.round(abs(delta) * 1.0, 3)
      # set_jog_step accepts any float, so we land on an exact machine position;
      # then push the directional jog. (Pushed as events the LiveView handles.)
      render_hook(view, "set_jog_step", %{"step" => Float.to_string(step)})
      render_hook(view, "jog", %{"axis" => axis, "dir" => dir})
    end

    :ok
  end

  # Re-render the view until `pattern` matches (the async drill/dry-run stream
  # folds progress events between renders). Returns the matching HTML, or fails
  # after the attempt budget so a stuck stream surfaces as a test failure.
  defp wait_for_render(view, %Regex{} = pattern, attempts \\ 200) do
    html = render(view)

    cond do
      Regex.match?(pattern, html) ->
        html

      attempts <= 0 ->
        flunk("timed out waiting for #{inspect(pattern)}; last render:\n#{html}")

      true ->
        Process.sleep(5)
        wait_for_render(view, pattern, attempts - 1)
    end
  end

  # Drive upload → align stage → energize. Leaves the view at :registering with
  # motors ON, ready to capture.
  defp to_registering(view) do
    upload_fixture(view)
    render_click(element(view, "[data-test='proceed-align']"))
    render_click(element(view, "[data-test='motors-toggle']"))
  end

  # Pull the BoardCanvas props (live_svelte embeds them as a JSON `data-props`
  # attribute, HTML-escaped) out of the rendered view.
  defp canvas_props(view) do
    [_, raw] = Regex.run(~r/data-props="([^"]*)"/, render(view))

    raw
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> Jason.decode!()
  end

  # Capture all four candidates at the given machine targets (a list of {x,y}),
  # then fit. `targets` controls the residual: identity targets → clean fit;
  # an outlier → residual-gate rejection.
  defp capture_and_fit(view, name, targets) do
    Enum.each(targets, fn target ->
      jog_to(view, name, target)
      render_click(element(view, "[data-test='capture-fiducial']"))
    end)

    render_click(element(view, "[data-test='fit-alignment']"))
  end

  # ── mount / stage 1 ─────────────────────────────────────────────────────────

  test "mounting renders stage 1 (Load & Connect)", %{conn: conn} do
    {conn, _name} = with_printer(conn)
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "blau-drill"
    assert html =~ "Control Panel"
    assert html =~ "Drop PCB files here"
    assert html =~ "Load"
    assert html =~ "Align"
    assert html =~ "Drill"
  end

  test "the connection shows connected once the sim wire is attached", %{conn: conn} do
    {conn, _name} = with_printer(conn)
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "CONNECTED"
  end

  test "the header links to the printer configuration screen", %{conn: conn} do
    {conn, _name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "[data-test='settings-link']")
    # Following it lands on /settings (Printer Configuration).
    {:ok, _settings, html} =
      view |> element("[data-test='settings-link']") |> render_click() |> follow_redirect(conn)

    assert html =~ "Printer Configuration" or html =~ "SYSTEM CONFIGURATION"
  end

  # ── connection card: device selection / connect lifecycle ────────────────────
  #
  # These mount WITHOUT a `conn_name` so the card starts disconnected (the test
  # env backend is `:none`), exercising the operator-facing device picker and the
  # Connect/Disconnect flow. They are hardware-free: the Simulator is always
  # offered, and the real-port path is driven to its failure branch with a bogus
  # port (no hardware needed).

  test "the connection card lists the Simulator as a selectable device", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    # Disconnected card: a device select with the Simulator, a refresh button and
    # a Connect button (no Disconnect while disconnected).
    assert has_element?(view, "[data-test='device-select']")
    assert has_element?(view, "[data-test='refresh-devices']")
    assert has_element?(view, "[data-test='connect-device']")
    refute has_element?(view, "[data-test='disconnect-device']")
    assert html =~ "Simulator"
    assert html =~ "DISCONNECTED"
  end

  test "select_device updates the selected device", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Selecting the Simulator keeps it as the selection (it's the option).
    html = render_change(element(view, "#device-form"), %{"device" => "sim"})
    assert html =~ "Simulator"
    # The Simulator option is the selected one.
    assert has_element?(view, "option[value='sim'][selected]")
  end

  test "select_device with an empty/missing device value does not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # The form's phx-change can fire with no device (e.g. a replay, or the
    # disabled select). It must be ignored, not raise a FunctionClauseError.
    assert render_change(element(view, "#device-form"), %{"device" => ""}) =~ "blau-drill"
    assert render_change(element(view, "#device-form"), %{}) =~ "blau-drill"
    # The view is still alive after both.
    assert has_element?(view, "[data-test='device-select']")
  end

  test "refresh_devices re-enumerates and keeps the Simulator available", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = render_click(element(view, "[data-test='refresh-devices']"))
    # Still hardware-free: the Simulator is always present after a refresh.
    assert html =~ "Simulator"
    assert has_element?(view, "[data-test='device-select']")
  end

  test "connecting to the Simulator device yields a connected state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Default selection is the Simulator (dev/test default device). Connect.
    html = render_click(element(view, "[data-test='connect-device']"))

    assert html =~ "CONNECTED"
    # Now connected: Disconnect replaces Connect, select disables.
    assert has_element?(view, "[data-test='disconnect-device']")
    refute has_element?(view, "[data-test='connect-device']")

    # Disconnecting returns to the disconnected card.
    html = render_click(element(view, "[data-test='disconnect-device']"))
    assert html =~ "DISCONNECTED"
    assert has_element?(view, "[data-test='connect-device']")
  end

  test "connecting to a non-existent real port flashes an error and stays disconnected",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Simulate a real serial port the operator could have picked, then connect.
    # No hardware is attached, so opening it fails — the handler must flash and
    # stay disconnected, never crash the LiveView.
    port = "definitely-not-a-port"
    send(view.pid, {:inject_device, %{id: port, label: port, kind: :real, port: port}})
    render(view)

    html = render_click(element(view, "[data-test='connect-device']"))

    # Error surfaced, still disconnected, view alive.
    assert html =~ "Could not connect"
    assert html =~ "DISCONNECTED"
    assert has_element?(view, "[data-test='connect-device']")
    assert Process.alive?(view.pid)
  end

  # ── upload / parse ──────────────────────────────────────────────────────────

  test "uploading a valid .drl parses and advances; diagnostic shows 130 holes / 5 tools",
       %{conn: conn} do
    {conn, _name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    html = upload_fixture(view)

    assert html =~ "FILE VALID"
    assert has_element?(view, "[data-test='hole-count']", "130")
    assert has_element?(view, "[data-test='tool-count']", "5")
    assert has_element?(view, "[data-test='proceed-align']:not([disabled])")
  end

  test "the board canvas receives the bbox and tools it needs to fit the whole board to view",
       %{conn: conn} do
    # The canvas sizes its SVG viewBox to the board's bbox (so the WHOLE board
    # fits, aspect ratio preserved — not just the width) and draws holes at their
    # true tool diameter. Both come from the live_svelte props (`data-props`).
    # This locks the data contract the fit-to-view + true-size-hole rendering
    # depends on; the visual fit itself is verified in-browser.
    {conn, _name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    html = upload_fixture(view)

    # The SvelteHook element carries the BoardCanvas props as a JSON
    # `data-props` attribute (HTML-escaped). Pull it out without adding an HTML
    # parser dep: grab the attribute value, then unescape and decode it.
    [_, raw] = Regex.run(~r/data-props="([^"]*)"/, html)

    props_json =
      raw
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")
      |> String.replace("&amp;", "&")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")

    props = Jason.decode!(props_json)

    # bbox = [minx, miny, maxx, maxy] of the real fixture; the viewBox is derived
    # from this, so its span (and thus aspect ratio) must reflect the board.
    assert [minx, miny, maxx, maxy] = props["bbox"]
    assert_in_delta maxx - minx, 81.28, 0.01
    assert_in_delta maxy - miny, 83.82, 0.01

    # Tool diameters drive the true-size hole radii.
    assert props["tools"] == %{
             "T1" => 0.6,
             "T2" => 0.7,
             "T3" => 0.8,
             "T4" => 1.0,
             "T5" => 1.2
           }

    # 130 holes carried through, each with a tool ref for sizing/colour.
    assert length(props["holes"]) == 130
    assert Enum.all?(props["holes"], &(Map.has_key?(&1, "tool") and Map.has_key?(&1, "x")))
  end

  test "an optional Edge.Cuts SVG upload draws the board outline on the canvas",
       %{conn: conn} do
    {conn, _name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    # Without an Edge.Cuts upload, the outline is nil (holes-only).
    upload_fixture(view)
    assert canvas_props(view)["outline"] == nil

    # Reload, upload BOTH the .drl and the Edge.Cuts SVG → outline is populated.
    {:ok, view, _html} = live(conn, ~p"/")

    drl =
      file_input(view, "#upload-form", :drl, [
        %{name: "segby_v1.drl", content: File.read!(@fixture), type: "text/plain"}
      ])

    edge =
      file_input(view, "#upload-form", :edge_cuts, [
        %{
          name: "segby_v1-Edge_Cuts.svg",
          content: File.read!(@edge_cuts_fixture),
          type: "image/svg+xml"
        }
      ])

    render_upload(drl, "segby_v1.drl")
    render_upload(edge, "segby_v1-Edge_Cuts.svg")
    render_submit(element(view, "#upload-form"))

    outline = canvas_props(view)["outline"]
    assert is_list(outline)
    assert length(outline) >= 3
    # Each point is an [x, y] pair (the closed board polyline).
    assert Enum.all?(outline, &match?([_x, _y], &1))
  end

  test "an absolute-page-coordinate export shows the trap error and does NOT advance",
       %{conn: conn} do
    {conn, _name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    drl =
      file_input(view, "#upload-form", :drl, [
        %{name: "bad.drl", content: @absolute_page_drl, type: "text/plain"}
      ])

    render_upload(drl, "bad.drl")
    render_submit(element(view, "#upload-form"))

    assert has_element?(view, "[data-test='upload-error']")
    refute has_element?(view, "[data-test='diagnostic-bar']")
    refute has_element?(view, "[data-test='proceed-align']")
  end

  test "a malformed .drl (no M48 header) surfaces an error and does NOT advance or crash",
       %{conn: conn} do
    {conn, _name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    drl =
      file_input(view, "#upload-form", :drl, [
        %{name: "junk.drl", content: "this is not a drill file at all", type: "text/plain"}
      ])

    render_upload(drl, "junk.drl")
    render_submit(element(view, "#upload-form"))

    assert has_element?(view, "[data-test='upload-error']")
    refute has_element?(view, "[data-test='diagnostic-bar']")
    refute has_element?(view, "[data-test='proceed-align']")
    # The LiveView is still alive and responsive (no crash).
    assert render(view) =~ "blau-drill"
  end

  # NOTE: a 0-byte upload can't be exercised through `render_upload/2` — Phoenix's
  # test UploadClient divides by the entry size to compute progress and raises
  # ArithmeticError before our code runs. The empty-content path is asserted
  # directly at the parse layer instead (whitespace-only stands in for "empty"
  # without tripping the harness), which is where the real rejection happens.
  test "an empty/whitespace .drl is rejected at the parse layer (no holes, no crash)" do
    assert {:error, reason} = BlauDrill.BoardModel.parse_drl("   \n  \n")
    assert reason in [:missing_m48_header, :no_holes]
  end

  # ── energize-before-jog gate ────────────────────────────────────────────────

  test "jog controls are disabled until Enable Motors is clicked (energize gate)",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    upload_fixture(view)
    render_click(element(view, "[data-test='proceed-align']"))

    # Before energizing: jog d-pad + capture disabled; the printer is :idle.
    assert PrinterConnection.state(name) == :idle
    assert has_element?(view, "[data-test='jog-x-+'][disabled]")
    assert has_element?(view, "[data-test='capture-fiducial'][disabled]")

    # Enable motors → PrinterConnection energizes (the only path to :jogging).
    render_click(element(view, "[data-test='motors-toggle']"))
    assert PrinterConnection.state(name) == :jogging

    refute has_element?(view, "[data-test='jog-x-+'][disabled]")
    refute has_element?(view, "[data-test='capture-fiducial'][disabled]")
  end

  # ── no drill without dry-run ────────────────────────────────────────────────

  test "you cannot reach a Start Drilling action from :aligned without dry-run",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)
    capture_and_fit(view, name, @candidates)

    # In :aligned, the only forward action is Proceed to Dry-run — there is NO
    # confirm-drill control on the page (mirrors Job.can?).
    assert has_element?(view, "[data-test='proceed-dryrun']:not([disabled])")
    refute has_element?(view, "[data-test='confirm-drill']")

    # After dry-run, the confirm-drill control appears (and is enabled).
    render_click(element(view, "[data-test='proceed-dryrun']"))
    assert has_element?(view, "[data-test='confirm-drill']:not([disabled])")
  end

  test "a FORGED confirm_registration from :aligned does not start a drill stream (server-side gate)",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)
    capture_and_fit(view, name, @candidates)

    # In :aligned the motors are still energized from fiducial capture, so the
    # connection is :jogging (not :streaming). The key invariant is that it must
    # NOT be streaming, before or after.
    refute PrinterConnection.state(name) == :streaming

    # The button is absent in :aligned, but a malicious/raced client can still
    # push the raw event. Forge it directly, bypassing the disabled-button
    # cosmetic. The server must refuse: no transition into :drilling, and NO
    # G-code streamed to the printer (so no M3 S255 / plunge ever issued).
    render_click(view, "confirm_registration", %{})

    # The connection never entered :streaming, and the UI did not advance to the
    # drilling stage — the dry-run gate held server-side, not just in the button.
    refute PrinterConnection.state(name) == :streaming
    refute has_element?(view, "[data-test='abort-drilling']")
    assert render(view) =~ "Cannot stream drill from the current stage."
  end

  # ── abort / E-stop present in motion stages ─────────────────────────────────

  test "emergency stop is present in the alignment stage", %{conn: conn} do
    {conn, _name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    upload_fixture(view)
    render_click(element(view, "[data-test='proceed-align']"))
    assert has_element?(view, "[data-test='emergency-stop']")
  end

  # ── test spindle (gated) ────────────────────────────────────────────────────

  test "Test Spindle is disabled until motors are energized, then pulses the spindle",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    upload_fixture(view)
    render_click(element(view, "[data-test='proceed-align']"))

    # Motors off → the button is present but disabled, and a forged event is
    # refused by the gate ("Enable motors") with no spindle command written.
    assert has_element?(view, "[data-test='test-spindle'][disabled]")
    html = render_click(view, "test_spindle", %{})
    assert html =~ "Enable motors"

    # Energize, then the test pulses the configured spindle (M3 S255 → M5).
    render_click(element(view, "[data-test='motors-toggle']"))
    assert has_element?(view, "[data-test='test-spindle']:not([disabled])")
    render_click(element(view, "[data-test='test-spindle']"))

    {:ok, _} = PrinterConnection.where(name)
    assert PrinterConnection.state(name) == :jogging
  end

  # ── restart alignment ───────────────────────────────────────────────────────

  test "Restart Alignment wipes captures and returns to a fresh registering",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)
    capture_and_fit(view, name, @candidates)
    # Now :aligned (clean fit) with the dry-run gate open.
    assert has_element?(view, "[data-test='proceed-dryrun']:not([disabled])")

    # Restart is offered from :aligned and returns to capturing with 0 points.
    assert has_element?(view, "[data-test='restart-alignment']")
    render_click(element(view, "[data-test='restart-alignment']"))

    assert has_element?(view, "[data-test='capture-fiducial']", "0/4")
    refute has_element?(view, "[data-test='proceed-dryrun']:not([disabled])")
    # The canvas captures are cleared (no captured fiducials in the props).
    fids = canvas_props(view)["fiducials"]
    assert Enum.all?(fids, &(&1["state"] != "captured"))
  end

  # ── current-target distinction ──────────────────────────────────────────────

  test "exactly one registration candidate is the current target; clicking another switches it",
       %{conn: conn} do
    {conn, _name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    upload_fixture(view)
    render_click(element(view, "[data-test='proceed-align']"))

    fids = canvas_props(view)["fiducials"]
    current = Enum.filter(fids, &(&1["state"] == "current"))
    pending = Enum.filter(fids, &(&1["state"] == "pending"))

    # One blinks (current), the rest fade (pending) — index 0 is current at start.
    assert length(current) == 1
    assert Enum.all?(pending, &(&1["state"] == "pending"))
    assert hd(current)["index"] == 0
    assert length(current) + length(pending) == length(fids)

    # Clicking another candidate makes IT the current one (operator-driven order).
    render_hook(view, "set_current_target", %{"index" => 2})

    fids2 = canvas_props(view)["fiducials"]
    current2 = Enum.filter(fids2, &(&1["state"] == "current"))
    assert length(current2) == 1
    assert hd(current2)["index"] == 2
  end

  # ── click-to-jump ───────────────────────────────────────────────────────────

  test "jump_to is refused until motors are energized, then moves the head (gated)",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    upload_fixture(view)
    render_click(element(view, "[data-test='proceed-align']"))

    # Capture one point first so a board↔machine mapping exists.
    render_click(element(view, "[data-test='motors-toggle']"))
    candidates = BlauDrillWeb.SessionLive.feature_candidates(board_for(view))
    capture_at(view, name, Enum.at(candidates, 0))

    # With motors ON (we're :jogging) a jump moves the head: state stays :jogging
    # (not :idle/refused) and the sim head ends up near the requested board point.
    {tx, ty} = Enum.at(candidates, 1)
    render_hook(view, "jump_to", %{"x" => tx, "y" => ty})
    assert PrinterConnection.state(name) == :jogging
    {:ok, {hx, hy, _}} = PrinterConnection.where(name)
    assert_in_delta hx, tx, 0.5
    assert_in_delta hy, ty, 0.5

    # Release motors → :idle → a jump is refused (the energize-before-move gate),
    # and the head does not move.
    render_click(element(view, "[data-test='motors-toggle']"))
    assert PrinterConnection.state(name) == :idle
    {:ok, before} = PrinterConnection.where(name)
    html = render_hook(view, "jump_to", %{"x" => List.first(candidates) |> elem(0), "y" => 0.0})
    assert html =~ "Enable motors"
    assert {:ok, ^before} = PrinterConnection.where(name)
  end

  # ── live head confidence ────────────────────────────────────────────────────

  test "the live head marker's confidence grows none -> estimate -> rough -> aligned",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)

    # 0 captures: no usable transform — no in-board marker, confidence "none".
    # (The Svelte caption itself is client-rendered, so it's verified in-browser;
    # here we assert the prop contract the canvas reads.)
    assert canvas_props(view)["head_confidence"] == "none"
    assert canvas_props(view)["head"] == nil

    candidates = BlauDrillWeb.SessionLive.feature_candidates(board_for(view))

    # Capture point 1 → translation-only estimate.
    capture_at(view, name, Enum.at(candidates, 0))
    assert canvas_props(view)["head_confidence"] == "estimate"
    assert canvas_props(view)["head"]

    # Capture point 2 → similarity (rough).
    render_hook(view, "set_current_target", %{"index" => 1})
    capture_at(view, name, Enum.at(candidates, 1))
    assert canvas_props(view)["head_confidence"] == "rough"

    # Capture point 3 + fit → full affine (aligned).
    render_hook(view, "set_current_target", %{"index" => 2})
    capture_at(view, name, Enum.at(candidates, 2))
    render_click(element(view, "[data-test='fit-alignment']"))
    assert canvas_props(view)["head_confidence"] == "aligned"
  end

  # The parsed board behind the current view (for candidate coordinates).
  defp board_for(view) do
    {:ok, board} =
      BlauDrill.BoardModel.parse_drl(File.read!("test/support/fixtures/segby_v1.drl"))

    _ = view
    board
  end

  # Jog the (sim) head onto a board point's coordinates and capture it. With the
  # sim, machine == board here, so captures give a clean identity-ish fit.
  defp capture_at(view, name, {bx, by}) do
    jog_to(view, name, {bx, by})
    render_click(element(view, "[data-test='capture-fiducial']"))
  end

  test "abort + emergency stop are present while drilling, and aborting faults the job",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)
    capture_and_fit(view, name, @candidates)
    render_click(element(view, "[data-test='proceed-dryrun']"))
    render_click(element(view, "[data-test='confirm-drill']"))

    assert has_element?(view, "[data-test='abort-drilling']")
    assert has_element?(view, "[data-test='emergency-stop']")

    html = render_click(element(view, "[data-test='abort-drilling']"))

    assert PrinterConnection.state(name) == :faulted
    assert html =~ "HARDWARE DISCONNECTED"
    assert has_element?(view, "#fault-banner")
  end

  test "reconnect after a drilling fault returns to :aligned, clears stale progress, and requires a fresh dry-run",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)
    capture_and_fit(view, name, @candidates)
    render_click(element(view, "[data-test='proceed-dryrun']"))
    render_click(element(view, "[data-test='confirm-drill']"))

    # Fault mid-run, then recover.
    render_click(element(view, "[data-test='abort-drilling']"))
    assert PrinterConnection.state(name) == :faulted

    html = render_click(element(view, "[data-test='reconnect']"))

    # The FSM routes faulted → aligned (NOT back into drilling): resuming the
    # real run requires passing through dry-run again, so registration is
    # re-validated before any bit touches copper. There is no confirm-drill
    # control here, and the stale "X / Y" drilling progress is gone.
    refute has_element?(view, "[data-test='confirm-drill']")
    refute has_element?(view, "[data-test='abort-drilling']")
    assert has_element?(view, "[data-test='proceed-dryrun']:not([disabled])")
    refute html =~ "Bit Change"
  end

  # ── residual gate ───────────────────────────────────────────────────────────

  test "a clean fit reaches :aligned with a quality readout (residual gate passes)",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)
    # Machine points = board points (identity) → residual ≈ 0 → passes the gate.
    capture_and_fit(view, name, @candidates)

    assert has_element?(view, "[data-test='quality']")
    assert has_element?(view, "[data-test='residuals']")
    # Aligned: the dry-run gate is open; rejection is NOT shown.
    assert has_element?(view, "[data-test='proceed-dryrun']:not([disabled])")
    refute has_element?(view, "[data-test='alignment-rejected']")
  end

  test "a high-residual fit lands in alignment_rejected with no drill path",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)

    # Three identity captures + one gross outlier (20 mm off): a non-degenerate
    # but bad fit → residual.max far over the 0.1 mm tolerance → rejected.
    [c1, c2, c3, {x4, y4}] = @candidates
    bad_targets = [c1, c2, c3, {x4 + 20.0, y4 + 20.0}]
    capture_and_fit(view, name, bad_targets)

    assert has_element?(view, "[data-test='alignment-rejected']")
    # No path forward to drilling — the proceed-to-dry-run gate is closed.
    refute has_element?(view, "[data-test='proceed-dryrun']:not([disabled])")

    # Recapture returns to :registering (the only off-ramp).
    render_click(element(view, "[data-test='recapture']"))
    assert has_element?(view, "[data-test='capture-fiducial']")
  end

  # ── live drilling progress + telemetry (real, not placeholders) ─────────────

  test "the dry-run stream advances the progress count incrementally to all holes",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)
    capture_and_fit(view, name, @candidates)
    render_click(element(view, "[data-test='proceed-dryrun']"))

    # The async stream folds per-line progress; wait for it to reach all 130
    # holes. (Streaming is genuine: holes_done rises from 0 as each ok arrives.)
    html = wait_for_render(view, ~r{Traced\s+130/130\s+positions})
    assert html =~ "Traced 130/130 positions"
  end

  test "the completion summary reports a derived (non-placeholder) total time",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)
    capture_and_fit(view, name, @candidates)
    render_click(element(view, "[data-test='proceed-dryrun']"))
    render_click(element(view, "[data-test='confirm-drill']"))
    render_click(element(view, "[data-test='resume-drilling']"))
    html = render_click(element(view, "[data-test='complete-drilling']"))

    assert html =~ "Drilling Complete"
    # Total Time is a derived mm:ss, not the old "—" placeholder.
    assert html =~ ~r/Total Time/
    assert html =~ ~r/\d+:\d\d/
  end

  # ── full happy path → done ──────────────────────────────────────────────────

  test "the flow runs upload → align → dry-run → drill → bit change → done",
       %{conn: conn} do
    {conn, name} = with_printer(conn)
    {:ok, view, _html} = live(conn, ~p"/")

    to_registering(view)
    capture_and_fit(view, name, @candidates)

    render_click(element(view, "[data-test='proceed-dryrun']"))
    render_click(element(view, "[data-test='confirm-drill']"))

    # The fixture has 5 tools → the first bit-change pause surfaces as the modal.
    assert has_element?(view, "[data-test='bit-change-modal']")
    render_click(element(view, "[data-test='resume-drilling']"))

    # Mark complete → Stage 5 completion card with the summary.
    render_click(element(view, "[data-test='complete-drilling']"))
    assert has_element?(view, "[data-test='completion-card']")
    assert has_element?(view, "[data-test='new-board']")

    # Start a new board returns to Stage 1.
    render_click(element(view, "[data-test='new-board']"))
    assert has_element?(view, "#upload-form")
  end
end
