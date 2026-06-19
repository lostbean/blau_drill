//// localStorage-backed persistence for the operator Config (the settings
//// screen) and the selected backend/baud. Serialized as a simple
//// newline+`=`-delimited key/value blob (no JSON dependency); unknown / missing
//// keys fall back to the seed config so an old or partial blob still loads.

import blau_drill/ui/model.{type BackendKind, type Config, Config}
import gleam/list
import gleam/string

const config_key = "blau_drill.config"

const backend_key = "blau_drill.backend"

@external(javascript, "./storage_ffi.mjs", "getItem")
fn get_item(key: String) -> String

@external(javascript, "./storage_ffi.mjs", "setItem")
fn set_item(key: String, value: String) -> Nil

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
    #("port", c.port),
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
    port: get("port", seed.port),
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
