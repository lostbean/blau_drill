defmodule BlauDrillWeb.SettingsLiveTest do
  @moduledoc """
  LiveView tests for the printer-configuration screen (`/settings`):

    * renders the four category nav entries and switches the panel,
    * inline-validates a bad baud / non-positive motion limit / invalid PWM
      range and disables Apply,
    * Apply with a valid form produces a valid `BlauDrill.Config` in the
      application env (the "next session" slot),
    * the applied spindle/defaults values flow into a built `GcodeProgram`'s opts
      (a custom zdrill shows up in the generated drill lines).

  The application-env tests are NOT async — they share the global
  `:blau_drill, BlauDrill.Config` env slot — and restore it on exit.
  """
  use BlauDrillWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BlauDrill.{Alignment, BoardModel, Config, Correspondence, GcodeProgram}

  @fixture Path.expand("../../support/fixtures/segby_v1.drl", __DIR__)

  setup do
    previous = Application.get_env(:blau_drill, BlauDrill.Config)
    Application.delete_env(:blau_drill, BlauDrill.Config)
    on_exit(fn -> restore_env(previous) end)
    :ok
  end

  defp restore_env(nil), do: Application.delete_env(:blau_drill, BlauDrill.Config)
  defp restore_env(v), do: Application.put_env(:blau_drill, BlauDrill.Config, v)

  # The four config fields, posted as the form would, with overrides merged in.
  defp form_params(overrides) do
    base = %{
      "port" => "",
      "baud" => "115200",
      "auto_connect" => "false",
      "max_x" => "300.0",
      "max_y" => "200.0",
      "max_z" => "50.0",
      "spindle_on" => "M3 S255",
      "spindle_off" => "M5",
      "pwm_max" => "255",
      "spindle_speed" => "255",
      "zdrill" => "-2.5",
      "zsafe" => "5.0",
      "zchange" => "30.0",
      "drill_feed" => "200",
      "hover" => "0.2"
    }

    Map.merge(base, overrides)
  end

  describe "render" do
    test "shows all four category nav entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "[data-test='nav-connection']")
      assert has_element?(view, "[data-test='nav-motion']")
      assert has_element?(view, "[data-test='nav-spindle']")
      assert has_element?(view, "[data-test='nav-defaults']")
    end

    test "defaults to the Connection panel (serial port + baud)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "[data-test='field-baud']")
      assert has_element?(view, "[data-test='toggle-auto_connect']")
    end

    test "switching category renders that panel's fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_click(element(view, "[data-test='nav-spindle']"))
      assert has_element?(view, "[data-test='field-spindle_on']")
      assert has_element?(view, "[data-test='field-pwm_max']")

      render_click(element(view, "[data-test='nav-defaults']"))
      assert has_element?(view, "[data-test='field-zdrill']")
      assert has_element?(view, "[data-test='field-drill_feed']")

      render_click(element(view, "[data-test='nav-motion']"))
      assert has_element?(view, "[data-test='field-max_x']")
    end

    test "Apply is enabled with the default (valid) config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      refute has_element?(view, "[data-test='apply-config'][disabled]")
    end
  end

  describe "validation" do
    test "rejects a bad baud and disables Apply", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_change(element(view, "#settings-form"), %{
        "config" => form_params(%{"baud" => "12345"})
      })

      assert has_element?(view, "[data-test='error-baud']")
      assert has_element?(view, "[data-test='apply-config'][disabled]")
    end

    test "rejects a non-positive motion limit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_change(element(view, "#settings-form"), %{"config" => form_params(%{"max_x" => "0"})})

      assert has_element?(view, "[data-test='apply-config'][disabled]")
    end

    test "rejects an invalid PWM range", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_change(element(view, "#settings-form"), %{
        "config" => form_params(%{"pwm_max" => "512"})
      })

      assert has_element?(view, "[data-test='apply-config'][disabled]")
    end

    test "a submit of an invalid form does not apply and flags an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        render_submit(element(view, "#settings-form"), %{
          "config" => form_params(%{"max_y" => "-1"})
        })

      assert html =~ "Cannot apply"
      # Nothing was written to the applied slot.
      assert Application.get_env(:blau_drill, BlauDrill.Config) == nil
    end
  end

  describe "apply" do
    test "a valid submit writes a valid Config to the next-session slot", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        render_submit(element(view, "#settings-form"), %{
          "config" => form_params(%{"port" => "/dev/ttyUSB0", "zdrill" => "-3.0"})
        })

      assert html =~ "Configuration applied"

      applied = Application.get_env(:blau_drill, BlauDrill.Config)
      assert %Config{} = applied
      assert applied.port == "/dev/ttyUSB0"
      assert applied.zdrill == -3.0
      # It is, by construction, a valid Config.
      assert {:ok, ^applied} = Config.new(Map.from_struct(applied))
    end

    test "Reset to Defaults restores the default working config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # View the Defaults panel and dirty the zdrill field.
      render_click(element(view, "[data-test='nav-defaults']"))

      render_change(element(view, "#settings-form"), %{
        "config" => form_params(%{"zdrill" => "-9.0"})
      })

      assert view |> element("[data-test='field-zdrill']") |> render() =~ ~s(value="-9.0")

      render_click(element(view, "[data-test='reset-defaults']"))

      # The zdrill input is back at the default value.
      assert view |> element("[data-test='field-zdrill']") |> render() =~ ~s(value="-2.5")
    end
  end

  describe "config flows into the generated GcodeProgram" do
    test "a custom zdrill applied here shows up in a built :drill program", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_submit(element(view, "#settings-form"), %{
        "config" => form_params(%{"zdrill" => "-3.7", "spindle_speed" => "200"})
      })

      config = Config.current()
      assert config.zdrill == -3.7
      assert config.spindle_speed == 200

      # Build a real program with this config's opts (the same opts SessionLive
      # threads into GcodeProgram.build/3) and assert the custom values appear.
      {:ok, board} = BoardModel.parse_drl(File.read!(@fixture))
      alignment = xmirror_alignment()

      program =
        GcodeProgram.build(board, alignment, [mode: :drill] ++ Config.gcode_opts(config))

      assert Enum.any?(program.lines, &(&1 == "G1 Z-3.70000"))
      assert Enum.any?(program.lines, &String.starts_with?(&1, "M3 S200"))
      # The default depth must NOT appear.
      refute Enum.any?(program.lines, &(&1 == "G1 Z-2.50000"))
    end
  end

  # A back-side X-mirror alignment via the real constructor (no public
  # Alignment constructor exists).
  defp xmirror_alignment do
    correspondences =
      for {bx, by} <- [{0.0, 0.0}, {1.0, 0.0}, {0.0, 1.0}] do
        %Correspondence{board: {bx, by}, machine: {-bx, by}}
      end

    {:ok, alignment} = Alignment.fit(correspondences)
    alignment
  end
end
