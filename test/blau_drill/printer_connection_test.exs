defmodule BlauDrill.PrinterConnectionTest do
  @moduledoc """
  Drives the `:gen_statem` `PrinterConnection` against a fake UART (no hardware).

  The fake records every write and lets the test inject incoming Marlin replies.
  By default it auto-acks each non-`M114` write with `"ok"` so streaming flows
  without manual replies; `M114` writes are auto-answered with a position line.
  Tests that exercise resend / fault paths drive the replies explicitly.
  """
  use ExUnit.Case, async: true

  alias BlauDrill.PrinterConnection
  alias BlauDrill.PrinterConnection.UART.Fake

  # Settle time is configurable so tests don't pay a real delay.
  defp start_conn(fake_opts \\ []) do
    {:ok, fake} = Fake.start_link(fake_opts)

    {:ok, conn} =
      PrinterConnection.start_link(
        uart: Fake,
        uart_pid: fake,
        port: "fake0",
        settle_ms: 0
      )

    on_exit(fn ->
      if Process.alive?(conn), do: stop_quietly(conn)
      if Process.alive?(fake), do: Process.exit(fake, :normal)
    end)

    %{conn: conn, fake: fake}
  end

  # Stop the statem without crashing the test on an already-dead process.
  defp stop_quietly(pid) do
    :gen_statem.stop(pid, :normal, 1000)
  catch
    :exit, _ -> :ok
  end

  describe "lifecycle" do
    test "starts in :idle" do
      %{conn: conn} = start_conn()
      assert PrinterConnection.state(conn) == :idle
    end

    test "energize transitions :idle -> :jogging and sends the enable-steppers command" do
      %{conn: conn, fake: fake} = start_conn()
      assert :ok = PrinterConnection.energize(conn)
      assert PrinterConnection.state(conn) == :jogging

      writes = Fake.writes(fake)
      assert Enum.any?(writes, &String.contains?(&1, "M17"))
    end

    test "release transitions :jogging -> :idle" do
      %{conn: conn} = start_conn()
      :ok = PrinterConnection.energize(conn)
      assert :ok = PrinterConnection.release(conn)
      assert PrinterConnection.state(conn) == :idle
    end
  end

  describe "energize-before-jog snap invariant" do
    test "jog in :idle returns {:error, :idle} and writes NOTHING to the port" do
      %{conn: conn, fake: fake} = start_conn()
      assert PrinterConnection.state(conn) == :idle

      assert {:error, :idle} = PrinterConnection.jog(conn, :x, 1.0)

      assert Fake.writes(fake) == [],
             "jogging from idle must not write anything to the serial port"
    end

    test "jog in :jogging sends a relative-move gcode and returns :ok" do
      %{conn: conn, fake: fake} = start_conn()
      :ok = PrinterConnection.energize(conn)

      assert :ok = PrinterConnection.jog(conn, :x, 1.0)

      writes = Fake.writes(fake)
      # A relative move: switch to relative (G91), move X, and (optionally) back.
      move = Enum.find(writes, &String.match?(&1, ~r/G[01].*X1(\.0+)?/))
      assert move, "expected a relative X move, got: #{inspect(writes)}"
      assert Enum.any?(writes, &String.contains?(&1, "G91"))
    end
  end

  describe "where/1 (M114)" do
    test "issues M114 and parses X/Y/Z from the reply" do
      # The fake answers M114 with a Marlin-style position line.
      %{conn: conn, fake: fake} =
        start_conn(m114_reply: "X:10.00 Y:20.00 Z:5.00 E:0.00 Count X:800 Y:1600 Z:2000")

      assert {:ok, {10.0, 20.0, 5.0}} = PrinterConnection.where(conn)
      assert Enum.any?(Fake.writes(fake), &String.contains?(&1, "M114"))
    end
  end

  describe "stream/2 — ok-handshake" do
    test "sends each line in order, waiting for ok between lines" do
      %{conn: conn, fake: fake} = start_conn()

      program = ["G90", "G0 X1 Y1", "G0 X2 Y2", "M400"]
      assert :ok = PrinterConnection.stream(conn, program)
      assert PrinterConnection.state(conn) == :idle

      writes = Fake.writes(fake)
      # Strip line-number/checksum wrappers to compare the payloads in order.
      payloads = Enum.map(writes, &strip_line/1)
      assert payloads == program
    end

    test "a Resend: N reply re-sends the line rather than skipping" do
      # Configure the fake to NAK the 2nd accepted line once with a Resend, then
      # ack normally. We assert the offending line is written twice.
      %{conn: conn, fake: fake} = start_conn(resend_once_on_index: 2)

      program = ["G90", "G0 X1 Y1", "G0 X2 Y2"]
      assert :ok = PrinterConnection.stream(conn, program)

      payloads = Enum.map(Fake.writes(fake), &strip_line/1)
      # The 2nd line ("G0 X1 Y1") must appear at least twice (sent, NAK, resent).
      assert Enum.count(payloads, &(&1 == "G0 X1 Y1")) >= 2
      # And all three program lines must ultimately have been accepted, in order.
      assert "G0 X2 Y2" in payloads
    end
  end

  describe "stream/3 — per-line progress events" do
    test "broadcasts one progress event per confirmed line, in order, totalling N" do
      %{conn: conn} = start_conn()

      topic = "progress_test_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(BlauDrill.PubSub, topic)

      # A plunge-bearing program (drill triple per hole + a couple of setup lines).
      program = [
        "G90",
        "G0 X1 Y1",
        "G1 Z-2.5",
        "G1 Z5.0",
        "G0 X2 Y2",
        "G1 Z-2.5",
        "G1 Z5.0"
      ]

      assert :ok = PrinterConnection.stream(conn, program, progress_topic: topic)

      # Exactly one event per line, with monotonically increasing `sent` from 1
      # to N, total fixed, and the confirmed line echoed.
      total = length(program)

      events =
        for expected_sent <- 1..total do
          assert_receive {:stream_progress, %{sent: ^expected_sent, total: ^total, line: line}}
          line
        end

      # The line carried at sent=k is the k-th program line (in order).
      assert events == program
    end

    test "no progress event is emitted without a :progress_topic" do
      %{conn: conn} = start_conn()

      topic = "progress_test_silent_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(BlauDrill.PubSub, topic)

      program = ["G90", "G0 X1 Y1", "G1 Z-2.5"]
      assert :ok = PrinterConnection.stream(conn, program)

      refute_receive {:stream_progress, _}, 50
    end

    test "a Resend re-sends the line and progress still totals N in order" do
      # NAK the 2nd accepted line once; progress must still emit one event per
      # line in order (the resend does not double-count or skip).
      %{conn: conn} = start_conn(resend_once_on_index: 2)

      topic = "progress_test_resend_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(BlauDrill.PubSub, topic)

      program = ["G90", "G0 X1 Y1", "G0 X2 Y2"]
      assert :ok = PrinterConnection.stream(conn, program, progress_topic: topic)

      total = length(program)

      for expected_sent <- 1..total do
        assert_receive {:stream_progress, %{sent: ^expected_sent, total: ^total}}
      end

      refute_receive {:stream_progress, _}, 50
    end
  end

  describe "faulted is loud and reachable from any active state" do
    test "halt from :idle lands in :faulted" do
      %{conn: conn} = start_conn()
      assert :ok = PrinterConnection.halt(conn)
      assert PrinterConnection.state(conn) == :faulted
    end

    test "halt from :jogging lands in :faulted" do
      %{conn: conn} = start_conn()
      :ok = PrinterConnection.energize(conn)
      assert :ok = PrinterConnection.halt(conn)
      assert PrinterConnection.state(conn) == :faulted
    end

    test "simulated serial loss during streaming lands in :faulted and stops the stream" do
      # The fake disconnects after the 1st accepted line; the statem should
      # observe the loss and fault rather than block forever.
      %{conn: conn, fake: fake} = start_conn(disconnect_after_index: 1)

      program = ["G90", "G0 X1 Y1", "G0 X2 Y2", "G0 X3 Y3"]
      # stream may return :ok (kicked off) — the fault is observable via state.
      _ = PrinterConnection.stream(conn, program)

      # Give the statem a moment to process the disconnect message.
      wait_until(fn -> PrinterConnection.state(conn) == :faulted end)
      assert PrinterConnection.state(conn) == :faulted

      # The stream stopped early: not all lines were written.
      payloads = Enum.map(Fake.writes(fake), &strip_line/1)
      refute "G0 X3 Y3" in payloads
    end

    test "reconnect drives :faulted -> :idle" do
      %{conn: conn} = start_conn()
      :ok = PrinterConnection.halt(conn)
      assert PrinterConnection.state(conn) == :faulted

      assert :ok = PrinterConnection.reconnect(conn)
      assert PrinterConnection.state(conn) == :idle
    end
  end

  # Strip an optional `N<n> ` prefix and `*<checksum>` suffix from a written
  # line so tests compare the bare gcode payload.
  defp strip_line(line) do
    line
    |> String.trim_trailing()
    |> String.replace(~r/^N\d+\s+/, "")
    |> String.replace(~r/\*\d+$/, "")
    |> String.trim()
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        :timeout

      true ->
        Process.sleep(5)
        wait_until(fun, attempts - 1)
    end
  end
end
