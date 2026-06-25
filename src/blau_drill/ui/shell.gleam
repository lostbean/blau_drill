//// The persistent operator shell: the header (brand + 5-node stepper + config
//// link), the left sidebar (Control Panel header, stage nav, connection card,
//// e-stop), and the bottom telemetry/data bar. Composed from the header,
//// sidebar, connection-card and bottom-bar components.

import blau_drill/control/controller
import blau_drill/control/printer
import blau_drill/ui/model.{
  type Model, type Screen, type StageId, Align, ConnectDevice, DisconnectDevice,
  Done, Drill, DryRun, EmuBackend, GoToLog, GoToSettings, Load, Log, RealBackend,
  SelectBackend, Settings, SimBackend, StageAlign, StageDone, StageDrill,
  StageDryRun, StageLoad,
}
import blau_drill/ui/session
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

// ── Session-derived reads (ADR-0012) ─────────────────────────────────────────
// The screen + wire state are no longer stored on the model; they are projected
// from the `Session` (the job + the controller's REAL `printer.PrinterState`).

/// The current `Session`, derived from the app's real machines.
fn sess(model: Model) -> session.Session {
  session.of(model.job, model.board, controller.state(model.controller))
}

/// The current SCREEN, projected from the Session + overlay.
fn screen_of(model: Model) -> Screen {
  session.screen(sess(model), model.overlay)
}

/// The REAL wire state (the genuine `printer.PrinterState`, 6 cases) the badges
/// and gates read off — `StreamPaused` is now visible (it was lost in the old
/// 5-case mirror).
fn wire(model: Model) -> printer.PrinterState {
  session.printer_state(sess(model))
}

// ── header ──────────────────────────────────────────────────────────────────

pub fn header(model: Model) -> Element(model.Msg) {
  let current = screen_stage(screen_of(model))
  h.header([a.class("header")], [
    brand(),
    h.ol([a.class("stepper")], stepper_nodes(current)),
    h.div([a.class("header-actions")], [
      h.button(
        [
          a.class("config-link"),
          a.attribute("type", "button"),
          a.attribute("aria-label", "Serial communications log"),
          a.attribute("title", "Serial communications log"),
          event.on_click(GoToLog),
        ],
        [h.span([], [h.text("≣")]), h.span([], [h.text("Log")])],
      ),
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
    ]),
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
        h.text(control_status(wire(model))),
      ]),
    ]),
    h.div([a.class("sidebar-body")], [
      // The 5-stage sequence is shown in the top-bar stepper; the sidebar no
      // longer duplicates it.
      connection_card(model),
      h.div([a.class("sidebar-foot")], [estop(screen_of(model))]),
    ]),
  ])
}

fn connection_card(model: Model) -> Element(model.Msg) {
  let connected = session.is_connected(sess(model))
  let #(state_cls, state_label) = conn_display(wire(model))
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
              "emu" -> SelectBackend(EmuBackend)
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
          h.option(
            [a.value("emu"), a.selected(model.backend_kind == EmuBackend)],
            "Emulator (faithful)",
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
              SimBackend | EmuBackend -> "Connect"
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
    EmuBackend -> "Emulator"
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
  let state = wire(model)
  // Online = a port is open and NOT faulted (Idle/Jogging/Streaming/StreamPaused).
  let online = case state {
    printer.Disconnected | printer.Faulted -> False
    _ -> True
  }
  let status_cls = case online {
    True -> "data-bar-status online"
    False -> "data-bar-status offline"
  }
  h.footer([a.class("data-bar")], [
    h.span([a.class(status_cls)], [
      h.span([a.class("dot")], []),
      h.text(printer_label(state)),
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
    // Settings / Log have no stepper position; show Load as the resting stage.
    Settings -> StageLoad
    Log -> StageLoad
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

// These render the REAL `printer.PrinterState` (6 cases). A stream halted at an
// in-app pause (`StreamPaused`) reads as "PAUSED" — newly visible vs the old
// 5-case mirror that collapsed it into Streaming.
fn control_status(state: printer.PrinterState) -> String {
  case state {
    printer.Jogging(..) -> "Motors Live"
    printer.Streaming(..) -> "Streaming"
    printer.StreamPaused(..) -> "Paused"
    printer.Faulted -> "Faulted"
    printer.Idle(..) -> "Machine Ready"
    printer.Disconnected -> "Disconnected"
  }
}

fn printer_label(state: printer.PrinterState) -> String {
  case state {
    printer.Jogging(..) -> "MOTORS LIVE"
    printer.Streaming(..) -> "STREAMING"
    printer.StreamPaused(..) -> "PAUSED"
    printer.Idle(..) -> "CONNECTED"
    printer.Faulted -> "FAULTED"
    printer.Disconnected -> "DISCONNECTED"
  }
}

fn conn_display(state: printer.PrinterState) -> #(String, String) {
  case state {
    printer.Faulted -> #("fault", "FAULTED")
    printer.Disconnected -> #("offline", "DISCONNECTED")
    printer.Idle(..) -> #("online", "CONNECTED")
    printer.Jogging(..) -> #("online", "MOTORS LIVE")
    printer.Streaming(..) -> #("online", "STREAMING")
    printer.StreamPaused(..) -> #("online", "PAUSED")
  }
}

fn fmt(v: Float) -> String {
  // 3 decimals, mono-friendly.
  let scaled = int.to_float(float.round(v *. 1000.0)) /. 1000.0
  float.to_string(scaled)
}
