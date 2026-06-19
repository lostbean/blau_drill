defmodule BlauDrill.Printer.DevicesTest do
  @moduledoc """
  Unit tests for the operator-selectable printer **device** list backing the
  Stage 1 connection card: the Simulator is always present, ports are best-effort,
  and a chosen device maps to the right `Printer.connect/1` opts.

  These run with no hardware: whatever `Circuits.UART.enumerate/0` returns on the
  test machine (typically empty), the Simulator must still be listed.
  """
  use ExUnit.Case, async: true

  alias BlauDrill.Printer.Devices

  describe "list/0" do
    test "always includes the Simulator, first, with the documented shape" do
      [sim | _rest] = devices = Devices.list()

      # Always available, no hardware, and the head of the list.
      assert sim.kind == :sim
      assert sim.id == Devices.sim_id()
      assert sim.port == nil
      assert is_binary(sim.label)

      # Every device matches the {id, label, kind, port} shape.
      for device <- devices do
        assert is_binary(device.id)
        assert is_binary(device.label)
        assert device.kind in [:sim, :real]
        assert is_nil(device.port) or is_binary(device.port)
      end

      # Exactly one Simulator; any extras are real serial ports.
      assert Enum.count(devices, &(&1.kind == :sim)) == 1
    end
  end

  describe "find/2" do
    test "resolves a known id and falls back to the Simulator for an unknown one" do
      devices = [
        Devices.simulator(),
        %{id: "ttyUSB0", label: "ttyUSB0", kind: :real, port: "ttyUSB0"}
      ]

      assert Devices.find("ttyUSB0", devices).kind == :real
      assert Devices.find(Devices.sim_id(), devices).kind == :sim
      # Unknown id (e.g. a port unplugged since selection) → Simulator.
      assert Devices.find("ghost", devices).kind == :sim
    end
  end

  describe "connect_opts/1" do
    test "maps a sim device to the :sim backend" do
      assert Devices.connect_opts(Devices.simulator()) == [backend: :sim]
    end

    test "maps a real device to the :real backend with its port" do
      device = %{id: "ttyUSB1", label: "ttyUSB1", kind: :real, port: "ttyUSB1"}
      assert Devices.connect_opts(device) == [backend: :real, port: "ttyUSB1"]
    end
  end

  describe "default_device/2" do
    test "is the Simulator for the hardware-free backends" do
      assert Devices.default_device(:sim).kind == :sim
      assert Devices.default_device(:fake).kind == :sim
      assert Devices.default_device(:none).kind == :sim
    end

    test "is a real device honouring the configured port for the :real backend" do
      assert Devices.default_device(:real, "ttyACM0") == %{
               id: "ttyACM0",
               label: "ttyACM0",
               kind: :real,
               port: "ttyACM0"
             }

      # No port given → a standard real-port fallback (still kind: :real).
      assert Devices.default_device(:real, nil).kind == :real
    end
  end
end
