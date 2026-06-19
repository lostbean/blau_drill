# PRD: blau_drill → pure-web Gleam app (no backend, no install)

Status: ready-for-agent
Owner: edgar
Date: 2026-06-19

## Goal

Eliminate the server entirely. Today blau_drill is a Phoenix LiveView app: the
Elixir backend owns the serial link, file parsing, the job state machine, the
affine alignment, and G-code generation; the browser is a thin LiveView client
with one Svelte SVG canvas. To use it, a person must install and run the Elixir
app and host it.

Target: a **pure browser application** — static HTML/JS/CSS, no server process —
that the operator opens in a browser and uses to drive the printer **directly
over USB** via the **Web Serial API**. No install, no hosting beyond static
files (or even `file://`). The browser becomes the whole machine controller.

## Why this is viable

- **Web Serial API** lets a web page open a USB-CDC serial port and read/write
  byte streams. MDN explicitly lists 3D printers / microcontrollers as the use
  case. Marlin-over-USB is exactly this. The current `PrinterConnection`
  (`:gen_statem` owning the UART) becomes client-side Web Serial code.
- Everything else the backend does (parsing `.drl`/SVG, FSM, least-squares fit,
  affine transform, G-code generation) is **deterministic, language-portable
  logic** with no server dependency. It moves into the browser.
- LiveView's server-pushed state sync is not needed: a single-operator,
  single-client app has no cross-client state to sync. Removing it is a
  simplification, not a loss.

## Hard constraints (accepted)

1. **Chromium only.** Web Serial works in Chrome/Edge/Opera 89+ only. Firefox
   and Safari do not and will not support it. The app states this requirement up
   front and feature-detects `navigator.serial`.
2. **Secure context.** Web Serial requires HTTPS, `localhost`, or `file://`.
   Hosting on any HTTPS static host (GitHub/Cloudflare/Netlify Pages) or opening
   a local file works; plain `http://` LAN addresses do not.
3. **User gesture to connect.** `navigator.serial.requestPort()` must be called
   from a click. The existing Stage-1 "Connect" button satisfies this.
   Permissions persist via `navigator.serial.getPorts()`.
4. **Client-only persistence.** Config + session state live in
   `localStorage`/`IndexedDB`. Appropriate for a single-operator tool.

## Non-goals

- Cross-browser support (explicitly Chromium-only).
- Multi-user / remote / cloud anything.
- Rewriting the *backend math* differently — we port behavior 1:1, using the
  existing Elixir code + tests as the reference spec.

## Safety invariants (must be preserved, now client-side)

These currently live structurally in the backend and MUST survive the move into
Gleam, enforced with sum types so illegal states are unrepresentable:

- **Energize-before-jog**: no motion command issued unless motors energized.
- **Retract-before-XY**: always lift to Z-safe before any XY move.
- **Spindle gating**: spindle on before plunge in drill mode; off in dry-run.
- **Linear 5-stage flow**: a stage's preconditions must hold before advancing
  (Load→Align→Dry-run→Drill→Done). Job FSM has no illegal transitions.
- **Abort / E-stop**: M112 must be reachable at all times during streaming.
- Alignment requires 3+ non-collinear fiducials.

## Target architecture

```
Browser (Chrome/Edge) — static SPA, no server
├── Lustre (Gleam→JS)            MVU app: 5-stage flow, sidebar, e-stop, telemetry bar
│   └── board_canvas (Lustre SVG)  holes/outline/fiducials/live head crosshair, zoom+pan
├── Gleam domain core (ported 1:1 from Elixir)
│   ├── board_model    .drl + Edge.Cuts SVG → holes/tools/bbox
│   ├── job (FSM)      parsed→registering→aligned→dry_run→drilling→done (sum types)
│   ├── alignment      least-squares affine fit + residuals
│   ├── transform2d    2×3 affine board↔machine
│   └── gcode_program  Marlin G-code (dry-run vs drill, safety invariants baked in)
└── FFI layer (Gleam @external → JS .mjs)
    ├── serial         requestPort / getPorts / open / read-loop / write / close (Web Serial)
    ├── serial_sim     in-browser fake Marlin (mirrors current sim UART) for dev w/o hardware
    ├── file_read      <input type=file> → ArrayBuffer (replaces upload)
    └── storage        localStorage config + session persistence (replaces Config snapshot)
```

## Library / tooling choices

- **Gleam** targeting JavaScript (`target = "javascript"` in `gleam.toml`).
- **lustre** (~v5.7) — MVU framework, vDOM, `lustre/element/svg` for the board.
- **lustre_dev_tools** (dev) — `gleam run -m lustre/dev start` watch server on
  :1234; `lustre/dev build` for static output.
- **gleam_javascript** — `gleam/javascript/promise` to bridge Web Serial's
  Promises (`promise.await`, `try_await`) into Lustre `Effect`s.
- **gleam_json** / `gleamson` — only if we serialize session/config to storage.
- **Web Serial** — no Gleam binding exists; we write a thin `.mjs` FFI wrapper
  and bind it with `@external(javascript, "./serial.mjs", "...")`.
- Tests: `gleeunit` for unit tests; port the existing Elixir property tests as
  the behavioral spec for the domain core.

## Migration plan (phased; serial-spike first)

### Phase 0 — Serial spike (de-risk the riskiest part first)
Tiny standalone Lustre app that proves the dangerous end-to-end path before any
porting. Acceptance: in Chrome, click Connect → pick port → app opens the Marlin
port, sends a jog/`M114`, shows the response; an Abort button sends `M112`. Also
prove the **serial_sim** path works with no hardware. Output: confidence that
Web Serial + Marlin + Lustre effects work; a reusable `serial` FFI module + sim.

### Phase 1 — Domain core port (pure, fully testable)
Port `transform2d`, `board_model`, `alignment`, `gcode_program`, `job` (FSM)
from Elixir to Gleam, porting the tests alongside as the spec. No UI, no serial.
Acceptance: ported tests pass and match Elixir outputs (diff against the
existing implementation as oracle).

### Phase 2 — Serial/control layer
Build the Gleam control state machine over the Phase-0 serial module: energize,
jog, move-to, where (`M114`), stream G-code line-by-line with progress, halt
(`M112`). Enforce the safety gates in the type system. Acceptance: full
dry-run/drill stream against the simulator with correct gating + abort.

### Phase 3 — UI shell + board canvas
Re-implement the 5-stage UI (Load/Align/Dry-run/Drill/Done), sidebar, e-stop,
telemetry bar, settings screen, and the `board_canvas` SVG view (zoom/pan,
click-to-jump, live head crosshair, confidence styling) in Lustre. Port the
Industrial Dark design tokens to CSS. Acceptance: visual + interaction parity
with the current app, verified in a real Chrome viewport (full-page screenshot —
per CLAUDE.md, trust the rendered screen, not the markup).

### Phase 4 — Wire it together + persistence + packaging
Connect UI ↔ control ↔ domain; config/session in localStorage; produce the
static build; document the Chromium/HTTPS requirements; ship a hosted static
page and/or a single openable file. Acceptance: a clean machine with only Chrome
can run a full Load→Done cycle against the simulator, and (manual) against real
hardware.

### Phase 5 — Decommission the Elixir app
Once parity is confirmed on hardware, retire the Phoenix/LiveView/Elixir tier.
Keep the Elixir source archived as the reference spec until then.

## Phase 0 — COMPLETE & coordinator-validated (2026-06-19)

Spike lives at `web/spike` (Lustre 5.7, Gleam 1.17 → JS). Two interchangeable
serial backends behind one `backend.Backend` record seam: real Web Serial
(`serial_ffi.mjs`) and an in-browser simulator (`sim_ffi.mjs`, ported 1:1 from
`sim.ex`). Pure protocol helpers in `protocol.gleam` (checksum / framing /
format_mm / parse_m114), 14 unit tests.

Coordinator validation (independent, not taken on the agent's word):
- Clean `gleam build` + `gleam test` from scratch in the dev shell → 14/14 pass.
- Test ground-truth checksums re-derived against the REAL Elixir
  `PrinterConnection.checksum/1` (N1 M17→20, N123 G1 X10→81, N2 G91→19,
  N3 G0 X1.000→125, N5 G0 X12.500 Y-3.000→53) — all match.
- Drove the sim flow in Chrome via DevTools MCP: Connect→IDLE; Energize→JOGGING
  (TX `N1 M17*20`); jog X+×2, Y+×1 → M114 reads **X 2 Y 1 Z 0** (proves the
  G91/G0/G90 ordering is correct, framed `N2 G91*19 / N3 G0 X1*99 / N4 G90*20…`
  with monotonic line numbers); Stream 35 lines → strict one-in-flight
  ok-handshake `N11…N44`, "stream complete", returns to JOGGING; ABORT → FAULTED
  with **raw** `TX M112` (OOB, no N/checksum) + Reconnect→Idle affordance.
- No console errors/warnings. Evidence:
  `.scratch/gleam-pure-web-migration/coordinator_validation_faulted.png` plus the
  agent's `web/spike/dist/evidence_*.png`.

Toolchain fixes landed in `flake.nix`: added `pkgs.gleam` (1.17.0) and
`pkgs.rebar3` (the latter is required to compile `lustre_dev_tools`' Erlang-target
deps for the `gleam run -m lustre/dev …` watch server).

### Carry-forward rules for later phases (learned in Phase 0)
- **Never emit order-dependent multi-line writes via `effect.batch`** — it
  reverses synchronous run order (prepend-while-folding), which silently broke
  G91/G0/G90 → run them inside ONE `effect.from`.
- The dev server does **not** hot-rebuild hand-written `.mjs` FFI files; after
  editing an `.mjs` run `gleam build` (or restart) and hard-reload (ES modules
  cache aggressively).
- Promise→Effect bridge pattern: `use dispatch <- effect.from` then
  `b.open(baud) |> promise.map(fn(res){ dispatch(Msg(res)) })`; the read loop
  calls `start_reading` once with dispatch-wrapped `on_line`/`on_error`.
- Lustre HTML config is under `[tools.lustre.html]` in gleam.toml; CSS via
  `[[tools.lustre.html.stylesheets]]`. Body defaults to `<div id="app">`.
- Form inputs need `id`/label association — Phase 3 must fix (a11y-clean CI gate).
- The `backend.Backend` record (open/write/start_reading/close over an opaque
  `Conn`, Result-inside-Promise) is the seam Phase 2's control state machine
  builds on.

## Phase 2 — COMPLETE & coordinator-validated (2026-06-19)

Serial control state machine at `web/app/src/blau_drill/control/`:
- `printer.gleam` — PURE state machine: `command(state, Command) -> Step` and
  `feed(state, line) -> Step` returning `Step(state, writes, events)`. Sum-typed
  `PrinterState {Disconnected Idle Jogging Streaming Faulted}`. Faithful 1:1 port
  of `printer_connection.ex` (verified by reading): ok-handshake (advance on `ok`,
  re-send current line on `Resend:`/`Error` w/o advancing, one-in-flight, last-ok
  → Idle+StreamComplete); energize-before-jog structural (motion only matches in
  Jogging, all else writes nothing); M112 raw + counter unchanged on Halt; jog
  emits G91/G0/G90 via `frame_all` with `list.reverse` to preserve order.
- `controller.gleam` — thin effectful shell: performs a Step's `writes` in ONE
  `effect.from` (never effect.batch), feeds inbound lines via `Inbound` msg.
- Copied from spike (reused): `protocol.gleam`/`protocol_ffi.mjs`,
  `backend.gleam`, `transport.gleam`, `serial_ffi.mjs`, `sim_ffi.mjs`.

Coordinator validation: copied control/ + its tests (control/protocol/printer)
into an isolated throwaway project (decoupled from the still-in-progress sibling
phases, since `gleam build` compiles the whole package) → clean build + **51/51
tests pass**. Read `printer.gleam` in full and confirmed handshake/gating/abort
match the Elixir source.

Intentional Elixir-matching deviations (documented): stream completes → Idle (not
spike's originating-mode); progress is a sum-type `Event` not PubSub; no settle
timer in the pure core (a hardware concern for the controller layer if needed).

### Note for Phase 4
- Drive the progress RING from the `Progress` event (`sent = idx+1`), NOT the
  `stream_progress/1` inspection helper (which reports `job.idx` = confirmed-so-
  far for a badge). Minor but avoids an off-by-one in the ring.
- Integration shape: host holds a `Controller`, forwards its `Msg` to
  `controller.update`, reacts to the returned `events`. `controller.connect(baud)`
  must be called from a user gesture for the real Web Serial backend.

## Phase 1 — COMPLETE & coordinator-validated (2026-06-19)

Pure domain core at `web/app/src/blau_drill/domain/`: `transform2d`,
`correspondence`, `pending_alignment`, `alignment` (least-squares affine fit +
residuals), `board_model` (Excellon .drl + Edge.Cuts SVG parse, bbox,
absolute-page-coords trap), `config` (GcodeConfig + safe dry-run default),
`gcode_program` (Marlin dry-run/drill, both safety invariants structural), `job`
(FSM as State×Event sum types), + `gcode_ffi.mjs` (Erlang-faithful float
formatting incl. −0.0 collapse). All `{:error, atom}` → typed sum types; nullable
fields → Option; the two Elixir FunctionClauseError tests dropped because the
typed `Alignment` param makes raw-holes unrepresentable (stronger guarantee).

Coordinator validation:
- Isolated build of domain/ + its tests (same Gleam 1.17/JS, same deps) → clean
  build, **100/100 tests pass, zero warnings**.
- Cross-checked the g-code safety invariants against the REAL committed Elixir
  golden files: `segby_v1.drill.gcode` = 130 plunges / **130 travel retracts** /
  5 spindle-on (1/tool) / 6 tool retracts; `segby_v1.dryrun.gcode` = 130 hovers /
  **0 spindle**. The Gleam tests assert exactly these and pass. The embedded test
  `.drl` is a verbatim copy of the real `test/support/fixtures/segby_v1.drl`.
- Confirmed the invariant tests are real & executing: `drill_mode_xy_safe`,
  `every_plunge_preceded_by_m3`, `spindle_rearmed_per_tool`,
  `dry_run_no_armed_spindle`, `dry_run_never_negative_z`, plus property-style
  `invariant1/2_holds_for_random_programs` (invariants hold over random inputs,
  not just the golden).
- Confirmed the Job FSM enforces the linear flow: drilling reachable ONLY via
  `DryRun --ConfirmRegistration--> Drilling`; no `Aligned → Drilling` edge — the
  unsafe shortcut is unrepresentable, matching the Elixir.
- Alignment floats diffed vs freshly-run Elixir `Alignment.fit/1` (overdetermined
  exact recovery to ~9e-16; misfit residuals match) — within 1e-9.

Note: `gcode_program.build` takes `GcodeConfig` explicitly (no default args in
Gleam); pass `config.default()` for the safe dry-run default. Intra-tool hole
ORDER is file-order (Elixir golden uses a TSP order) — the drilled SET is
identical (130); a documented, safe deviation. Only intra-tool travel path
length differs, not which holes are drilled or any safety property.

Whole-package build was (transiently) blocked by Phase 3's in-progress
`ui/board_canvas.gleam` syntax error — both Phase 1 & 2 confirmed this and
validated in isolation. Expected to resolve when Phase 3 lands; domain has no
dependency on control/ or ui/.

## Phase 3 — COMPLETE & coordinator-validated (2026-06-19)

Lustre UI at `web/app/src/blau_drill/ui/` (`model`, `mock`, `board_canvas`,
`canvas_ffi.mjs`, `shell`, `stages`) + entry (`app.gleam`, `blau_drill.gleam`
shim) + `assets/styles.css` (plain CSS, Industrial Dark tokens, no Tailwind).
All 5 stages + settings, the board canvas ported from BoardCanvas.svelte to
Lustre SVG, driven by mock data with documented Phase-4 seams.

### INTEGRATION MILESTONE: whole-package build green
With all three phases on disk, `web/app` builds clean as ONE package and the
**full suite of 151 tests passes** (100 domain + 51 control). The syntax error
that transiently blocked the shared build is resolved.

Coordinator validation (browser, per CLAUDE.md "trust the rendered screen"):
drove the app in Chrome via DevTools MCP —
- Shell renders: brand, 5-node stepper, sidebar Control Panel + stage nav +
  connection card, bottom data bar (X/Y/Z + Bit).
- Loaded the mock board (✓ FILE VALID, 28 holes / 3 tools / 100×86mm) → took a
  full-page screenshot and CONFIRMED WITH MY OWN EYES the whole board is visible
  and letterboxed (substrate fills canvas, dark bands, chamfered outline corner
  in view). `coordinator_stage1_loaded.png`.
- Stage 2 Align: energize-before-jog gate verified LIVE — motors OFFLINE →
  jog/step/spindle/capture all disabled; click ENABLE MOTORS → ONLINE/MOTORS
  LIVE, controls unlock; FIT stays disabled until ≥3 captures, PROCEED until a
  fit (linear preconditions hold).
- E-stop → FAULTED everywhere + red fault banner + RECONNECT + motion re-locked.
  `coordinator_stage2_faulted.png`.
- Zero console errors/warnings across the whole run (a11y-clean: labelled
  inputs, keyboard-operable fiducial buttons with aria-labels).
- Agent's 14 screenshots cover every stage + settings + bit-change modal +
  fault/recovery (`.scratch/.../phase3_*.png`).

### Notes for Phase 4
- UI is `lustre.simple` with a flat mock `Model` + `Msg` vocabulary matching the
  LiveView events. Phase 4 switches to `lustre.application` (for `Effect`s),
  routes motion verbs through `control` + reads real `domain` outputs. Seams
  documented in `model.gleam` moduledoc: board←board_model, head←M114+alignment,
  progress←control Progress events (use sent=idx+1), printer←control state.
- Deferred (Phase 4): drag-pan (zoom works), real residual/fit math (mock always
  98%), Material Symbol brand glyph (currently emoji). All cosmetic/non-blocking.

## Phase 4 — COMPLETE & coordinator-validated (2026-06-19)

Integration done: the UI's mock data is fully replaced by the real domain +
control layers; localStorage persistence + static build produced. New files under
`web/app/src/blau_drill/ui/`: `file_ffi.mjs` (file picker), `storage_ffi.mjs` +
`storage.gleam` (config persistence), `sample.gleam` (built-in segby_v1 board),
`bridge.gleam` (domain/control↔UI translation). `app.gleam` rewritten
`lustre.simple`→`lustre.application`. + `integration_test.gleam` (4 tests incl.
full parse→fit→build→stream-through-sim → StreamComplete).

Coordinator validation: built clean, **155/155 tests pass** (151 + 4). Then drove
the COMPLETE Load→Done flow myself in Chrome against the simulator (real domain +
control, not mocks):
- Loaded the built-in segby_v1 sample → real `board_model.parse`: **130 holes, 5
  tools (0.6–1.2mm), 81.28×83.82mm** (genuine fixture values).
- Connect (sim) → CONNECTED. Energize → MOTORS LIVE; **jog X+ → bottom bar reads
  X:1.0** — the full real serial round-trip (UI→controller→framed G-code→sim→
  M114→parsed position→live readout).
- Captured 3 fiducials at distinct jogged positions; confidence progressed
  None→Rough(2)→**ALIGNED**; `alignment.fit` → **100% GOOD, residual 0.0** (clean
  similarity recovered exactly, as Phase 1's exact-recovery test predicted).
- Dry-run streamed real gcode through the sim ok-handshake → **Traced 130/130**.
- Confirm→Drill: **SPINDLE ON · 200/255 PWM** (drill-mode gating), bit-change
  pause modal "Swap to 0.7mm" → Resume → **130/130 100%** → Completion (130
  holes / 3:15 / 4 bit changes), board shows holes drilled green.
- Gates real on live data: jog disabled until energize; FIT needs ≥3 captures;
  PROCEED needs a GOOD fit; drill only via dry-run→confirm. Zero console errors.
- Evidence: `coordinator_drill_bitchange.png`, `coordinator_done.png` + agent's
  `phase4_01..11_*.png` (incl. fault/reconnect).

Static build → `web/app/dist/` (index.html + blau_drill.js ~380KB w/ all FFI
inlined + styles.css), self-contained, served & verified.

Intentional Elixir-matching deviations (documented): pre-fit click-to-jump mirrors
`board_to_machine` (translation@1 / similarity@2+); one representative M0
bit-change pause for multi-tool (not per-boundary); jog issues move then M114 on
next microtask (not effect.batch). Real Web Serial hardware path compiles + is
wired but unverifiable headlessly (needs USB Marlin + user gesture) — the sim
exercises the whole flow.

### Phase 5 carry-over
- `dist/index.html` uses ABSOLUTE asset paths (`/styles.css`, `/blau_drill.js`)
  — works from a static-server root but NOT a bare `file://` open. Since "open a
  local file" is part of the goal, Phase 5 should make these paths relative (or
  document the localhost-serve requirement).
- Deferred (non-blocking): canvas drag-pan (zoom works), Material Symbol brand
  glyph (emoji placeholder).

## Open questions / risks

- **Web Serial write backpressure & flow control** for streaming long G-code
  programs (Marlin "ok" handshaking) — must replicate the backend's line-by-line
  ack flow. Spike should touch this.
- **Reconnect / port loss** mid-job handling (USB unplug) — abort semantics.
- **Gleam domain port fidelity** for floating-point alignment math — diff
  against Elixir outputs on the same fixtures.
- **Real-hardware verification** can't be done by an agent — requires the
  operator with the physical machine for Phases 0/4.
