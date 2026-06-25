# 16. The drilling program is a typed Operation algebra, rendered to G-code at the edge
<a id="adr-0016"></a>

- **Status:** Accepted
- **Date:** 2026-06-25
- **Builds on / amends:** [ADR-0001](0001-native-gcode-generation.md#adr-0001)
  (native G-code generation), [ADR-0009](0009-real-hardware-correct-streamed-program.md#adr-0009)
  (the in-app pause), [ADR-0015](0015-per-mode-feed-profiles.md#adr-0015)
  (per-mode feeds). Paired with [ADR-0017](0017-typed-rendered-line-through-fsm.md#adr-0017)
  (the typed line through the FSM) and [ADR-0018](0018-model-is-params-plus-machines.md#adr-0018)
  (project, don't store).

## Context

`gcode_program.build` returns a `GcodeProgram` whose payload is `lines:
List(String)` — human-readable G-code. Downstream code then **reverse-parses those
strings to recover structure it once had and threw away**: `app.count_holes`
greps lines starting `"G0 X"` to tally drilled holes; `app.upcoming_tool` /
`first_tool_token` / `last_tool_token` grep bare `T<n>` tokens; `printer.gleam`'s
`is_pause_sentinel` matches the literal `"M0_APP_PAUSE"`; `gcode_program.is_streamable`
greps for a leading `(` / `;` to decide what to stream.

Every one of these is brittle against a rendering change. [ADR-0015](0015-per-mode-feed-profiles.md#adr-0015)
changed inter-hole travel from `G0 X.. Y..` to `G1 X.. Y.. F<feed>`; `count_holes`
still matched `"G0 X"`, so it counted **zero holes** on every confirmed line —
dry-run progress froze at `0/N` and the board never marked a hole, even though the
wire streamed correctly. The generated program was perfect; the *string
re-derivation* of its structure had silently rotted. This is not one bug — a
generator that emits strings and consumers that parse them back is a bug
*generator*.

## Decision

The drilling program is a **typed `Operation` algebra** — the value `build`
returns — and G-code strings are **rendered from it at the wire edge**, once, by a
pure renderer. Structure is read from the types; it is never recovered by parsing.

```gleam
pub type Operation {
  Preamble                                     // unit/mode setup (G94/G21/G90/G91.1)
  Prepare(centroid: Point, safe_z: Float)      // ADR-0014 flush-then-prepare (drill mode only)
  ToolBlock(tool: ToolId)                      // bit exchange: retract, park at centroid, M5/M6, spindle-on
  DrillHole(hole_id: HoleId, board: Point)     // a hole at a BOARD point; renders travel→plunge→retract
  Pause(reason: PauseReason)                   // ADR-0009 in-app pause; never a string sentinel
  Postamble                                    // home, spindle off, M2
}

pub type HoleId = Int                          // file-parse order (board_model), stable across tool grouping
pub type PauseReason { BitChange(tool: ToolId)  TouchOff }
```

### Ops are symbolic; numbers live in a render context

Operations carry **intent** (a hole at a *board* point), not resolved G-code
numbers. The numbers — feeds, safe Z, centroid, mode — live in a `RenderContext`
passed at render time (the immutable run-start config snapshot). So one op list
renders to **two views** (the streamed wire form and a future human-readable
export) and to either **mode** (dry-run hover vs drill plunge) without rebuilding
the list:

```gleam
pub type RenderContext {
  RenderContext(mode: Mode, feeds: FeedProfile, safe_z: Float, centroid: Point, cfg: GcodeConfig)
}
pub type RenderTarget { Wire  Rich }
pub fn render(ops: List(Operation), ctx: RenderContext, target: RenderTarget) -> List(RenderedLine)
```

The render is **pure and deterministic** given `(ops, ctx)`, with the existing
`fmt5` FFI as the single number-formatting authority — so the wire output is
byte-stable (the property [ADR-0017](0017-typed-rendered-line-through-fsm.md#adr-0017)
relies on for the Marlin resend handshake).

### The safety invariants live in the renderer, structurally

The two structural invariants (CONTEXT.md, [ADR-0001](0001-native-gcode-generation.md#adr-0001))
move from `build`'s combinators into the renderer, where they stay *unviolatable*:

- **XY only at safe Z.** A `DrillHole` renders as the atom *travel→plunge→retract*
  in one function; there is no standalone XY-move primitive a caller could emit at
  an unsafe Z. The invariant is structural in the renderer, not caller discipline.
- **Spindle before plunge (drill).** Ops are ordered: a `ToolBlock` (which renders
  spindle-on) always precedes its `DrillHole`s in the typed list. "A `DrillHole`
  before its `ToolBlock`" is expressible only by mis-building the list, which the
  build is the single place to get right — and is golden-tested.

### Hole identity is file-parse order

A hole gets a stable `HoleId` (an `Int`) assigned at `BoardModel` parse time, in
file order. Tool grouping reorders holes for drilling, but the id rides along, so
"hole N done" is unambiguous and matches the board view's file-order walk
(`mark_holes`).

## Consequences

- `count_holes` becomes "count `DrillHole` ops confirmed"; `upcoming_tool` becomes
  "read the origin's tool"; both immune to any future rendering change. The
  reverse-parsers are deleted, not patched.
- `is_streamable`'s string filter is replaced by a structural render-target choice
  (a comment is a `Rich`-only render, not a line to grep back out), so the wire
  and rich views can never drift — they are two renders of one algebra.
- `build`'s return type changes shape (the algebra, then a render pass). The public
  `GcodeProgram` keeps its metadata fields (`mode`, `bbox_machine`, `tool_order`),
  now *projected* from the ops rather than parsed from lines.
- Trade-off (symbolic ops + ctx vs self-contained ops): a render step survives at
  the edge and must be fed the right `ctx`. We accept it because two-view / two-mode
  rendering from one list is worth more than a context-free `op -> lines`, and the
  ctx is already the immutable `applied_config` snapshot, so determinism holds.
- Golden string tests (the exact wire bytes) stay valuable and remain; structural
  tests (130 holes, 5 tools, spindle-before-plunge) move to asserting on ops, which
  is stronger than regex over lines.
