# 4. Ephemeral session state — no persistence, no database

- **Status:** Accepted
- **Date:** 2026-06-18

## Context

blau-drill drives one board through one drilling session — load → register →
align → dry-run → drill — and a session lasts minutes. The tempting default for a
Phoenix app is to add Ecto and persist boards, alignments, and job history. But
nothing in the workflow needs to outlive the session: there is one operator, one
board at a time, and the physical board itself is the durable artifact.

## Decision

State is **ephemeral**: one board per session, held as immutable values in
LiveView assigns (the parsed `BoardModel`, the captured correspondences, the
fitted `Alignment`, the emitted `GcodeProgram`). **No database, no Ecto, no
persistence layer.** Session config (serial port, baud, bed size, tool
diameters, feeds/depths) resolves **once** at session start into an immutable
config value and is never re-read mid-run. The only thing with genuine identity
is the `PrinterConnection` (see ADR-0005).

## Consequences

- Drastically simpler stack: no migrations, no schema, no DB to run alongside the
  bench laptop.
- The full domain stays as pure values flowing through pure functions, which is
  what makes the alignment math and G-code generation trivially testable.
- **Trade-off (accepted):** a crash loses the session. This is acceptable
  precisely because sessions are minutes long — the redo cost is re-uploading the
  KiCad files and re-capturing 3 fiducials, both cheap. We deliberately
  under-optimize *persistence* robustness in favour of *physical* robustness (the
  residual gate, the energize gate).
- **Reconsider if** a real need for cross-session history appears (e.g. logging
  drilled-board provenance for a batch). At that point add an append-only audit
  log, not a mutable job store — and keep the live domain ephemeral.
