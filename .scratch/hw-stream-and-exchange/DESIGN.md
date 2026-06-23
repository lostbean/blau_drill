# Design: real-hardware streaming fix + bit-exchange position

Status: ready-for-implementation
Date: 2026-06-23

Two issues from real-printer use, both in the g-code generator / stream path.

## Issue #2 (CRITICAL) — dry-run/drill stuck at 0 on real hardware

**Observed:** On the real printer, dry-run and drill hang at 0/130 — no error,
nothing moves. Works fine in the simulator.

**Root cause (diagnosed):** the generated program (`gcode_program.build`) contains
**blank lines `""`**, full-line **`( comments )`**, and **`M0` pauses**, and the
app streams `program.lines` **verbatim** through Marlin's numbered ok-handshake
(send line → wait for `ok` → send next). Real Marlin does **not** reliably emit an
`ok` for a blank line, so the handshake stalls on the first blank line → stuck at
0, no error. The **simulator synthesizes an `ok` for every written line**, so it
never stalls there — hence sim-passes / hardware-hangs.

**Fix (decided): sanitize the program before streaming.**
- Add a sanitize step applied to the lines that go to `printer.Stream(...)` (NOT to
  the human-readable export): drop empty/whitespace-only lines and full-line
  comments (`(` … `)` — and any `;`-style if present). Marlin then only sees real
  commands, each of which it acks; the handshake advances.
- Keep the full, commented program for any future g-code EXPORT (comments/blanks are
  useful for humans). So: `program.lines` stays the rich form; streaming uses a
  sanitized view. Add e.g. `gcode_program.stream_lines(program) -> List(String)`
  (sanitized) or sanitize in the app right before `issue(..., printer.Stream(...))`.
  Prefer a pure helper in `gcode_program` so it's unit-testable.

## M0 pauses — configurable app-mode vs export

**Context:** `M0` (mandatory machine stop) appears at touch-off (preamble) and at
EVERY bit change (`tool_block`). `M0` blocks until the operator presses resume ON
THE PRINTER's panel. This app is screen-driven, so a streamed `M0` freezes the
app's progress while waiting on the printer.

**Decision (configurable):**
- Add a config flag, e.g. `app_pause: Bool` (or `omit_m0`/`pause_mode`) to
  `GcodeConfig` (+ the UI `Config` record + a settings toggle, like `auto_connect`).
- **App mode (the streaming path, when the flag is set):** omit `M0` from the
  streamed program. The app pauses the stream at touch-off / each bit change and the
  operator resumes IN-APP (the app already has bit-change UI / a resume affordance).
- **Export / default:** a future g-code export ALWAYS keeps `M0` (a standalone file
  has no app to drive it). **Default is M0 present** (conservative). The flag only
  strips M0 for the in-app streaming workflow.
- NOTE: This interacts with sanitize — sanitize removes blanks/comments always;
  the M0 flag governs M0 specifically. The streamed program in app-mode = sanitize
  ∘ (omit M0). The export = full program (M0 kept, comments kept).

**Scope clarity:** wiring the in-app PAUSE/RESUME at each omitted-M0 point is the
larger behavioral piece. Minimum for THIS feature: (a) the config flag exists and
is honored by the generator (M0 omitted when set), (b) sanitize unblocks the
stream. The app-driven pause/resume at bit changes builds on the existing
bit-change UI — implement it so a bit change actually pauses the stream and offers
resume, OR (if that's too large) at least ensure the stream doesn't stall (the bit
change still needs the operator to swap — so a pause point is required, not
optional, when M0 is omitted). DECISION for impl: when app_pause is on, the stream
PAUSES in-app at each bit-change boundary and shows resume; it must not silently
run through a bit change without a swap opportunity.

## Issue #1 — bit-exchange position (Z retract + board-center XY)

**Observed:** at start and at each bit-size change, the machine should go to an
exchange position so the operator can swap the bit comfortably; currently
`tool_block` only retracts Z to `zchange` (no XY move — you swap over the board).

**Fix (decided): Z retract + move to the board CENTER (centroid / center of mass)
in XY for the swap.**
- At each tool block (start of each bit size), after retracting Z to `zchange`,
  move XY to the board center (in MACHINE coords, via the alignment transform), then
  pause for the swap, then return to the work.
- "Board center" = the centroid of the machine-space holes (center of mass) — the
  generator already maps holes to machine space and computes a bbox; compute the
  centroid (mean of machine hole positions) — center-on-mass, per the decision (not
  bbox-center). Add a helper.
- This is part of the generated g-code (so it applies to both dry-run and drill, and
  to export). The exchange move is: `G0 Z<zchange>` (retract) → `G0 X<cx> Y<cy>`
  (centroid) → pause (M0 or app-pause per the flag) → spindle/return as today.

## Invariants (must hold; assert in tests)

- **Sanitize is lossless for COMMANDS:** sanitizing drops only blank + comment-only
  lines; every real g-code command line survives in order. (Test: a program with
  blanks/comments sanitizes to exactly the command lines, same order.)
- **No blank lines ever streamed:** `stream_lines(program)` contains no empty/
  whitespace-only line and no full-line comment. (The real-hw stall regression.)
- **M0 flag:** with app_pause on, the generated/streamed program contains NO `M0`;
  with it off (default/export), `M0` is present at touch-off + each bit change.
- **Exchange position:** each tool block moves XY to the board centroid (machine
  coords) after the Z retract, before the swap pause. Centroid = mean of machine
  hole coords.
- **Default unchanged behavior:** default config (M0 on) + a board with no blanks
  still produces a valid program; existing gcode tests stay green (update only the
  ones that assert the now-changed tool_block / preamble).

## Interface contracts (pin)

- `gcode_program`:
  - `pub fn stream_lines(p: GcodeProgram) -> List(String)` — sanitized (no blanks /
    full-line comments). The app streams THIS, not `p.lines`.
  - centroid helper (internal or pub-for-test) over machine holes.
- `config.GcodeConfig` gains `app_pause: Bool` (name TBD by impl; honored by build).
  `config.default()` sets it False (M0 kept by default).
- `model.Config` gains the string/bool field + a settings toggle; `bridge.gcode_config`
  coerces it.
- `gcode_program.build` honors `app_pause` (omit M0) and emits the centroid exchange
  move in each tool block.

## Gate (every chunk)

`cd /code/edgar/blau_drill && nix develop -c bash -c 'gleam build && gleam test'`
→ clean build (no warnings in touched files), all tests pass (currently 293 + new).
Plus: coordinator verifies on real-hardware-shaped behavior where possible
(sanitized stream advances; the sim can't reproduce the blank-line stall, so the
sanitize proof is the unit test + a streamed-lines inspection).
