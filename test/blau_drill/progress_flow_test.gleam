//// The frozen-progress regression guard (ADR-0017), driven end-to-end through
//// `app.update`. This was the HEADLINE red→green test of Chunk 2; it is GREEN now
//// and stands as a regression guard against the bug returning.
////
//// THE BUG (was red before ADR-0017): dry-run drilled-count froze at 0/N because
//// `app.count_holes` greped the confirmed-line prefix for `"G0 X"`, but ADR-0015
//// changed the inter-hole travel from a `G0 X..` rapid to a controlled
//// `G1 X.. Y.. F<xy_feed>` move — so the grep counted nothing, `progress.drilled`
//// never advanced, and the board never marked a hole, even though the wire
//// streamed fine. The fix (ADR-0017) threads the typed `LineOrigin` through the
//// FSM and counts confirmed lines whose `origin.kind == DrillHoleKind` — never the
//// line's text.
////
//// THE GOTCHA (verified): with `app_pause` ON (the default), the dry-run stream
//// PAUSES at the first bit-change sentinel after the preamble + first tool block
//// (~11 lines). The DRILL holes come AFTER that pause, so a naive "feed N oks"
//// STALLS at the pause. This test drives THROUGH the pause via `ResumeDrilling`
//// (which issues `ResumeStream`), exactly as the operator does, to reach the
//// `DrillHole` lines whose confirmation must advance `drilled`.

import blau_drill/app
import blau_drill/control/controller
import blau_drill/control/printer
import blau_drill/test_support.{
  aligned_jogging_model_from, base_model, done_holes, drilled_of,
  pump_through_pause,
}
import blau_drill/ui/model
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// ── THE RED→GREEN TEST (now a regression guard) ───────────────────────────────
//
// Was RED (before ADR-0017): `app.count_holes` greped `"G0 X"`, but the inter-hole
// travel is `G1 X.. Y.. F..` (ADR-0015), so the confirmed-prefix hole count was 0
// however far the stream ran — `progress.drilled` stayed 0 and no `HoleDone` was
// marked. The assertion `drilled > 0` failed.
//
// GREEN (after ADR-0017): the FSM threads each line's `LineOrigin` through the
// `Progress` event; `apply_progress` counts confirmed `DrillHoleKind` lines and
// marks holes by `hole_id`. As `DrillHole` lines confirm, `drilled` advances past
// 0 and the matching `HoleDone` holes light up.
pub fn dry_run_progress_advances_past_zero_test() {
  let m_aligned = aligned_jogging_model_from(base_model())

  // RunDryRun: the job is DryRun and the dry-run program is STREAMING.
  let #(m_dryrun, _e1) = app.update(m_aligned, model.RunDryRun)
  controller.state(m_dryrun.controller)
  |> printer.is_streaming
  |> should.be_true

  // Drive the handshake THROUGH the first bit-change pause until at least one
  // hole confirms. (Generous fuel: the preamble + first tool block + pause come
  // before any hole.)
  let m = pump_through_pause(m_dryrun, 1, 400)

  // THE ASSERTION: progress advanced past 0 (was RED — the `"G0 X"` grep counted
  // nothing because travel is `G1 X..`) and the board marks the drilled holes.
  { drilled_of(m) > 0 } |> should.be_true
  { done_holes(m) > 0 } |> should.be_true
  // The two stay in lockstep: every drilled hole is marked Done.
  done_holes(m) |> should.equal(drilled_of(m))
}
