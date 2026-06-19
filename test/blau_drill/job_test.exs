defmodule BlauDrill.JobTest do
  use ExUnit.Case, async: true

  alias BlauDrill.BoardModel
  alias BlauDrill.Correspondence
  alias BlauDrill.Job
  alias BlauDrill.PendingAlignment

  @moduletag :job

  # A minimal parsed board to seed a Job. The Job FSM treats the BoardModel as
  # opaque payload, so any parsed value will do; we use a one-tool, one-hole
  # board parsed through the real edge to keep the value honest.
  @drl """
  M48
  METRIC
  T1C0.600
  %
  T1
  X0.0Y0.0
  M30
  """

  defp board do
    {:ok, board} = BoardModel.parse_drl(@drl)
    board
  end

  defp job, do: Job.new(board(), tol: 0.1)

  # The exact back-side X-mirror correspondence set from the prompt/CONTEXT:
  # board {0,0}->{0,0}, {1,0}->{-1,0}, {0,1}->{0,1}. These 3 board points are
  # non-collinear, so Alignment.fit/1 solves an exact affine with residuals ≈ 0
  # — it passes any reasonable tolerance.
  @exact_corrs [
    %Correspondence{board: {0.0, 0.0}, machine: {0.0, 0.0}},
    %Correspondence{board: {1.0, 0.0}, machine: {-1.0, 0.0}},
    %Correspondence{board: {0.0, 1.0}, machine: {0.0, 1.0}}
  ]

  # Collinear board points: all on the y = 0 line. A fit on these is degenerate.
  @collinear_corrs [
    %Correspondence{board: {0.0, 0.0}, machine: {0.0, 0.0}},
    %Correspondence{board: {1.0, 0.0}, machine: {-1.0, 0.0}},
    %Correspondence{board: {2.0, 0.0}, machine: {-2.0, 0.0}}
  ]

  # A correspondence set with a known, small misfit. FOUR points (a unit square,
  # identity map) overdetermine the 6-unknown affine, so the least-squares fit
  # cannot satisfy them all exactly: the 4th machine point is nudged +0.4 in Y,
  # which the fit spreads into a residuals.max of ≈ 0.1 mm. (Three points always
  # have an exact affine solution and so always residual ≈ 0 — overdetermination
  # is what makes the residual gate testable.) tol 0.05 rejects; tol 0.5 accepts.
  @misfit_corrs [
    %Correspondence{board: {0.0, 0.0}, machine: {0.0, 0.0}},
    %Correspondence{board: {1.0, 0.0}, machine: {1.0, 0.0}},
    %Correspondence{board: {0.0, 1.0}, machine: {0.0, 1.0}},
    %Correspondence{board: {1.0, 1.0}, machine: {1.0, 1.4}}
  ]

  # Drive a job from :parsed to :registering with the given correspondences
  # captured (start_registering, then a capture per correspondence).
  defp register_with(job, corrs) do
    {:ok, job} = Job.transition(job, :start_registering)

    Enum.reduce(corrs, job, fn corr, acc ->
      {:ok, acc} = Job.transition(acc, {:capture, corr})
      acc
    end)
  end

  describe "new/2" do
    test "starts in :parsed holding the board and an empty PendingAlignment" do
      j = Job.new(board(), tol: 0.1)
      assert j.state == :parsed
      assert %BoardModel{} = j.board
      assert %PendingAlignment{captured: []} = j.pending
      assert j.alignment == nil
      assert j.residuals == nil
      assert j.tol == 0.1
    end

    test "defaults tol when not supplied" do
      j = Job.new(board())
      assert is_float(j.tol)
      assert j.state == :parsed
    end
  end

  describe "parsed -> registering" do
    test ":start_registering moves :parsed to :registering" do
      assert {:ok, %Job{state: :registering}} = Job.transition(job(), :start_registering)
    end
  end

  describe "registering -> registering (accumulate)" do
    test "{:capture, corr} appends to the PendingAlignment and stays :registering" do
      {:ok, j} = Job.transition(job(), :start_registering)
      corr = %Correspondence{board: {0.0, 0.0}, machine: {0.0, 0.0}}

      assert {:ok, %Job{state: :registering} = j} = Job.transition(j, {:capture, corr})
      assert PendingAlignment.count(j.pending) == 1

      corr2 = %Correspondence{board: {1.0, 0.0}, machine: {-1.0, 0.0}}
      assert {:ok, %Job{state: :registering} = j} = Job.transition(j, {:capture, corr2})
      assert PendingAlignment.count(j.pending) == 2
      assert j.pending.captured == [corr, corr2]
    end
  end

  describe "registering -> aligned / alignment_rejected (the residual gate)" do
    test "fit ok and residuals.max <= tol promotes to :aligned" do
      j = register_with(job(), @exact_corrs)

      assert {:ok, %Job{state: :aligned} = j} = Job.transition(j, {:fit, 0.1})
      assert %BlauDrill.Alignment{} = j.alignment
      assert %{max: max, rms: _} = j.residuals
      assert max <= 0.1
    end

    test "fit ok but residuals.max > tol routes to :alignment_rejected (residual gate)" do
      j = register_with(job(), @misfit_corrs)

      assert {:ok, %Job{state: :alignment_rejected} = j} = Job.transition(j, {:fit, 0.05})
      assert %{max: max} = j.residuals
      assert max > 0.05
      # A rejected fit exposes no usable transform on the job.
      assert j.alignment == nil
    end

    test "the SAME fit with a looser tolerance passes the gate -> :aligned" do
      reject = register_with(job(), @misfit_corrs)
      accept = register_with(job(), @misfit_corrs)

      assert {:ok, %Job{state: :alignment_rejected, residuals: %{max: max}}} =
               Job.transition(reject, {:fit, 0.05})

      assert {:ok, %Job{state: :aligned}} = Job.transition(accept, {:fit, 0.5})
      # Sanity: the threshold straddles residuals.max.
      assert max > 0.05 and max <= 0.5
    end

    test "{:fit, tol} with < 3 captures stays :registering and returns :too_few" do
      j = register_with(job(), Enum.take(@exact_corrs, 2))

      assert {:error, :too_few} = Job.transition(j, {:fit, 0.1})
      # The operator keeps capturing — still in :registering with captures intact.
      assert %Job{state: :registering, pending: %PendingAlignment{captured: [_, _]}} = j
    end

    test "{:fit, tol} with collinear captures stays :registering and returns :degenerate" do
      j = register_with(job(), @collinear_corrs)

      assert {:error, :degenerate} = Job.transition(j, {:fit, 0.1})
      assert %Job{state: :registering} = j
    end
  end

  describe "alignment_rejected -> registering (recapture)" do
    test ":recapture returns to :registering" do
      j = register_with(job(), @misfit_corrs)
      {:ok, rejected} = Job.transition(j, {:fit, 0.05})
      assert rejected.state == :alignment_rejected

      assert {:ok, %Job{state: :registering}} = Job.transition(rejected, :recapture)
    end

    test ":alignment_rejected has no dry-run / drill event" do
      j = register_with(job(), @misfit_corrs)
      {:ok, rejected} = Job.transition(j, {:fit, 0.05})

      assert {:error, :illegal_transition} = Job.transition(rejected, :run_dry_run)
      assert {:error, :illegal_transition} = Job.transition(rejected, :confirm_registration)
    end
  end

  describe ":restart_alignment (start the whole alignment over)" do
    test "from :registering wipes captures and stays in a fresh :registering" do
      j = register_with(job(), @misfit_corrs)
      assert BlauDrill.PendingAlignment.count(j.pending) == 4

      assert {:ok, restarted} = Job.transition(j, :restart_alignment)
      assert restarted.state == :registering
      assert BlauDrill.PendingAlignment.count(restarted.pending) == 0
      assert restarted.alignment == nil
      assert restarted.residuals == nil
    end

    test "from :aligned returns to a clean :registering (no transform left)" do
      j = register_with(job(), @misfit_corrs)
      {:ok, aligned} = Job.transition(j, {:fit, 0.5})
      assert aligned.state == :aligned
      assert aligned.alignment

      assert {:ok, restarted} = Job.transition(aligned, :restart_alignment)
      assert restarted.state == :registering
      assert BlauDrill.PendingAlignment.count(restarted.pending) == 0
      assert restarted.alignment == nil
    end

    test "from :alignment_rejected returns to a clean :registering" do
      j = register_with(job(), @misfit_corrs)
      {:ok, rejected} = Job.transition(j, {:fit, 0.05})
      assert rejected.state == :alignment_rejected

      assert {:ok, restarted} = Job.transition(rejected, :restart_alignment)
      assert restarted.state == :registering
      assert BlauDrill.PendingAlignment.count(restarted.pending) == 0
    end

    test "is illegal once past alignment (dry_run / drilling / done)" do
      j = register_with(job(), @misfit_corrs)
      {:ok, aligned} = Job.transition(j, {:fit, 0.5})
      {:ok, dry} = Job.transition(aligned, :run_dry_run)

      assert {:error, :illegal_transition} = Job.transition(dry, :restart_alignment)
    end
  end

  describe "aligned -> dry_run" do
    test ":run_dry_run moves :aligned to :dry_run" do
      j = register_with(job(), @exact_corrs)
      {:ok, aligned} = Job.transition(j, {:fit, 0.1})

      assert {:ok, %Job{state: :dry_run}} = Job.transition(aligned, :run_dry_run)
    end
  end

  describe "the no-shortcut invariant: aligned -X-> drilling" do
    test ":aligned rejects :confirm_registration (no straight edge to drilling)" do
      j = register_with(job(), @exact_corrs)
      {:ok, aligned} = Job.transition(j, {:fit, 0.1})
      assert aligned.state == :aligned

      assert {:error, :illegal_transition} = Job.transition(aligned, :confirm_registration)
      assert {:error, :illegal_transition} = Job.transition(aligned, :complete)
    end
  end

  describe "dry_run -> aligned / drilling" do
    setup do
      j = register_with(job(), @exact_corrs)
      {:ok, aligned} = Job.transition(j, {:fit, 0.1})
      {:ok, dry_run} = Job.transition(aligned, :run_dry_run)
      %{dry_run: dry_run}
    end

    test ":redo_alignment moves :dry_run back to :aligned", %{dry_run: dry_run} do
      assert {:ok, %Job{state: :aligned}} = Job.transition(dry_run, :redo_alignment)
    end

    test ":confirm_registration moves :dry_run to :drilling (the ONLY path)", %{dry_run: dry_run} do
      assert {:ok, %Job{state: :drilling}} = Job.transition(dry_run, :confirm_registration)
    end
  end

  describe "drilling -> done / faulted" do
    setup do
      j = register_with(job(), @exact_corrs)
      {:ok, aligned} = Job.transition(j, {:fit, 0.1})
      {:ok, dry_run} = Job.transition(aligned, :run_dry_run)
      {:ok, drilling} = Job.transition(dry_run, :confirm_registration)
      %{drilling: drilling}
    end

    test ":complete moves :drilling to :done", %{drilling: drilling} do
      assert {:ok, %Job{state: :done}} = Job.transition(drilling, :complete)
    end

    test "{:serial_loss, reason} moves :drilling to :faulted", %{drilling: drilling} do
      assert {:ok, %Job{state: :faulted}} = Job.transition(drilling, {:serial_loss, :timeout})
    end
  end

  describe "faulted -> aligned (reconnect & resume)" do
    setup do
      j = register_with(job(), @exact_corrs)
      {:ok, aligned} = Job.transition(j, {:fit, 0.1})
      {:ok, dry_run} = Job.transition(aligned, :run_dry_run)
      {:ok, drilling} = Job.transition(dry_run, :confirm_registration)
      {:ok, faulted} = Job.transition(drilling, {:serial_loss, :disconnect})
      %{faulted: faulted}
    end

    test ":reconnect moves :faulted to :aligned", %{faulted: faulted} do
      assert {:ok, %Job{state: :aligned} = j} = Job.transition(faulted, :reconnect)
      # The solved alignment survives the fault — we resume from it, not refit.
      assert %BlauDrill.Alignment{} = j.alignment
    end

    test ":faulted accepts no other event", %{faulted: faulted} do
      assert {:error, :illegal_transition} = Job.transition(faulted, :complete)
      assert {:error, :illegal_transition} = Job.transition(faulted, :run_dry_run)
      assert {:error, :illegal_transition} = Job.transition(faulted, :confirm_registration)
      assert {:error, :illegal_transition} = Job.transition(faulted, {:serial_loss, :again})
    end
  end

  describe ":done is terminal" do
    setup do
      j = register_with(job(), @exact_corrs)
      {:ok, aligned} = Job.transition(j, {:fit, 0.1})
      {:ok, dry_run} = Job.transition(aligned, :run_dry_run)
      {:ok, drilling} = Job.transition(dry_run, :confirm_registration)
      {:ok, done} = Job.transition(drilling, :complete)
      %{done: done}
    end

    test ":done rejects all events (terminal)", %{done: done} do
      assert {:error, :illegal_transition} = Job.transition(done, :run_dry_run)
      assert {:error, :illegal_transition} = Job.transition(done, :confirm_registration)
      assert {:error, :illegal_transition} = Job.transition(done, :start_registering)
      assert {:error, :illegal_transition} = Job.transition(done, :complete)
    end
  end

  describe "no drill in pre-aligned states" do
    test ":parsed rejects drill/confirm/dry-run events" do
      j = job()
      assert {:error, :illegal_transition} = Job.transition(j, :confirm_registration)
      assert {:error, :illegal_transition} = Job.transition(j, :run_dry_run)
      assert {:error, :illegal_transition} = Job.transition(j, :complete)
    end

    test ":registering rejects drill/confirm/dry-run events" do
      {:ok, j} = Job.transition(job(), :start_registering)
      assert {:error, :illegal_transition} = Job.transition(j, :confirm_registration)
      assert {:error, :illegal_transition} = Job.transition(j, :run_dry_run)
      assert {:error, :illegal_transition} = Job.transition(j, :complete)
    end
  end

  describe "catch-all" do
    test "an unknown event is a typed error, not a crash" do
      assert {:error, :illegal_transition} = Job.transition(job(), :wat)
      assert {:error, :illegal_transition} = Job.transition(job(), {:bogus, 1})
    end
  end

  describe "legal_events/1 and can?/2 (UI affordances)" do
    test "legal_events lists exactly the events that succeed from a state" do
      assert Job.legal_events(job()) == [:start_registering]

      {:ok, registering} = Job.transition(job(), :start_registering)
      assert :capture in Job.legal_events(registering)
      assert :fit in Job.legal_events(registering)

      aligned = register_with(job(), @exact_corrs)
      {:ok, aligned} = Job.transition(aligned, {:fit, 0.1})
      assert Job.legal_events(aligned) == [:run_dry_run, :restart_alignment]
      # The no-shortcut invariant surfaces in the UI too: no confirm from aligned.
      refute :confirm_registration in Job.legal_events(aligned)
    end

    test "can?/2 agrees with legal_events/1" do
      assert Job.can?(job(), :start_registering)
      refute Job.can?(job(), :confirm_registration)

      aligned = register_with(job(), @exact_corrs)
      {:ok, aligned} = Job.transition(aligned, {:fit, 0.1})
      assert Job.can?(aligned, :run_dry_run)
      refute Job.can?(aligned, :confirm_registration)
    end
  end

  describe "full happy-path integration (real Alignment.fit)" do
    test "parsed -> registering -> capture x3 -> fit -> aligned -> dry_run -> drilling -> done" do
      j = Job.new(board(), tol: 0.1)
      assert j.state == :parsed

      {:ok, j} = Job.transition(j, :start_registering)
      assert j.state == :registering

      j =
        Enum.reduce(@exact_corrs, j, fn corr, acc ->
          {:ok, acc} = Job.transition(acc, {:capture, corr})
          assert acc.state == :registering
          acc
        end)

      assert PendingAlignment.count(j.pending) == 3

      {:ok, j} = Job.transition(j, {:fit, 0.1})
      assert j.state == :aligned
      # The exact X-mirror set fits to ≈ 0 residuals through real Alignment.fit.
      assert j.residuals.max < 1.0e-6

      {:ok, j} = Job.transition(j, :run_dry_run)
      assert j.state == :dry_run

      {:ok, j} = Job.transition(j, :confirm_registration)
      assert j.state == :drilling

      {:ok, j} = Job.transition(j, :complete)
      assert j.state == :done
    end
  end
end
