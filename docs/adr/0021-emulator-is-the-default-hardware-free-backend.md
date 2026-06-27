# 21. The Emulator is the default hardware-free backend; the Simulator is test-only
<a id="adr-0021"></a>

- **Status:** Accepted
- **Date:** 2026-06-27
- **Amends:** [ADR-0013](0013-faithful-emulator-motion-queue-and-envelope.md#adr-0013)
  (which made the faithful emulator a third operator-selectable backend *beside*
  the simulator).

## Context

There are two hardware-free backends behind the `Backend` seam:

- the **Simulator** (`transport.simulator()` / `sim_ffi.mjs`) — a *thin* stub: it
  acks every line ~10 ms later and answers `M114` with a fixed position. It models
  no real-hardware behaviour (no numbered ok/resend handshake, no motion queue, no
  blank-line stall, no `M0` timing). It is fast and trivial — ideal as a cheap test
  double for flows that don't care about wire fidelity.
- the **Emulator** (`transport.emulator()` / the faithful `marlin_emulator.gleam`
  core, [ADR-0013](0013-faithful-emulator-motion-queue-and-envelope.md#adr-0013)) —
  a *faithful* Marlin protocol model: line/checksum validation, the numbered
  ok/resend handshake, blank-line stalls, `M0` pauses, a motion queue + envelope +
  physical time. It reproduces real-hardware bug classes the simulator masks.

[ADR-0013](0013-faithful-emulator-motion-queue-and-envelope.md#adr-0013) exposed
**all three** (`SimBackend` / `RealBackend` / `EmuBackend`) in the operator's backend
picker, with `SimBackend` as the boot default. But to an *operator*, the thin
Simulator is the weakest choice: it is **test infrastructure leaking into the product
UI**. An operator who wants a hardware-free experience should get a *faithful* one
(the Emulator, which behaves like the real machine — pauses, motion timing, the real
handshake); an operator with hardware uses Web Serial. Offering the thin stub invites
"it worked in Simulator" confidence that the simulator cannot actually justify.

## Decision

**The operator picker offers only Web Serial and Emulator. The Emulator is the
default. The Simulator is retained as a test-only backend, not an operator choice.**

- The backend dropdown lists **Web Serial (CNC)** and **Emulator (faithful)** only.
  `SimBackend` is removed from the picker's options and its select-decoder branch.
- The boot/default backend becomes `EmuBackend` (was `SimBackend`): `init` and
  `storage.load_backend`'s fallback resolve to the Emulator — a realistic
  hardware-free mode out of the box.
- A persisted `"sim"` (an operator whose `localStorage` predates this change)
  **migrates to the default** (`EmuBackend`) on load, so no one is stranded on a
  backend the picker no longer offers.
- `model.BackendKind` keeps `SimBackend`, and `transport.simulator()` stays — the
  **test suite** still uses the thin simulator as a cheap double (e.g.
  `integration_test`, `controller_test`, `test_support`) where wire fidelity is not
  the point. `save_backend`/`load_backend` still round-trip `"sim"` for completeness
  (a test or a hand-set value can still select it), but the UI never writes it.

## Consequences

- The product UI no longer presents a backend that models nothing — "hardware-free"
  now means *faithful* by default, so an operator's pre-bench dry-run behaves like
  the bench will.
- The change is small and contained: the picker options + decoder (`shell.gleam`),
  the default (`app.gleam` `init` / `storage.load_backend`), and the `"sim"` →
  default migration. `BackendKind`, `transport.simulator()`, and the simulator's test
  uses are untouched.
- Tests that asserted "the picker offers Simulator" or "the default is SimBackend"
  update to the new default/options. Tests that construct `transport.simulator()` /
  `SimBackend` directly are unaffected.
- Trade-off: the Emulator is heavier than the thin simulator, so first connect is
  marginally slower than the instant fake. Acceptable — fidelity at the operator
  boundary is worth more than a few ms, and the cheap stub remains available to tests
  where speed matters.
