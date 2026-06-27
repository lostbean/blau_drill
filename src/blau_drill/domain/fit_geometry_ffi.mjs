// Tiny, pure trig FFI backing `fit_geometry.gleam`. `gleam/float` has no
// trig functions, and the QR/polar decomposition of the fitted transform needs
// atan2 (column/azimuth angles) and acos (angle-between / tilt). No DOM, no IO,
// no side effects — just JS Math, kept unit-testable like `domain/gcode_ffi.mjs`.
//
// NOTE: callers MUST clamp the acos argument to [-1, 1] before calling. Float
// round-off can push a value like the column dot-product cosine a hair past 1.0,
// and Math.acos returns NaN for out-of-domain inputs. We do not clamp here so
// the contract stays a thin pass-through; the clamp lives in the Gleam caller.

export function atan2(y, x) {
  return Math.atan2(y, x);
}

export function acos(x) {
  return Math.acos(x);
}

export function cos(x) {
  return Math.cos(x);
}

export function sin(x) {
  return Math.sin(x);
}
