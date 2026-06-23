//// The minimal operator/hardware configuration the G-code generator consumes.
////
//// Machine-specific values (motion limits, serial port, spindle G-code
//// commands) are NOT hardcoded as product truth — they live as config fields.
//// This module models only what the generator's `build` actually reads (the
//// tuned Z heights / feed / spindle speed / hover); the full settings/validation
//// surface is the UI agent's territory.

/// The drilling mode: a real cut, or a spindle-off rehearsal.
pub type Mode {
  DryRun
  Drill
}

/// The G-code generator's tunables. These are the safe generic fallbacks
/// already encoded in the domain (the generator's Z/feed defaults) — not the
/// truth of any one machine. `drill_feed` is a `Float` here; the emitter formats
/// it to 5 decimals regardless of whole vs fractional (e.g. 200 -> "200.00000").
pub type GcodeConfig {
  GcodeConfig(
    mode: Mode,
    zdrill: Float,
    zsafe: Float,
    zchange: Float,
    drill_feed: Float,
    spindle_speed: Int,
    hover: Float,
    /// In-app pause mode. When `True`, the streamed program OMITS the mandatory
    /// machine-stop `M0` (touch-off + every bit change) and emits an in-band
    /// `M0_APP_PAUSE` sentinel in its place. The streaming FSM recognizes that
    /// sentinel, halts the stream there, and offers an on-screen Resume — so
    /// control stays on the app instead of the printer's panel. When `False`
    /// (the default, and any g-code export), `M0` is kept exactly as-is and no
    /// sentinel is emitted. Either way a PAUSE happens at every bit-change
    /// boundary — a bit swap is never skipped. See ADR-0009.
    app_pause: Bool,
  )
}

// Defaults from drill.cfg (tuned, carried in session config — never the
// hardware truth, just safe fallbacks for a generator call). These are the
// generator's built-in default tunables.
pub const default_zdrill = -2.5

pub const default_zsafe = 5.0

pub const default_zchange = 30.0

pub const default_drill_feed = 200.0

pub const default_spindle_speed = 255

pub const default_hover = 0.2

// `M0` is kept by default — the in-app pause workflow is opt-in (see ADR-0009).
pub const default_app_pause = False

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
    app_pause: default_app_pause,
  )
}
