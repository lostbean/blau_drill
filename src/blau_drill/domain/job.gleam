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
////     Faulted            --Reconnect-->            Parsed         (re-register; no trusted transform survives a fault)
////     {Registering|Aligned|AlignmentRejected|DryRun} --Deenergize--> Parsed (ADR-0011: de-energize discards the alignment)
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
  /// Explicit, acknowledged override of a rejected (over-tolerance) fit:
  /// `AlignmentRejected -> Aligned` on the already-solved transform. The residual
  /// gate stays a hard guard; this is the ONLY non-recapture way past it, and the
  /// UI gates it behind a deliberate confirm.
  OverrideAlignment
  RestartAlignment
  /// ADR-0011: the motors de-energized (operator Release, fault, serial loss, or
  /// disconnect). Position/alignment is valid ONLY while motors stay continuously
  /// energized, so ANY de-energize invalidates it: from an alignment-bearing state
  /// this discards the alignment and drops back to a clean `Parsed` slate. From
  /// `Parsed`/`Drilling`/`Done`/`Faulted` there is nothing to lose, so it is a
  /// benign no-op success (callers don't have to special-case it).
  Deenergize
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
  OverrideAlignmentE
  RestartAlignmentE
  DeenergizeE
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
          // ADR-0020: the residual gate is now XY-AND-Z. XY always gates; the Z
          // plane residual gates only when it is MEANINGFUL (`n >= 4`) — with < 4
          // captures a plane fits the points exactly (z_max ~0) so Z is UNVERIFIED
          // (not a failure, allowed on XY). So a fit can be XY-perfect yet
          // Z-rejected when 4+ captures expose an inconsistent capture height.
          let xy_ok = r.max <=. tol
          let z_ok = r.n < 4 || r.z_max <=. tol
          case xy_ok && z_ok {
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
              // Keep the solved (but over-tolerance) alignment so the operator
              // can inspect per-point residuals AND, with an explicit
              // acknowledged override, proceed on it. The residual gate stays a
              // hard guard — `AlignmentRejected` still has no path to drilling
              // except via `OverrideAlignment` (loud, deliberate) or recapture.
              Ok(
                Job(
                  ..job,
                  state: AlignmentRejected,
                  alignment: Some(al),
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

    // alignment_rejected -> aligned : explicit acknowledged override. Promotes
    // the already-solved (over-tolerance) alignment so the flow can continue.
    // Only legal when an alignment is actually present; the UI gates this behind
    // a deliberate confirm. The residual gate is otherwise untouched.
    AlignmentRejected, OverrideAlignment ->
      case job.alignment {
        Some(_) -> Ok(Job(..job, state: Aligned))
        None -> Error(IllegalTransition)
      }

    // {registering | aligned | alignment_rejected} -> registering :
    // start the whole alignment over (WIPES pending/alignment/residuals).
    Registering, RestartAlignment -> Ok(restart(job))
    Aligned, RestartAlignment -> Ok(restart(job))
    AlignmentRejected, RestartAlignment -> Ok(restart(job))

    // {registering | aligned | alignment_rejected | dry_run} -> parsed :
    // ADR-0011 — a de-energize (Release / fault / serial loss / disconnect)
    // invalidates the alignment, since position is valid only while the motors
    // stay continuously energized. Discard everything and drop to a clean Parsed.
    Registering, Deenergize -> Ok(deenergized(job))
    Aligned, Deenergize -> Ok(deenergized(job))
    AlignmentRejected, Deenergize -> Ok(deenergized(job))
    DryRun, Deenergize -> Ok(deenergized(job))

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

    // faulted -> parsed : ADR-0011 — a fault is a de-energize / trust loss, so
    // NO trusted transform survives it. Reconnect re-registers from a clean slate.
    Faulted, Reconnect ->
      Ok(
        Job(
          ..job,
          state: Parsed,
          pending: pending_alignment.new(),
          alignment: None,
          residuals: None,
        ),
      )

    // Deenergize from a non-alignment state (Parsed/Drilling/Done/Faulted): there
    // is nothing to invalidate, so it is a benign no-op success (so callers can
    // fire it unconditionally on any de-energize without special-casing state).
    _, Deenergize -> Ok(job)

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

// ADR-0011: a de-energize clean-slate. Like `restart`, but lands in `Parsed`
// (not `Registering`) — a de-energize invalidates the whole alignment, so the
// operator must explicitly re-start registration (energize → StartRegistering),
// it does not silently resume a capture session.
fn deenergized(job: Job) -> Job {
  Job(
    ..job,
    state: Parsed,
    pending: pending_alignment.new(),
    alignment: None,
    residuals: None,
  )
}

/// The event *names* that are legal from `job`'s current state. A UI uses this
/// to enable exactly the right buttons. The no-shortcut invariant surfaces here
/// too: `ConfirmRegistrationE` is never in the list while merely `Aligned`.
///
/// `DeenergizeE` is ALWAYS legal: `transition` accepts `Deenergize` from every
/// state (alignment states drop to a clean `Parsed`; everywhere else it is the
/// benign no-op documented above), so `legal_events` lists it in EVERY state to
/// keep the `can(j, e) ⇔ transition(j, e) succeeds` invariant for Deenergize.
pub fn legal_events(job: Job) -> List(EventName) {
  case job.state {
    Parsed -> [StartRegisteringE, DeenergizeE]
    Registering -> [CaptureE, FitE, RestartAlignmentE, DeenergizeE]
    AlignmentRejected -> [
      RecaptureE,
      OverrideAlignmentE,
      RestartAlignmentE,
      DeenergizeE,
    ]
    Aligned -> [RunDryRunE, RestartAlignmentE, DeenergizeE]
    DryRun -> [RedoAlignmentE, ConfirmRegistrationE, DeenergizeE]
    Drilling -> [CompleteE, SerialLossE, DeenergizeE]
    Faulted -> [ReconnectE, DeenergizeE]
    Done -> [DeenergizeE]
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
