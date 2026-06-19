//// The session **state machine** — a pure value, never a process.
////
//// `Job` enforces the only legal order of a drilling session, so that illegal
//// sequencing is *unrepresentable* rather than merely discouraged. Each event
//// exists only in the states where it is legal — there is no "drill" in
//// `Parsed`, and crucially **no straight edge from `Aligned` to `Drilling`**
//// (the real run must route through `DryRun`). A `transition/2` that does not
//// match a legal edge returns `Error(IllegalTransition)`; it never crashes.
////
//// ## The legal transition graph
////
////     Parsed             --StartRegistering-->     Registering
////     Registering        --Capture(corr)-->        Registering   (accumulate)
////     Registering        --Fit(tol)-->             Aligned        (residuals.max <= tol)
////     Registering        --Fit(tol)-->             AlignmentRejected (residuals.max > tol)
////     {Registering|Aligned|AlignmentRejected} --RestartAlignment--> Registering (clean slate)
////     AlignmentRejected  --Recapture-->            Registering
////     Aligned            --RunDryRun-->            DryRun
////     DryRun             --RedoAlignment-->        Aligned
////     DryRun             --ConfirmRegistration-->  Drilling       (the ONLY path to drilling)
////     Drilling           --Complete-->             Done
////     Drilling           --SerialLoss(reason)-->   Faulted
////     Faulted            --Reconnect-->            Aligned
////
//// A `Fit(tol)` whose fit *fails* — `TooFew` (< 3 points) or `Degenerate`
//// (collinear/coincident board points) — does **not** transition: the job stays
//// in `Registering` and the error is returned.

import blau_drill/domain/alignment.{type Alignment, type Residuals}
import blau_drill/domain/board_model.{type BoardModel}
import blau_drill/domain/correspondence.{type Correspondence}
import blau_drill/domain/pending_alignment.{type PendingAlignment}
import gleam/option.{type Option, None, Some}

const default_tol = 0.1

/// The session lifecycle state. `AlignmentRejected` and `Faulted` are the two
/// off-ramps; `Done` is terminal.
pub type State {
  Parsed
  Registering
  Aligned
  AlignmentRejected
  DryRun
  Drilling
  Done
  Faulted
}

/// An event drives a transition. Events carry the data their guards need.
pub type Event {
  StartRegistering
  Capture(Correspondence)
  Fit(tol: Float)
  Recapture
  RestartAlignment
  RunDryRun
  RedoAlignment
  ConfirmRegistration
  Complete
  SerialLoss(reason: String)
  Reconnect
}

/// The bare *name* of an event, used by `legal_events/1` / `can?/2` so the UI
/// can enable exactly the right buttons without carrying event payloads.
pub type EventName {
  StartRegisteringE
  CaptureE
  FitE
  RecaptureE
  RestartAlignmentE
  RunDryRunE
  RedoAlignmentE
  ConfirmRegistrationE
  CompleteE
  SerialLossE
  ReconnectE
}

/// A transition failure.
///
/// * `IllegalTransition` — the event is not legal from the current state.
/// * `FitTooFew` — a `Fit` with fewer than 3 captured correspondences.
/// * `FitDegenerate` — a `Fit` whose board points are collinear/coincident.
pub type TransitionError {
  IllegalTransition
  FitTooFew
  FitDegenerate
}

/// The session value.
///
/// * `state` — the current lifecycle state.
/// * `board` — the parsed `BoardModel` carried for the whole session.
/// * `pending` — the in-progress `PendingAlignment` accumulating captures.
/// * `alignment` — the solved `Alignment`, once `Aligned` (else `None`).
/// * `residuals` — the fit residuals of the last fit (else `None`).
/// * `tol` — the session residual-gate tolerance in millimetres.
pub type Job {
  Job(
    state: State,
    board: BoardModel,
    pending: PendingAlignment,
    alignment: Option(Alignment),
    residuals: Option(Residuals),
    tol: Float,
  )
}

/// Build a fresh `Job` for `board`, in `Parsed`, with an empty
/// `PendingAlignment` and the default residual-gate tolerance.
pub fn new(board: BoardModel) -> Job {
  new_with_tol(board, default_tol)
}

/// Build a fresh `Job` with an explicit residual-gate tolerance (mm).
pub fn new_with_tol(board: BoardModel, tol: Float) -> Job {
  Job(
    state: Parsed,
    board: board,
    pending: pending_alignment.new(),
    alignment: None,
    residuals: None,
    tol: tol,
  )
}

/// Apply `event` to `job`, returning the next `Job` or a typed error.
///
/// Each clause below is exactly one legal edge of the graph. The final catch-all
/// keeps illegal sequencing a typed error rather than a crash. There is
/// deliberately **no clause taking `Aligned` to `Drilling`**.
pub fn transition(job: Job, event: Event) -> Result(Job, TransitionError) {
  case job.state, event {
    // parsed -> registering
    Parsed, StartRegistering -> Ok(Job(..job, state: Registering))

    // registering -> registering : accumulate a correspondence
    Registering, Capture(corr) ->
      Ok(Job(..job, pending: pending_alignment.add(job.pending, corr)))

    // registering -> aligned / alignment_rejected : the residual gate.
    // A failed fit (TooFew / Degenerate) does NOT transition.
    Registering, Fit(tol) ->
      case alignment.fit(job.pending.captured) {
        Ok(al) -> {
          let r = al.residuals
          case r.max <=. tol {
            True ->
              Ok(
                Job(
                  ..job,
                  state: Aligned,
                  alignment: Some(al),
                  residuals: Some(r),
                ),
              )
            False ->
              Ok(
                Job(
                  ..job,
                  state: AlignmentRejected,
                  alignment: None,
                  residuals: Some(r),
                ),
              )
          }
        }
        Error(alignment.TooFew) -> Error(FitTooFew)
        Error(alignment.Degenerate) -> Error(FitDegenerate)
      }

    // alignment_rejected -> registering : recapture
    AlignmentRejected, Recapture -> Ok(Job(..job, state: Registering))

    // {registering | aligned | alignment_rejected} -> registering :
    // start the whole alignment over (WIPES pending/alignment/residuals).
    Registering, RestartAlignment -> Ok(restart(job))
    Aligned, RestartAlignment -> Ok(restart(job))
    AlignmentRejected, RestartAlignment -> Ok(restart(job))

    // aligned -> dry_run : run the mandatory dry-run rehearsal
    Aligned, RunDryRun -> Ok(Job(..job, state: DryRun))

    // dry_run -> aligned : redo the dry-run later
    DryRun, RedoAlignment -> Ok(Job(..job, state: Aligned))

    // dry_run -> drilling : confirm registration — the ONLY path to drilling
    DryRun, ConfirmRegistration -> Ok(Job(..job, state: Drilling))

    // drilling -> done : all holes complete
    Drilling, Complete -> Ok(Job(..job, state: Done))

    // drilling -> faulted : serial loss
    Drilling, SerialLoss(_reason) -> Ok(Job(..job, state: Faulted))

    // faulted -> aligned : reconnect & resume from the solved alignment
    Faulted, Reconnect -> Ok(Job(..job, state: Aligned))

    // Catch-all: illegal sequencing is a typed error, never a crash.
    _, _ -> Error(IllegalTransition)
  }
}

fn restart(job: Job) -> Job {
  Job(
    ..job,
    state: Registering,
    pending: pending_alignment.new(),
    alignment: None,
    residuals: None,
  )
}

/// The event *names* that are legal from `job`'s current state. A UI uses this
/// to enable exactly the right buttons. The no-shortcut invariant surfaces here
/// too: `ConfirmRegistrationE` is never in the list while merely `Aligned`.
pub fn legal_events(job: Job) -> List(EventName) {
  case job.state {
    Parsed -> [StartRegisteringE]
    Registering -> [CaptureE, FitE, RestartAlignmentE]
    AlignmentRejected -> [RecaptureE, RestartAlignmentE]
    Aligned -> [RunDryRunE, RestartAlignmentE]
    DryRun -> [RedoAlignmentE, ConfirmRegistrationE]
    Drilling -> [CompleteE, SerialLossE]
    Faulted -> [ReconnectE]
    Done -> []
  }
}

/// Whether `event_name` is legal from `job`'s current state. Agrees with
/// `legal_events/1`.
pub fn can(job: Job, event_name: EventName) -> Bool {
  list_contains(legal_events(job), event_name)
}

fn list_contains(names: List(EventName), name: EventName) -> Bool {
  case names {
    [] -> False
    [first, ..rest] ->
      case first == name {
        True -> True
        False -> list_contains(rest, name)
      }
  }
}
