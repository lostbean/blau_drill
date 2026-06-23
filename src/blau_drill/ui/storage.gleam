//// localStorage-backed persistence for the operator Config (the settings
//// screen) and the selected backend/baud. Serialized as a simple
//// newline+`=`-delimited key/value blob (no JSON dependency); unknown / missing
//// keys fall back to the seed config so an old or partial blob still loads.

import blau_drill/domain/transform2d.{type Point, type Transform2D, Transform2D}
import blau_drill/ui/model.{type BackendKind, type Config, Config}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

const config_key = "blau_drill.config"

const backend_key = "blau_drill.backend"

// Session keys. The board source texts are stored as their own keys (they
// contain newlines, so they can't live in the `=`/newline-delimited config
// blob) and the UI prefs in a small separate blob.
const session_drl_key = "blau_drill.session.drl"

const session_edge_key = "blau_drill.session.edge"

const session_outline_key = "blau_drill.session.outline"

const session_prefs_key = "blau_drill.session.prefs"

const session_alignment_key = "blau_drill.session.alignment"

@external(javascript, "./storage_ffi.mjs", "getItem")
fn get_item(key: String) -> String

@external(javascript, "./storage_ffi.mjs", "setItem")
fn set_item(key: String, value: String) -> Nil

@external(javascript, "./storage_ffi.mjs", "removeItem")
fn remove_item(key: String) -> Nil

// ── config ───────────────────────────────────────────────────────────────────

/// Persist the operator config (best-effort; never throws).
pub fn save_config(c: Config) -> Nil {
  set_item(config_key, encode_config(c))
}

/// Load the persisted config, falling back to `seed` for any missing field (so a
/// partial or pre-existing blob still yields a complete config).
pub fn load_config(seed: Config) -> Config {
  case get_item(config_key) {
    "" -> seed
    blob -> decode_config(blob, seed)
  }
}

fn encode_config(c: Config) -> String {
  [
    #("baud", c.baud),
    #("auto_connect", bool_str(c.auto_connect)),
    #("max_x", c.max_x),
    #("max_y", c.max_y),
    #("max_z", c.max_z),
    #("spindle_on", c.spindle_on),
    #("spindle_off", c.spindle_off),
    #("pwm_max", c.pwm_max),
    #("spindle_speed", c.spindle_speed),
    #("zdrill", c.zdrill),
    #("zsafe", c.zsafe),
    #("zchange", c.zchange),
    #("drill_feed", c.drill_feed),
    #("hover", c.hover),
  ]
  |> list.map(fn(kv) { kv.0 <> "=" <> kv.1 })
  |> string.join("\n")
}

fn decode_config(blob: String, seed: Config) -> Config {
  let kv =
    blob
    |> string.split("\n")
    |> list.filter_map(fn(line) {
      case string.split_once(line, "=") {
        Ok(#(k, v)) -> Ok(#(k, v))
        Error(_) -> Error(Nil)
      }
    })
  let get = fn(key, fallback) {
    case list.key_find(kv, key) {
      Ok(v) -> v
      Error(_) -> fallback
    }
  }
  Config(
    baud: get("baud", seed.baud),
    auto_connect: get("auto_connect", bool_str(seed.auto_connect)) == "true",
    max_x: get("max_x", seed.max_x),
    max_y: get("max_y", seed.max_y),
    max_z: get("max_z", seed.max_z),
    spindle_on: get("spindle_on", seed.spindle_on),
    spindle_off: get("spindle_off", seed.spindle_off),
    pwm_max: get("pwm_max", seed.pwm_max),
    spindle_speed: get("spindle_speed", seed.spindle_speed),
    zdrill: get("zdrill", seed.zdrill),
    zsafe: get("zsafe", seed.zsafe),
    zchange: get("zchange", seed.zchange),
    drill_feed: get("drill_feed", seed.drill_feed),
    hover: get("hover", seed.hover),
  )
}

// ── backend selection ────────────────────────────────────────────────────────

/// Persist the selected transport backend.
pub fn save_backend(kind: BackendKind) -> Nil {
  let v = case kind {
    model.SimBackend -> "sim"
    model.RealBackend -> "real"
  }
  set_item(backend_key, v)
}

/// Load the selected transport backend (defaults to the simulator).
pub fn load_backend() -> BackendKind {
  case get_item(backend_key) {
    "real" -> model.RealBackend
    _ -> model.SimBackend
  }
}

fn bool_str(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

// ── session (board + UI prefs) ────────────────────────────────────────────────

/// The reload-survivable slice of a session. Deliberately holds ONLY data that
/// is cheap and safe to restore: the board source texts (re-parsed
/// deterministically) and UI preferences. It carries NO connection, alignment,
/// or run state — those are re-established fresh each load (safety model).
pub type Session {
  Session(
    drl: String,
    edge_cuts: String,
    outline_file: String,
    jog_step: Float,
    zoom: Float,
  )
}

/// Persist the session slice (best-effort). An empty `drl` clears the board keys
/// so a reload starts clean.
pub fn save_session(s: Session) -> Nil {
  case s.drl {
    "" -> {
      remove_item(session_drl_key)
      remove_item(session_edge_key)
      remove_item(session_outline_key)
    }
    drl -> {
      set_item(session_drl_key, drl)
      set_item(session_edge_key, s.edge_cuts)
      set_item(session_outline_key, s.outline_file)
    }
  }
  set_item(
    session_prefs_key,
    "jog_step="
      <> float.to_string(s.jog_step)
      <> "\nzoom="
      <> float.to_string(s.zoom),
  )
}

/// Load the persisted session slice. Returns a `Session` with `drl: ""` when no
/// board was stored; prefs fall back to the given defaults.
pub fn load_session(default_jog: Float, default_zoom: Float) -> Session {
  let prefs =
    get_item(session_prefs_key)
    |> string.split("\n")
    |> list.filter_map(fn(line) {
      case string.split_once(line, "=") {
        Ok(kv) -> Ok(kv)
        Error(_) -> Error(Nil)
      }
    })
  let get_float = fn(key, fallback) {
    case list.key_find(prefs, key) {
      Ok(v) ->
        case float.parse(v) {
          Ok(f) -> f
          Error(_) -> fallback
        }
      Error(_) -> fallback
    }
  }
  Session(
    drl: get_item(session_drl_key),
    edge_cuts: get_item(session_edge_key),
    outline_file: get_item(session_outline_key),
    jog_step: get_float("jog_step", default_jog),
    zoom: get_float("zoom", default_zoom),
  )
}

/// Forget the persisted board (e.g. on "Start new board"). Prefs are kept.
pub fn clear_session_board() -> Nil {
  remove_item(session_drl_key)
  remove_item(session_edge_key)
  remove_item(session_outline_key)
}

// ── alignment (fitted transform + captures) ──────────────────────────────────

/// The reload-survivable slice of a SOLVED alignment. Persisted on a successful
/// fit so a page reload can RESTORE the transform without re-capturing fiducials.
/// It is deliberately NOT trusted on restore: the live serial port is gone after
/// a reload, so the operator must reconnect and explicitly confirm the board has
/// not moved ("resume") before the restored alignment is re-instated. See
/// `app.init` / `ResumeAlignment`.
pub type AlignmentSave {
  AlignmentSave(
    transform: Transform2D,
    captures: List(#(Point, Point)),
    side: model.BoardSide,
    quality: Int,
    residual_max: Float,
    residual_rms: Float,
  )
}

/// Persist the alignment slice (best-effort; never throws).
pub fn save_alignment(a: AlignmentSave) -> Nil {
  set_item(session_alignment_key, encode_alignment(a))
}

/// Load the persisted alignment slice. Returns `Error(Nil)` when nothing is
/// stored or the blob is garbled — a bad/partial slice simply means "no restore".
pub fn load_alignment() -> Result(AlignmentSave, Nil) {
  case get_item(session_alignment_key) {
    "" -> Error(Nil)
    blob -> decode_alignment(blob)
  }
}

/// Forget the persisted alignment (on reset / restart / new board).
pub fn clear_alignment() -> Nil {
  remove_item(session_alignment_key)
}

/// PURE serialize of the alignment slice — newline-delimited `key=value` lines,
/// floats via `float.to_string`, captures as `bx,by,mx,my` quads joined by `;`.
/// Separated from the FFI so it is unit-testable without real localStorage.
pub fn encode_alignment(a: AlignmentSave) -> String {
  let t = a.transform
  let captures =
    a.captures
    |> list.map(fn(pair) {
      let #(#(bx, by), #(mx, my)) = pair
      float.to_string(bx)
      <> ","
      <> float.to_string(by)
      <> ","
      <> float.to_string(mx)
      <> ","
      <> float.to_string(my)
    })
    |> string.join(";")
  [
    #("a", float.to_string(t.a)),
    #("b", float.to_string(t.b)),
    #("c", float.to_string(t.c)),
    #("d", float.to_string(t.d)),
    #("tx", float.to_string(t.tx)),
    #("ty", float.to_string(t.ty)),
    #("side", side_str(a.side)),
    #("quality", int_str(a.quality)),
    #("rmax", float.to_string(a.residual_max)),
    #("rrms", float.to_string(a.residual_rms)),
    #("captures", captures),
  ]
  |> list.map(fn(kv) { kv.0 <> "=" <> kv.1 })
  |> string.join("\n")
}

/// PURE parse of the alignment slice. Returns `Error(Nil)` on any missing /
/// unparseable field (so a partial or corrupt blob just means "no restore").
pub fn decode_alignment(blob: String) -> Result(AlignmentSave, Nil) {
  let kv =
    blob
    |> string.split("\n")
    |> list.filter_map(fn(line) { string.split_once(line, "=") })
  let float_field = fn(key) {
    list.key_find(kv, key) |> result.try(fn(v) { float.parse(v) })
  }
  use a <- result.try(float_field("a"))
  use b <- result.try(float_field("b"))
  use c <- result.try(float_field("c"))
  use d <- result.try(float_field("d"))
  use tx <- result.try(float_field("tx"))
  use ty <- result.try(float_field("ty"))
  use rmax <- result.try(float_field("rmax"))
  use rrms <- result.try(float_field("rrms"))
  use side <- result.try(list.key_find(kv, "side") |> result.try(parse_side))
  use quality <- result.try(
    list.key_find(kv, "quality") |> result.try(int.parse),
  )
  use captures <- result.try(
    list.key_find(kv, "captures") |> result.try(parse_captures),
  )
  Ok(AlignmentSave(
    transform: Transform2D(a: a, b: b, c: c, d: d, tx: tx, ty: ty),
    captures: captures,
    side: side,
    quality: quality,
    residual_max: rmax,
    residual_rms: rrms,
  ))
}

// Parse the `;`-joined `bx,by,mx,my` capture quads. An empty string yields the
// empty list; any malformed quad fails the whole parse (→ no restore).
fn parse_captures(s: String) -> Result(List(#(Point, Point)), Nil) {
  case s {
    "" -> Ok([])
    _ ->
      s
      |> string.split(";")
      |> list.try_map(parse_capture)
  }
}

fn parse_capture(quad: String) -> Result(#(Point, Point), Nil) {
  case string.split(quad, ",") {
    [bx, by, mx, my] -> {
      use bx <- result.try(float.parse(bx))
      use by <- result.try(float.parse(by))
      use mx <- result.try(float.parse(mx))
      use my <- result.try(float.parse(my))
      Ok(#(#(bx, by), #(mx, my)))
    }
    _ -> Error(Nil)
  }
}

fn side_str(side: model.BoardSide) -> String {
  case side {
    model.Front -> "front"
    model.Back -> "back"
  }
}

fn parse_side(s: String) -> Result(model.BoardSide, Nil) {
  case s {
    "front" -> Ok(model.Front)
    "back" -> Ok(model.Back)
    _ -> Error(Nil)
  }
}

fn int_str(n: Int) -> String {
  int.to_string(n)
}

// ── URL hash <-> screen ───────────────────────────────────────────────────────

@external(javascript, "./storage_ffi.mjs", "getHash")
fn get_hash() -> String

@external(javascript, "./storage_ffi.mjs", "setHash")
fn set_hash(value: String) -> Nil

/// The slug used in the URL hash for a screen.
fn screen_slug(screen: model.Screen) -> String {
  case screen {
    model.Load -> "load"
    model.Align -> "align"
    model.DryRun -> "dryrun"
    model.Drill -> "drill"
    model.Done -> "done"
    model.Settings -> "settings"
  }
}

/// Reflect the current screen in the URL hash (replaceState — no history spam).
pub fn save_screen(screen: model.Screen) -> Nil {
  set_hash(screen_slug(screen))
}

/// The screen requested by the URL hash, if any. Returns `Error(Nil)` when the
/// hash is empty or unrecognized. The CALLER is responsible for capping this to
/// a safe restore target (e.g. never restore straight into Drill).
pub fn screen_from_hash() -> Result(model.Screen, Nil) {
  case get_hash() {
    "load" -> Ok(model.Load)
    "align" -> Ok(model.Align)
    "dryrun" -> Ok(model.DryRun)
    "drill" -> Ok(model.Drill)
    "done" -> Ok(model.Done)
    "settings" -> Ok(model.Settings)
    _ -> Error(Nil)
  }
}
