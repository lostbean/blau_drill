//// GcodeProgram tests, ported from `test/blau_drill/gcode_program_test.exs`.
//// Covers both safety invariants (XY only at safe Z; spindle armed before
//// plunge / off in dry-run), structural counts, the value fields, and a
//// semantic golden diff against the embedded segby_v1 goldens. The StreamData
//// property tests are covered as concrete random-ish example boards/alignments
//// that exercise the same invariants.

import blau_drill/domain/alignment.{type Alignment}
import blau_drill/domain/board_model.{type BoardModel}
import blau_drill/domain/config.{Drill, DryRun, GcodeConfig}
import blau_drill/domain/correspondence.{Correspondence}
import blau_drill/domain/gcode_program.{type GcodeProgram, GcodeProgram}
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
      Correspondence(board: b, machine: #(float.negate(bx), by))
    })
  let assert Ok(al) = alignment.fit(corrs)
  al
}

fn board_from_fixture() -> BoardModel {
  let assert Ok(b) = board_model.parse_drl(fixtures.segby_drl())
  b
}

fn cfg(mode: config.Mode) -> config.GcodeConfig {
  GcodeConfig(..config.default(), mode: mode)
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
fn xy_only_when_safe(program: GcodeProgram) -> Bool {
  let #(ok, _final) =
    list.fold(program.lines, #(True, Unknown), fn(acc, line) {
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
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  xy_only_when_safe(p) |> should.be_true
}

pub fn dry_run_mode_xy_safe_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(DryRun))
  xy_only_when_safe(p) |> should.be_true
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
fn every_plunge_armed(program: GcodeProgram) -> Bool {
  let #(ok, _spindle) =
    list.fold(program.lines, #(True, False), fn(acc, line) {
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
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  every_plunge_armed(p) |> should.be_true
}

pub fn m3_carries_speed_on_same_line_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let assert Ok(bare) = regexp.from_string("^\\s*M3\\b")
  let m3_lines = list.filter(p.lines, fn(l) { regexp.check(bare, l) })
  { m3_lines != [] } |> should.be_true
  // Every M3 line carries an S<digits>.
  list.all(m3_lines, m3_on) |> should.be_true
}

pub fn spindle_rearmed_per_tool_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let assert Ok(re) = regexp.from_string("^\\s*M3\\s+S255\\b")
  let count = list.filter(p.lines, fn(l) { regexp.check(re, l) }) |> list.length
  count |> should.equal(5)
}

pub fn dry_run_no_armed_spindle_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(DryRun))
  let assert Ok(re) = regexp.from_string("^\\s*M3\\s+S[1-9]")
  list.any(p.lines, fn(l) { regexp.check(re, l) }) |> should.be_false
  list.any(p.lines, fn(l) {
    string.contains(l, "( dry run: spindle left OFF )")
  })
  |> should.be_true
}

pub fn dry_run_never_negative_z_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(DryRun))
  let all_nonneg =
    list.all(p.lines, fn(l) {
      case parse_axis(l, "Z") {
        Some(z) -> z >=. 0.0 -. z_tol
        None -> True
      }
    })
  all_nonneg |> should.be_true

  let hover_lines =
    list.filter(p.lines, fn(l) { string.contains(l, "dry-run hover") })
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
    list.map(holes, fn(h) {
      let #(x, y, t) = h
      board_model.Hole(x: x, y: y, tool: t)
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
          Correspondence(board: b, machine: transform2d_apply(src, b))
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
        let p = gcode_program.build(board, al, cfg(mode))
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
      let drill = gcode_program.build(board, al, cfg(Drill))
      every_plunge_armed(drill) |> should.be_true

      let dry = gcode_program.build(board, al, cfg(DryRun))
      let assert Ok(re) = regexp.from_string("^\\s*M3\\s+S[1-9]")
      list.any(dry.lines, fn(l) { regexp.check(re, l) }) |> should.be_false
      list.all(dry.lines, fn(l) {
        case parse_axis(l, "Z") {
          Some(z) -> z >=. 0.0 -. z_tol
          None -> True
        }
      })
      |> should.be_true
    })
  })
}

// --- structural counts (drill mode) -----------------------------------------

pub fn total_plunges_130_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  list.filter(p.lines, plunge_line) |> list.length |> should.equal(130)
}

pub fn exactly_five_tool_blocks_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let assert Ok(re) = regexp.from_string("^T[1-5]$")
  let tool_lines = list.filter(p.lines, fn(l) { regexp.check(re, l) })
  tool_lines |> should.equal(["T1", "T2", "T3", "T4", "T5"])
  p.tool_order |> should.equal(["T1", "T2", "T3", "T4", "T5"])
}

pub fn per_tool_plunge_counts_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  per_tool_plunge_counts(p.lines) |> should.equal([40, 4, 38, 42, 6])
}

pub fn tool_change_pauses_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let assert Ok(m6) = regexp.from_string("^M6\\b")
  let assert Ok(m0) = regexp.from_string("^M0\\b")
  list.filter(p.lines, fn(l) { regexp.check(m6, l) })
  |> list.length
  |> should.equal(5)
  // Touch-off M0 + 5 tool-change M0 = 6.
  list.filter(p.lines, fn(l) { regexp.check(m0, l) })
  |> list.length
  |> should.equal(6)
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
    let p =
      gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(mode))
    // Touch-off + 5 tool changes = 6 M0; and not a single sentinel.
    m0_count(p.lines) |> should.equal(6)
    sentinel_count(p.lines) |> should.equal(0)
  })
}

// app_pause ON: every M0 is replaced by the sentinel — zero M0, six sentinels
// (touch-off + one per bit change), so the bit-swap opportunity is never skipped.
pub fn app_pause_on_omits_m0_and_emits_sentinel_per_boundary_test() {
  [Drill, DryRun]
  |> each(fn(mode) {
    let p =
      gcode_program.build(
        board_from_fixture(),
        xmirror_alignment(),
        cfg_app_pause(mode),
      )
    m0_count(p.lines) |> should.equal(0)
    // One pause per former-M0: touch-off (1) + 5 tool changes = 6.
    sentinel_count(p.lines) |> should.equal(6)
  })
}

// The pause count under app_pause exactly matches the M0 count under the default
// — converting M0 → pause never drops a pause point.
pub fn app_pause_preserves_every_pause_boundary_test() {
  let off =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let on =
    gcode_program.build(
      board_from_fixture(),
      xmirror_alignment(),
      cfg_app_pause(Drill),
    )
  sentinel_count(on.lines) |> should.equal(m0_count(off.lines))
}

// The sentinel SURVIVES sanitize: stream_lines keeps it (it is non-blank and
// doesn't begin with `(`/`;`), so the FSM can see and intercept it.
pub fn app_pause_sentinel_survives_stream_lines_test() {
  let p =
    gcode_program.build(
      board_from_fixture(),
      xmirror_alignment(),
      cfg_app_pause(Drill),
    )
  let streamed = gcode_program.stream_lines(p)
  // The marker is itself streamable, and all 6 markers reach the streamed view.
  gcode_program.is_streamable(gcode_program.app_pause_marker) |> should.be_true
  sentinel_count(streamed) |> should.equal(6)
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

// Center-of-MASS: the mean of all points. A symmetric 4-corner square -> center.
pub fn centroid_is_mean_of_points_test() {
  let #(cx, cy) =
    gcode_program.centroid_of_points([
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
    gcode_program.centroid_of_points([
      #(0.0, 0.0),
      #(0.0, 0.0),
      #(0.0, 0.0),
      #(12.0, 0.0),
    ])
  approx(cx, 3.0) |> should.be_true
  approx(cy, 0.0) |> should.be_true
}

pub fn centroid_empty_is_origin_test() {
  let #(cx, cy) = gcode_program.centroid_of_points([])
  approx(cx, 0.0) |> should.be_true
  approx(cy, 0.0) |> should.be_true
}

// The expected machine-space centroid for the real fixture board, computed
// independently of the generator (parse -> transform every hole -> mean).
fn expected_machine_centroid() -> #(Float, Float) {
  let board = board_from_fixture()
  let t = xmirror_alignment().transform
  let machine_pts =
    list.map(board.holes, fn(h) { transform2d_apply(t, #(h.x, h.y)) })
  gcode_program.centroid_of_points(machine_pts)
}

// Every tool block emits ONE bit-exchange move (the centroid move), placed
// IMMEDIATELY after the `G00 Z<zchange> (Retract)` line and BEFORE the swap.
pub fn each_tool_block_retract_followed_by_exchange_move_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let assert Ok(retract_re) = regexp.from_string("^G00 Z.*\\(Retract\\)")
  let assert Ok(exchange_re) =
    regexp.from_string("^G0 X.*Y.*bit-exchange position")

  // Walk pairs: every retract line is immediately followed by an exchange move.
  let pairs =
    list.window_by_2(p.lines)
    |> list.filter(fn(pair) { regexp.check(retract_re, pair.0) })
  // There is one retract per tool block.
  list.length(pairs) |> should.equal(list.length(p.tool_order))
  list.all(pairs, fn(pair) { regexp.check(exchange_re, pair.1) })
  |> should.be_true

  // Count of exchange-move lines == number of tool sizes.
  list.filter(p.lines, fn(l) { regexp.check(exchange_re, l) })
  |> list.length
  |> should.equal(list.length(p.tool_order))
}

// The exchange move's X/Y equal the board centroid in machine space, and the
// SAME XY appears for every tool block (one shared centroid).
pub fn exchange_move_uses_shared_board_centroid_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let assert Ok(exchange_re) =
    regexp.from_string("^G0 X.*Y.*bit-exchange position")
  let exchange_lines =
    list.filter(p.lines, fn(l) { regexp.check(exchange_re, l) })

  // One per tool size, and they are all byte-identical (one shared centroid).
  list.length(exchange_lines) |> should.equal(list.length(p.tool_order))
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

// --- golden semantic diff ---------------------------------------------------

pub fn drill_golden_drilled_set_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let emitted = drilled_set(p.lines)
  // 130 distinct {tool, x, y} drilled, all with machine X in [0, 81.28].
  set.size(emitted) |> should.equal(130)
}

pub fn drill_zdepths_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  // Every plunge is exactly zdrill.
  let plunge_zs =
    p.lines
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
  list.filter(p.lines, fn(l) { regexp.check(rt, l) })
  |> list.length
  |> should.equal(130)

  // Tool-change retracts to zchange (>= 5 lines containing Z30.00000).
  let zchange_count =
    list.filter(p.lines, fn(l) { string.contains(l, "Z30.00000") })
    |> list.length
  { zchange_count >= 5 } |> should.be_true
}

pub fn preamble_touchoff_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let core = list.map(p.lines, semantic_core)
  list.contains(core, "G92 X0 Y0 Z0") |> should.be_true
  list.contains(core, "G94") |> should.be_true
  list.contains(core, "G21") |> should.be_true
  list.contains(core, "G91.1") |> should.be_true
  list.contains(core, "G90") |> should.be_true
}

pub fn postamble_homes_and_ends_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let core = list.map(p.lines, semantic_core)
  list.contains(core, "G00 Z30.000") |> should.be_true
  list.contains(core, "G00 X0.0 Y0.0 Z0.0") |> should.be_true
  list.contains(core, "M5") |> should.be_true
  list.contains(core, "M9") |> should.be_true
  list.contains(core, "M2") |> should.be_true
}

pub fn tool_structure_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  let core = list.map(p.lines, semantic_core)
  count_eq(core, "T1") |> should.equal(1)
  count_eq(core, "T5") |> should.equal(1)
  // Feed lines: one per tool block.
  let assert Ok(feed) = regexp.from_string("^G1 F200\\.0+\\b")
  list.filter(p.lines, fn(l) { regexp.check(feed, l) })
  |> list.length
  |> should.equal(5)
  // Per-tool dwell G04 P1.00000 (>= 5).
  let assert Ok(dwell) = regexp.from_string("^G04 P1\\.0+\\b")
  { list.filter(p.lines, fn(l) { regexp.check(dwell, l) }) |> list.length >= 5 }
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

// --- the GcodeProgram value -------------------------------------------------

pub fn value_carries_mode_order_bbox_test() {
  let p =
    gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(Drill))
  p.mode |> should.equal(Drill)
  p.tool_order |> should.equal(["T1", "T2", "T3", "T4", "T5"])
  let #(minx, miny, maxx, maxy) = p.bbox_machine
  { minx <=. maxx } |> should.be_true
  { miny <=. maxy } |> should.be_true
  // Post-mirror, board X in [-81.28, 0] -> machine X in [0, 81.28].
  { float.absolute_value(minx -. 0.0) <. 1.0e-6 } |> should.be_true
  { float.absolute_value(maxx -. 81.28) <. 1.0e-6 } |> should.be_true
}

pub fn defaults_to_dry_run_test() {
  let p =
    gcode_program.build(
      board_from_fixture(),
      xmirror_alignment(),
      config.default(),
    )
  p.mode |> should.equal(DryRun)
  let assert Ok(re) = regexp.from_string("^\\s*M3\\s+S[1-9]")
  list.any(p.lines, fn(l) { regexp.check(re, l) }) |> should.be_false
}

// --- stream_lines / is_streamable -------------------------------------------
//
// The HANG fix: the streamed view must drop blank lines and FULL-LINE comments
// (Marlin doesn't reliably `ok` a blank line, so the handshake stalls), while
// keeping every real command — INCLUDING commands with a trailing inline
// comment.

// Build a `GcodeProgram` with arbitrary lines for the unit tests (mode/bbox/
// tool_order are irrelevant to `stream_lines`, which only filters `lines`).
fn program_with_lines(lines: List(String)) -> GcodeProgram {
  GcodeProgram(
    lines: lines,
    mode: DryRun,
    bbox_machine: #(0.0, 0.0, 0.0, 0.0),
    tool_order: [],
  )
}

pub fn is_streamable_classifies_lines_test() {
  // Dropped: blanks, whitespace-only, full-line ( and ; comments.
  gcode_program.is_streamable("") |> should.be_false
  gcode_program.is_streamable("   ") |> should.be_false
  gcode_program.is_streamable("\t") |> should.be_false
  gcode_program.is_streamable("( blau-drill native G-code )") |> should.be_false
  gcode_program.is_streamable("  ( indented full-line comment )")
  |> should.be_false
  gcode_program.is_streamable(";foo") |> should.be_false
  gcode_program.is_streamable("  ; leading semicolon comment")
  |> should.be_false

  // Kept: real commands, including those with a TRAILING inline comment.
  gcode_program.is_streamable("G0 Z5") |> should.be_true
  gcode_program.is_streamable("G92 X0 Y0 Z0") |> should.be_true
  gcode_program.is_streamable("M0      (Temporary machine stop.)")
  |> should.be_true
  gcode_program.is_streamable("G00 Z30 (Retract)") |> should.be_true
  gcode_program.is_streamable("M3 S255      (Spindle on clockwise.)")
  |> should.be_true
}

pub fn stream_lines_drops_blanks_and_full_comments_test() {
  let p =
    program_with_lines([
      "( c )",
      "",
      "  ",
      "G0 Z5",
      "M0  (stop)",
      ";foo",
      "G92 X0 Y0 Z0",
    ])
  gcode_program.stream_lines(p)
  |> should.equal(["G0 Z5", "M0  (stop)", "G92 X0 Y0 Z0"])
}

// REGRESSION (the bug): over the REAL generated program, nothing streamed is a
// blank/whitespace-only line and nothing's trim starts with `(` — in BOTH modes.
pub fn stream_lines_real_program_has_no_blank_or_full_comment_test() {
  [Drill, DryRun]
  |> each(fn(mode) {
    let p =
      gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(mode))
    let streamed = gcode_program.stream_lines(p)
    // Every streamed line is streamable (non-blank, not a full-line comment).
    list.all(streamed, gcode_program.is_streamable) |> should.be_true
    // Belt-and-braces: explicit blank + leading-`(` checks.
    list.any(streamed, fn(l) { string.trim(l) == "" }) |> should.be_false
    list.any(streamed, fn(l) { string.starts_with(string.trim(l), "(") })
    |> should.be_false
  })
}

// LOSSLESS for commands: `stream_lines` == `lines` minus exactly the dropped
// noise, in the SAME order (filter, not reorder). The count of streamable lines
// in the raw program equals the streamed count, and the streamed list IS the
// filtered raw list.
pub fn stream_lines_lossless_for_commands_test() {
  [Drill, DryRun]
  |> each(fn(mode) {
    let p =
      gcode_program.build(board_from_fixture(), xmirror_alignment(), cfg(mode))
    let streamed = gcode_program.stream_lines(p)
    let expected = list.filter(p.lines, gcode_program.is_streamable)
    // Order preserved (filter, not reorder) and counts agree.
    streamed |> should.equal(expected)
    list.length(streamed) |> should.equal(list.length(expected))
    // Sanity: the program really did contain droppable noise.
    { list.length(p.lines) > list.length(streamed) } |> should.be_true
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
