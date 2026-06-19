//// Phase-0 de-risking spike: a pure-browser Gleam/Lustre app that drives a
//// Marlin PCB driller directly over the Web Serial API — no backend server.
////
//// The connection state machine mirrors the Elixir `PrinterConnection`
//// `:gen_statem` so illegal states are hard to reach:
////
////     Disconnected ─connect→ Idle ─energize(M17)→ Jogging ─release(M18)→ Idle
////     Idle/Jogging ─stream→ Streaming ─done→ (back to where it started)
////     any active ─halt(M112)|serial-loss→ Faulted ─reconnect→ Idle
////
//// Motion (jog / move / stream) is structurally gated behind `Jogging` (motors
//// energized) exactly like the reference — the energize-before-jog invariant.

import backend.{type Backend, type Conn}
import gleam/float
import gleam/int
import gleam/javascript/promise
import gleam/list
import gleam/string
import lustre
import lustre/attribute as a
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/event
import protocol
import transports

// ── connection state machine ─────────────────────────────────────────────────

/// The connection mode. Sum type so the view can only offer legal actions and
/// the update loop can reject illegal ones (e.g. jog while `Idle`).
pub type ConnState {
  /// No port. Only `Connect` is meaningful.
  Disconnected
  /// Connected, motors NOT energized. Jog/move/spindle are refused here.
  Idle
  /// Motors energized (after M17 + settle). Motion is allowed.
  Jogging
  /// A G-code program is in flight (ok-handshake). One line at a time.
  Streaming(StreamJob)
  /// Aborted / serial-loss. Loud, reachable from any active state.
  Faulted
}

/// A streaming job: the lines, how many are confirmed, and where to return.
pub type StreamJob {
  StreamJob(lines: List(String), idx: Int, total: Int, return_to: ReturnTo)
}

/// Where the machine returns when a stream completes — it began from Idle or
/// Jogging; we restore the originating mode so an energized session stays so.
pub type ReturnTo {
  ReturnIdle
  ReturnJogging
}

/// A pending one-shot request an inbound line completes (only `M114` here).
pub type Pending {
  PendingNone
  PendingWhere
}

pub type LogEntry {
  Tx(String)
  Rx(String)
  Info(String)
}

pub type Model {
  Model(
    backend: Backend,
    conn: ConnOpt,
    state: ConnState,
    pending: Pending,
    line_no: Int,
    baud: String,
    step: String,
    pos: PosOpt,
    log: List(LogEntry),
    error: String,
  )
}

/// `Option`-shaped wrappers kept local so the model stays a flat record.
pub type ConnOpt {
  NoConn
  HaveConn(Conn)
}

pub type PosOpt {
  NoPos
  HavePos(protocol.Position)
}

pub type Msg {
  SelectBackend(which: String)
  Connect
  Connected(Result(Conn, String))
  Disconnect
  Energize
  Release
  Jog(axis: String, sign: Float)
  MoveOrigin
  Where
  StartStream
  Halt
  Reconnect
  SetStep(String)
  SetBaud(String)
  // a confirmed write completed (or failed) — keeps the log honest and lets a
  // failed write fault the machine.
  WriteResult(Result(Nil, String))
  // an inbound line from the port's read loop.
  Inbound(String)
  // a read-loop error / serial loss.
  SerialLost(String)
}

// ── init ─────────────────────────────────────────────────────────────────────

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

fn init(_args) -> #(Model, Effect(Msg)) {
  #(
    Model(
      backend: transports.simulator(),
      conn: NoConn,
      state: Disconnected,
      pending: PendingNone,
      line_no: 0,
      baud: "115200",
      step: "1.0",
      pos: NoPos,
      log: [],
      error: "",
    ),
    effect.none(),
  )
}

// ── update ───────────────────────────────────────────────────────────────────

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    SelectBackend(which) ->
      // Only switchable while disconnected.
      case model.state {
        Disconnected -> {
          let backend = case which {
            "real" -> transports.web_serial()
            _ -> transports.simulator()
          }
          #(Model(..model, backend: backend, error: ""), effect.none())
        }
        _ -> #(model, effect.none())
      }

    SetBaud(b) -> #(Model(..model, baud: b), effect.none())
    SetStep(s) -> #(Model(..model, step: s), effect.none())

    Connect ->
      case model.backend.available() {
        False -> #(
          Model(
            ..model,
            error: model.backend.name
              <> " is unavailable in this browser (Chromium + HTTPS/localhost required)",
          ),
          effect.none(),
        )
        True -> {
          let baud = parse_int(model.baud, 115_200)
          #(
            log(
              model,
              Info(
                "connect " <> model.backend.name <> " @ " <> int.to_string(baud),
              ),
            ),
            open_effect(model.backend, baud),
          )
        }
      }

    Connected(Ok(conn)) -> {
      // Install the read loop once, then go Idle (connected, not energized).
      let m =
        Model(..model, conn: HaveConn(conn), state: Idle, line_no: 0, error: "")
      #(log(m, Info("connected")), read_effect(model.backend, conn))
    }

    Connected(Error(reason)) -> #(
      log(
        Model(..model, error: "connect failed: " <> reason),
        Info("connect failed: " <> reason),
      ),
      effect.none(),
    )

    Disconnect -> {
      let eff = case model.conn {
        HaveConn(c) -> close_effect(model.backend, c)
        NoConn -> effect.none()
      }
      #(
        Model(
          ..model,
          conn: NoConn,
          state: Disconnected,
          pending: PendingNone,
          pos: NoPos,
        ),
        eff,
      )
    }

    Energize ->
      // Idle -> Jogging. M17 is the structural entry action of Jogging.
      case model.state, model.conn {
        Idle, HaveConn(c) -> write(Model(..model, state: Jogging), c, "M17")
        _, _ -> #(refuse(model, "energize"), effect.none())
      }

    Release ->
      case model.state, model.conn {
        Jogging, HaveConn(c) -> write(Model(..model, state: Idle), c, "M18")
        _, _ -> #(refuse(model, "release"), effect.none())
      }

    Jog(axis, sign) ->
      // Energize-before-jog: only in Jogging. Sends G91 / G0 A<mm> / G90.
      case model.state, model.conn {
        Jogging, HaveConn(c) -> {
          let mm = sign *. parse_float(model.step, 1.0)
          let line = "G0 " <> axis <> protocol.format_mm(mm)
          write_many(model, c, ["G91", line, "G90"])
        }
        _, _ -> #(refuse(model, "jog (not energized)"), effect.none())
      }

    MoveOrigin ->
      // Absolute rapid to machine origin (already in G90). Gated like jog.
      case model.state, model.conn {
        Jogging, HaveConn(c) -> write(model, c, "G0 X0 Y0")
        _, _ -> #(refuse(model, "move (not energized)"), effect.none())
      }

    Where ->
      // M114 is valid in Idle or Jogging; stash a pending so the position line
      // resolves it.
      case model.state, model.conn {
        Idle, HaveConn(c) | Jogging, HaveConn(c) ->
          write(Model(..model, pending: PendingWhere), c, "M114")
        _, _ -> #(refuse(model, "where"), effect.none())
      }

    StartStream ->
      case model.state, model.conn {
        Idle, HaveConn(c) | Jogging, HaveConn(c) -> {
          let return_to = case model.state {
            Jogging -> ReturnJogging
            _ -> ReturnIdle
          }
          let lines = test_program()
          let job =
            StreamJob(
              lines: lines,
              idx: 0,
              total: list.length(lines),
              return_to: return_to,
            )
          let m = Model(..model, state: Streaming(job))
          // Entry action: send the first line.
          case lines {
            [first, ..] -> write(m, c, first)
            [] -> #(model, effect.none())
          }
        }
        _, _ -> #(refuse(model, "stream"), effect.none())
      }

    Halt ->
      // M112 is ALWAYS reachable (raw, OOB). Drives to Faulted; aborts a stream.
      case model.conn {
        HaveConn(c) ->
          write(Model(..model, state: Faulted, pending: PendingNone), c, "M112")
        NoConn -> #(Model(..model, state: Faulted), effect.none())
      }

    Reconnect ->
      // Faulted -> Idle. Line counter resets, like the reference reopen.
      case model.state {
        Faulted -> #(
          log(
            Model(..model, state: Idle, line_no: 0, error: ""),
            Info("reconnect -> idle"),
          ),
          effect.none(),
        )
        _ -> #(model, effect.none())
      }

    WriteResult(Ok(_)) -> #(model, effect.none())
    WriteResult(Error(reason)) ->
      // A write failure is treated as serial loss -> fault.
      #(
        log(
          Model(..model, state: Faulted, pending: PendingNone),
          Info("write error -> faulted: " <> reason),
        ),
        effect.none(),
      )

    SerialLost(reason) -> #(
      log(
        Model(..model, state: Faulted, pending: PendingNone),
        Info("serial loss -> faulted: " <> reason),
      ),
      effect.none(),
    )

    Inbound(line) -> handle_inbound(model, string.trim(line))
  }
}

// ── inbound line handling ────────────────────────────────────────────────────

fn handle_inbound(model: Model, line: String) -> #(Model, Effect(Msg)) {
  let model = log(model, Rx(line))
  case model.state {
    Streaming(job) -> handle_stream_reply(model, job, line)
    _ ->
      // In Idle/Jogging an inbound position line completes a pending `where`.
      case model.pending {
        PendingWhere ->
          case protocol.parse_m114(line) {
            Ok(pos) -> #(
              Model(..model, pending: PendingNone, pos: HavePos(pos)),
              effect.none(),
            )
            // Probably the trailing `ok`; keep waiting for the position line.
            Error(_) -> #(model, effect.none())
          }
        PendingNone -> #(model, effect.none())
      }
  }
}

/// The ok-handshake. `ok` confirms the current line and advances; `Resend:` /
/// `Error` re-send the current line WITHOUT advancing; other lines are ignored.
fn handle_stream_reply(
  model: Model,
  job: StreamJob,
  line: String,
) -> #(Model, Effect(Msg)) {
  case classify_reply(line) {
    ReplyOk -> {
      let next = job.idx + 1
      case next >= job.total {
        True -> {
          // All lines accepted: return to the originating mode.
          let return_state = case job.return_to {
            ReturnJogging -> Jogging
            ReturnIdle -> Idle
          }
          #(
            log(Model(..model, state: return_state), Info("stream complete")),
            effect.none(),
          )
        }
        False -> {
          let job2 = StreamJob(..job, idx: next)
          let model2 = Model(..model, state: Streaming(job2))
          case model.conn, line_at(job2.lines, next) {
            HaveConn(c), Ok(next_line) -> write(model2, c, next_line)
            _, _ -> #(model2, effect.none())
          }
        }
      }
    }
    ReplyResend ->
      // NAK / Error: re-send the CURRENT line without advancing.
      case model.conn, line_at(job.lines, job.idx) {
        HaveConn(c), Ok(cur) -> write(model, c, cur)
        _, _ -> #(model, effect.none())
      }
    ReplyOther ->
      // Position / busy / echo during a stream: informational, ignore.
      #(model, effect.none())
  }
}

type Reply {
  ReplyOk
  ReplyResend
  ReplyOther
}

fn classify_reply(line: String) -> Reply {
  case string.starts_with(line, "ok") {
    True -> ReplyOk
    False ->
      case
        string.starts_with(line, "Resend:") || string.starts_with(line, "Error")
      {
        True -> ReplyResend
        False -> ReplyOther
      }
  }
}

// ── effects: bridge backend Promises into Lustre ─────────────────────────────

fn open_effect(b: Backend, baud: Int) -> Effect(Msg) {
  use dispatch <- effect.from
  b.open(baud)
  |> promise.map(fn(res) { dispatch(Connected(res)) })
  Nil
}

fn read_effect(b: Backend, conn: Conn) -> Effect(Msg) {
  use dispatch <- effect.from
  // The read loop pushes each decoded line straight into the runtime as a Msg.
  b.start_reading(
    conn,
    fn(line) { dispatch(Inbound(line)) },
    fn(reason) { dispatch(SerialLost(reason)) },
  )
  Nil
}

fn write_effect(b: Backend, conn: Conn, payload: String) -> Effect(Msg) {
  use dispatch <- effect.from
  // Caller appends the newline (the backend writes the raw payload).
  b.write(conn, payload <> "\n")
  |> promise.map(fn(res) { dispatch(WriteResult(res)) })
  Nil
}

fn close_effect(b: Backend, conn: Conn) -> Effect(Msg) {
  use _dispatch <- effect.from
  b.close(conn)
  Nil
}

// ── write helpers (frame, log TX, emit the write effect) ─────────────────────

/// Frame one raw line, log it, advance the counter, and emit the write effect.
fn write(model: Model, conn: Conn, raw: String) -> #(Model, Effect(Msg)) {
  let #(payload, line_no) = protocol.frame(raw, model.line_no)
  let model = Model(..model, line_no: line_no)
  #(log(model, Tx(payload)), write_effect(model.backend, conn, payload))
}

/// Write several lines IN ORDER (jog: G91 / G0 / G90). Each gets its own frame
/// and TX log line. The payloads are emitted in ONE effect that writes them
/// sequentially — `effect.batch` reverses the synchronous run order, which for
/// an order-dependent sequence (set relative, move, restore absolute) silently
/// breaks motion, so we never batch independent writes for a jog.
fn write_many(
  model: Model,
  conn: Conn,
  raws: List(String),
) -> #(Model, Effect(Msg)) {
  let #(model, payloads) =
    list.fold(raws, #(model, []), fn(acc, raw) {
      let #(m, ps) = acc
      let #(payload, line_no) = protocol.frame(raw, m.line_no)
      let m2 = log(Model(..m, line_no: line_no), Tx(payload))
      #(m2, [payload, ..ps])
    })
  #(model, write_seq_effect(model.backend, conn, list.reverse(payloads)))
}

/// Write a sequence of already-framed payloads to the port in order, within a
/// single effect, so ordering is deterministic (independent of `effect.batch`).
fn write_seq_effect(
  b: Backend,
  conn: Conn,
  payloads: List(String),
) -> Effect(Msg) {
  use dispatch <- effect.from
  list.each(payloads, fn(payload) {
    b.write(conn, payload <> "\n")
    |> promise.map(fn(res) { dispatch(WriteResult(res)) })
    Nil
  })
  Nil
}

// ── small helpers ─────────────────────────────────────────────────────────────

fn refuse(model: Model, what: String) -> Model {
  log(model, Info("refused: " <> what <> " in " <> state_name(model.state)))
}

fn log(model: Model, entry: LogEntry) -> Model {
  // Newest first, capped so the DOM stays small.
  Model(..model, log: list.take([entry, ..model.log], 200))
}

fn line_at(lines: List(String), idx: Int) -> Result(String, Nil) {
  case list.drop(lines, idx) {
    [x, ..] -> Ok(x)
    [] -> Error(Nil)
  }
}

fn parse_int(s: String, default: Int) -> Int {
  case int.parse(string.trim(s)) {
    Ok(i) -> i
    Error(_) -> default
  }
}

fn parse_float(s: String, default: Float) -> Float {
  case float.parse(string.trim(s)) {
    Ok(f) -> f
    Error(_) ->
      case int.parse(string.trim(s)) {
        Ok(i) -> int.to_float(i)
        Error(_) -> default
      }
  }
}

/// A short canned test program (~35 lines) for the streaming proof. A tiny
/// raster of rapid moves with dwells / M-codes mixed in so the handshake (and
/// the sim's incremental ack) is observable.
fn test_program() -> List(String) {
  let header = ["G90", "G0 X0 Y0", "M114"]
  let moves =
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    |> list.flat_map(fn(i) {
      let x = int.to_string(i)
      let y = int.to_string(9 - i)
      ["G0 X" <> x <> " Y" <> y, "G1 X" <> x <> " Y0", "G4 P50"]
    })
  let footer = ["G0 X0 Y0", "M400"]
  list.flatten([header, moves, footer])
}

fn state_name(s: ConnState) -> String {
  case s {
    Disconnected -> "disconnected"
    Idle -> "idle"
    Jogging -> "jogging"
    Streaming(_) -> "streaming"
    Faulted -> "faulted"
  }
}

// ── view ─────────────────────────────────────────────────────────────────────

fn view(model: Model) -> Element(Msg) {
  h.div([a.class("app")], [
    h.header([a.class("topbar")], [
      h.div([a.class("brand")], [h.text("blau_drill · Phase 0 spike")]),
      state_badge(model.state),
    ]),
    h.div([a.class("cols")], [
      h.div([a.class("panel controls")], [
        backend_section(model),
        connection_section(model),
        motion_section(model),
        stream_section(model),
        abort_section(model),
        error_box(model),
      ]),
      h.div([a.class("panel logpanel")], [
        h.div([a.class("sec-title")], [h.text("TX / RX log")]),
        log_view(model),
      ]),
    ]),
  ])
}

fn state_badge(s: ConnState) -> Element(Msg) {
  h.div([a.class("badge badge-" <> state_name(s))], [
    h.text(string.uppercase(state_name(s))),
  ])
}

fn backend_section(model: Model) -> Element(Msg) {
  let connected = model.state != Disconnected
  h.div([a.class("sec")], [
    h.div([a.class("sec-title")], [h.text("Backend")]),
    h.div([a.class("row")], [
      backend_btn(model, "sim", "Simulator"),
      backend_btn(model, "real", "Web Serial"),
    ]),
    h.div([a.class("hint")], [
      h.text(case connected {
        True -> "Disconnect to switch backends."
        False -> "Selected: " <> model.backend.name
      }),
    ]),
  ])
}

fn backend_btn(model: Model, which: String, label: String) -> Element(Msg) {
  let is_sim = model.backend.name == "Simulator"
  let selected = case which {
    "sim" -> is_sim
    _ -> !is_sim
  }
  h.button(
    [
      a.class(
        "btn toggle"
        <> case selected {
          True -> " on"
          False -> ""
        },
      ),
      a.disabled(model.state != Disconnected),
      event.on_click(SelectBackend(which)),
    ],
    [h.text(label)],
  )
}

fn connection_section(model: Model) -> Element(Msg) {
  h.div([a.class("sec")], [
    h.div([a.class("sec-title")], [h.text("Connection")]),
    h.div([a.class("row")], [
      h.label([a.class("fieldlabel")], [h.text("Baud")]),
      h.input([
        a.class("num"),
        a.type_("text"),
        a.value(model.baud),
        a.disabled(model.state != Disconnected),
        event.on_input(SetBaud),
      ]),
    ]),
    h.div(
      [a.class("row")],
      case model.state {
        Disconnected -> [
          h.button([a.class("btn primary"), event.on_click(Connect)], [
            h.text("Connect"),
          ]),
        ]
        _ -> [
          h.button([a.class("btn"), event.on_click(Disconnect)], [
            h.text("Disconnect"),
          ]),
        ]
      },
    ),
  ])
}

fn motion_section(model: Model) -> Element(Msg) {
  let energized = model.state == Jogging
  let can_energize = model.state == Idle
  h.div([a.class("sec")], [
    h.div([a.class("sec-title")], [h.text("Motion")]),
    h.div([a.class("row")], [
      h.button(
        [
          a.class("btn" <> on_if(can_energize)),
          a.disabled(!can_energize),
          event.on_click(Energize),
        ],
        [h.text("Energize (M17)")],
      ),
      h.button(
        [a.class("btn"), a.disabled(!energized), event.on_click(Release)],
        [h.text("Release (M18)")],
      ),
    ]),
    h.div([a.class("row")], [
      h.label([a.class("fieldlabel")], [h.text("Step (mm)")]),
      h.input([
        a.class("num"),
        a.type_("text"),
        a.value(model.step),
        event.on_input(SetStep),
      ]),
    ]),
    jog_grid(energized),
    h.div([a.class("row")], [
      h.button(
        [a.class("btn"), a.disabled(!energized), event.on_click(MoveOrigin)],
        [h.text("Move → X0 Y0")],
      ),
      h.button(
        [
          a.class("btn"),
          a.disabled(!can_jog_or_where(model)),
          event.on_click(Where),
        ],
        [h.text("Where (M114)")],
      ),
    ]),
    pos_view(model),
    case energized {
      True -> element.none()
      False ->
        h.div([a.class("hint warn")], [
          h.text("Motion is gated: energize first (energize-before-jog)."),
        ])
    },
  ])
}

fn jog_grid(energized: Bool) -> Element(Msg) {
  let jb = fn(label, axis, sign) {
    h.button(
      [
        a.class("btn jog"),
        a.disabled(!energized),
        event.on_click(Jog(axis, sign)),
      ],
      [h.text(label)],
    )
  }
  h.div([a.class("joggrid")], [
    h.div([a.class("jogrow")], [jb("Y+", "Y", 1.0)]),
    h.div([a.class("jogrow")], [jb("X-", "X", -1.0), jb("X+", "X", 1.0)]),
    h.div([a.class("jogrow")], [jb("Y-", "Y", -1.0)]),
    h.div([a.class("jogrow")], [jb("Z+", "Z", 1.0), jb("Z-", "Z", -1.0)]),
  ])
}

fn pos_view(model: Model) -> Element(Msg) {
  case model.pos {
    HavePos(p) ->
      h.div([a.class("pos")], [
        h.text(
          "X "
          <> protocol.format_mm(p.x)
          <> "   Y "
          <> protocol.format_mm(p.y)
          <> "   Z "
          <> protocol.format_mm(p.z),
        ),
      ])
    NoPos -> h.div([a.class("pos dim")], [h.text("X —   Y —   Z —")])
  }
}

fn stream_section(model: Model) -> Element(Msg) {
  let can_stream = model.state == Idle || model.state == Jogging
  let #(sent, total) = case model.state {
    Streaming(job) -> #(job.idx, job.total)
    _ -> #(0, list.length(test_program()))
  }
  let pct = case total {
    0 -> 0
    _ -> sent * 100 / total
  }
  h.div([a.class("sec")], [
    h.div([a.class("sec-title")], [h.text("Stream test program")]),
    h.div([a.class("row")], [
      h.button(
        [
          a.class("btn primary"),
          a.disabled(!can_stream),
          event.on_click(StartStream),
        ],
        [h.text("Stream " <> int.to_string(total) <> " lines")],
      ),
    ]),
    h.div([a.class("progress")], [
      h.div([a.class("bar"), a.style("width", int.to_string(pct) <> "%")], []),
    ]),
    h.div([a.class("counter")], [
      h.text(int.to_string(sent) <> " / " <> int.to_string(total) <> " acked"),
    ]),
  ])
}

fn abort_section(model: Model) -> Element(Msg) {
  h.div([a.class("sec")], [
    h.div([a.class("row")], [
      h.button(
        [
          a.class("btn estop"),
          a.disabled(model.conn == NoConn),
          event.on_click(Halt),
        ],
        [h.text("ABORT (M112)")],
      ),
      case model.state {
        Faulted ->
          h.button([a.class("btn"), event.on_click(Reconnect)], [
            h.text("Reconnect → Idle"),
          ])
        _ -> element.none()
      },
    ]),
  ])
}

fn error_box(model: Model) -> Element(Msg) {
  case model.error {
    "" -> element.none()
    e -> h.div([a.class("errorbox")], [h.text(e)])
  }
}

fn log_view(model: Model) -> Element(Msg) {
  h.div(
    [a.class("loglist")],
    list.map(model.log, fn(entry) {
      let #(cls, prefix, text) = case entry {
        Tx(s) -> #("tx", "TX ", s)
        Rx(s) -> #("rx", "RX ", s)
        Info(s) -> #("info", ".. ", s)
      }
      h.div([a.class("logentry " <> cls)], [
        h.span([a.class("logpfx")], [h.text(prefix)]),
        h.span([], [h.text(text)]),
      ])
    }),
  )
}

fn on_if(b: Bool) -> String {
  case b {
    True -> " primary"
    False -> ""
  }
}

fn can_jog_or_where(model: Model) -> Bool {
  model.state == Idle || model.state == Jogging
}
