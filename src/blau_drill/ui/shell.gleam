//// The persistent operator shell: the header (brand + 5-node stepper + config
//// link), the left sidebar (Control Panel header, stage nav, connection card,
//// e-stop), and the bottom telemetry/data bar. Composed from the header,
//// sidebar, connection-card and bottom-bar components.

import blau_drill/ui/model.{
  type Model, type PrinterState, type Screen, type StageId, Align, ConnectDevice,
  DisconnectDevice, Disconnected, Done, Drill, DryRun, Faulted, GoToSettings,
  Idle, Jogging, Load, RealBackend, SelectBackend, Settings, SimBackend,
  StageAlign, StageDone, StageDrill, StageDryRun, StageLoad, Streaming,
}
import gleam/float
import gleam/int
import gleam/list
import gleam/order.{Eq, Gt, Lt}
import lustre/attribute as a
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/event

// The stepper / nav order.
const stages = [StageLoad, StageAlign, StageDryRun, StageDrill, StageDone]

// ── header ──────────────────────────────────────────────────────────────────

pub fn header(model: Model) -> Element(model.Msg) {
  let current = screen_stage(model.screen)
  h.header([a.class("header")], [
    brand(),
    h.ol([a.class("stepper")], stepper_nodes(current)),
    h.button(
      [
        a.class("config-link"),
        a.attribute("type", "button"),
        a.attribute("aria-label", "Printer configuration"),
        a.attribute("title", "Printer configuration"),
        event.on_click(GoToSettings),
      ],
      [h.span([], [h.text("⚙")]), h.span([], [h.text("Config")])],
    ),
  ])
}

pub fn brand() -> Element(model.Msg) {
  h.div([a.class("brand")], [
    h.span(
      [
        a.class("brand-mark material-symbols-outlined"),
        a.attribute("aria-hidden", "true"),
      ],
      [h.text("precision_manufacturing")],
    ),
    h.span([a.class("brand-word")], [h.text("blau-drill")]),
  ])
}

fn stepper_nodes(current: StageId) -> List(Element(model.Msg)) {
  let cur_i = stage_index(current)
  stages
  |> list.index_map(fn(stage, i) { #(stage, i) })
  |> list.flat_map(fn(pair) {
    let #(stage, i) = pair
    let node_cls = case int.compare(i, cur_i) {
      Lt -> "step-node done"
      Eq -> "step-node current"
      Gt -> "step-node upcoming"
    }
    let label_cls = case i == cur_i {
      True -> "step-label current"
      False -> "step-label"
    }
    let node =
      h.li([a.class("step")], [
        h.div([a.class(node_cls)], [h.text(int.to_string(i + 1))]),
        h.span([a.class(label_cls)], [h.text(stage_label(stage))]),
      ])
    case i < 4 {
      True -> [node, h.li([a.class("step-rail")], [])]
      False -> [node]
    }
  })
}

// ── sidebar ───────────────────────────────────────────────────────────────────

pub fn sidebar(model: Model) -> Element(model.Msg) {
  h.aside([a.class("sidebar")], [
    h.div([a.class("sidebar-head")], [
      h.h2([a.class("sidebar-title")], [h.text("Control Panel")]),
      h.p([a.class("sidebar-status")], [
        h.span([a.class("dot pulse-dot")], []),
        h.text(control_status(model.printer)),
      ]),
    ]),
    h.div([a.class("sidebar-body")], [
      // The 5-stage sequence is shown in the top-bar stepper; the sidebar no
      // longer duplicates it.
      connection_card(model),
      h.div([a.class("sidebar-foot")], [estop(model.screen)]),
    ]),
  ])
}

fn connection_card(model: Model) -> Element(model.Msg) {
  let connected = model.printer != Disconnected
  let #(state_cls, state_label) = conn_display(model.printer)
  h.div([a.class("conn-card")], [
    h.div([a.class("conn-row")], [
      h.span([a.class("conn-label")], [h.text("Connection")]),
      h.span([a.class("conn-state " <> state_cls)], [
        h.span([a.class("dot")], []),
        h.text(state_label),
      ]),
    ]),
    h.div([a.class("conn-picker")], [
      h.label(
        [a.attribute("for", "device-select"), a.class("visually-hidden")],
        [h.text("Backend")],
      ),
      // Backend choice: the simulator (no hardware) vs the real Web Serial port.
      // It is NOT a device list — Web Serial can't enumerate devices; the actual
      // USB device is chosen in the browser's picker when you click Connect.
      h.select(
        [
          a.id("device-select"),
          a.class("conn-select"),
          a.disabled(connected),
          a.attribute("aria-label", "Connection backend"),
          event.on_change(fn(v) {
            case v {
              "real" -> SelectBackend(RealBackend)
              _ -> SelectBackend(SimBackend)
            }
          }),
        ],
        [
          h.option(
            [a.value("sim"), a.selected(model.backend_kind == SimBackend)],
            "Simulator",
          ),
          h.option(
            [a.value("real"), a.selected(model.backend_kind == RealBackend)],
            "Web Serial (CNC)",
          ),
        ],
      ),
    ]),
    case connected {
      False ->
        h.button(
          [
            a.class("btn btn-primary btn-block"),
            a.style("margin-top", "0.75rem"),
            a.attribute("type", "button"),
            event.on_click(ConnectDevice),
          ],
          // For the real port, the click opens the browser's serial-port picker;
          // say so, since there's no in-page device list.
          [
            h.text(case model.backend_kind {
              RealBackend -> "Choose Port & Connect"
              SimBackend -> "Connect"
            }),
          ],
        )
      True ->
        h.button(
          [
            a.class("btn btn-outline btn-block"),
            a.style("margin-top", "0.75rem"),
            a.attribute("type", "button"),
            event.on_click(DisconnectDevice),
          ],
          [h.text("Disconnect")],
        )
    },
    h.p([a.class("conn-backend")], [
      h.text("Backend: " <> backend_label(model.backend_kind)),
    ]),
  ])
}

fn backend_label(kind: model.BackendKind) -> String {
  case kind {
    SimBackend -> "Simulator"
    RealBackend -> "Web Serial"
  }
}

fn estop(screen: Screen) -> Element(model.Msg) {
  case motion_stage(screen) {
    True ->
      h.button(
        [
          a.class("btn-estop"),
          a.attribute("type", "button"),
          a.attribute("aria-label", "Emergency stop"),
          event.on_click(model.Abort),
        ],
        [h.text("⚠ Emergency Stop")],
      )
    False -> element.none()
  }
}

// ── bottom data bar ───────────────────────────────────────────────────────────

pub fn data_bar(model: Model) -> Element(model.Msg) {
  let online = case model.printer {
    Idle | Jogging | Streaming -> True
    _ -> False
  }
  let status_cls = case online {
    True -> "data-bar-status online"
    False -> "data-bar-status offline"
  }
  h.footer([a.class("data-bar")], [
    h.span([a.class(status_cls)], [
      h.span([a.class("dot")], []),
      h.text(printer_label(model.printer)),
    ]),
    h.div([a.class("data-bar-coords")], [
      h.span([], [h.text("X: " <> fmt(model.head.x))]),
      h.span([], [h.text("Y: " <> fmt(model.head.y))]),
      h.span([], [h.text("Z: " <> fmt(model.head.z))]),
      h.span([a.class("sep")], [h.text("|")]),
      h.span([a.class("bit")], [h.text("Bit: " <> model.telemetry_bit)]),
    ]),
  ])
}

// ── fault banner ──────────────────────────────────────────────────────────────

pub fn fault_banner() -> Element(model.Msg) {
  h.div([a.class("fault-banner")], [
    h.span([a.class("dot blink")], []),
    h.span([a.class("label")], [
      h.text("HARDWARE DISCONNECTED. Check USB cable and power."),
    ]),
    h.button(
      [
        a.class("fault-reconnect"),
        a.attribute("type", "button"),
        event.on_click(model.Reconnect),
      ],
      [h.text("Reconnect")],
    ),
  ])
}

// ── derived display helpers ───────────────────────────────────────────────────

pub fn screen_stage(screen: Screen) -> StageId {
  case screen {
    Load -> StageLoad
    Align -> StageAlign
    DryRun -> StageDryRun
    Drill -> StageDrill
    Done -> StageDone
    // Settings has no stepper position; show Load as the resting stage.
    Settings -> StageLoad
  }
}

pub fn motion_stage(screen: Screen) -> Bool {
  case screen {
    Align | DryRun | Drill -> True
    _ -> False
  }
}

fn stage_index(stage: StageId) -> Int {
  case stage {
    StageLoad -> 0
    StageAlign -> 1
    StageDryRun -> 2
    StageDrill -> 3
    StageDone -> 4
  }
}

fn stage_label(stage: StageId) -> String {
  case stage {
    StageLoad -> "Load"
    StageAlign -> "Align"
    StageDryRun -> "Dry-run"
    StageDrill -> "Drill"
    StageDone -> "Done"
  }
}

fn control_status(state: PrinterState) -> String {
  case state {
    Jogging -> "Motors Live"
    Streaming -> "Streaming"
    Faulted -> "Faulted"
    Idle -> "Machine Ready"
    Disconnected -> "Disconnected"
  }
}

fn printer_label(state: PrinterState) -> String {
  case state {
    Jogging -> "MOTORS LIVE"
    Streaming -> "STREAMING"
    Idle -> "CONNECTED"
    Faulted -> "FAULTED"
    Disconnected -> "DISCONNECTED"
  }
}

fn conn_display(state: PrinterState) -> #(String, String) {
  case state {
    Faulted -> #("fault", "FAULTED")
    Disconnected -> #("offline", "DISCONNECTED")
    Idle -> #("online", "CONNECTED")
    Jogging -> #("online", "MOTORS LIVE")
    Streaming -> #("online", "STREAMING")
  }
}

fn fmt(v: Float) -> String {
  // 3 decimals, mono-friendly.
  let scaled = int.to_float(float.round(v *. 1000.0)) /. 1000.0
  float.to_string(scaled)
}
