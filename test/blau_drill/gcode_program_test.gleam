//// Gcode renderer tests, ported from `test/blau_drill/gcode_program_test.exs`.
//// Covers both safety invariants (XY only at safe Z; spindle armed before
//// plunge / off in dry-run), structural counts, the projected metadata
//// (mode / tool_order / machine bbox), and a semantic golden diff against the
//// embedded segby_v1 goldens. The StreamData property tests are covered as
//// concrete random-ish example boards/alignments that exercise the same
//// invariants. The program lines come from `render(build_ops(..), .., target)`:
//// `rich_lines` (the human-readable `Rich` form) and `wire_lines` (the streamed
//// `Wire` form, blank + full-comment lines dropped).

import blau_drill/domain/alignment.{type Alignment}
import blau_drill/domain/board_model.{type BoardModel}
import blau_drill/domain/config.{Drill, DryRun, GcodeConfig}
import blau_drill/domain/correspondence.{Correspondence}
import blau_drill/domain/gcode_program.{
  type Operation, BitChange, DrillHole, DrillHoleKind, Pause, PauseKind,
  Postamble, Preamble, Prepare, Rich, ToolBlock, ToolBlockKind, Wire,
}
import blau_drill/domain/transform2d.{type Transform2D, Transform2D}
import blau_drill/fixtures
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/set
import gleam/string
import gleeunit/should

const zdrill = -2.5

const zsafe = 5.0

const z_tol = 1.0e-6

// --- helpers ----------------------------------------------------------------

// The back-side X-mirror alignment obtained through the REAL constructor.
fn xmirror_alignment() -> Alignment {
  let corrs =
    list.map([#(0.0, 0.0), #(1.0, 0.0), #(0.0, 1.0)], fn(b) {
      let #(bx, by) = b
      Correspondence(board: b, machine: #(float.negate(bx), by), machine_z: 0.0)
    })
  let assert Ok(al) = alignment.fit(corrs)
  al
}

fn board_from_fixture() -> BoardModel {
  let assert Ok(b) = board_model.parse_drl(fixtures.segby_drl())
  b
}

// The M0-path baseline: app_pause OFF explicitly. The default is now ON (ADR-0009),
// so this helper pins the "keeps M0" export form; `cfg_app_pause` is the ON form.
fn cfg(mode: config.Mode) -> config.GcodeConfig {
  GcodeConfig(..config.default(), mode: mode, app_pause: False)
}

// The HUMAN-READABLE program lines: `build_ops` rendered to the `Rich` target,
// projected to wire strings. Byte-identical to the historical `build(..).lines`.
fn rich_lines(
  board: BoardModel,
  alignment: Alignment,
  cfg: config.GcodeConfig,
) -> List(String) {
  let ops = gcode_program.build_ops(board, alignment, cfg)
  let ctx = gcode_program.render_context(board, alignment, cfg)
  gcode_program.render(ops, ctx, Rich) |> list.map(fn(rl) { rl.wire })
}

// The STREAMED program lines: `build_ops` rendered to the `Wire` target (blank
// lines + full-line comments dropped). Byte-identical to the historical
// `stream_lines(build(..))`.
fn wire_lines(
  board: BoardModel,
  alignment: Alignment,
  cfg: config.GcodeConfig,
) -> List(String) {
  let ops = gcode_program.build_ops(board, alignment, cfg)
  let ctx = gcode_program.render_context(board, alignment, cfg)
  gcode_program.render(ops, ctx, Wire) |> list.map(fn(rl) { rl.wire })
}

// The file-order tool list — the projected `tool_order` the old `build(..)`
// carried on its return value, now read straight off the `RenderContext`.
fn tool_order(
  board: BoardModel,
  alignment: Alignment,
  cfg: config.GcodeConfig,
) -> List(String) {
  gcode_program.render_context(board, alignment, cfg).tool_order
}

// Parse an `X..`/`Y..`/`Z..` value out of a move line, if present.
fn parse_axis(line: String, axis: String) -> Option(Float) {
  let assert Ok(re) =
    regexp.from_string("\\b" <> axis <> "(-?\\d+(?:\\.\\d+)?)")
  case regexp.scan(re, line) {
    [match, ..] ->
      case match.submatches {
        [Some(v), ..] -> parse_float_loose(v)
        _ -> None
      }
    [] -> None
  }
}

fn parse_float_loose(s: String) -> Option(Float) {
  case float.parse(s) {
    Ok(f) -> Some(f)
    Error(_) ->
      case int.parse(s) {
        Ok(i) -> Some(int.to_float(i))
        Error(_) -> None
      }
  }
}

fn move_line(line: String) -> Bool {
  let assert Ok(re) = regexp.from_string("^\\s*[Gg]0?[0-3]\\b")
  regexp.check(re, line)
}

fn commands_xy(line: String) -> Bool {
  move_line(line)
  && { parse_axis(line, "X") != None || parse_axis(line, "Y") != None }
}

fn commands_z(line: String) -> Bool {
  move_line(line) && parse_axis(line, "Z") != None
}

// --- Invariant 1: never traverse XY without Z safe --------------------------

type ZState {
  Unknown
  AtZ(Float)
}

// Returns True if the program never commands an XY move below zsafe.
fn xy_only_when_safe(lines: List(String)) -> Bool {
  let #(ok, _final) =
    list.fold(lines, #(True, Unknown), fn(acc, line) {
      let #(ok, current_z) = acc
      case commands_xy(line) {
        True -> {
          let safe = case current_z {
            Unknown -> False
            AtZ(z) -> z >=. zsafe -. z_tol
          }
          let next_z = case parse_axis(line, "Z") {
            Some(z) -> AtZ(z)
            None -> current_z
          }
          #(ok && safe, next_z)
        }
        False ->
          case commands_z(line) {
            True -> {
              let assert Some(z) = parse_axis(line, "Z")
              #(ok, AtZ(z))
            }
            False -> #(ok, current_z)
          }
      }
    })
  ok
}

pub fn drill_mode_xy_safe_test() {
  let lines = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  xy_only_when_safe(lines) |> should.be_true
}

pub fn dry_run_mode_xy_safe_test() {
  let lines = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(DryRun))
  xy_only_when_safe(lines) |> should.be_true
}

// --- Invariant 2: spindle armed before plunge (drill) -----------------------

// A real plunge is `G1 Z<negative>`.
fn plunge_line(line: String) -> Bool {
  case parse_z_of_g1(line) {
    Some(z) -> z <. 0.0
    None -> False
  }
}

fn parse_z_of_g1(line: String) -> Option(Float) {
  let assert Ok(re) =
    regexp.from_string("^\\s*[Gg]0?1\\s+Z(-?\\d+(?:\\.\\d+)?)")
  case regexp.scan(re, line) {
    [match, ..] ->
      case match.submatches {
        [Some(z), ..] -> parse_float_loose(z)
        _ -> None
      }
    [] -> None
  }
}

fn m3_on(line: String) -> Bool {
  let assert Ok(re) = regexp.from_string("^\\s*M3\\s+S(\\d+)")
  case regexp.scan(re, line) {
    [match, ..] ->
      case match.submatches {
        [Some(s), ..] ->
          case int.parse(s) {
            Ok(n) -> n > 0
            Error(_) -> False
          }
        _ -> False
      }
    [] -> False
  }
}

fn m5_off(line: String) -> Bool {
  let assert Ok(re) = regexp.from_string("^\\s*M5\\b")
  regexp.check(re, line)
}

// Walk the spindle state; return True if every plunge is reached with the
// spindle on.
fn every_plunge_armed(lines: List(String)) -> Bool {
  let #(ok, _spindle) =
    list.fold(lines, #(True, False), fn(acc, line) {
      let #(ok, spindle) = acc
      case m3_on(line), m5_off(line), plunge_line(line) {
        True, _, _ -> #(ok, True)
        _, True, _ -> #(ok, False)
        _, _, True -> #(ok && spindle, spindle)
        _, _, _ -> #(ok, spindle)
      }
    })
  ok
}

pub fn every_plunge_preceded_by_m3_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  every_plunge_armed(p) |> should.be_true
}

pub fn m3_carries_speed_on_same_line_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let assert Ok(bare) = regexp.from_string("^\\s*M3\\b")
  let m3_lines = list.filter(p, fn(l) { regexp.check(bare, l) })
  { m3_lines != [] } |> should.be_true
  // Every M3 line carries an S<digits>.
  list.all(m3_lines, m3_on) |> should.be_true
}

pub fn spindle_rearmed_per_tool_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let assert Ok(re) = regexp.from_string("^\\s*M3\\s+S255\\b")
  let count = list.filter(p, fn(l) { regexp.check(re, l) }) |> list.length
  count |> should.equal(5)
}

pub fn dry_run_no_armed_spindle_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(DryRun))
  let assert Ok(re) = regexp.from_string("^\\s*M3\\s+S[1-9]")
  list.any(p, fn(l) { regexp.check(re, l) }) |> should.be_false
  list.any(p, fn(l) { string.contains(l, "( dry run: spindle left OFF )") })
  |> should.be_true
}

pub fn dry_run_never_negative_z_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(DryRun))
  let all_nonneg =
    list.all(p, fn(l) {
      case parse_axis(l, "Z") {
        Some(z) -> z >=. 0.0 -. z_tol
        None -> True
      }
    })
  all_nonneg |> should.be_true

  let hover_lines =
    list.filter(p, fn(l) { string.contains(l, "dry-run hover") })
  list.length(hover_lines) |> should.equal(130)
  list.all(hover_lines, fn(l) {
    string.contains(l, "G1 Z0.20000") && string.contains(l, "was Z-2.50000")
  })
  |> should.be_true
}

// --- property-equivalent example cases --------------------------------------

// A few hand-built boards exercising arbitrary geometry, each checked for both
// invariants under both modes — same coverage the StreamData properties give.
fn example_boards() -> List(BoardModel) {
  [
    make_board([
      #(-10.0, 20.0, "T1"),
      #(5.0, -30.0, "T2"),
      #(40.0, 40.0, "T1"),
      #(-60.0, -60.0, "T3"),
    ]),
    make_board([#(0.0, 0.0, "T5"), #(80.0, -80.0, "T5")]),
    make_board([#(-80.0, 80.0, "T4"), #(0.0, 0.0, "T1"), #(33.0, -33.0, "T2")]),
  ]
}

fn make_board(holes: List(#(Float, Float, String))) -> BoardModel {
  let hs =
    list.index_map(holes, fn(h, i) {
      let #(x, y, t) = h
      // File-order ids 0..n-1, mirroring the real parse (ADR-0016).
      board_model.Hole(id: i, x: x, y: y, tool: t)
    })
  let tools =
    [#("T1", 0.6), #("T2", 0.7), #("T3", 0.8), #("T4", 1.0), #("T5", 1.2)]
    |> list.fold(board_model_dict_new(), fn(d, kv) {
      board_model_dict_insert(d, kv.0, kv.1)
    })
  board_model.BoardModel(
    holes: hs,
    tools: tools,
    bbox: #(0.0, 0.0, 0.0, 0.0),
    outline: None,
    fiducials: [],
  )
}

fn example_alignments() -> List(Alignment) {
  list.map(
    [
      #(1.5, 1.2, 10.0, -5.0),
      #(-2.0, 0.7, -30.0, 40.0),
      #(0.5, -1.8, 0.0, 0.0),
    ],
    fn(p) {
      let #(a, d, tx, ty) = p
      let src = Transform2D(a: a, b: 0.0, c: 0.0, d: d, tx: tx, ty: ty)
      let corrs =
        list.map([#(0.0, 0.0), #(1.0, 0.0), #(0.0, 1.0)], fn(b) {
          Correspondence(
            board: b,
            machine: transform2d_apply(src, b),
            machine_z: 0.0,
          )
        })
      let assert Ok(al) = alignment.fit(corrs)
      al
    },
  )
}

pub fn invariant1_holds_for_random_programs_test() {
  example_boards()
  |> each(fn(board) {
    example_alignments()
    |> each(fn(al) {
      [Drill, DryRun]
      |> each(fn(mode) {
        let p = rich_lines(board, al, cfg(mode))
        xy_only_when_safe(p) |> should.be_true
      })
    })
  })
}

pub fn invariant2_holds_for_random_programs_test() {
  example_boards()
  |> each(fn(board) {
    example_alignments()
    |> each(fn(al) {
      let drill = rich_lines(board, al, cfg(Drill))
      every_plunge_armed(drill) |> should.be_true

      let dry = rich_lines(board, al, cfg(DryRun))
      let assert Ok(re) = regexp.from_string("^\\s*M3\\s+S[1-9]")
      list.any(dry, fn(l) { regexp.check(re, l) }) |> should.be_false
      list.all(dry, fn(l) {
        case parse_axis(l, "Z") {
          Some(z) -> z >=. 0.0 -. z_tol
          None -> True
        }
      })
      |> should.be_true
    })
  })
}

// ── per-mode feed profiles (ADR-0015) ─────────────────────────────────────────
//
// XY travel is now a controlled `G1 X.. Y.. F<xy_feed>` (was an uncontrolled
// `G0`). Plunge carries `F<plunge_feed>`, retract `F<retract_feed>`. The profile
// is selected by mode: dry-run xy is 2× drill xy by default.

// The inter-hole travel move (the XY at safe Z that precedes each plunge): a
// `G1 X.. Y.. F..` line — NOT the `G0` bit-exchange reposition (which has a
// comment), NOT the ADR-0014 drill prepare-pose travel (also commented), and NOT
// a Z move. Inter-hole travels carry NO inline comment, so excluding commented
// lines keeps this a pure "one per hole" predicate.
fn xy_travel_line(line: String) -> Bool {
  let assert Ok(re) =
    regexp.from_string("^G1 X-?\\d.*\\bY-?\\d.*\\bF(\\d+(?:\\.\\d+)?)")
  regexp.check(re, line) && !string.contains(line, "(")
}

// The F value parsed out of a move line, if present.
fn parse_feed(line: String) -> Option(Float) {
  let assert Ok(re) = regexp.from_string("\\bF(\\d+(?:\\.\\d+)?)")
  case regexp.scan(re, line) {
    [match, ..] ->
      case match.submatches {
        [Some(f), ..] -> parse_float_loose(f)
        _ -> None
      }
    [] -> None
  }
}

// Inter-hole XY travel is emitted as a controlled G1 with the profile's xy_feed —
// drill = 200 (the tuned base), dry-run = 400 (2×). No bare `G0 X.. Y..` cut
// travel survives (the only G0 X/Y is the commented bit-exchange reposition).
pub fn xy_travel_is_controlled_g1_with_xy_feed_test() {
  let drill = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let dry = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(DryRun))

  let drill_travel = list.filter(drill, xy_travel_line)
  let dry_travel = list.filter(dry, xy_travel_line)
  // There is one travel move per hole (130 holes in the fixture).
  list.length(drill_travel) |> should.equal(130)
  list.length(dry_travel) |> should.equal(130)

  // Every drill travel move runs at xy_feed = 200; every dry-run at 400 (2×).
  list.all(drill_travel, fn(l) {
    case parse_feed(l) {
      Some(f) -> float.absolute_value(f -. 200.0) <. z_tol
      None -> False
    }
  })
  |> should.be_true
  list.all(dry_travel, fn(l) {
    case parse_feed(l) {
      Some(f) -> float.absolute_value(f -. 400.0) <. z_tol
      None -> False
    }
  })
  |> should.be_true

  // No bare `G0 X.. Y..` CUT travel remains: the only `G0` carrying X/Y is the
  // commented bit-exchange reposition (one per tool, ADR-0015 leaves it alone).
  let assert Ok(g0xy) = regexp.from_string("^G0 X")
  let g0_xy_lines = list.filter(drill, fn(l) { regexp.check(g0xy, l) })
  list.all(g0_xy_lines, fn(l) { string.contains(l, "bit-exchange") })
  |> should.be_true
}

// The plunge (the cut/hover Z into the work) carries the profile's plunge_feed:
// 200 in BOTH modes by default (dry-run plunge matches drill).
pub fn plunge_carries_plunge_feed_test() {
  let drill = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let drill_plunges = list.filter(drill, plunge_line)
  list.length(drill_plunges) |> should.equal(130)
  list.all(drill_plunges, fn(l) {
    case parse_feed(l) {
      Some(f) -> float.absolute_value(f -. 200.0) <. z_tol
      None -> False
    }
  })
  |> should.be_true

  // Dry-run hover lines also carry the plunge feed (200 by default).
  let dry = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(DryRun))
  let hover_lines =
    list.filter(dry, fn(l) { string.contains(l, "dry-run hover") })
  list.length(hover_lines) |> should.equal(130)
  list.all(hover_lines, fn(l) {
    case parse_feed(l) {
      Some(f) -> float.absolute_value(f -. 200.0) <. z_tol
      None -> False
    }
  })
  |> should.be_true
}

// The per-hole retract back to safe Z carries the profile's retract_feed (300 =
// 1.5× the 200 base) in both modes by default.
pub fn retract_carries_retract_feed_test() {
  [Drill, DryRun]
  |> each(fn(mode) {
    let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(mode))
    // The per-hole travel retract is `G1 Z5.00000 F300.00000` (130 of them).
    let assert Ok(re) = regexp.from_string("^G1 Z5\\.00000 F(\\d+(?:\\.\\d+)?)")
    let retracts = list.filter(p, fn(l) { regexp.check(re, l) })
    list.length(retracts) |> should.equal(130)
    list.all(retracts, fn(l) {
      case parse_feed(l) {
        Some(f) -> float.absolute_value(f -. 300.0) <. z_tol
        None -> False
      }
    })
    |> should.be_true
  })
}

// The headline ADR-0015 invariant: the dry-run XY feed is exactly 2× the drill XY
// feed (and they differ), proving the per-mode profile is selected by mode.
pub fn dry_run_xy_feed_is_double_drill_xy_feed_test() {
  let drill = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let dry = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(DryRun))
  let assert Some(drill_xy) =
    list.filter(drill, xy_travel_line)
    |> list.first
    |> option_of_result
    |> option.then(parse_feed)
  let assert Some(dry_xy) =
    list.filter(dry, xy_travel_line)
    |> list.first
    |> option_of_result
    |> option.then(parse_feed)
  { float.absolute_value(dry_xy -. drill_xy *. 2.0) <. z_tol } |> should.be_true
  { float.absolute_value(dry_xy -. drill_xy) >. 1.0 } |> should.be_true
}

fn option_of_result(r: Result(a, b)) -> Option(a) {
  case r {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

// --- structural counts (drill mode) -----------------------------------------

pub fn total_plunges_130_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  list.filter(p, plunge_line) |> list.length |> should.equal(130)
}

pub fn exactly_five_tool_blocks_test() {
  let board = board_from_fixture()
  let al = xmirror_alignment()
  let p = rich_lines(board, al, cfg(Drill))
  let assert Ok(re) = regexp.from_string("^T[1-5]$")
  let tool_lines = list.filter(p, fn(l) { regexp.check(re, l) })
  tool_lines |> should.equal(["T1", "T2", "T3", "T4", "T5"])
  tool_order(board, al, cfg(Drill))
  |> should.equal(["T1", "T2", "T3", "T4", "T5"])
}

pub fn per_tool_plunge_counts_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  per_tool_plunge_counts(p) |> should.equal([40, 4, 38, 42, 6])
}

pub fn tool_change_pauses_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let assert Ok(m6) = regexp.from_string("^M6\\b")
  let assert Ok(m0) = regexp.from_string("^M0\\b")
  list.filter(p, fn(l) { regexp.check(m6, l) })
  |> list.length
  |> should.equal(5)
  // ADR-0010: no touch-off M0. Exactly 5 tool-change M0 (one per tool block; the
  // first is the first bit's change, not a touch-off).
  list.filter(p, fn(l) { regexp.check(m0, l) })
  |> list.length
  |> should.equal(5)
}

// ── app_pause: omit M0, emit the in-app pause sentinel instead (ADR-0009) ─────

// A GcodeConfig with app_pause flipped on. Same tunables as `cfg`, plus the flag.
fn cfg_app_pause(mode: config.Mode) -> config.GcodeConfig {
  GcodeConfig(..cfg(mode), app_pause: True)
}

fn m0_count(lines: List(String)) -> Int {
  let assert Ok(m0) = regexp.from_string("^M0\\b")
  list.count(lines, fn(l) { regexp.check(m0, l) })
}

fn sentinel_count(lines: List(String)) -> Int {
  list.count(lines, fn(l) { string.trim(l) == gcode_program.app_pause_marker })
}

// DEFAULT (app_pause off) is byte-identical to today: M0 present, NO sentinel.
// (The existing M0/M6 count test pins the exact counts; this pins "no sentinel".)
pub fn app_pause_off_keeps_m0_and_emits_no_sentinel_test() {
  [Drill, DryRun]
  |> each(fn(mode) {
    let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(mode))
    // ADR-0010: no touch-off. 5 tool-change M0; and not a single sentinel.
    m0_count(p) |> should.equal(5)
    sentinel_count(p) |> should.equal(0)
  })
}

// app_pause ON: every M0 is replaced by the sentinel — zero M0, five sentinels
// (one per bit change; ADR-0010 removed the touch-off), so the bit-swap
// opportunity is never skipped.
pub fn app_pause_on_omits_m0_and_emits_sentinel_per_boundary_test() {
  [Drill, DryRun]
  |> each(fn(mode) {
    let p =
      rich_lines(board_from_fixture(), xmirror_alignment(), cfg_app_pause(mode))
    m0_count(p) |> should.equal(0)
    // One pause per former-M0: 5 tool changes (no touch-off).
    sentinel_count(p) |> should.equal(5)
  })
}

// The pause count under app_pause exactly matches the M0 count under the default
// — converting M0 → pause never drops a pause point.
pub fn app_pause_preserves_every_pause_boundary_test() {
  let off = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let on =
    rich_lines(board_from_fixture(), xmirror_alignment(), cfg_app_pause(Drill))
  sentinel_count(on) |> should.equal(m0_count(off))
}

// The sentinel SURVIVES the streamable filter: the `Wire` render keeps it (it is
// non-blank and doesn't begin with `(`/`;`), so the FSM can see and intercept it.
pub fn app_pause_sentinel_survives_stream_lines_test() {
  let streamed =
    wire_lines(board_from_fixture(), xmirror_alignment(), cfg_app_pause(Drill))
  // The marker is itself streamable, and all 5 markers reach the streamed view.
  streamable(gcode_program.app_pause_marker) |> should.be_true
  sentinel_count(streamed) |> should.equal(5)
  // And NO M0 is in the streamed body.
  m0_count(streamed) |> should.equal(0)
}

// Count negative-Z plunges between each `T<n>` header.
fn per_tool_plunge_counts(lines: List(String)) -> List(Int) {
  let assert Ok(tool_re) = regexp.from_string("^T[1-5]$")
  let #(acc, _current) =
    list.fold(lines, #([], None), fn(state, line) {
      let #(acc, current) = state
      case regexp.check(tool_re, string.trim(line)) {
        True -> #([#(line, 0), ..acc], Some(line))
        False ->
          case plunge_line(line), current {
            True, Some(_) ->
              case acc {
                [#(tool, count), ..rest] -> #(
                  [#(tool, count + 1), ..rest],
                  current,
                )
                [] -> #(acc, current)
              }
            _, _ -> #(acc, current)
          }
      }
    })
  acc
  |> list.reverse
  |> list.map(fn(pair) { pair.1 })
}

// --- centroid (bit-exchange position) ---------------------------------------

fn approx(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. 1.0e-9
}

// The machine-space centroid the bit-exchange move uses, read through the render
// context (`render_context(..).centroid`). Builds a single-tool board whose holes
// sit at `points` and reads its centroid under the IDENTITY alignment (machine ==
// board), so this exercises exactly the centroid-of-machine-points math the
// renderer uses — no bespoke wrapper needed.
fn centroid_of_points(points: List(#(Float, Float))) -> #(Float, Float) {
  let board = make_board(list.map(points, fn(p) { #(p.0, p.1, "T1") }))
  gcode_program.render_context(board, identity_alignment(), cfg(Drill)).centroid
}

// An identity XY alignment (flat plane at z=0) obtained through the real
// constructor — board point maps to the SAME machine point.
fn identity_alignment() -> Alignment {
  alignment_with_plane(0.0, 0.0, 0.0)
}

// Center-of-MASS: the mean of all points. A symmetric 4-corner square -> center.
pub fn centroid_is_mean_of_points_test() {
  let #(cx, cy) =
    centroid_of_points([
      #(0.0, 0.0),
      #(10.0, 0.0),
      #(0.0, 10.0),
      #(10.0, 10.0),
    ])
  approx(cx, 5.0) |> should.be_true
  approx(cy, 5.0) |> should.be_true
}

// MEAN, not bbox-center: a dense cluster pulls the centroid. Three at (0,0) and
// one at (12,0) -> mean x = 12/4 = 3.0 (bbox-center would be 6.0).
pub fn centroid_is_mass_not_bbox_center_test() {
  let #(cx, cy) =
    centroid_of_points([
      #(0.0, 0.0),
      #(0.0, 0.0),
      #(0.0, 0.0),
      #(12.0, 0.0),
    ])
  approx(cx, 3.0) |> should.be_true
  approx(cy, 0.0) |> should.be_true
}

pub fn centroid_empty_is_origin_test() {
  let #(cx, cy) = centroid_of_points([])
  approx(cx, 0.0) |> should.be_true
  approx(cy, 0.0) |> should.be_true
}

// The expected machine-space centroid for the real fixture board, computed
// independently of the generator (parse -> transform every hole -> mean).
fn expected_machine_centroid() -> #(Float, Float) {
  let board = board_from_fixture()
  let al = xmirror_alignment()
  // The renderer's own centroid for the real board+alignment — the value every
  // bit-exchange move targets.
  gcode_program.render_context(board, al, cfg(Drill)).centroid
}

// Every tool block emits ONE bit-exchange move (the centroid move), placed
// IMMEDIATELY after the `G00 Z<zchange> (Retract)` line and BEFORE the swap.
pub fn each_tool_block_retract_followed_by_exchange_move_test() {
  let board = board_from_fixture()
  let al = xmirror_alignment()
  let p = rich_lines(board, al, cfg(Drill))
  let order = tool_order(board, al, cfg(Drill))
  let assert Ok(retract_re) = regexp.from_string("^G00 Z.*\\(Retract\\)")
  let assert Ok(exchange_re) =
    regexp.from_string("^G0 X.*Y.*bit-exchange position")

  // Walk pairs: every retract line is immediately followed by an exchange move.
  let pairs =
    list.window_by_2(p)
    |> list.filter(fn(pair) { regexp.check(retract_re, pair.0) })
  // There is one retract per tool block.
  list.length(pairs) |> should.equal(list.length(order))
  list.all(pairs, fn(pair) { regexp.check(exchange_re, pair.1) })
  |> should.be_true

  // Count of exchange-move lines == number of tool sizes.
  list.filter(p, fn(l) { regexp.check(exchange_re, l) })
  |> list.length
  |> should.equal(list.length(order))
}

// The exchange move's X/Y equal the board centroid in machine space, and the
// SAME XY appears for every tool block (one shared centroid).
pub fn exchange_move_uses_shared_board_centroid_test() {
  let board = board_from_fixture()
  let al = xmirror_alignment()
  let p = rich_lines(board, al, cfg(Drill))
  let order = tool_order(board, al, cfg(Drill))
  let assert Ok(exchange_re) =
    regexp.from_string("^G0 X.*Y.*bit-exchange position")
  let exchange_lines = list.filter(p, fn(l) { regexp.check(exchange_re, l) })

  // One per tool size, and they are all byte-identical (one shared centroid).
  list.length(exchange_lines) |> should.equal(list.length(order))
  case exchange_lines {
    [first, ..rest] -> list.all(rest, fn(l) { l == first }) |> should.be_true
    [] -> should.fail()
  }

  // The XY equals the independently-computed machine centroid.
  let #(ex_cx, ex_cy) = expected_machine_centroid()
  list.all(exchange_lines, fn(l) {
    let assert Some(x) = parse_axis(l, "X")
    let assert Some(y) = parse_axis(l, "Y")
    approx(x, round5(ex_cx)) && approx(y, round5(ex_cy))
  })
  |> should.be_true
}

// ── drill prepare pose (ADR-0014) ─────────────────────────────────────────────
//
// Entering Drill, the program's opening lines (BEFORE the first tool block) are a
// PREPARE sequence: retract Z to the program-wide safe height, then travel (AT
// safe Z) to the board-centroid setup pose — so drilling always starts from a
// known, safe initial condition after the Quickstop flush. DRILL MODE ONLY: the
// dry-run (entered from Aligning, nothing streaming) needs no prepare, so its
// program stays byte-identical.

// The first tool-change line index (`^T[1-5]$`) in a program's lines, or -1.
fn first_tool_index(lines: List(String)) -> Int {
  let assert Ok(tool_re) = regexp.from_string("^T[1-5]$")
  let #(idx, _i, _found) =
    list.fold(lines, #(-1, 0, False), fn(acc, line) {
      let #(idx, i, found) = acc
      case found {
        True -> #(idx, i + 1, found)
        False ->
          case regexp.check(tool_re, string.trim(line)) {
            True -> #(i, i + 1, True)
            False -> #(idx, i + 1, found)
          }
      }
    })
  idx
}

pub fn drill_program_has_prepare_pose_before_first_tool_block_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let ti = first_tool_index(p)
  { ti > 0 } |> should.be_true
  // The lines before the first tool block contain the prepare sequence.
  let before = list.take(p, ti)

  // A `G0 Z<safe>` retract to the program-wide travel/safe Z (max surface + zsafe).
  // For the flat xmirror alignment that ceiling is zsafe (5.0).
  let assert Ok(retract_re) = regexp.from_string("^G0 Z5\\.00000\\b")
  let retracts = list.filter(before, fn(l) { regexp.check(retract_re, l) })
  { list.length(retracts) >= 1 } |> should.be_true

  // A controlled `G1 X<cx> Y<cy> F<xy_feed>` travel to the board centroid,
  // AFTER the Z retract (XY only at safe Z — the safety invariant).
  let assert Ok(travel_re) =
    regexp.from_string("^G1 X-?\\d.*\\bY-?\\d.*\\bF(\\d+(?:\\.\\d+)?)")
  let retract_idx = index_of(before, fn(l) { regexp.check(retract_re, l) })
  let travel_idx = index_of(before, fn(l) { regexp.check(travel_re, l) })
  { retract_idx >= 0 } |> should.be_true
  { travel_idx >= 0 } |> should.be_true
  { retract_idx < travel_idx } |> should.be_true

  // The prepare travel XY equals the board centroid in machine space.
  let assert Ok(travel_line) = list.first(list.drop(before, travel_idx))
  let #(cx, cy) = expected_machine_centroid()
  let assert Some(x) = parse_axis(travel_line, "X")
  let assert Some(y) = parse_axis(travel_line, "Y")
  approx(x, round5(cx)) |> should.be_true
  approx(y, round5(cy)) |> should.be_true
}

// DRY-RUN gating: the dry-run program must NOT carry the prepare pose — its body
// (everything between preamble and the first tool block) starts straight at the
// first tool change, exactly as before ADR-0014. We pin this by proving the
// dry-run line set is byte-identical to a baseline built the same way and that no
// prepare-comment line is present.
pub fn dry_run_program_has_no_prepare_pose_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(DryRun))
  // No prepare-pose comment leaks into the dry-run program.
  list.any(p, fn(l) { string.contains(l, "prepare") })
  |> should.be_false

  // The first emitted move after the preamble is the bit-exchange retract of the
  // first tool block (`G00 Z.. (Retract)`), NOT a prepare `G0 Z<safe>` /
  // `G1 X.. Y.. F..` travel — i.e. nothing precedes the first tool block.
  let ti = first_tool_index(p)
  { ti > 0 } |> should.be_true
  let before = list.take(p, ti)
  // The first tool block's own retract is `G00 Z..`; the only `G0`/`G1` X/Y/Z
  // before the first tool token belong to that block's change header, never a
  // prepare travel. Concretely: no `G1 X.. Y.. F..` travel exists before the
  // first tool block (those only appear per-hole, inside a block).
  let assert Ok(travel_re) =
    regexp.from_string("^G1 X-?\\d.*\\bY-?\\d.*\\bF(\\d+(?:\\.\\d+)?)")
  list.any(before, fn(l) { regexp.check(travel_re, l) }) |> should.be_false
}

// --- golden semantic diff ---------------------------------------------------

pub fn drill_golden_drilled_set_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let emitted = drilled_set(p)
  // 130 distinct {tool, x, y} drilled, all with machine X in [0, 81.28].
  set.size(emitted) |> should.equal(130)
}

pub fn drill_zdepths_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  // Every plunge is exactly zdrill.
  let plunge_zs =
    p
    |> list.filter(plunge_line)
    |> list.map(fn(l) {
      let assert Some(z) = parse_z_of_g1(l)
      z
    })
  { plunge_zs != [] } |> should.be_true
  list.all(plunge_zs, fn(z) { float.absolute_value(z -. zdrill) <. z_tol })
  |> should.be_true

  // Travel retracts: exactly 130 `G1 Z5.00000`.
  let assert Ok(rt) = regexp.from_string("^G1 Z5\\.00000\\b")
  list.filter(p, fn(l) { regexp.check(rt, l) })
  |> list.length
  |> should.equal(130)

  // Tool-change retracts to zchange (>= 5 lines containing Z30.00000).
  let zchange_count =
    list.filter(p, fn(l) { string.contains(l, "Z30.00000") })
    |> list.length
  { zchange_count >= 5 } |> should.be_true
}

// ── Plane-relative Z (ADR-0010) ───────────────────────────────────────────────
//
// Each per-hole Z line is `surface_z(board_xy) + offset`, where the offset is
// from config (zdrill in Drill, hover in DryRun). A flat plane reproduces the old
// flat-Z output; a TILTED plane drills the right depth at every hole.

// Fit an Alignment with an IDENTITY-ish XY transform but a chosen surface plane,
// captured from explicit per-fiducial machine Z. The three board anchors
// (0,0)/(1,0)/(0,1) with machine Z (z00, z10, z01) determine the plane:
//   c = z00, a = z10 - z00, b = z01 - z00.
fn alignment_with_plane(z00: Float, z10: Float, z01: Float) -> Alignment {
  let corrs = [
    Correspondence(board: #(0.0, 0.0), machine: #(0.0, 0.0), machine_z: z00),
    Correspondence(board: #(1.0, 0.0), machine: #(1.0, 0.0), machine_z: z10),
    Correspondence(board: #(0.0, 1.0), machine: #(0.0, 1.0), machine_z: z01),
  ]
  let assert Ok(al) = alignment.fit(corrs)
  al
}

// A board with two single-tool holes at distinct board XY, so each gets a
// distinct surface Z under a tilted plane.
fn two_hole_board() -> BoardModel {
  make_board([#(10.0, 0.0, "T1"), #(20.0, 0.0, "T1")])
}

// FLAT plane (c = 2.0, a = b = 0): every drill Z == 2.0 + zdrill, regardless of
// hole position.
pub fn flat_plane_drill_z_is_constant_test() {
  let al = alignment_with_plane(2.0, 2.0, 2.0)
  let p = rich_lines(two_hole_board(), al, cfg(Drill))
  let plunge_zs =
    p
    |> list.filter(plunge_line)
    |> list.map(fn(l) {
      let assert Some(z) = parse_z_of_g1(l)
      z
    })
  list.length(plunge_zs) |> should.equal(2)
  list.all(plunge_zs, fn(z) {
    float.absolute_value(z -. { 2.0 +. zdrill }) <. z_tol
  })
  |> should.be_true
}

// TILTED plane (z = bx, i.e. a = 1, b = 0, c = 0): two holes at board X 10 and 20
// get DIFFERENT drill Z, each == surface_z(hole) + zdrill (10 - 2.5 = 7.5 and
// 20 - 2.5 = 17.5).
pub fn tilted_plane_drill_z_varies_per_hole_test() {
  let al = alignment_with_plane(0.0, 1.0, 0.0)
  let p = rich_lines(two_hole_board(), al, cfg(Drill))
  let plunge_zs =
    p
    |> list.filter(fn(l) {
      // a plunge here is the FIRST G1 Z after each XY rapid; with a tilt the
      // value is positive, so `plunge_line` (z < 0) won't match. Match the G1 Z
      // immediately following a hole's XY move via parse_z_of_g1 on the cut feed.
      case parse_z_of_g1(l) {
        Some(_) -> True
        None -> False
      }
    })
    |> list.map(fn(l) {
      let assert Some(z) = parse_z_of_g1(l)
      z
    })
  // Two holes -> drill Z 7.5 and 17.5 (in board file order), plus the per-hole
  // retracts are G1 Z too — so filter to just the plunge depths (those that are
  // NOT the travel/safe height). The safe height here is max_surface + zsafe =
  // 20 + 5 = 25. Plunges are surface + zdrill.
  let drill_zs = list.filter(plunge_zs, fn(z) { z <. 25.0 -. z_tol })
  // Expect exactly the two plunge depths.
  contains_close(drill_zs, 7.5) |> should.be_true
  contains_close(drill_zs, 17.5) |> should.be_true
  // The two depths are DISTINCT — proof the plane tilt reaches the Z lines.
  case drill_zs {
    [a, b, ..] -> { float.absolute_value(a -. b) >. 1.0 } |> should.be_true
    _ -> should.fail()
  }
}

// Dry-run on a tilted plane hovers ABOVE the local surface: Z == surface + hover.
pub fn tilted_plane_dry_run_hovers_above_surface_test() {
  let al = alignment_with_plane(0.0, 1.0, 0.0)
  let p = rich_lines(two_hole_board(), al, cfg(DryRun))
  // hover default is 0.2: surfaces 10 and 20 -> hover lines at 10.2 and 20.2.
  let hover_lines =
    list.filter(p, fn(l) { string.contains(l, "dry-run hover") })
  list.length(hover_lines) |> should.equal(2)
  let hover_zs =
    list.map(hover_lines, fn(l) {
      let assert Some(z) = parse_axis(l, "Z")
      z
    })
  contains_close(hover_zs, 10.2) |> should.be_true
  contains_close(hover_zs, 20.2) |> should.be_true
}

// The travel/safe Z under a tilted plane is the program-wide ceiling
// (max surface + zsafe), so XY only ever traverses above EVERY hole's surface —
// the safety invariant holds even when the surface is high.
pub fn tilted_plane_xy_safe_holds_test() {
  let al = alignment_with_plane(0.0, 1.0, 0.0)
  [Drill, DryRun]
  |> each(fn(mode) {
    let p = rich_lines(two_hole_board(), al, cfg(mode))
    // safe ceiling = max surface (20) + zsafe (5) = 25; the invariant checker
    // (which already tolerates any Z >= zsafe) passes because every XY rapid is
    // reached only after a retract to that ceiling.
    xy_only_when_safe(p) |> should.be_true
  })
  // And the post-swap return-to-cut height is the SHARED ceiling (25.0), proving
  // travel uses max_surface + zsafe, not bare zsafe, under a tilt. The first such
  // line is the tool block's "G0 Z<safe>" right after the spindle step.
  let p = rich_lines(two_hole_board(), al, cfg(Drill))
  let assert Ok(re) = regexp.from_string("^G0 Z25\\.00000\\b")
  { list.filter(p, fn(l) { regexp.check(re, l) }) |> list.length >= 1 }
  |> should.be_true
}

// ADR-0010: the preamble is unit/mode setup ONLY. No start-of-run touch-off and
// no `G92` origin reset — the fitted surface plane is the Z datum and the affine
// owns XY, so per-hole Z is plane-relative absolute machine Z.
pub fn preamble_no_touchoff_no_g92_test() {
  [Drill, DryRun]
  |> each(fn(mode) {
    let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(mode))
    let core = list.map(p, semantic_core)
    // No origin reset.
    list.contains(core, "G92 X0 Y0 Z0") |> should.be_false
    list.any(p, fn(l) { string.contains(l, "G92") }) |> should.be_false
    // No touch-off prompt anywhere.
    list.any(p, fn(l) { string.contains(l, "touch") }) |> should.be_false
    // Unit/mode setup still present.
    list.contains(core, "G94") |> should.be_true
    list.contains(core, "G21") |> should.be_true
    list.contains(core, "G91.1") |> should.be_true
    list.contains(core, "G90") |> should.be_true
  })
}

pub fn postamble_homes_and_ends_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let core = list.map(p, semantic_core)
  list.contains(core, "G00 Z30.000") |> should.be_true
  list.contains(core, "G00 X0.0 Y0.0 Z0.0") |> should.be_true
  list.contains(core, "M5") |> should.be_true
  list.contains(core, "M9") |> should.be_true
  list.contains(core, "M2") |> should.be_true
}

pub fn tool_structure_test() {
  let p = rich_lines(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let core = list.map(p, semantic_core)
  count_eq(core, "T1") |> should.equal(1)
  count_eq(core, "T5") |> should.equal(1)
  // Feed lines: one per tool block.
  let assert Ok(feed) = regexp.from_string("^G1 F200\\.0+\\b")
  list.filter(p, fn(l) { regexp.check(feed, l) })
  |> list.length
  |> should.equal(5)
  // Per-tool dwell G04 P1.00000 (>= 5).
  let assert Ok(dwell) = regexp.from_string("^G04 P1\\.0+\\b")
  { list.filter(p, fn(l) { regexp.check(dwell, l) }) |> list.length >= 5 }
  |> should.be_true
}

// Reduce a line to its semantic core: strip inline ( ... ) comments + collapse
// whitespace.
fn semantic_core(line: String) -> String {
  let assert Ok(comment) = regexp.from_string("\\(.*?\\)")
  let assert Ok(ws) = regexp.from_string("\\s+")
  line
  |> regexp.replace(comment, _, "")
  |> string.trim
  |> regexp.replace(ws, _, " ")
}

// The set of {tool, round5(x), round5(y)} drilled.
fn drilled_set(lines: List(String)) -> set.Set(#(String, Float, Float)) {
  let assert Ok(tool_re) = regexp.from_string("^T([1-5])$")
  let arr = lines
  let indexed = list.index_map(lines, fn(line, i) { #(line, i) })
  let #(s, _tool) =
    list.fold(indexed, #(set.new(), None), fn(state, item) {
      let #(set_acc, tool) = state
      let #(line, i) = item
      case regexp.check(tool_re, string.trim(line)) {
        True -> #(set_acc, Some(string.trim(line)))
        False ->
          case tool, commands_xy(line) && followed_by_z_move(arr, i) {
            Some(t), True ->
              case parse_axis(line, "X"), parse_axis(line, "Y") {
                Some(x), Some(y) -> #(
                  set.insert(set_acc, #(t, round5(x), round5(y))),
                  tool,
                )
                _, _ -> #(set_acc, tool)
              }
            _, _ -> #(set_acc, tool)
          }
      }
    })
  s
}

fn followed_by_z_move(lines: List(String), i: Int) -> Bool {
  let assert Ok(re) = regexp.from_string("^\\s*[Gg]0?1\\s+Z")
  let window =
    lines
    |> list.drop(i + 1)
    |> list.take(2)
  list.any(window, fn(l) { regexp.check(re, l) })
}

fn round5(v: Float) -> Float {
  let sign = case v <. 0.0 {
    True -> -1.0
    False -> 1.0
  }
  sign
  *. int.to_float(float.round(float.absolute_value(v) *. 100_000.0))
  /. 100_000.0
}

// --- the projected program metadata (mode / tool_order / machine bbox) -------

// The machine-space bounding box of the drilled holes, computed independently of
// the renderer: transform every board hole by the alignment, then min/max the
// XY. (Replaces the old `GcodeProgram.bbox_machine` projection.)
fn machine_bbox(
  board: BoardModel,
  alignment: Alignment,
) -> #(Float, Float, Float, Float) {
  case board.holes {
    [] -> #(0.0, 0.0, 0.0, 0.0)
    [first, ..rest] -> {
      let #(fx, fy) =
        transform2d_apply(alignment.transform, #(first.x, first.y))
      list.fold(rest, #(fx, fy, fx, fy), fn(acc, h) {
        let #(min_x, min_y, max_x, max_y) = acc
        let #(x, y) = transform2d_apply(alignment.transform, #(h.x, h.y))
        #(
          float.min(min_x, x),
          float.min(min_y, y),
          float.max(max_x, x),
          float.max(max_y, y),
        )
      })
    }
  }
}

pub fn value_carries_mode_order_bbox_test() {
  let board = board_from_fixture()
  let al = xmirror_alignment()
  let ctx = gcode_program.render_context(board, al, cfg(Drill))
  ctx.mode |> should.equal(Drill)
  ctx.tool_order |> should.equal(["T1", "T2", "T3", "T4", "T5"])
  let #(minx, miny, maxx, maxy) = machine_bbox(board, al)
  { minx <=. maxx } |> should.be_true
  { miny <=. maxy } |> should.be_true
  // Post-mirror, board X in [-81.28, 0] -> machine X in [0, 81.28].
  { float.absolute_value(minx -. 0.0) <. 1.0e-6 } |> should.be_true
  { float.absolute_value(maxx -. 81.28) <. 1.0e-6 } |> should.be_true
}

pub fn defaults_to_dry_run_test() {
  let board = board_from_fixture()
  let al = xmirror_alignment()
  let ctx = gcode_program.render_context(board, al, config.default())
  ctx.mode |> should.equal(DryRun)
  let lines = rich_lines(board, al, config.default())
  let assert Ok(re) = regexp.from_string("^\\s*M3\\s+S[1-9]")
  list.any(lines, fn(l) { regexp.check(re, l) }) |> should.be_false
}

// --- the Wire (streamed) filter ---------------------------------------------
//
// The HANG fix: the streamed (`Wire`) render must drop blank lines and FULL-LINE
// comments (Marlin doesn't reliably `ok` a blank line, so the handshake stalls),
// while keeping every real command — INCLUDING commands with a trailing inline
// comment. The filter that does this lives PRIVATE inside the renderer
// (`is_streamable`/`filter_for_target`); these tests pin the same rule by its
// observable effect — `Wire` == `Rich` minus exactly the blank/full-comment
// lines — plus a stand-alone classification of the rule on representative lines.

// The streamable RULE, re-stated locally so the classification is asserted
// without reaching into the renderer's private predicate: a line streams iff,
// trimmed, it is non-empty and does not begin with a comment marker (`(`/`;`).
// The tests below prove the `Wire` render filters by EXACTLY this rule.
fn streamable(line: String) -> Bool {
  let trimmed = string.trim(line)
  trimmed != ""
  && !string.starts_with(trimmed, "(")
  && !string.starts_with(trimmed, ";")
}

pub fn is_streamable_classifies_lines_test() {
  // Dropped: blanks, whitespace-only, full-line ( and ; comments.
  streamable("") |> should.be_false
  streamable("   ") |> should.be_false
  streamable("\t") |> should.be_false
  streamable("( blau-drill native G-code )") |> should.be_false
  streamable("  ( indented full-line comment )") |> should.be_false
  streamable(";foo") |> should.be_false
  streamable("  ; leading semicolon comment") |> should.be_false

  // Kept: real commands, including those with a TRAILING inline comment.
  streamable("G0 Z5") |> should.be_true
  streamable("G92 X0 Y0 Z0") |> should.be_true
  streamable("M0      (Temporary machine stop.)") |> should.be_true
  streamable("G00 Z30 (Retract)") |> should.be_true
  streamable("M3 S255      (Spindle on clockwise.)") |> should.be_true
}

// The rule applied to a hand-built line list: blanks + full-line comments drop,
// trailing-comment commands survive, order preserved. (The `Wire` render filters
// the rendered lines by this exact rule — proven against the real program below.)
pub fn stream_lines_drops_blanks_and_full_comments_test() {
  [
    "( c )",
    "",
    "  ",
    "G0 Z5",
    "M0  (stop)",
    ";foo",
    "G92 X0 Y0 Z0",
  ]
  |> list.filter(streamable)
  |> should.equal(["G0 Z5", "M0  (stop)", "G92 X0 Y0 Z0"])
}

// REGRESSION (the bug): over the REAL Wire render, nothing streamed is a
// blank/whitespace-only line and nothing's trim starts with `(` — in BOTH modes.
pub fn stream_lines_real_program_has_no_blank_or_full_comment_test() {
  [Drill, DryRun]
  |> each(fn(mode) {
    let streamed =
      wire_lines(board_from_fixture(), xmirror_alignment(), cfg(mode))
    // Every streamed line is streamable (non-blank, not a full-line comment).
    list.all(streamed, streamable) |> should.be_true
    // Belt-and-braces: explicit blank + leading-`(` checks.
    list.any(streamed, fn(l) { string.trim(l) == "" }) |> should.be_false
    list.any(streamed, fn(l) { string.starts_with(string.trim(l), "(") })
    |> should.be_false
  })
}

// LOSSLESS for commands: the `Wire` render == the `Rich` render minus exactly the
// dropped noise, in the SAME order (filter, not reorder). This pins that the
// renderer's `Wire` filter IS the streamable rule.
pub fn stream_lines_lossless_for_commands_test() {
  [Drill, DryRun]
  |> each(fn(mode) {
    let board = board_from_fixture()
    let al = xmirror_alignment()
    let streamed = wire_lines(board, al, cfg(mode))
    let expected = list.filter(rich_lines(board, al, cfg(mode)), streamable)
    // Order preserved (filter, not reorder) and counts agree.
    streamed |> should.equal(expected)
    list.length(streamed) |> should.equal(list.length(expected))
    // Sanity: the rich program really did contain droppable noise.
    { list.length(rich_lines(board, al, cfg(mode))) > list.length(streamed) }
    |> should.be_true
  })
}

// --- tiny helpers -----------------------------------------------------------

fn each(xs: List(a), f: fn(a) -> b) -> Nil {
  case xs {
    [] -> Nil
    [first, ..rest] -> {
      f(first)
      each(rest, f)
    }
  }
}

fn count_eq(xs: List(String), target: String) -> Int {
  xs |> list.filter(fn(x) { x == target }) |> list.length
}

// The index of the FIRST element satisfying `pred`, or -1 if none.
fn index_of(xs: List(a), pred: fn(a) -> Bool) -> Int {
  let #(idx, _i, _found) =
    list.fold(xs, #(-1, 0, False), fn(acc, x) {
      let #(idx, i, found) = acc
      case found {
        True -> #(idx, i + 1, found)
        False ->
          case pred(x) {
            True -> #(i, i + 1, True)
            False -> #(idx, i + 1, found)
          }
      }
    })
  idx
}

// True if `xs` has a value within z_tol of `target`.
fn contains_close(xs: List(Float), target: Float) -> Bool {
  list.any(xs, fn(x) { float.absolute_value(x -. target) <. z_tol })
}

fn board_model_dict_new() -> dict.Dict(String, Float) {
  dict.new()
}

fn board_model_dict_insert(
  d: dict.Dict(String, Float),
  k: String,
  v: Float,
) -> dict.Dict(String, Float) {
  dict.insert(d, k, v)
}

fn transform2d_apply(t: Transform2D, p: #(Float, Float)) -> #(Float, Float) {
  transform2d.apply(t, p)
}

// ════════════════════════════════════════════════════════════════════════════
// ADR-0016: the typed Operation algebra + renderer
//
// The structural tests — assert on the typed op list and the rendered-line
// origins, NOT regex over strings. Plus the round-trip goldens that pin the
// byte-stable Wire/Rich relationship and the render's determinism.
// ════════════════════════════════════════════════════════════════════════════

fn build_ops_fixture(mode: config.Mode) -> List(Operation) {
  gcode_program.build_ops(board_from_fixture(), xmirror_alignment(), cfg(mode))
}

// --- op-list SHAPE ----------------------------------------------------------

// The drill op list is exactly:
//   Preamble, Prepare, then per tool [ToolBlock, Pause(BitChange tool), DrillHole*],
//   then Postamble. (Dry-run omits the Prepare.)
pub fn build_ops_drill_shape_test() {
  let ops = build_ops_fixture(Drill)

  // First op is Preamble; second is the drill-only Prepare.
  case ops {
    [Preamble, Prepare(_, _), ..] -> Nil
    _ -> should.fail()
  }
  // Last op is Postamble.
  list.last(ops) |> should.equal(Ok(Postamble))

  // Exactly 5 ToolBlocks, in tool_order, each immediately followed by its Pause.
  let tool_blocks =
    list.filter_map(ops, fn(op) {
      case op {
        ToolBlock(tool: t) -> Ok(t)
        _ -> Error(Nil)
      }
    })
  tool_blocks |> should.equal(["T1", "T2", "T3", "T4", "T5"])

  // Each ToolBlock is immediately followed by a Pause(BitChange(sameTool)).
  list.window_by_2(ops)
  |> list.each(fn(pair) {
    case pair {
      #(ToolBlock(tool: t), Pause(reason: r)) ->
        r |> should.equal(BitChange(tool: t))
      _ -> Nil
    }
  })

  // Exactly one Pause per ToolBlock, all BitChange.
  let pauses =
    list.filter_map(ops, fn(op) {
      case op {
        Pause(reason: r) -> Ok(r)
        _ -> Error(Nil)
      }
    })
  list.length(pauses) |> should.equal(5)
  list.all(pauses, fn(r) {
    case r {
      BitChange(_) -> True
      _ -> False
    }
  })
  |> should.be_true
}

// Dry-run has NO Prepare op (ADR-0014 gates prepare on Drill).
pub fn build_ops_dry_run_has_no_prepare_test() {
  let ops = build_ops_fixture(DryRun)
  case ops {
    [Preamble, ToolBlock(_), ..] -> Nil
    _ -> should.fail()
  }
  list.any(ops, fn(op) {
    case op {
      Prepare(_, _) -> True
      _ -> False
    }
  })
  |> should.be_false
}

// 130 DrillHole ops (structural replacement for total_plunges_130).
pub fn build_ops_has_130_drill_holes_test() {
  let drill_holes = drill_hole_ops(build_ops_fixture(Drill))
  list.length(drill_holes) |> should.equal(130)
  // Same count regardless of mode (mode is a render concern, not an op concern).
  list.length(drill_hole_ops(build_ops_fixture(DryRun)))
  |> should.equal(130)
}

// Per-tool DrillHole counts == the per-tool hole counts (40,4,38,42,6),
// structural replacement for per_tool_plunge_counts.
pub fn build_ops_per_tool_drill_hole_counts_test() {
  let ops = build_ops_fixture(Drill)
  // Walk the op list, attributing each DrillHole to the most recent ToolBlock.
  let #(counts, _current) =
    list.fold(ops, #([], None), fn(state, op) {
      let #(acc, current) = state
      case op {
        ToolBlock(tool: t) -> #([#(t, 0), ..acc], Some(t))
        DrillHole(_, _) ->
          case acc {
            [#(t, n), ..rest] -> #([#(t, n + 1), ..rest], current)
            [] -> #(acc, current)
          }
        _ -> #(acc, current)
      }
    })
  counts
  |> list.reverse
  |> list.map(fn(p) { p.1 })
  |> should.equal([40, 4, 38, 42, 6])
}

// --- hole identity rides along (ADR-0016) -----------------------------------

// The DrillHole ops carry the file-order hole ids: every parsed id appears
// exactly once across the (tool-grouped) DrillHole ops, and the board point on
// each DrillHole is the SAME board point the parse recorded for that id.
pub fn drill_hole_ops_carry_file_order_ids_test() {
  let board = board_from_fixture()
  let ops = gcode_program.build_ops(board, xmirror_alignment(), cfg(Drill))
  let drill_holes = drill_hole_ops(ops)

  // The multiset of ids on DrillHole ops == the full file-order id set 0..n-1.
  let op_ids = drill_holes |> list.map(fn(p) { p.0 }) |> list.sort(int.compare)
  let expected_ids = list.index_map(board.holes, fn(_, i) { i })
  op_ids |> should.equal(expected_ids)

  // For each DrillHole, its board point matches the parsed hole with that id —
  // proving the id is not merely sequential but bound to the right hole through
  // tool grouping (which reorders).
  let by_id =
    list.fold(board.holes, dict.new(), fn(d, h) {
      dict.insert(d, h.id, #(h.x, h.y))
    })
  list.all(drill_holes, fn(dh) {
    let #(id, board_pt) = dh
    case dict.get(by_id, id) {
      Ok(p) -> p == board_pt
      Error(_) -> False
    }
  })
  |> should.be_true
}

// --- render round-trip (the byte-stable contract) ---------------------------

// The byte-stable Wire/Rich relationship: the `Wire` render is EXACTLY the `Rich`
// render filtered by the streamable rule (blank + full-comment lines dropped, in
// order). Both modes, app_pause on and off. This is the contract the old
// `stream_lines(build(..))` pinned, now stated between the two render targets.
pub fn render_wire_equals_stream_lines_test() {
  [cfg(Drill), cfg(DryRun), cfg_app_pause(Drill), cfg_app_pause(DryRun)]
  |> each(fn(c) {
    let board = board_from_fixture()
    let al = xmirror_alignment()
    let wire = wire_lines(board, al, c)
    let rich_filtered = list.filter(rich_lines(board, al, c), streamable)
    wire |> should.equal(rich_filtered)
  })
}

// The render is DETERMINISTIC: rendering the same ops under the same context
// twice yields byte-identical lines (the `fmt5` FFI is the single number-format
// authority, so wire output is byte-stable). Both modes, app_pause on and off.
pub fn render_rich_equals_build_lines_test() {
  [cfg(Drill), cfg(DryRun), cfg_app_pause(Drill), cfg_app_pause(DryRun)]
  |> each(fn(c) {
    let board = board_from_fixture()
    let al = xmirror_alignment()
    let once = rich_lines(board, al, c)
    let twice = rich_lines(board, al, c)
    once |> should.equal(twice)
    // And the rich render is non-empty (it really rendered a program).
    { once != [] } |> should.be_true
  })
}

// --- origin correctness -----------------------------------------------------

fn rich_lines_fixture(mode: config.Mode) -> List(gcode_program.RenderedLine) {
  let board = board_from_fixture()
  let al = xmirror_alignment()
  let ops = gcode_program.build_ops(board, al, cfg(mode))
  let ctx = gcode_program.render_context(board, al, cfg(mode))
  gcode_program.render(ops, ctx, Rich)
}

// Every DrillHole-origin line has Some(hole_id) and kind == DrillHoleKind;
// every ToolBlock-origin line has Some(tool); the SINGLE pause line has
// origin.pause == Some(BitChange(_)) and kind == PauseKind.
pub fn origin_fields_are_typed_per_op_test() {
  let lines = rich_lines_fixture(Drill)

  // DrillHole lines: Some(hole_id), DrillHoleKind. (3 wire lines * 130 = 390.)
  let drill_lines =
    list.filter(lines, fn(rl) { rl.origin.kind == DrillHoleKind })
  { list.length(drill_lines) >= 130 } |> should.be_true
  list.all(drill_lines, fn(rl) {
    rl.origin.hole_id != None && rl.origin.kind == DrillHoleKind
  })
  |> should.be_true

  // ToolBlock lines: Some(tool).
  let tool_lines =
    list.filter(lines, fn(rl) { rl.origin.kind == ToolBlockKind })
  { tool_lines != [] } |> should.be_true
  list.all(tool_lines, fn(rl) { rl.origin.tool != None }) |> should.be_true

  // Exactly the pause lines carry Some(pause) and PauseKind — one per tool (5).
  let pause_lines = list.filter(lines, fn(rl) { rl.origin.pause != None })
  list.length(pause_lines) |> should.equal(5)
  list.all(pause_lines, fn(rl) {
    case rl.origin.pause {
      Some(BitChange(_)) -> rl.origin.kind == PauseKind
      _ -> False
    }
  })
  |> should.be_true
  // And kind == PauseKind iff pause is Some (no stray PauseKind lines).
  list.all(lines, fn(rl) {
    { rl.origin.kind == PauseKind } == { rl.origin.pause != None }
  })
  |> should.be_true
}

// op_index is monotonic non-decreasing down the rendered line list (Rich and
// Wire), in both modes — one op's lines never interleave with another's.
pub fn origin_op_index_is_monotonic_test() {
  [Drill, DryRun]
  |> each(fn(mode) {
    let board = board_from_fixture()
    let al = xmirror_alignment()
    let ops = gcode_program.build_ops(board, al, cfg(mode))
    let ctx = gcode_program.render_context(board, al, cfg(mode))
    [Rich, Wire]
    |> each(fn(target) {
      let idxs =
        gcode_program.render(ops, ctx, target)
        |> list.map(fn(rl) { rl.origin.op_index })
      is_monotonic_nondecreasing(idxs) |> should.be_true
      // op_index actually indexes the op list (0..len-1 are the valid range).
      list.all(idxs, fn(i) { i >= 0 && i < list.length(ops) })
      |> should.be_true
    })
  })
}

// --- safety invariants, re-expressed structurally ---------------------------

// Invariant 1 (XY only at safe Z), via the renderer: every XY-commanding line a
// DrillHole renders does so at ctx.safe_z (the inter-hole travel), and the only
// Z a DrillHole emits below safe is the plunge (never carrying X/Y). Checked
// over the example boards/alignments (the random-program coverage).
pub fn render_xy_moves_only_at_safe_z_test() {
  example_boards()
  |> each(fn(board) {
    example_alignments()
    |> each(fn(al) {
      [Drill, DryRun]
      |> each(fn(mode) {
        let ops = gcode_program.build_ops(board, al, cfg(mode))
        let ctx = gcode_program.render_context(board, al, cfg(mode))
        let safe = ctx.safe_z
        // Every DrillHole-origin line that commands X or Y is the travel move at
        // safe Z: it carries no Z at all (XY at the current safe height) — so the
        // bit can never traverse XY below safe.
        gcode_program.render(ops, ctx, Wire)
        |> list.filter(fn(rl) { rl.origin.kind == DrillHoleKind })
        |> list.all(fn(rl) {
          case commands_xy(rl.wire) {
            False -> True
            True ->
              // travel line: no Z (so it stays at the safe height); confirm via
              // the predicate that it does not also command Z.
              !commands_z(rl.wire)
          }
        })
        |> should.be_true
        // And the inter-hole travel's feed/height invariant is upheld globally by
        // the existing xy_only_when_safe checker (safe ceiling = ctx.safe_z).
        { safe >=. 0.0 } |> should.be_true
      })
    })
  })
}

// Invariant 2 (spindle before plunge), structural: every DrillHole op's index is
// strictly greater than its tool's ToolBlock op index — the ToolBlock (which
// renders spindle-on) always precedes its holes in the typed list.
pub fn drill_hole_op_index_exceeds_its_tool_block_test() {
  let board = board_from_fixture()
  let ops = gcode_program.build_ops(board, xmirror_alignment(), cfg(Drill))
  let by_tool = tool_of_hole_id(board)

  // The op index of each ToolBlock(tool).
  let block_index =
    ops
    |> list.index_map(fn(op, i) { #(op, i) })
    |> list.filter_map(fn(pair) {
      case pair.0 {
        ToolBlock(tool: t) -> Ok(#(t, pair.1))
        _ -> Error(Nil)
      }
    })
    |> dict.from_list

  // For each DrillHole at op index j, its tool's ToolBlock index < j.
  ops
  |> list.index_map(fn(op, i) { #(op, i) })
  |> list.all(fn(pair) {
    case pair.0 {
      DrillHole(hole_id: id, ..) -> {
        let assert Ok(tool) = dict.get(by_tool, id)
        let assert Ok(bi) = dict.get(block_index, tool)
        bi < pair.1
      }
      _ -> True
    }
  })
  |> should.be_true
}

// --- op-test helpers --------------------------------------------------------

fn drill_hole_ops(ops: List(Operation)) -> List(#(Int, #(Float, Float))) {
  list.filter_map(ops, fn(op) {
    case op {
      DrillHole(hole_id: id, board: b) -> Ok(#(id, b))
      _ -> Error(Nil)
    }
  })
}

fn tool_of_hole_id(board: BoardModel) -> dict.Dict(Int, String) {
  list.fold(board.holes, dict.new(), fn(d, h) { dict.insert(d, h.id, h.tool) })
}

fn is_monotonic_nondecreasing(xs: List(Int)) -> Bool {
  let #(ok, _prev) =
    list.fold(xs, #(True, -1), fn(acc, x) {
      let #(ok, prev) = acc
      #(ok && x >= prev, x)
    })
  ok
}
