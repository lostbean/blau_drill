# 1. Native Marlin G-code generation in Elixir
<a id="adr-0001"></a>

- **Status:** Accepted
- **Date:** 2026-06-18

## Context

The hand-rolled workflow generated drill G-code with an external binary
(`pcb2gcode`, pinned to the nixos-24.05 channel because it fails to build against
boost 1.87) and then fixed it up with `postprocess_drill.py`. The Python
post-processor did three jobs: rewrite the spindle command to **M3 S255** (a
bare `M3` only toggles Marlin's enable pin and never sets the PWM —
MarlinFirmware/Marlin#8379), emit a **Dry-run** variant alongside the real run,
and bake a fiducial `G92` offset into the preamble. This is a fragile two-tool,
two-language chain that pins a stale nixpkgs channel and splits the
spindle/mirror/offset knowledge across config files and a script.

## Decision

Generate Marlin G-code **natively in Elixir** in the `GcodeProgram` module, and
drop both `pcb2gcode` and `postprocess_drill.py` entirely. `GcodeProgram.build/2`
takes an `Alignment` and a mode, transforms each `Hole` from board to machine
coordinates via `Transform2D.apply`, groups by tool, and emits the lines —
**M3 S255** encoded once as a property of this module. The fiducial `G92` ritual
disappears: the fitted affine `Transform2D` already absorbs the
back-side X-mirror and the offset, so no separate mirror flag or baked-in `G92`
is needed. De-risk the cutover by **golden-diffing** the generated output against
the known-good reference files (`segby_v1.*.gcode`) from the old chain.

## Consequences

- One language, one in-process function; no pinned external binary, no Python
  interpreter, no intermediate `.gcode` files on disk.
- The spindle quirk, the per-mode plunge depth, and the tool grouping live in one
  typed place instead of three.
- Golden tests must be maintained: if we intentionally change emitted G-code, we
  re-bless the golden files deliberately, which keeps drift visible.
- **Trade-off / reconsider if:** the golden diff against `segby_v1.*.gcode`
  reveals a non-trivial pcb2gcode behaviour we depended on (e.g. oval-hole
  handling), we capture that behaviour as an explicit, tested case in
  `GcodeProgram` rather than reaching back for the external binary.
