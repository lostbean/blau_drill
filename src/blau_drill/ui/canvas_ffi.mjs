// View-only FFI for the BoardCanvas: turn a click on the <svg> into the SVG's
// own user-space coordinates, using the live screen CTM (handles the
// preserveAspectRatio letterboxing + current viewBox/zoom). The Gleam side then
// converts that SVG point into BOARD coordinates (inverse of `project`) — that
// math stays in Gleam so it is testable; only the DOM matrix lives here.
//
// Returns #(svg_x, svg_y) as a 2-tuple (Gleam tuples are JS arrays).

export function svg_point_from_click(event) {
  const svg = event.currentTarget
  if (!svg || typeof svg.createSVGPoint !== "function") {
    return [0.0, 0.0]
  }
  const pt = svg.createSVGPoint()
  pt.x = event.clientX
  pt.y = event.clientY
  const ctm = svg.getScreenCTM()
  if (!ctm) return [0.0, 0.0]
  const loc = pt.matrixTransform(ctm.inverse())
  return [loc.x, loc.y]
}
