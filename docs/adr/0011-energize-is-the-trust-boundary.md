# 11. Energize is the trust boundary — alignment/position is FSM-scoped, never persisted
<a id="adr-0011"></a>

- **Status:** Accepted
- **Date:** 2026-06-25
- **Reaffirms:** ADR-0004 (ephemeral run state — no persistence). **Supersedes**
  the alignment-persistence/restore added in the reload work (commit 43554be):
  the fitted alignment must NOT be persisted or restored.

## Context

A real-hardware near-crash, twice: refresh → restart alignment → manually drag
the bit onto fiducial 1 with **motors OFF** → enable motors → capture 1 → click
fiducial 2. The head slammed down into the board / ran to the +X limit.

Cause: `model.head` defaults to `(0,0,0)` and only updates from an `M114` reply.
Energize emits only `M17` (no M114); capture reads the stale `model.head`; jog is
the only thing that queries position. With a motors-off manual move, no M114 ever
runs, so capture 1 records `machine = (0,0)` while the head is physically
elsewhere — and the 1-capture estimate then offsets every jump by the true
position. Worse, alignment state was DUPLICATED (the `job` FSM held it, and the
model held parallel `transform`/`captures`/confidence copies NOT bound to the FSM
state) and PERSISTED (saved to localStorage, restored on refresh) — so stale or
guessed positions survived exactly the boundaries where they become invalid.

Physical truth: **Marlin's position is only reliable while steppers stay
continuously energized.** A motors-off move (manual drag, skipped steps) is
untracked; M114 after it returns a stale belief. So you cannot recover trust by
querying — only by the operator physically re-registering.

## Decision

**Energize is the trust boundary. Position/alignment knowledge is valid ONLY
while motors stay continuously energized; ANY de-energize invalidates it.** Make
this a CODE invariant — illegal states unrepresentable — not scattered guards:

1. **De-energize resets alignment (FSM).** A job FSM `Deenergize` event, reachable
   from every alignment-bearing state, returns to `Parsed` and DISCARDS
   `pending`/`alignment`/`residuals`. Operator `Release`, serial loss, fault, and
   disconnect all drive it. A fault recover (`Reconnect`) returns to `Parsed`
   (re-register), NOT `Aligned`.
2. **Model alignment/position resets in lockstep.** The model's
   `transform`/`captures`/`captured`/`head_confidence`/`head_pos`/`quality`/
   `fit_diag` are cleared atomically with the job de-energize. The job state is the
   single source of truth for "is there a trusted alignment."
3. **No persistence of alignment/position.** localStorage holds CONFIG/params
   ONLY (per ADR-0004). The alignment-save/load/restore subsystem and the
   resume-on-refresh prompt are REMOVED. A refresh is a new runtime with nothing
   to load → blank slate by construction.
4. **Capture requires energized (Jogging).** A captured machine point can only
   come from an energized session.
5. **Click-to-jump requires ≥1 capture.** With no captures there is no transform
   and no estimate, so a jump is structurally a no-op (no phantom (0,0) origin).
   After a de-energize reset, captures are empty → jumps are inert until
   re-registration.
6. **Interactive-jump Z is RELATIVE.** The pre-fit safe-jump lifts Z by a fixed
   relative amount (`G91 Z+lift` then `G90`) before any XY move, instead of an
   absolute `zsafe` that could sit below the current (unknown) Z. Up-relative can
   never plunge regardless of datum. (The streamed drill program keeps its
   plane-relative absolute Z — that path has a solved surface plane; ADR-0010.)

**Release confirm (UX, anti-surprise):** an explicit operator Release that would
discard a non-trivial alignment shows a confirm ("De-energizing resets the
alignment — continue?"), shown ONLY when energized AND alignment exists. A bare
energize→release with nothing captured, or an involuntary fault/loss, gets no
confirm. The confirm is UX; the FSM reset is identical either way.

## Consequences

- The crash is structurally impossible: no capture/jump on a guessed position, no
  trusted alignment across a motors-off gap, no plunging "retract."
- Stricter than before: releasing motors or recovering a fault costs a re-align
  (~3–4 jog+capture clicks). This matches "every re-energize, assume the position
  may be wrong."
- A whole subsystem is DELETED (alignment persistence + reload-restore +
  resume-pending), simplifying the code and restoring ADR-0004's intent.
- Alignment state stops being duplicated/unscoped; it lives with the FSM state
  that makes it valid.
