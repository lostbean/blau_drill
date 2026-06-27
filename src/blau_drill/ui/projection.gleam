//// Pure PROJECTIONS of the `Model`'s machines (ADR-0018).
////
//// ADR-0018 makes the `Model` hold ONLY parameters + the nested machines (the
//// `job` FSM, the `controller`/`printer` FSM, the `applied_config` snapshot).
//// Every value that used to be a STORED shadow of those machines — alignment
//// quality, residuals, the captured fiducials, the solved transform, the live
//// head pose/confidence, the stream progress + telemetry, the bit-change modal,
//// and the completion summary — is recomputed here, each frame, from its
//// authority. Nothing is stored, so nothing can drift.
////
//// The handlers (`app.gleam`) that advance a machine no longer hand-sync these:
//// an alignment reset is just a `job` transition; a stream advance is just the
//// FSM moving. The views call these functions instead of reading `model.<field>`.
////
//// ## Authorities, by projection group
////
////   * Alignment (transform / quality / residuals / rejected / fit-diag /
////     captured / captures) ← the `job` FSM (`job.alignment`, `job.residuals`,
////     `job.pending.captured`, `job.state`, `job.tol`).
////   * Head pose / confidence ← `(transform-projection, captures-projection,
////     model.head)`, reusing the same logic the old `apply_head` /
////     `refresh_head_conf` used.
////   * Stream progress / telemetry / bit-change ← the `printer` FSM's `StreamJob`
////     (`printer.stream_rendered` + `stream_progress` + `stream_paused_reason`),
////     the board hole count, and `applied_config` (ADR-0017: typed origins, not
////     a wire-text grep; Chunk 2's StreamJob is the ONE streaming authority, so
////     there is no `stream_index` field — we read it off the FSM).
////   * Summary ← the `job` being `Done`/`Drilling`-complete + the board hole
////     count + the `bit_changes_seen` projection + the per-hole time model.

import blau_drill/control/controller
import blau_drill/control/printer
import blau_drill/domain/alignment
import blau_drill/domain/board_model
import blau_drill/domain/config
import blau_drill/domain/fit_geometry
import blau_drill/domain/gcode_program
import blau_drill/domain/job
import blau_drill/domain/transform2d
import blau_drill/ui/bridge
import blau_drill/ui/model.{
  type Head, type Model, BitChange, BothFailure, Capture, Captured, ConfAligned,
  ConfEstimate, ConfNone, ConfRough, DrillMode, DryRunMode, Fiducial,
  HaveBitChange, HaveBoard, HaveFitDiag, HaveFitGeometry, HaveFitSanity,
  HaveHeadPos, HaveJob, HaveProgress, HaveSummary, HaveTransform, NoBitChange,
  NoBoard, NoFailure, NoFitDiag, NoFitGeometry, NoFitSanity, NoHeadPos, NoJob,
  NoProgress, NoSummary, NoTransform, Progress, Summary, XyFailure, ZFailure,
}
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}

// ── alignment group (authority: the job FSM) ─────────────────────────────────

/// The solved transform, PROJECTED from `job.alignment`. Present only while the
/// job carries a TRUSTED alignment — `Aligned`/`DryRun`/`Drilling`/`Done` (the
/// states the old stored `transform` was set in, set on `apply_fit` and carried
/// forward). NOT present in `Registering`/`AlignmentRejected` (the over-tolerance
/// fit is kept on the job for inspection but was never promoted to the stored
/// `transform`) nor in `Faulted` (a fault de-energizes — the alignment is no
/// longer trusted from any state).
pub fn transform(model: Model) -> model.TransformOpt {
  case model.job {
    HaveJob(j) ->
      case j.state, j.alignment {
        job.Aligned, Some(al)
        | job.DryRun, Some(al)
        | job.Drilling, Some(al)
        | job.Done, Some(al)
        -> HaveTransform(al.transform)
        _, _ -> NoTransform
      }
    NoJob -> NoTransform
  }
}

/// The captured correspondences as `model.Capture`s, PROJECTED from
/// `job.pending.captured` (the registration authority). Mirror of the pending
/// set, in capture order.
pub fn captures(model: Model) -> List(model.Capture) {
  case model.job {
    HaveJob(j) ->
      list.map(j.pending.captured, fn(c) {
        Capture(board: c.board, machine: c.machine, machine_z: c.machine_z)
      })
    NoJob -> []
  }
}

/// The captured fiducials, PROJECTED from `job.pending.captured`. Each pending
/// correspondence's BOARD point becomes a `Captured` fiducial; the `index` is the
/// board candidate the capture matched (looked up by exact board coords). Capture
/// order is preserved.
pub fn captured(model: Model) -> List(model.Fiducial) {
  let candidates = case model.board {
    HaveBoard(b) -> b.candidates
    NoBoard -> []
  }
  case model.job {
    HaveJob(j) ->
      list.map(j.pending.captured, fn(c) {
        let #(bx, by) = c.board
        Fiducial(bx, by, candidate_index(candidates, bx, by), Captured)
      })
    NoJob -> []
  }
}

/// The board-candidate index whose point matches `#(bx, by)` (the capture's
/// board coords are taken from the candidate, so they match exactly), or -1.
fn candidate_index(
  candidates: List(#(Float, Float)),
  bx: Float,
  by: Float,
) -> Int {
  candidates
  |> list.index_map(fn(pt, i) { #(pt, i) })
  |> list.find(fn(pair) {
    let #(#(cx, cy), _i) = pair
    cx == bx && cy == by
  })
  |> fn(r) {
    case r {
      Ok(#(_pt, i)) -> i
      Error(_) -> -1
    }
  }
}

/// The fit residuals `#(max, rms)`, PROJECTED from `job.residuals` (the last
/// fit's residuals). `#(0.0, 0.0)` when not yet fitted.
pub fn residuals(model: Model) -> #(Float, Float) {
  case model.job {
    HaveJob(j) ->
      case j.residuals {
        Some(r) -> #(r.max, r.rms)
        None -> #(0.0, 0.0)
      }
    NoJob -> #(0.0, 0.0)
  }
}

/// The max residual (mm), or `0.0`. PROJECTED from `job.residuals`.
pub fn residual_max(model: Model) -> Float {
  residuals(model).0
}

/// The RMS residual (mm), or `0.0`. PROJECTED from `job.residuals`.
pub fn residual_rms(model: Model) -> Float {
  residuals(model).1
}

/// The Z-plane max residual (mm), or `0.0`. PROJECTED from `job.residuals.z_max`
/// (ADR-0020). Mirrors `residual_max` but over the fitted surface plane's
/// `machine_z` residual — the depth honesty signal that gates the fit at `n >= 4`.
pub fn z_residual_max(model: Model) -> Float {
  case model.job {
    HaveJob(j) ->
      case j.residuals {
        Some(r) -> r.z_max
        None -> 0.0
      }
    NoJob -> 0.0
  }
}

/// The Z-plane RMS residual (mm), or `0.0`. PROJECTED from `job.residuals.z_rms`.
pub fn z_residual_rms(model: Model) -> Float {
  case model.job {
    HaveJob(j) ->
      case j.residuals {
        Some(r) -> r.z_rms
        None -> 0.0
      }
    NoJob -> 0.0
  }
}

/// The capture count `n` of the last fit, or `0` before a fit. PROJECTED from
/// `job.residuals.n` (ADR-0020) — the UI needs it to show "Z unverified" at
/// `n < 4` (where the Z residual is structurally ~0 and proves nothing).
pub fn capture_count(model: Model) -> Int {
  case model.job {
    HaveJob(j) ->
      case j.residuals {
        Some(r) -> r.n
        None -> 0
      }
    NoJob -> 0
  }
}

/// The session's residual-gate tolerance (mm). PROJECTED from `job.tol` so the
/// rejected box can tell which residual (XY and/or Z) is over tolerance and label
/// the failing one (ADR-0020). `0.0` with no job.
pub fn tolerance(model: Model) -> Float {
  case model.job {
    HaveJob(j) -> j.tol
    NoJob -> 0.0
  }
}

/// Alignment quality 0..100, or `-1` when not yet fitted. PROJECTED from the
/// max residual vs `job.tol`. Quality only shows once a fit has produced
/// residuals (the job is `Aligned`/`AlignmentRejected`/`DryRun`/`Drilling`/
/// `Done`) — before that it is `-1` (the old stored sentinel).
pub fn quality(model: Model) -> Int {
  case model.job {
    HaveJob(j) ->
      case j.residuals {
        Some(r) -> quality_pct(r.max, j.tol)
        None -> -1
      }
    NoJob -> -1
  }
}

/// Quality 0..100 from residual_max vs tolerance (identical to the old
/// `app.quality_pct`): residual 0 → 100, residual == 2*tol → 0.
pub fn quality_pct(residual_max: Float, tol: Float) -> Int {
  let t = float.max(tol, 1.0e-6)
  let frac = 1.0 -. residual_max /. { 2.0 *. t }
  let clamped = float.min(float.max(frac, 0.0), 1.0)
  float.round(clamped *. 100.0)
}

/// Whether the last fit was rejected (over tolerance / degenerate). PROJECTED
/// from `job.state == AlignmentRejected`. (A degenerate fit does not transition
/// the job — the old code set `alignment_rejected: True` AND surfaced a
/// degenerate `fit_diag` on the still-`Registering` job; see `fit_diag` below,
/// which carries that guidance even though the state stays Registering. The
/// rejected BOX renders off this flag, so a degenerate fit must also flag here.
/// We can't observe "degenerate fit just happened" from a standing state — it
/// leaves the job in Registering with no residuals — so the rejected flag tracks
/// exactly the `AlignmentRejected` state, and the degenerate guidance is a
/// transient the handler surfaces via the upload-error path instead.)
pub fn alignment_rejected(model: Model) -> Bool {
  case model.job {
    HaveJob(j) ->
      case j.state {
        job.AlignmentRejected -> True
        _ -> False
      }
    NoJob -> False
  }
}

/// The actionable fit diagnosis (per-point residuals + worst + hint), PROJECTED
/// from the job's solved (but over-tolerance) alignment + its pending captures.
/// Present only in `AlignmentRejected` (where the old `fit` handler built it from
/// `alignment.point_errors(al.transform, j.pending.captured)` via
/// `bridge.diagnose_fit`). `NoFitDiag` otherwise.
pub fn fit_diag(model: Model) -> model.FitDiagOpt {
  case model.job {
    HaveJob(j) ->
      case j.state, j.alignment {
        job.AlignmentRejected, Some(al) -> {
          let errs = alignment.point_errors(al.transform, j.pending.captured)
          HaveFitDiag(bridge.diagnose_fit(errs, j.tol))
        }
        _, _ -> NoFitDiag
      }
    NoJob -> NoFitDiag
  }
}

/// The per-point DEPTH diagnosis (ADR-0020) — the Z mirror of `fit_diag`. Built
/// from `alignment.z_point_errors(al.z_plane, j.pending.captured)` (each capture's
/// distance off the fitted surface plane) via the SAME axis-agnostic
/// `bridge.diagnose_fit` builder, reusing `FitDiag`/`PointResidual`/`WorstOpt` (a
/// residual is a residual). Gated like `fit_diag` — present only in
/// `AlignmentRejected` with a solved alignment, so the rejected box can quote the
/// FAILING axis's per-point errors when DEPTH is the failure. The hint inside the
/// returned `FitDiag` is XY-flavored and unused for the Z box (the view builds the
/// DEPTH message); only `points`/`worst`/`can_override` are consumed.
pub fn z_fit_diag(model: Model) -> model.FitDiagOpt {
  case model.job {
    HaveJob(j) ->
      case j.state, j.alignment {
        job.AlignmentRejected, Some(al) -> {
          let z_errs = alignment.z_point_errors(al.z_plane, j.pending.captured)
          HaveFitDiag(bridge.diagnose_fit(z_errs, j.tol))
        }
        _, _ -> NoFitDiag
      }
    NoJob -> NoFitDiag
  }
}

/// Which of the fit's two independent quality axes is over tolerance (ADR-0020),
/// driving the rejected box's headline / per-point list / override. A fit has a
/// REGISTRATION (XY) axis (`residual_max`) and a DEPTH (Z) axis (`z_residual_max`,
/// meaningful only at `n >= 4`), each gated on the SAME `tol`. The DEPTH axis fails
/// only when MEANINGFUL — at `n < 4` a plane fits the points exactly, so Z proves
/// nothing and never counts as a failure here (it shows "unverified" instead). The
/// classification is a pure read of the residual projections; it does NOT recompute
/// or change the gate. `NoFailure` whenever the fit is not rejected.
pub fn fit_failure(model: Model) -> model.FitFailure {
  case alignment_rejected(model) {
    False -> NoFailure
    True -> {
      let tol = tolerance(model)
      let xy_over = residual_max(model) >. tol
      let z_over = capture_count(model) >= 4 && z_residual_max(model) >. tol
      case xy_over, z_over {
        True, True -> BothFailure
        False, True -> ZFailure
        True, False -> XyFailure
        // Rejected but neither residual reads over tol (shouldn't happen for a
        // residual-gated rejection); treat as the XY axis (the historical default).
        False, False -> XyFailure
      }
    }
  }
}

/// The decomposed geometry of the solved fit (ADR-0019), or `NoFitGeometry`
/// before a fit. PROJECTED from `job.alignment` with the SAME gating as
/// `transform/1` — a solved (trusted) `Alignment` exists only in
/// `Aligned`/`DryRun`/`Drilling`/`Done`, so this projection turns on/off in
/// lockstep with `transform`. The decomposition itself is pure (no math here).
pub fn fit_geometry(model: Model) -> model.FitGeometryOpt {
  case model.job {
    HaveJob(j) ->
      case j.state, j.alignment {
        job.Aligned, Some(al)
        | job.DryRun, Some(al)
        | job.Drilling, Some(al)
        | job.Done, Some(al)
        -> HaveFitGeometry(fit_geometry.decompose(al))
        _, _ -> NoFitGeometry
      }
    NoJob -> NoFitGeometry
  }
}

/// The advisory sanity verdict over the decomposed geometry (ADR-0019), or
/// `NoFitSanity` before a fit. Classifies `fit_geometry`'s result with
/// `fit_geometry.default_bands()`, so it is present iff `fit_geometry` is.
/// Advisory only — it never gates (the residuals stay the sole hard gate).
pub fn fit_sanity(model: Model) -> model.FitSanityOpt {
  case fit_geometry(model) {
    HaveFitGeometry(g) ->
      HaveFitSanity(fit_geometry.classify(g, fit_geometry.default_bands()))
    NoFitGeometry -> NoFitSanity
  }
}

// ── head pose / confidence (authority: transform + captures + head) ──────────

/// The head confidence, PROJECTED from the alignment + captures:
///   * a solved transform → `ConfAligned`;
///   * else by capture count: 0 → `ConfNone`, 1 → `ConfEstimate`, 2+ → `ConfRough`.
/// (Mirrors the old `apply_head` / `refresh_head_conf` logic exactly.)
pub fn head_confidence(model: Model) -> model.HeadConfidence {
  case transform(model) {
    HaveTransform(_) -> ConfAligned
    NoTransform ->
      case list.length(captures(model)) {
        0 -> ConfNone
        1 -> ConfEstimate
        _ -> ConfRough
      }
  }
}

/// The head's projected BOARD position for the crosshair, PROJECTED from the
/// transform (solved → inverse-project the head) or the captures (estimate), or
/// `NoHeadPos` with no captures. Mirrors `apply_head` / `refresh_head_conf`.
pub fn head_pos(model: Model) -> model.HeadPosOpt {
  case transform(model) {
    HaveTransform(t) -> HaveHeadPos(project_head(t, model.head))
    NoTransform ->
      case list.length(captures(model)) {
        0 -> NoHeadPos
        _ ->
          case bridge.board_to_machine_inverse(captures(model), model.head) {
            Ok(p) -> HaveHeadPos(p)
            Error(_) -> HaveHeadPos(#(model.head.x, model.head.y))
          }
      }
  }
}

/// Project the machine head back to a board position via the inverse transform
/// (identical to the old `app.project_head`).
pub fn project_head(t: transform2d.Transform2D, head: Head) -> #(Float, Float) {
  case transform2d.invert(t) {
    Ok(inv) -> transform2d.apply(inv, #(head.x, head.y))
    Error(_) -> #(head.x, head.y)
  }
}

// ── streaming group (authority: the printer FSM's StreamJob) ─────────────────

/// Live stream progress, PROJECTED from the FSM's `StreamJob` (the ONE streaming
/// authority, Chunk 2 / ADR-0017) + the board hole count + the job's mode. The
/// confirmed prefix's `DrillHoleKind` lines are the drilled holes (counted by
/// TYPE off `origin.kind`, never a wire grep). `NoProgress` when the run is not
/// in a streaming-capable lifecycle (the job is not `DryRun`/`Drilling`/`Done`).
pub fn progress(model: Model) -> model.ProgressOpt {
  case model.job {
    HaveJob(j) ->
      case progress_mode(j.state) {
        Some(mode) -> {
          let total = board_hole_count(model)
          let drilled = drilled_count(model)
          HaveProgress(Progress(drilled: drilled, total: total, mode: mode))
        }
        None -> NoProgress
      }
    NoJob -> NoProgress
  }
}

/// The progress mode for a lifecycle state, or `None` when no run is shown:
///   * `DryRun` → `DryRunMode`;
///   * `Drilling`/`Done` → `DrillMode` (Done keeps the drill ring at 100%);
///   * anything else → `None` (no progress panel).
fn progress_mode(state: job.State) -> option.Option(model.ProgressMode) {
  case state {
    job.DryRun -> Some(DryRunMode)
    job.Drilling -> Some(DrillMode)
    job.Done -> Some(DrillMode)
    _ -> None
  }
}

/// The number of holes confirmed drilled so far, PROJECTED from the FSM:
///   * while streaming/paused → the confirmed prefix's unique `DrillHoleKind`
///     `hole_id`s (counted by TYPE off the StreamJob, ADR-0017);
///   * the stream FINISHED → every hole is done. The standing signal is the FSM
///     state: a naturally-completed stream returns to `Idle` (the StreamJob is
///     dropped), whereas a CANCELLED stream (overlay-close / Quickstop) lands in
///     `Jogging`. So `Idle` + a streaming-capable job (`DryRun`/`Drilling`) — and
///     `Done` from any wire — means the run streamed to completion.
///   * otherwise (cancelled mid-stream, or not started) → 0.
pub fn drilled_count(model: Model) -> Int {
  let wire = controller.state(model.controller)
  case printer.is_streaming(wire) || printer.is_stream_paused(wire) {
    True -> {
      let #(sent, _total) = printer.stream_progress(wire)
      printer.stream_rendered(wire)
      |> list.take(sent)
      |> confirmed_hole_ids
      |> list.length
    }
    False ->
      // The drill/dry stream ran to completion (the FSM dropped to Idle with the
      // job still in its streaming stage — a cancel would have left it in Jogging)
      // or the operator marked the run `Done`: every hole is drilled. Otherwise
      // (cancelled mid-stream, or not started) nothing is drilled.
      case run_finished(model) {
        True -> board_hole_count(model)
        False -> 0
      }
  }
}

/// The file-order hole ids of the confirmed `DrillHole` lines (identical to the
/// old `app.confirmed_hole_ids`): read off each line's typed origin, deduped.
pub fn confirmed_hole_ids(
  rendered: List(gcode_program.RenderedLine),
) -> List(board_model.HoleId) {
  rendered
  |> list.filter_map(fn(rl) {
    case rl.origin.kind, rl.origin.hole_id {
      gcode_program.DrillHoleKind, Some(id) -> Ok(id)
      _, _ -> Error(Nil)
    }
  })
  |> list.unique
}

/// The bit-change modal, PROJECTED from the STANDING printer state (ADR-0018):
/// present ONLY while the FSM is stream-paused, reading the paused line's typed
/// `origin.pause` (`BitChange(tool)` → that tool's diameter). When not paused →
/// `NoBitChange` (no modal). This replaces the event-driven field set on
/// `StreamPausedAt` / cleared on resume; the FSM's paused state IS the standing
/// signal.
pub fn bit_change(model: Model) -> model.BitChangeOpt {
  let wire = controller.state(model.controller)
  case printer.stream_paused_reason(wire), model.job {
    Some(gcode_program.BitChange(tool: t)), HaveJob(j) ->
      HaveBitChange(BitChange(diameter: tool_diameter(j.board, t)))
    Some(gcode_program.BitChange(tool: _t)), NoJob ->
      HaveBitChange(BitChange(diameter: 0.0))
    Some(gcode_program.TouchOff), _ -> HaveBitChange(BitChange(diameter: 0.0))
    None, _ -> NoBitChange
  }
}

// ── board hole status (authority: the drilled-prefix projection) ─────────────

/// The canvas board with each hole's `status` PROJECTED from the run, rather
/// than mutated in place by the handlers (ADR-0018). The set of DONE holes is
/// the confirmed `DrillHoleKind` `hole_id`s; the single `Active` hole is the
/// lowest id not yet done (the one the board "walks" to); the rest are `Pending`.
/// Outside a run (no progress) every hole reads `Pending`.
pub fn board(model: Model) -> model.BoardOpt {
  case model.board {
    HaveBoard(b) ->
      case progress(model) {
        // A run is in view: mark by the confirmed `hole_id`s.
        HaveProgress(_) -> {
          let done_ids = done_hole_ids(model)
          let active =
            b.holes
            |> list.index_map(fn(_h, i) { i })
            |> list.filter(fn(i) { !list.contains(done_ids, i) })
            |> list.first
          let holes =
            b.holes
            |> list.index_map(fn(hole, i) {
              let status = case list.contains(done_ids, i), active == Ok(i) {
                True, _ -> model.HoleDone
                False, True -> model.Active
                False, False -> model.Pending
              }
              model.Hole(..hole, status: status)
            })
          HaveBoard(model.Board(..b, holes: holes))
        }
        // No run in view: all holes Pending (the reset state).
        NoProgress -> {
          let holes =
            list.map(b.holes, fn(h) { model.Hole(..h, status: model.Pending) })
          HaveBoard(model.Board(..b, holes: holes))
        }
      }
    NoBoard -> NoBoard
  }
}

/// The file-order ids of the holes confirmed drilled so far. While streaming,
/// these are the confirmed prefix's unique `DrillHoleKind` ids; once the run has
/// fully streamed (or is `Done`), ALL ids are done.
fn done_hole_ids(model: Model) -> List(board_model.HoleId) {
  let wire = controller.state(model.controller)
  case printer.is_streaming(wire) || printer.is_stream_paused(wire) {
    True -> {
      let #(sent, _total) = printer.stream_progress(wire)
      printer.stream_rendered(wire)
      |> list.take(sent)
      |> confirmed_hole_ids
    }
    False ->
      // Stream finished / done → every hole id; else none.
      case run_finished(model) {
        True ->
          case model.board {
            HaveBoard(b) -> b.holes |> list.index_map(fn(_h, i) { i })
            NoBoard -> []
          }
        False -> []
      }
  }
}

/// Whether the run has fully streamed (the standing FSM signal: a completed
/// stream returns to `Idle` with the job still in its streaming stage, or the
/// job is `Done`).
fn run_finished(model: Model) -> Bool {
  let wire = controller.state(model.controller)
  case model.job {
    HaveJob(j) ->
      case j.state, wire {
        job.DryRun, printer.Idle(..) -> True
        job.Drilling, printer.Idle(..) -> True
        job.Done, _ -> True
        _, _ -> False
      }
    NoJob -> False
  }
}

// ── completion summary (authority: job Done + board + applied_config) ────────

/// The completion summary, PROJECTED when the run is `Done` (the standing signal,
/// per ADR-0018 SUBTLETY): total holes (board count), total time (the full-run
/// per-hole estimate × holes — derived from `applied_config`, NOT a wall clock,
/// so no run-start timestamp is needed), and the bit changes (the `tool_order`
/// projection). `NoSummary` until the job reaches `Done`.
pub fn summary(model: Model) -> model.SummaryOpt {
  case model.job {
    HaveJob(j) ->
      case j.state {
        job.Done -> {
          let total = board_hole_count(model)
          let total_time =
            fmt_mmss(per_hole_seconds(model) *. int.to_float(total))
          HaveSummary(Summary(
            total_holes: total,
            total_time: total_time,
            bit_changes: bit_changes_seen(model),
          ))
        }
        _ -> NoSummary
      }
    NoJob -> NoSummary
  }
}

/// The bit-change count for the run, PROJECTED from the run's `tool_order`:
/// `max(len(tool_order) - 1, 0)` (one swap per tool boundary after the first).
/// The tool order is derived from the job board + alignment + `applied_config`,
/// matching the old `confirm_registration` computation. `0` with no alignment.
pub fn bit_changes_seen(model: Model) -> Int {
  case model.job {
    HaveJob(j) ->
      case j.alignment {
        Some(al) -> {
          let cfg =
            config.GcodeConfig(..model.applied_config, mode: config.Drill)
          let order = gcode_program.render_context(j.board, al, cfg).tool_order
          int.max(list.length(order) - 1, 0)
        }
        None -> 0
      }
    NoJob -> 0
  }
}

// ── telemetry (authority: applied_config + progress) ─────────────────────────

/// The current-bit telemetry string, PROJECTED from the run's first tool's
/// diameter (`"X.Xmm"`), or `"—"` with no alignment / tools. Matches the old
/// `confirm_registration` `bit_label`.
pub fn telemetry_bit(model: Model) -> String {
  case model.job {
    HaveJob(j) ->
      case j.alignment {
        Some(al) -> {
          let cfg =
            config.GcodeConfig(..model.applied_config, mode: config.Drill)
          let order = gcode_program.render_context(j.board, al, cfg).tool_order
          case order {
            [first, ..] -> fmt_mm(tool_diameter(j.board, first)) <> "mm"
            [] -> "—"
          }
        }
        None -> "—"
      }
    NoJob -> "—"
  }
}

/// The ETA telemetry string, PROJECTED from the per-hole time model × remaining
/// holes (`eta_label`). `"0:00"` when the run is fully streamed.
pub fn telemetry_eta(model: Model) -> String {
  case progress(model) {
    HaveProgress(p) -> {
      case p.drilled >= p.total && p.total > 0 {
        True -> "0:00"
        False -> eta_label(model, p.total - p.drilled)
      }
    }
    NoProgress -> "—"
  }
}

/// The spindle telemetry string, PROJECTED from the config: `"ON · <speed>/<pwm>
/// PWM"` (the old `spindle_label`). The display reads the EDITABLE config (the
/// old `confirm_registration` passed `model.config`).
pub fn telemetry_spindle(model: Model) -> String {
  spindle_label(model.config)
}

fn spindle_label(c: model.Config) -> String {
  "ON · " <> c.spindle_speed <> "/" <> c.pwm_max <> " PWM"
}

fn eta_label(model: Model, remaining: Int) -> String {
  let secs = per_hole_seconds(model) *. int.to_float(int.max(remaining, 0))
  fmt_mmss(secs)
}

fn per_hole_seconds(model: Model) -> Float {
  let cfg = model.applied_config
  let feed_per_s = float.max(cfg.drill_feeds.plunge_feed /. 60.0, 1.0e-6)
  let z_travel = case cfg.mode {
    config.Drill -> 2.0 *. { cfg.zsafe -. cfg.zdrill }
    config.DryRun -> 2.0 *. float.max(cfg.hover, 0.0)
  }
  z_travel /. feed_per_s +. 0.5
}

// ── small shared helpers ─────────────────────────────────────────────────────

fn board_hole_count(model: Model) -> Int {
  case model.board {
    HaveBoard(b) -> list.length(b.holes)
    NoBoard -> 0
  }
}

fn tool_diameter(board: board_model.BoardModel, tool: String) -> Float {
  case list.key_find(dict.to_list(board.tools), tool) {
    Ok(d) -> d
    Error(_) -> 0.0
  }
}

fn fmt_mm(d: Float) -> String {
  case d == 10.0 {
    True -> "10"
    False -> float.to_string(d)
  }
}

fn fmt_mmss(seconds: Float) -> String {
  let total = float.round(seconds)
  let mm = total / 60
  let ss = total % 60
  int.to_string(mm) <> ":" <> pad2(ss)
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}
