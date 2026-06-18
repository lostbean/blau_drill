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
