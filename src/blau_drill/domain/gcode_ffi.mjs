// Pure number-formatting helpers backing `gcode_program.gleam`. No DOM / IO —
// kept tiny and side-effect-free so the generator stays unit-testable.
//
// The formatting rules the G-code generator relies on:
//
//   fmt5(v)         = v rounded to 5 decimals, always 5 fractional digits
//   fmt3(v)         = v rounded to 3 decimals, always 3 fractional digits
//   fmt_diameter(d) = d to 4 decimals, then strip trailing "0"s and a trailing "."
//
// The `Math.round(v*10^n)/10^n + 0` step is load-bearing: it rounds to the
// display precision FIRST, then the `+ 0` collapses a literal negative zero
// (from `-1 * 0.0` after the X-mirror) AND a sub-precision negative residual
// (e.g. -1.7e-15) to a clean +0.0, so board X=0 prints "X0.00000", never
// "X-0.00000". A plain `(-0.0).toFixed(5)` would print "-0.00000".

// Round-half-away-from-zero to `decimals` places, matching Erlang's
// `Float.round/2` (which rounds half away from zero), then collapse -0 to +0.
function roundTo(v, decimals) {
  const factor = Math.pow(10, decimals);
  // Math.round rounds half UP (toward +Inf); for negatives that is toward zero,
  // which differs from Erlang's "half away from zero". Mirror it by rounding the
  // magnitude and reapplying the sign.
  const sign = v < 0 ? -1 : 1;
  const rounded = sign * Math.round(Math.abs(v) * factor) / factor;
  // `+ 0` collapses -0 to +0.
  return rounded + 0;
}

export function fmtDecimals(v, decimals) {
  return roundTo(v, decimals).toFixed(decimals);
}

// Diameter: 0.600 -> "0.6", 1.000 -> "1", 1.200 -> "1.2".
export function fmtDiameter(d) {
  let s = d.toFixed(4);
  s = s.replace(/0+$/, "");
  s = s.replace(/\.$/, "");
  return s;
}
