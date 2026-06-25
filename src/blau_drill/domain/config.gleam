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

/// A per-mode feed profile (mm/min), carried on `GcodeConfig` per mode (ADR-0015).
/// Each feed is a `Float`; the emitter formats it to 5 decimals (e.g. 200 ->
/// "200.00000").
///
/// - `xy_feed` — XY travel between holes (was an uncontrolled `G0` rapid; now a
///   controlled `G1 X.. Y.. F<xy_feed>`).
/// - `plunge_feed` — the downward Z move into the work.
/// - `retract_feed` — the upward Z move back to the safe height.
pub type FeedProfile {
  FeedProfile(xy_feed: Float, plunge_feed: Float, retract_feed: Float)
}

/// The G-code generator's tunables. These are the safe generic fallbacks
/// already encoded in the domain (the generator's Z/feed defaults) — not the
/// truth of any one machine. Feeds are carried PER MODE as `FeedProfile`s
/// (`dry_run_feeds`, `drill_feeds`); `build` selects by `mode`. Each feed is a
/// `Float`; the emitter formats it to 5 decimals regardless of whole vs
/// fractional (e.g. 200 -> "200.00000").
pub type GcodeConfig {
  GcodeConfig(
    mode: Mode,
    zdrill: Float,
    zsafe: Float,
    zchange: Float,
    dry_run_feeds: FeedProfile,
    drill_feeds: FeedProfile,
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

// The retract (upward Z) move is free travel, so it can run a touch faster than
// the cut/plunge feed: `default_drill_feed * default_retract_factor`.
pub const default_retract_factor = 1.5

// The dry-run XY travel runs faster than a real cut — the spindle is off and the
// head is only tracing the pattern to verify registration. `dry_run_feeds.xy_feed
// = default_drill_feed * default_dry_run_xy_factor` (the headline ADR-0015 ask).
pub const default_dry_run_xy_factor = 2.0

pub const default_spindle_speed = 255

pub const default_hover = 0.2

// The in-app pause workflow is the DEFAULT (ADR-0009): the operator drives the
// run from the screen, so `M0` (which blocks on the printer's own panel) is
// omitted and the app pauses/resumes the stream on screen. A streamed `M0` would
// stall the run at 0 with no on-screen prompt. A future g-code EXPORT still keeps
// `M0` (a standalone file has no app to drive it).
pub const default_app_pause = True

/// The default DRILL feed profile (ADR-0015): `xy_feed` and `plunge_feed` from
/// the tuned base, `retract_feed` a touch faster (retract is free travel).
pub fn default_drill_feeds() -> FeedProfile {
  FeedProfile(
    xy_feed: default_drill_feed,
    plunge_feed: default_drill_feed,
    retract_feed: default_drill_feed *. default_retract_factor,
  )
}

/// The default DRY-RUN feed profile (ADR-0015): `xy_feed` ~2× the drill `xy_feed`
/// (dry-run traces faster — the headline ask); `plunge_feed`/`retract_feed` match
/// the drill profile (the hover move is small).
pub fn default_dry_run_feeds() -> FeedProfile {
  FeedProfile(
    xy_feed: default_drill_feed *. default_dry_run_xy_factor,
    plunge_feed: default_drill_feed,
    retract_feed: default_drill_feed *. default_retract_factor,
  )
}

/// The default generator config — the safe `DryRun` fallbacks, before any
/// operator override.
pub fn default() -> GcodeConfig {
  GcodeConfig(
    mode: DryRun,
    zdrill: default_zdrill,
    zsafe: default_zsafe,
    zchange: default_zchange,
    dry_run_feeds: default_dry_run_feeds(),
    drill_feeds: default_drill_feeds(),
    spindle_speed: default_spindle_speed,
    hover: default_hover,
    app_pause: default_app_pause,
  )
}
