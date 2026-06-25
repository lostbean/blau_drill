# 17. The streaming FSM carries RenderedLine (typed origin), not String
<a id="adr-0017"></a>

- **Status:** Accepted
- **Date:** 2026-06-25
- **Builds on / amends:** [ADR-0016](0016-typed-operation-algebra.md#adr-0016)
  (the Operation algebra), [ADR-0009](0009-real-hardware-correct-streamed-program.md#adr-0009)
  (the in-app pause sentinel + the ok/resend handshake), [ADR-0012](0012-session-coordinates-stage-wire-screen.md#adr-0012)
  (the Session coordinator).

## Context

[ADR-0016](0016-typed-operation-algebra.md#adr-0016) makes the program a typed
`Operation` algebra, but if it renders to `List(String)` *before* reaching
`printer.Stream`, the streaming FSM still reverse-parses: `is_pause_sentinel`
string-matches `"M0_APP_PAUSE"` to decide a pause, and the app reconstructs hole
counts and the current tool by grepping the confirmed line prefix. The string
disease would survive in the consumer. The fix only lands if the **typed origin
travels through the FSM** so progress, pause, and tool are read from the op a
streamed line came from — never from the line's text.

The hard subtlety: one high-level op (a `ToolBlock`) renders to **many** wire
lines (retract, park, `T<n>`, `M5`, dwell, `M6`, pause, spindle-on, return). The
Marlin handshake is **per line** — it acks/NAKs one line and may `Resend: N` a
specific line. So "op index" ≠ "line index", and the FSM cannot simply index ops.

## Decision

`printer.Stream` carries a `List(RenderedLine)`, where each line **pairs its framed
wire text with a typed back-reference to the op it came from**:

```gleam
pub type RenderedLine {
  RenderedLine(wire: String, origin: LineOrigin)
}
pub type LineOrigin {
  LineOrigin(
    op_index: Int,              // which Operation this line belongs to
    kind: OpKind,               // Preamble | Prepare | ToolBlock | DrillHole | Pause | Postamble
    tool: Option(ToolId),       // set on ToolBlock lines
    hole_id: Option(HoleId),    // set on DrillHole lines
    pause: Option(PauseReason), // set on the Pause line
  )
}

pub type StreamJob {
  StreamJob(rendered: List(RenderedLine), line_idx: Int, total: Int)
}
```

### Index lines, carry the op as a back-reference

The FSM indexes **lines** (preserving the per-line resend protocol), and each line
carries `origin.op_index` back to its op. The earlier "make every op render to
exactly one line" idea is rejected — a bit exchange is irreducibly multi-line, and
forcing 1:1 would either fracture ops or corrupt the handshake. `Progress(sent)`
counts **lines**; the UI maps `rendered[sent - 1].origin` to *which op / hole /
tool*. Counting drilled holes is counting confirmed lines whose
`origin.kind == DrillHole` (one travel line per hole, identified by type, not by
`"G0 X"`).

### The pause is a typed property, not a string

The FSM pauses when the next line's `origin.pause` is `Some(_)` — a pattern match,
not `line == "M0_APP_PAUSE"`. As today ([ADR-0009](0009-real-hardware-correct-streamed-program.md#adr-0009)),
the pause line is intercepted and **never framed/sent**, so Marlin's line counter
stays in sync; only the *recognition* mechanism changes from string to type. The
upcoming tool for the bit-change modal is `origin.pause`'s `BitChange(tool)` (or
the last `ToolBlock`'s `origin.tool`), never a grepped `T<n>`.

### Render once, at run start — byte-stable resend

The `rendered` list is produced **once** when the stream starts ([ADR-0016](0016-typed-operation-algebra.md#adr-0016)'s
`render`) and stored immutably in `StreamJob`. A `Resend: N` re-frames
`rendered[N].wire` — the **identical stored string** — never a regeneration. This
is the byte-stability the handshake requires; it is preserved because the FSM
never re-renders.

## Consequences

- The FSM stays **shallow**: it learns no G-code. It reads `.wire` to frame and
  pattern-matches `.origin` to pause. All rendering lives in the domain renderer
  ([ADR-0016](0016-typed-operation-algebra.md#adr-0016)); all UI meaning (tool, hole, ETA) lives in the
  app's projections ([ADR-0018](0018-model-is-params-plus-machines.md#adr-0018)).
- `printer.Stream(lines)` and the `Session` `Plan` payloads (`RunDryRun` /
  `ConfirmRegistration`) change from `List(String)` to `List(RenderedLine)`. The
  threading pattern is unchanged ([ADR-0012](0012-session-coordinates-stage-wire-screen.md#adr-0012):
  lines are passed in through action payloads); only the element type changes.
- The emulator and the printer transition tests feed synthetic `RenderedLine`
  programs; `Progress` assertions check the origin, not the line text.
- Trade-off: a `RenderedLine` is heavier than a bare string (it carries the
  origin). The cost is trivial against the bug class it removes, and it is the
  natural place for the typed metadata the UI needs anyway.
