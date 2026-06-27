//// Unit tests for the pure backend-string decode in `ui/storage`.
////
//// `storage.load_backend` reads `localStorage` (`undefined` headlessly), so we
//// exercise the PURE decode helper it delegates to — `storage.decode_backend`,
//// the single source of truth for the persisted-string → `BackendKind` mapping
//// shared by `load_backend` and the shell's picker decoder.
////
//// ADR-0021: the Emulator is the default hardware-free backend and the Simulator
//// is test-only. So the decode resolves `"real" -> RealBackend`,
//// `"emu" -> EmuBackend`, and EVERYTHING ELSE (a legacy `"sim"`, a missing key,
//// or any unknown value) -> `EmuBackend` — the new default. The legacy `"sim"`
//// case is the MIGRATION: an operator whose localStorage predates this change is
//// moved to the Emulator rather than stranded on a backend the picker dropped.

import blau_drill/ui/model.{EmuBackend, RealBackend}
import blau_drill/ui/storage
import gleeunit/should

// ── the two real picker values round-trip ─────────────────────────────────────

pub fn decode_real_is_real_backend_test() {
  storage.decode_backend("real") |> should.equal(RealBackend)
}

pub fn decode_emu_is_emu_backend_test() {
  storage.decode_backend("emu") |> should.equal(EmuBackend)
}

// ── MIGRATION: a persisted "sim" now loads as the Emulator (ADR-0021) ─────────

pub fn decode_legacy_sim_migrates_to_emulator_test() {
  storage.decode_backend("sim") |> should.equal(EmuBackend)
}

// ── the new default: missing / unknown values resolve to the Emulator ─────────

pub fn decode_missing_is_emulator_default_test() {
  storage.decode_backend("") |> should.equal(EmuBackend)
}

pub fn decode_unknown_is_emulator_default_test() {
  storage.decode_backend("definitely-not-a-backend") |> should.equal(EmuBackend)
}
