//// Job state-machine tests, ported from `test/blau_drill/job_test.exs`.

import blau_drill/domain/board_model.{type BoardModel}
import blau_drill/domain/correspondence.{type Correspondence, Correspondence}
import blau_drill/domain/job.{
  type Job, Aligned, AlignmentRejected, Capture, Complete, ConfirmRegistration,
  ConfirmRegistrationE, Done, Drilling, DryRun, Faulted, Fit, FitDegenerate,
  FitTooFew, IllegalTransition, OverrideAlignment, OverrideAlignmentE, Parsed,
  Recapture, Reconnect, RedoAlignment, Registering, RestartAlignment, RunDryRun,
  RunDryRunE, SerialLoss, StartRegistering, StartRegisteringE,
}
import blau_drill/domain/pending_alignment
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

const drl = "M48\nMETRIC\nT1C0.600\n%\nT1\nX0.0Y0.0\nM30\n"

fn board() -> BoardModel {
  let assert Ok(b) = board_model.parse_drl(drl)
  b
}

fn job() -> Job {
  job.new_with_tol(board(), 0.1)
}

// The exact back-side X-mirror correspondence set (3 non-collinear -> ~0 res).
fn exact_corrs() -> List(Correspondence) {
  [
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0)),
    Correspondence(board: #(1.0, 0.0), machine: #(-1.0, 0.0)),
    Correspondence(board: #(0.0, 1.0), machine: #(0.0, 1.0)),
  ]
}

// Collinear (all on y=0) -> degenerate fit.
fn collinear_corrs() -> List(Correspondence) {
  [
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0)),
    Correspondence(board: #(1.0, 0.0), machine: #(-1.0, 0.0)),
    Correspondence(board: #(2.0, 0.0), machine: #(-2.0, 0.0)),
  ]
}

// Four-point near-identity with a +0.4 Y nudge -> residuals.max ~ 0.1.
fn misfit_corrs() -> List(Correspondence) {
  [
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0)),
    Correspondence(board: #(1.0, 0.0), machine: #(1.0, 0.0)),
    Correspondence(board: #(0.0, 1.0), machine: #(0.0, 1.0)),
    Correspondence(board: #(1.0, 1.0), machine: #(1.0, 1.4)),
  ]
}

// Drive a job from Parsed to Registering with the given correspondences.
fn register_with(j: Job, corrs: List(Correspondence)) -> Job {
  let assert Ok(j) = job.transition(j, StartRegistering)
  list.fold(corrs, j, fn(acc, corr) {
    let assert Ok(acc) = job.transition(acc, Capture(corr))
    acc
  })
}

// --- new --------------------------------------------------------------------

pub fn new_starts_in_parsed_test() {
  let j = job.new_with_tol(board(), 0.1)
  j.state |> should.equal(Parsed)
  pending_alignment.count(j.pending) |> should.equal(0)
  j.alignment |> should.equal(None)
  j.residuals |> should.equal(None)
  j.tol |> should.equal(0.1)
}

pub fn new_defaults_tol_test() {
  let j = job.new(board())
  j.state |> should.equal(Parsed)
  j.tol |> should.equal(0.1)
}

// --- parsed -> registering --------------------------------------------------

pub fn start_registering_test() {
  let assert Ok(j) = job.transition(job(), StartRegistering)
  j.state |> should.equal(Registering)
}

// --- registering -> registering (accumulate) --------------------------------

pub fn capture_accumulates_test() {
  let assert Ok(j) = job.transition(job(), StartRegistering)
  let c1 = Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0))
  let assert Ok(j) = job.transition(j, Capture(c1))
  j.state |> should.equal(Registering)
  pending_alignment.count(j.pending) |> should.equal(1)
  let c2 = Correspondence(board: #(1.0, 0.0), machine: #(-1.0, 0.0))
  let assert Ok(j) = job.transition(j, Capture(c2))
  pending_alignment.count(j.pending) |> should.equal(2)
  j.pending.captured |> should.equal([c1, c2])
}

// --- the residual gate ------------------------------------------------------

pub fn fit_ok_under_tol_promotes_to_aligned_test() {
  let j = register_with(job(), exact_corrs())
  let assert Ok(j) = job.transition(j, Fit(0.1))
  j.state |> should.equal(Aligned)
  case j.alignment {
    Some(_) -> Nil
    None -> should.fail()
  }
  let assert Some(r) = j.residuals
  { r.max <=. 0.1 } |> should.be_true
}

pub fn fit_over_tol_routes_to_rejected_test() {
  let j = register_with(job(), misfit_corrs())
  let assert Ok(j) = job.transition(j, Fit(0.05))
  j.state |> should.equal(AlignmentRejected)
  let assert Some(r) = j.residuals
  { r.max >. 0.05 } |> should.be_true
  // The over-tolerance alignment is KEPT (not dropped) so the operator can
  // inspect per-point residuals and, with an explicit override, proceed on it.
  case j.alignment {
    Some(_) -> Nil
    None -> should.fail()
  }
}

// Explicit acknowledged override: a rejected fit can be promoted to Aligned on
// its already-solved transform. This is the ONLY non-recapture path past the
// residual gate (the UI gates it behind a deliberate confirm).
pub fn override_rejected_promotes_to_aligned_test() {
  let j = register_with(job(), misfit_corrs())
  let assert Ok(rj) = job.transition(j, Fit(0.05))
  rj.state |> should.equal(AlignmentRejected)
  let assert Ok(aj) = job.transition(rj, OverrideAlignment)
  aj.state |> should.equal(Aligned)
  // The transform carried through is the same solved (over-tol) one.
  case aj.alignment {
    Some(_) -> Nil
    None -> should.fail()
  }
}

// Override is listed as legal exactly in AlignmentRejected — not elsewhere.
pub fn override_is_legal_only_when_rejected_test() {
  let j = register_with(job(), misfit_corrs())
  let assert Ok(rj) = job.transition(j, Fit(0.05))
  job.can(rj, OverrideAlignmentE) |> should.be_true

  // From a clean Aligned (good fit) it is not legal.
  let good = register_with(job(), exact_corrs())
  let assert Ok(aj) = job.transition(good, Fit(0.1))
  aj.state |> should.equal(Aligned)
  job.can(aj, OverrideAlignmentE) |> should.be_false
}

pub fn same_fit_looser_tol_passes_test() {
  let reject = register_with(job(), misfit_corrs())
  let accept = register_with(job(), misfit_corrs())
  let assert Ok(rj) = job.transition(reject, Fit(0.05))
  rj.state |> should.equal(AlignmentRejected)
  let assert Ok(aj) = job.transition(accept, Fit(0.5))
  aj.state |> should.equal(Aligned)
  let assert Some(r) = rj.residuals
  { r.max >. 0.05 && r.max <=. 0.5 } |> should.be_true
}

pub fn fit_too_few_stays_registering_test() {
  let j = register_with(job(), list.take(exact_corrs(), 2))
  job.transition(j, Fit(0.1)) |> should.equal(Error(FitTooFew))
  j.state |> should.equal(Registering)
  pending_alignment.count(j.pending) |> should.equal(2)
}

pub fn fit_degenerate_stays_registering_test() {
  let j = register_with(job(), collinear_corrs())
  job.transition(j, Fit(0.1)) |> should.equal(Error(FitDegenerate))
  j.state |> should.equal(Registering)
}

// --- alignment_rejected -> registering --------------------------------------

pub fn recapture_returns_to_registering_test() {
  let j = register_with(job(), misfit_corrs())
  let assert Ok(rejected) = job.transition(j, Fit(0.05))
  rejected.state |> should.equal(AlignmentRejected)
  let assert Ok(j2) = job.transition(rejected, Recapture)
  j2.state |> should.equal(Registering)
}

pub fn rejected_has_no_dryrun_or_drill_test() {
  let j = register_with(job(), misfit_corrs())
  let assert Ok(rejected) = job.transition(j, Fit(0.05))
  job.transition(rejected, RunDryRun) |> should.equal(Error(IllegalTransition))
  job.transition(rejected, ConfirmRegistration)
  |> should.equal(Error(IllegalTransition))
}

// --- restart_alignment ------------------------------------------------------

pub fn restart_from_registering_wipes_captures_test() {
  let j = register_with(job(), misfit_corrs())
  pending_alignment.count(j.pending) |> should.equal(4)
  let assert Ok(r) = job.transition(j, RestartAlignment)
  r.state |> should.equal(Registering)
  pending_alignment.count(r.pending) |> should.equal(0)
  r.alignment |> should.equal(None)
  r.residuals |> should.equal(None)
}

pub fn restart_from_aligned_clean_registering_test() {
  let j = register_with(job(), misfit_corrs())
  let assert Ok(aligned) = job.transition(j, Fit(0.5))
  aligned.state |> should.equal(Aligned)
  let assert Ok(r) = job.transition(aligned, RestartAlignment)
  r.state |> should.equal(Registering)
  pending_alignment.count(r.pending) |> should.equal(0)
  r.alignment |> should.equal(None)
}

pub fn restart_from_rejected_clean_registering_test() {
  let j = register_with(job(), misfit_corrs())
  let assert Ok(rejected) = job.transition(j, Fit(0.05))
  rejected.state |> should.equal(AlignmentRejected)
  let assert Ok(r) = job.transition(rejected, RestartAlignment)
  r.state |> should.equal(Registering)
  pending_alignment.count(r.pending) |> should.equal(0)
}

pub fn restart_illegal_past_alignment_test() {
  let j = register_with(job(), misfit_corrs())
  let assert Ok(aligned) = job.transition(j, Fit(0.5))
  let assert Ok(dry) = job.transition(aligned, RunDryRun)
  job.transition(dry, RestartAlignment)
  |> should.equal(Error(IllegalTransition))
}

// --- aligned -> dry_run -----------------------------------------------------

pub fn run_dry_run_test() {
  let j = register_with(job(), exact_corrs())
  let assert Ok(aligned) = job.transition(j, Fit(0.1))
  let assert Ok(dry) = job.transition(aligned, RunDryRun)
  dry.state |> should.equal(DryRun)
}

// --- no-shortcut invariant: aligned -X-> drilling ---------------------------

pub fn aligned_rejects_confirm_and_complete_test() {
  let j = register_with(job(), exact_corrs())
  let assert Ok(aligned) = job.transition(j, Fit(0.1))
  aligned.state |> should.equal(Aligned)
  job.transition(aligned, ConfirmRegistration)
  |> should.equal(Error(IllegalTransition))
  job.transition(aligned, Complete) |> should.equal(Error(IllegalTransition))
}

// --- dry_run -> aligned / drilling ------------------------------------------

fn dry_run_job() -> Job {
  let j = register_with(job(), exact_corrs())
  let assert Ok(aligned) = job.transition(j, Fit(0.1))
  let assert Ok(dry) = job.transition(aligned, RunDryRun)
  dry
}

pub fn dry_run_redo_alignment_test() {
  let assert Ok(j) = job.transition(dry_run_job(), RedoAlignment)
  j.state |> should.equal(Aligned)
}

pub fn dry_run_confirm_to_drilling_test() {
  let assert Ok(j) = job.transition(dry_run_job(), ConfirmRegistration)
  j.state |> should.equal(Drilling)
}

// --- drilling -> done / faulted ---------------------------------------------

fn drilling_job() -> Job {
  let assert Ok(j) = job.transition(dry_run_job(), ConfirmRegistration)
  j
}

pub fn drilling_complete_to_done_test() {
  let assert Ok(j) = job.transition(drilling_job(), Complete)
  j.state |> should.equal(Done)
}

pub fn drilling_serial_loss_to_faulted_test() {
  let assert Ok(j) = job.transition(drilling_job(), SerialLoss("timeout"))
  j.state |> should.equal(Faulted)
}

// --- faulted -> aligned -----------------------------------------------------

fn faulted_job() -> Job {
  let assert Ok(j) = job.transition(drilling_job(), SerialLoss("disconnect"))
  j
}

pub fn faulted_reconnect_to_aligned_test() {
  let assert Ok(j) = job.transition(faulted_job(), Reconnect)
  j.state |> should.equal(Aligned)
  // The solved alignment survives the fault.
  case j.alignment {
    Some(_) -> Nil
    None -> should.fail()
  }
}

pub fn faulted_accepts_no_other_event_test() {
  let f = faulted_job()
  job.transition(f, Complete) |> should.equal(Error(IllegalTransition))
  job.transition(f, RunDryRun) |> should.equal(Error(IllegalTransition))
  job.transition(f, ConfirmRegistration)
  |> should.equal(Error(IllegalTransition))
  job.transition(f, SerialLoss("again"))
  |> should.equal(Error(IllegalTransition))
}

// --- done is terminal -------------------------------------------------------

fn done_job() -> Job {
  let assert Ok(j) = job.transition(drilling_job(), Complete)
  j
}

pub fn done_rejects_all_events_test() {
  let d = done_job()
  job.transition(d, RunDryRun) |> should.equal(Error(IllegalTransition))
  job.transition(d, ConfirmRegistration)
  |> should.equal(Error(IllegalTransition))
  job.transition(d, StartRegistering) |> should.equal(Error(IllegalTransition))
  job.transition(d, Complete) |> should.equal(Error(IllegalTransition))
}

// --- no drill in pre-aligned states -----------------------------------------

pub fn parsed_rejects_drill_events_test() {
  let j = job()
  job.transition(j, ConfirmRegistration)
  |> should.equal(Error(IllegalTransition))
  job.transition(j, RunDryRun) |> should.equal(Error(IllegalTransition))
  job.transition(j, Complete) |> should.equal(Error(IllegalTransition))
}

pub fn registering_rejects_drill_events_test() {
  let assert Ok(j) = job.transition(job(), StartRegistering)
  job.transition(j, ConfirmRegistration)
  |> should.equal(Error(IllegalTransition))
  job.transition(j, RunDryRun) |> should.equal(Error(IllegalTransition))
  job.transition(j, Complete) |> should.equal(Error(IllegalTransition))
}

// --- catch-all --------------------------------------------------------------

pub fn unknown_event_typed_error_test() {
  // Reconnect from Parsed is not a legal edge -> typed error, not crash.
  job.transition(job(), Reconnect) |> should.equal(Error(IllegalTransition))
}

// --- legal_events / can -----------------------------------------------------

pub fn legal_events_lists_succeeding_events_test() {
  job.legal_events(job()) |> should.equal([StartRegisteringE])

  let assert Ok(registering) = job.transition(job(), StartRegistering)
  list.contains(job.legal_events(registering), job.CaptureE) |> should.be_true
  list.contains(job.legal_events(registering), job.FitE) |> should.be_true

  let aligned0 = register_with(job(), exact_corrs())
  let assert Ok(aligned) = job.transition(aligned0, Fit(0.1))
  job.legal_events(aligned)
  |> should.equal([RunDryRunE, job.RestartAlignmentE])
  list.contains(job.legal_events(aligned), ConfirmRegistrationE)
  |> should.be_false
}

pub fn can_agrees_with_legal_events_test() {
  job.can(job(), StartRegisteringE) |> should.be_true
  job.can(job(), ConfirmRegistrationE) |> should.be_false

  let aligned0 = register_with(job(), exact_corrs())
  let assert Ok(aligned) = job.transition(aligned0, Fit(0.1))
  job.can(aligned, RunDryRunE) |> should.be_true
  job.can(aligned, ConfirmRegistrationE) |> should.be_false
}

// --- full happy path --------------------------------------------------------

pub fn full_happy_path_test() {
  let j = job.new_with_tol(board(), 0.1)
  j.state |> should.equal(Parsed)

  let assert Ok(j) = job.transition(j, StartRegistering)
  j.state |> should.equal(Registering)

  let j =
    list.fold(exact_corrs(), j, fn(acc, corr) {
      let assert Ok(acc) = job.transition(acc, Capture(corr))
      acc.state |> should.equal(Registering)
      acc
    })
  pending_alignment.count(j.pending) |> should.equal(3)

  let assert Ok(j) = job.transition(j, Fit(0.1))
  j.state |> should.equal(Aligned)
  let assert Some(r) = j.residuals
  { r.max <. 1.0e-6 } |> should.be_true

  let assert Ok(j) = job.transition(j, RunDryRun)
  j.state |> should.equal(DryRun)

  let assert Ok(j) = job.transition(j, ConfirmRegistration)
  j.state |> should.equal(Drilling)

  let assert Ok(j) = job.transition(j, Complete)
  j.state |> should.equal(Done)
}
