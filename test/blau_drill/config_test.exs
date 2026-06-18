defmodule BlauDrill.ConfigTest do
  @moduledoc """
  Unit tests for the operator `BlauDrill.Config` value: its documented defaults,
  the validation in the `new/1` smart constructor, and the opts it projects into
  `GcodeProgram.build/3` and `Printer.connect/1`.
  """
  use ExUnit.Case, async: true

  alias BlauDrill.Config

  describe "default/0" do
    test "carries the documented safe defaults and always validates" do
      c = Config.default()

      # Connection
      assert c.port == nil
      assert c.baud == 115_200
      assert c.auto_connect == false

      # Motion limits (positive travel)
      assert c.max_x > 0 and c.max_y > 0 and c.max_z > 0

      # Spindle
      assert c.spindle_on == "M3 S255"
      assert c.spindle_off == "M5"
      assert c.pwm_max == 255
      assert c.spindle_speed == 255

      # Drilling defaults (the GcodeProgram tunables)
      assert c.zdrill == -2.5
      assert c.zsafe == 5.0
      assert c.zchange == 30.0
      assert c.drill_feed == 200
      assert c.hover == 0.2

      assert {:ok, ^c} = Config.new(c |> Map.from_struct())
    end
  end

  describe "new/1 — happy path" do
    test "applies defaults for omitted fields" do
      assert {:ok, c} = Config.new(%{})
      assert c == Config.default()
    end

    test "coerces string-keyed form values (port/baud/limits/spindle/defaults)" do
      assert {:ok, c} =
               Config.new(%{
                 "port" => "/dev/ttyUSB0",
                 "baud" => "250000",
                 "auto_connect" => "true",
                 "max_x" => "320.5",
                 "max_y" => "210",
                 "max_z" => "60",
                 "spindle_on" => "M3 S1000",
                 "spindle_off" => "M5",
                 "pwm_max" => "1000",
                 "spindle_speed" => "750",
                 "zdrill" => "-3.0",
                 "zsafe" => "6.0",
                 "zchange" => "35",
                 "drill_feed" => "150",
                 "hover" => "0.5"
               })

      assert c.port == "/dev/ttyUSB0"
      assert c.baud == 250_000
      assert c.auto_connect == true
      assert c.max_x == 320.5
      assert c.pwm_max == 1000
      assert c.spindle_speed == 750
      assert c.zdrill == -3.0
      assert c.drill_feed == 150
    end

    test "a blank port string becomes nil" do
      assert {:ok, c} = Config.new(%{"port" => "   "})
      assert c.port == nil
    end
  end

  describe "new/1 — validation rejects illegal configs" do
    test "rejects a baud outside the allowed set" do
      assert {:error, errors} = Config.new(%{"baud" => "12345"})
      assert Keyword.has_key?(errors, :baud)
    end

    test "rejects a non-positive motion limit" do
      assert {:error, errors} = Config.new(%{"max_x" => "0"})
      assert Keyword.has_key?(errors, :max_x)

      assert {:error, errors2} = Config.new(%{"max_y" => "-10"})
      assert Keyword.has_key?(errors2, :max_y)
    end

    test "rejects an invalid PWM range" do
      assert {:error, errors} = Config.new(%{"pwm_max" => "512"})
      assert Keyword.has_key?(errors, :pwm_max)
    end

    test "rejects a spindle speed above the PWM full scale" do
      assert {:error, errors} = Config.new(%{"pwm_max" => "255", "spindle_speed" => "1000"})
      assert Keyword.has_key?(errors, :spindle_speed)
    end

    test "rejects an empty spindle command" do
      assert {:error, errors} = Config.new(%{"spindle_on" => "   "})
      assert Keyword.has_key?(errors, :spindle_on)
    end

    test "rejects incoherent Z heights (zsafe must be above zdrill)" do
      assert {:error, errors} = Config.new(%{"zsafe" => "-5", "zdrill" => "-2.5"})
      assert Keyword.has_key?(errors, :zsafe)
    end

    test "rejects a non-positive drill feed" do
      assert {:error, errors} = Config.new(%{"drill_feed" => "0"})
      assert Keyword.has_key?(errors, :drill_feed)
    end
  end

  describe "gcode_opts/1 + connect_opts/1" do
    test "gcode_opts carries the generator tunables" do
      {:ok, c} = Config.new(%{"zdrill" => "-3.0", "spindle_speed" => "200"})
      opts = Config.gcode_opts(c)

      assert opts[:zdrill] == -3.0
      assert opts[:spindle_speed] == 200
      assert Keyword.has_key?(opts, :zsafe)
      assert Keyword.has_key?(opts, :hover)
    end

    test "connect_opts carries the port/baud and drops a nil port" do
      {:ok, with_port} = Config.new(%{"port" => "/dev/ttyUSB0", "baud" => "57600"})
      assert Config.connect_opts(with_port) == [port: "/dev/ttyUSB0", baud: 57600]

      {:ok, no_port} = Config.new(%{})
      opts = Config.connect_opts(no_port)
      refute Keyword.has_key?(opts, :port)
      assert opts[:baud] == 115_200
    end
  end

  describe "current/0 + apply/1 (application env, the 'next session' slot)" do
    setup do
      previous = Application.get_env(:blau_drill, BlauDrill.Config)
      on_exit(fn -> restore_env(previous) end)
      :ok
    end

    test "current/0 falls back to default when nothing is applied" do
      Application.delete_env(:blau_drill, BlauDrill.Config)
      assert Config.current() == Config.default()
    end

    test "apply/1 then current/0 round-trips the applied config" do
      {:ok, c} = Config.new(%{"zdrill" => "-4.0", "drill_feed" => "120"})
      :ok = Config.apply(c)
      assert Config.current() == c
    end
  end

  defp restore_env(nil), do: Application.delete_env(:blau_drill, BlauDrill.Config)
  defp restore_env(v), do: Application.put_env(:blau_drill, BlauDrill.Config, v)
end
