//// The minimal operator/hardware configuration the G-code generator consumes.
//// Ported from the relevant slice of `BlauDrill.Config` plus the
//// `BlauDrill.GcodeProgram` `config(opts)` defaults.
////
//// Machine-specific values (motion limits, serial port, spindle G-code
//// commands) are NOT hardcoded as product truth — they live as config fields,
//// mirroring the Elixir. This module models only what `GcodeProgram.build`
//// actually reads (the tuned Z heights / feed / spindle speed / hover); the
//// full settings/validation surface is the UI agent's territory.

/// The drilling mode: a real cut, or a spindle-off rehearsal.
pub type Mode {
  DryRun
  Drill
}

/// The G-code generator's tunables. These are the safe generic fallbacks
/// already encoded in the domain (the GcodeProgram Z/feed defaults) — not the
/// truth of any one machine. `drill_feed` is a `Float` here (the Elixir allowed
/// int or float; the emitter formats it to 5 decimals either way, e.g. 200 ->
/// "200.00000").
pub type GcodeConfig {
  GcodeConfig(
    mode: Mode,
    zdrill: Float,
    zsafe: Float,
    zchange: Float,
    drill_feed: Float,
    spindle_speed: Int,
    hover: Float,
  )
}

// Defaults from drill.cfg (tuned, carried in session config — never the
// hardware truth, just safe fallbacks for a generator call). Mirrors the
// `@default_*` module attributes in `BlauDrill.GcodeProgram`.
pub const default_zdrill = -2.5

pub const default_zsafe = 5.0

pub const default_zchange = 30.0

pub const default_drill_feed = 200.0

pub const default_spindle_speed = 255

pub const default_hover = 0.2

/// The default generator config — the safe `DryRun` fallbacks, before any
/// operator override.
pub fn default() -> GcodeConfig {
  GcodeConfig(
    mode: DryRun,
    zdrill: default_zdrill,
    zsafe: default_zsafe,
    zchange: default_zchange,
    drill_feed: default_drill_feed,
    spindle_speed: default_spindle_speed,
    hover: default_hover,
  )
}
