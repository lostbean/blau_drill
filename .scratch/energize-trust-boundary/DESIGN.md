# Design: energize is the trust boundary (alignment/position is FSM-scoped, never persisted)

Status: ready-for-implementation
Date: 2026-06-25

## The safety incident

Sequence that crashed the machine (twice): refresh → restart alignment → manually
drag the bit onto fiducial 1 with **motors OFF** → enable motors → capture 1 →
click fiducial 2. The head slammed down into the board / ran to the +X limit.

## Root cause

`model.head` defaults to `Head(0,0,0)` and only updates from an `M114` reply
(jog appends M114; **energize does not**, **capture does not query**). With a
manual motors-off move, no M114 ever runs, so the app believes the head is at
(0,0) when it is physically elsewhere. Capture 1 records `machine = (0,0)`; the
1-capture estimate then offsets every jump by the true position → wild absolute
move. The Z "retract to absolute zsafe" with an unknown datum drove the bit DOWN.

Deeper cause: **alignment/position state is duplicated and unscoped.** The `job`
FSM holds `pending`/`alignment`/`residuals`, but the model ALSO holds parallel
copies (`transform`, `captures`, `captured`, `head_confidence`, `head_pos`,
`quality`, `fit_diag`, `resume_pending`) that are NOT bound to the FSM state. The
FSM has no de-energize event at all, so releasing/refreshing leaves stale
alignment the app still trusts. And alignment is PERSISTED (storage save/load +
resume-on-refresh), which trusts a position across a runtime boundary.

## The invariant (operator's framing)

**Position/alignment knowledge is valid ONLY while motors stay continuously
energized.** Any de-energize — Release, fault, serial loss, disconnect, or page
refresh (a new runtime) — invalidates it. You cannot re-establish trust by
querying M114 (Marlin's own position is unreliable after a motors-off move); only
the operator physically re-registering (jog onto fiducials, motors on) restores
trust. **No "are you sure" prompt — always reset.**

Make this a CODE invariant: illegal states (a de-energized job holding a trusted
transform; a jump with no captures; persisted alignment) must be
**unrepresentable**, enforced by the FSM/types, not scattered runtime guards.

## Decisions

1. **De-energize invalidates alignment.** Add a job FSM event (e.g.
   `Deenergize`) reachable from every alignment-bearing state
   (Registering/Aligned/AlignmentRejected/DryRun) → returns to `Parsed`,
   DISCARDING `pending`, `alignment`, `residuals`. `Release` (operator),
   `SerialLoss`/fault, and disconnect all drive it. (Drilling de-energize already
   faults; a fault is also a trust loss → on recover, re-register, NOT resume to
   Aligned — change `Faulted --Reconnect--> Aligned` to `--> Parsed`.)
   **Release confirm (anti-surprise):** an EXPLICIT operator Release that would
   discard a non-trivial alignment shows a confirm first ("De-energizing resets
   the alignment — continue?"). The confirm appears ONLY when currently energized
   AND there is alignment to lose (job past Registering / has captures). A bare
   energize→release with nothing captured needs no confirm. Fault / serial-loss /
   disconnect are involuntary → NO confirm, they just reset. The confirm is UX
   only; the FSM reset is identical either way.
2. **Alignment/position state is FSM-scoped, not duplicated.** The model's
   alignment/position fields are reset in lockstep with the job de-energize (one
   helper that clears transform/captures/captured/confidence/head_pos/quality/
   fit_diag together with the job transition). The single source of truth for "is
   there a trusted alignment" is the job state; the model fields are a render
   mirror that the de-energize path clears atomically. (Full unification of the
   duplication is a larger refactor — at minimum they MUST reset together.)
3. **No persistence of alignment/position.** REMOVE the alignment-save subsystem:
   `storage.AlignmentSave`/`save_alignment`/`load_alignment`/`clear_alignment`,
   `app.restore_alignment`, `resume_pending`, the resume panel, and the init
   restore branch. localStorage holds CONFIG/params ONLY. A refresh is a new
   runtime with no alignment to load → blank slate, by construction (no "reset on
   refresh" code needed; there is nothing to reset).
4. **Capture requires motors on (energized).** Keep/strengthen: a capture is only
   actionable in `Jogging` and the recorded machine point comes from a real,
   energized session. (Already gated on Jogging; ensure no capture path bypasses
   it.)
5. **Click-to-jump requires ≥1 capture.** With no captures there is no transform
   AND no estimate — so a jump is structurally a no-op (the `board_to_machine`
   estimate already returns `Error` on `[]` captures; ensure the marker-click and
   board-click paths both honor it and that no phantom origin exists). After a
   de-energize reset, captures are [] → jump is inert until the operator
   re-registers.
6. **Z moves are RELATIVE for jumps.** The safe-jump lifts Z by a fixed relative
   amount (`G91 Z+<lift>` then `G90`) BEFORE any XY move, instead of commanding an
   absolute `zsafe` that can be below the current (unknown) Z. Up-relative can
   never plunge regardless of datum. (The streamed drill program keeps its
   plane-relative absolute Z — that path has a fit + surface plane; this is only
   the pre-fit interactive jump.)

## Invariants to assert (tests)

- **De-energize clears alignment (FSM):** from Registering/Aligned/Rejected/DryRun,
  `Deenergize` → `Parsed` with `pending` empty, `alignment`/`residuals` None.
- **Release resets the model alignment:** after Release, model.transform =
  NoTransform, captures = [], captured = [], head_confidence = ConfNone,
  head_pos = NoHeadPos, quality = -1, job back to Parsed.
- **Fault → recover re-registers:** Faulted --Reconnect--> Parsed (not Aligned);
  no trusted transform survives a fault.
- **No alignment persistence:** the storage module exposes no alignment save/load;
  init never restores alignment; a fresh init has NoTransform / [] captures.
- **Jump needs a capture:** click-to-jump with captures == [] writes nothing
  (no MoveTo), regardless of model.head.
- **Z jump is relative:** the MoveTo write burst lifts Z relatively (G91 Z+ / G90)
  before XY; no absolute zsafe in the interactive jump.
- **Capture needs Jogging:** capture outside Jogging records nothing.

## Removal (this simplifies the codebase)

Delete the C2 persistence/restore subsystem entirely (it was built to RESTORE
alignment across refresh — now explicitly disallowed): AlignmentSave + encode/
decode + save/load/clear, restore_alignment, resume_pending field, ResumeAlignment
msg + handler, resume panel, the init restore branch, and the related tests.
Board-source + UI-pref persistence stays.

## ADR + CONTEXT

- New ADR-0011: "Energize is the trust boundary — alignment/position is
  FSM-scoped and never persisted." Amends ADR-0004 (ephemeral/no-persistence —
  reaffirms it for alignment) and supersedes the alignment-restore parts of the
  earlier reload work.
- CONTEXT: document the invariant + that localStorage is config-only.

## Gate

`cd /code/edgar/blau_drill && nix develop -c bash -c 'gleam build && gleam test'`
→ clean build, all tests pass. Emulator e2e: a Release mid-registration drops the
alignment; a jump with no captures emits nothing; the jump's Z burst is relative.
