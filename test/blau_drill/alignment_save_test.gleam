//// Round-trip guard for the persisted alignment slice
//// (`storage.encode_alignment` / `storage.decode_alignment`).
////
//// The slice survives a page reload so the operator can RESUME a fitted
//// alignment without re-capturing fiducials. These tests exercise the PURE
//// serialize/parse (no localStorage): a built `AlignmentSave` must survive a
//// save→load with its transform fields, captures, side, and quality intact
//// (floats compared approximately); and a missing / garbage blob must decode to
//// `Error(Nil)` (a bad slice means "no restore", never a crash).

import blau_drill/domain/transform2d.{Transform2D}
import blau_drill/ui/model.{Back, Front}
import blau_drill/ui/storage.{AlignmentSave}
import gleam/float
import gleeunit/should

fn approx(a: Float, b: Float) -> Bool {
  float.absolute_value(a -. b) <. 1.0e-9
}

fn sample() -> storage.AlignmentSave {
  AlignmentSave(
    transform: Transform2D(
      a: -1.0,
      b: 0.25,
      c: 0.1,
      d: 0.98,
      tx: 12.5,
      ty: -7.25,
    ),
    captures: [
      #(#(1.0, 2.0), #(11.0, 12.0)),
      #(#(3.5, 4.5), #(13.5, 14.5)),
      #(#(-5.0, 6.0), #(5.0, 16.0)),
    ],
    side: Back,
    quality: 87,
    residual_max: 0.042,
    residual_rms: 0.031,
  )
}

// ── round-trip: transform fields survive ──────────────────────────────────────

pub fn round_trip_transform_test() {
  let a = sample()
  let assert Ok(got) = storage.decode_alignment(storage.encode_alignment(a))
  let t = a.transform
  let g = got.transform
  approx(g.a, t.a) |> should.be_true
  approx(g.b, t.b) |> should.be_true
  approx(g.c, t.c) |> should.be_true
  approx(g.d, t.d) |> should.be_true
  approx(g.tx, t.tx) |> should.be_true
  approx(g.ty, t.ty) |> should.be_true
}

// ── round-trip: captures survive (order + values) ─────────────────────────────

pub fn round_trip_captures_test() {
  let a = sample()
  let assert Ok(got) = storage.decode_alignment(storage.encode_alignment(a))
  list_length(got.captures) |> should.equal(3)
  // each board/machine pair survives approximately, in order.
  each_pair(a.captures, got.captures)
}

fn each_pair(
  want: List(#(transform2d.Point, transform2d.Point)),
  got: List(#(transform2d.Point, transform2d.Point)),
) -> Nil {
  case want, got {
    [], [] -> Nil
    [#(#(wbx, wby), #(wmx, wmy)), ..wr], [#(#(gbx, gby), #(gmx, gmy)), ..gr] -> {
      approx(gbx, wbx) |> should.be_true
      approx(gby, wby) |> should.be_true
      approx(gmx, wmx) |> should.be_true
      approx(gmy, wmy) |> should.be_true
      each_pair(wr, gr)
    }
    _, _ -> should.fail()
  }
}

fn list_length(xs: List(a)) -> Int {
  case xs {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

// ── round-trip: side + quality + residuals survive ────────────────────────────

pub fn round_trip_scalars_test() {
  let a = sample()
  let assert Ok(got) = storage.decode_alignment(storage.encode_alignment(a))
  got.side |> should.equal(Back)
  got.quality |> should.equal(87)
  approx(got.residual_max, a.residual_max) |> should.be_true
  approx(got.residual_rms, a.residual_rms) |> should.be_true
}

pub fn round_trip_front_side_test() {
  let a = AlignmentSave(..sample(), side: Front)
  let assert Ok(got) = storage.decode_alignment(storage.encode_alignment(a))
  got.side |> should.equal(Front)
}

// ── empty captures round-trip ─────────────────────────────────────────────────

pub fn round_trip_empty_captures_test() {
  let a = AlignmentSave(..sample(), captures: [])
  let assert Ok(got) = storage.decode_alignment(storage.encode_alignment(a))
  got.captures |> should.equal([])
}

// ── garbage / empty → Error(Nil) (no restore, no crash) ───────────────────────

pub fn decode_empty_is_error_test() {
  storage.decode_alignment("") |> should.equal(Error(Nil))
}

pub fn decode_garbage_is_error_test() {
  storage.decode_alignment("this is not a slice") |> should.equal(Error(Nil))
}

pub fn decode_partial_is_error_test() {
  // Missing the rest of the transform / captures: must not partially restore.
  storage.decode_alignment("a=1.0\nb=2.0") |> should.equal(Error(Nil))
}

pub fn decode_bad_capture_is_error_test() {
  // A complete-looking header but a malformed capture quad → whole parse fails.
  let blob =
    "a=1.0\nb=0.0\nc=0.0\nd=1.0\ntx=0.0\nty=0.0\nside=front\nquality=50\nrmax=0.0\nrrms=0.0\ncaptures=1,2,3"
  storage.decode_alignment(blob) |> should.equal(Error(Nil))
}
