# Design: faithful Marlin emulator + e2e suite

Status: ready-for-implementation
Date: 2026-06-23

## Why

This session shipped multiple bugs that the SIMULATOR could not catch because it
is too forgiving — it `ok`s every written line and models almost no real-Marlin
behavior. They only surfaced on the operator's real printer:

- Streaming hung at 0/130 — Marlin does not `ok` a blank line (sim acked it).
- (Earlier) jog disconnects — line-number desync + resend storms (sim never
  validates line numbers).
- Now: motor-enable "does nothing" on real hardware, no console error — energize
  logic is provably correct at every headless layer, so the failure is in the
  real wire interaction the sim cannot reproduce.

The current `sim_ffi.mjs` (~97 lines): acks every line, integrates G-moves for
M114, answers M114. It does NOT model motor state, blank-line handling, M0
blocking, line-number/checksum validation, or resends. So our e2e tests pass while
real hardware fails.

## Goal

A **faithful Marlin emulator** (a richer Backend, alongside the existing thin
simulator — do not remove the thin one) that models enough of the real protocol
to reproduce the bug classes we hit, plus an **e2e suite** that drives the full
operator flow (connect → energize → jog → capture → fit → dry-run → drill)
through it and asserts the real behaviors.

## What the emulator MUST model (each tied to a real bug we hit)

1. **Line-number + checksum validation (the resend handshake).** Track Marlin's
   "last line number". A numbered line `N<n> ... *<cs>` must be `N = last+1` with a
   correct XOR checksum, else reply `Error:Line Number is not Last Line Number+1,
   Last Line: <k>` + `Resend: <k+1>` and do NOT advance. Unnumbered lines are
   accepted as-is (interactive raw commands). `M110 N<k>` resets the counter.
   → reproduces the jog-desync / streaming line bugs.
2. **Blank lines.** A blank/whitespace-only line gets **NO `ok`** (matches the real
   stall). (Our sanitize fix means we never send these — the emulator proves it.)
3. **Motor state.** `M17` → motors ON; `M18`/`M84` → motors OFF. Refuse/ignore
   motion (G0/G1) when motors are OFF (or at least track the state so e2e can
   assert energize actually happened). → reproduces "motor enable not working".
4. **M0 / M1 pause.** `M0` BLOCKS — no `ok` until an explicit resume input
   (simulating the printer-panel button). → proves the app-pause (M0-omitted) path
   vs the M0 path.
5. **M114 position.** Reply `X:.. Y:.. Z:.. E:.. Count ...` then `ok`, integrating
   G0/G1 moves with G90/G91 abs/rel — like the current sim but correct.
6. **ok discipline.** Every accepted command replies exactly one `ok` (after the
   position line for M114). Ordering + `\r\n` framing like real Marlin.
7. **Optional realism (stretch):** `echo:busy: processing` during long moves; a
   `start` banner on connect; temperature autoreport ignored. Keep these optional.

## Shape / seam

- Implement as a new Backend (so it plugs into the existing `Backend` seam used by
  `transport.simulator()` / `transport.web_serial()`): e.g.
  `transport.emulator()` backed by a new `emulator_ffi.mjs` (richer than
  `sim_ffi.mjs`) OR — preferable for testability — a **pure Gleam Marlin core**
  (`control/marlin_emulator.gleam`: a pure `feed(state, line) -> #(state, replies)`)
  with a thin FFI shim that pumps it on a timer. A pure core means the emulator's
  protocol logic is UNIT-TESTABLE in Gleam (no JS), and the same core can drive
  both the e2e Backend and direct unit tests.
- Keep the thin `sim_ffi.mjs` as the fast/forgiving dev simulator; the emulator is
  the FAITHFUL one used by the e2e suite (and selectable for manual testing if
  useful).

## The e2e suite (drives the FULL flow through the emulator)

Headless tests (gleeunit, async via the existing deferred-promise FFI pattern in
`control_test`/`integration_test`) that drive the real `controller` (and where
feasible the real `app.update`) through the emulator Backend and assert:

- **connect → energize:** after `M110 N0` + `M17`, the emulator reports motors ON
  and the FSM reaches Jogging. (The regression repro — this is the test that
  should have caught "motor enable not working".)
- **jog:** a relative jog burst (`G91`/`G0`/`G90`/`M114`) advances the emulator
  position and never desyncs (raw/unnumbered ⇒ no resend). Assert no
  `Error:Line Number`/`Resend` is emitted by the emulator for the interactive path.
- **stream (dry-run/drill):** the numbered handshake runs to completion with
  correct line numbers + checksums; a deliberately corrupted line triggers a
  resend and recovers. Assert NO blank line is ever sent (sanitize), and the run
  reaches StreamComplete.
- **app-pause vs M0:** with `app_pause` on, the streamed program has no M0 and the
  FSM pauses at the sentinel; with it off, the M0 in the stream BLOCKS the emulator
  until resume.

## Invariants / acceptance

- The emulator's protocol core is pure + unit-tested (line-number validation,
  checksum, blank-no-ok, motor state, M0 block, M114).
- At least one e2e test reproduces EACH bug class above and would FAIL against the
  old behavior (e.g. an energize e2e that asserts motors-on via the emulator; a
  blank-line test that asserts no-ok).
- The thin simulator and all existing tests stay green; the emulator is additive.

## Gate

`cd /code/edgar/blau_drill && nix develop -c bash -c 'gleam build && gleam test'`
→ clean build (no warnings in touched files), all tests pass (currently 326 + new).

## NOTE on the live regression

The emulator is the tool to REPRODUCE the real-hardware energize failure. Once it
models motor state + the wire protocol, the connect→energize e2e through it should
expose whatever the real printer is doing that the thin sim masks. If it does NOT
reproduce (emulator energize works too), the failure is below the protocol layer
(the physical Web Serial open/write on that specific machine) — which would point
to a real-hardware/driver issue rather than our code, and we capture that finding.
