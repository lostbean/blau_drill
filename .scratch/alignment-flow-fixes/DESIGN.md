# Design: Alignment-flow fixes (4 items from hardware testing)

Status: ready-for-implementation
Date: 2026-06-23

Four pieces of feedback from real-hardware use. Each diagnosed against the code.

## Item 1 — Click-to-jump targeting

**Observed:** Can't click exactly on a fiducial target to jump there; clicking
near it does nothing useful.

**Root cause (diagnosed):**
- Fiducial marker is an SVG `<g>` with a click handler firing
  `SetCurrentTarget(index)` with `stop_propagation: True` — it SWALLOWS clicks on/
  near the marker so the board-level `JumpTo` never fires there.
- BUT `SetCurrentTarget(idx)` handler only does `noeff(Model(..model,
  current_target: idx))` — it selects the target and does NOT jump the head.
- So: clicking ON a marker selects-but-doesn't-move; clicking ELSEWHERE jumps to
  the exact point (that part already works via `jump_to` → `MoveTo` exact).

**Desired (user):**
1. Clicking ON a fiducial marker → select it AND jump the head to its CENTER.
2. Clicking elsewhere → jump to the EXACT clicked point (already works; keep it).

**Fix:** make the `SetCurrentTarget` path also jump to that fiducial's center.
Either: marker click emits a jump to the candidate's board point (so `MoveTo`
fires for the center), or `SetCurrentTarget(idx)` handler additionally issues the
jump to `candidates[idx]`. Keep board-elsewhere `JumpTo(exact)` unchanged. The
marker keeps `stop_propagation` (so a marker click is center-jump, not exact).

## Item 2 — Override must still require dry-run

**Observed:** After "Proceed anyway" (override a poor fit), dry-run didn't run —
only "realign" or "drill" were offered.

**Invariant (CONTEXT.md):** real drilling is NEVER the first thing that runs; the
Job FSM has no Aligned→Drilling edge — it must route through DryRun. Override must
NOT bypass this — it only gets past the residual gate.

**Diagnosis to confirm during impl:** `override_alignment` → `apply_fit` puts the
job in `Aligned`, `alignment_rejected: False`, screen stays `Align`. The Align
"Proceed to Dry-run" button is gated `disabled(quality < 0 || alignment_rejected)`.
After override, quality may be 0 (residual over tol) but ≥ 0, and rejected is
False, so it SHOULD enable. The reported "only drill/realign" is the DryRun
screen's UI — so either the override advanced too far, or the dry-run button was
mis-gated. REPRODUCE first, then ensure: after override, the operator lands in
Aligned and the ONLY forward path is "Proceed to Dry-run" (then Confirm→Drill from
DryRun). Add a test: `OverrideAlignment` leaves the job in `Aligned` (not DryRun/
Drilling) and `RunDryRunE` is legal, `ConfirmRegistrationE` is NOT legal directly.

## Item 3 — Preserve alignment across navigation + reload (while session live)

**Observed:** Going back from the dry-run page disconnected + forced re-alignment.

**Desired:** As long as the session is continuous (connected, motors energized,
nothing physically moved), preserve the alignment when navigating back/forward,
and across a page reload via restore-with-reconnect.

**Reality:** A browser reload DROPS the Web Serial port (JS can't serialize a live
`SerialPort`). So "still connected after reload" is impossible — reload must
re-establish the port. Two cases:

- **Back/forward navigation (no reload):** alignment already lives in the model
  (`model.transform`, `model.captures`, the `job`). Navigation only changes
  `screen`. Going back must NOT disconnect or reset alignment. DIAGNOSE the
  reported disconnect: `redo_alignment`/`NavStage`/`GoToSession` don't call
  disconnect in the code — the drop was likely streaming-mid-dry-run + back, or a
  real serial loss. FIX: navigating back from DryRun (RedoAlignment / nav) must
  preserve the connection and the alignment; only abort the in-flight STREAM if
  one is running (Halt the stream, stay connected), never drop the port or clear
  the transform. After going back, the operator can re-proceed since the job is
  still Aligned and the head still holds position.

- **Reload:** persist the alignment to localStorage (the fitted transform +
  captures + board side + job stage up to Aligned). On reload: restore them, but
  the port is gone — so present a "reconnect & resume" path: reconnect the port,
  then an explicit "the board has not moved — resume alignment" confirm that
  re-instates `transform`/`ConfAligned` WITHOUT re-capturing. Never silently
  trust it (the residual gate's spirit: a human confirms the physical setup).
  Cap like the existing screen-restore: never restore straight into Drilling.

**Scope note:** this is the largest item. Implement nav-preservation first
(pure-ish, high value, fixes the reported bug), then reload-restore.

## Item 4 — Mark the worst / per-point residual on the canvas

**Observed:** The rejected-fit panel names "Point 3 = 0.12mm" but nothing on the
canvas shows WHICH dot that is.

**Have:** `bridge.diagnose_fit` already produces `model.FitDiag` with per-point
`PointResidual(index, error_mm)` and the worst. The captured fiducials are drawn
on the canvas with a `FiducialState` (Captured/Current/FidPending).

**Fix:** after a fit, annotate each CAPTURED fiducial on the canvas with its
residual: color/flag by error (worst = red/distinct), and render the error value
(e.g. "0.12") next to the marker. Thread the per-point residuals (by fiducial
index) into the canvas `Fiducial`/`CanvasData` so the marker can show its error
and whether it's the worst. Keep it legible (small mono label; only show after a
fit / when rejected).

## Gate (every chunk)

`cd /code/edgar/blau_drill && nix develop -c bash -c 'gleam build && gleam test'`
→ clean build (no warnings in touched files), all tests pass (currently 254 + new).
Plus: coordinator verifies the behavioral fixes in a real browser (this is exactly
where the bugs were invisible to unit tests).
