// Trig helpers for the domain test suite (Gleam stdlib has no trig). Used only
// to construct rotation transforms in the property-equivalent example cases.

export function cos(x) {
  return Math.cos(x);
}

export function sin(x) {
  return Math.sin(x);
}
