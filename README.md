# blau-drill (pure-browser app)

**blau-drill** controls a modified 3D printer for precision **PCB drilling** via a
strictly linear five-stage workflow — **Load & Connect → Physical Alignment →
Dry-run → Active Drilling → Completion** — with safety gates that lock motion and
drilling behind explicit toggles.

This is the **pure-browser rewrite**: a [Lustre](https://lustre.build) SPA
compiled from **Gleam → JavaScript** that talks to the printer **directly over
the Web Serial API**. There is **no backend server** and no install — the
operator just opens a URL (or serves the static build) in Chrome/Edge. It was
migrated from an Elixir/Phoenix-LiveView app (preserved in git history); the
domain logic and safety invariants were ported 1:1.

## Architecture (three layers)

- **`src/blau_drill/domain/`** — pure domain: `board_model` (`.drl` + Edge.Cuts
  parse), `alignment` (least-squares fit), `gcode_program` (Marlin generation +
  safety invariants), `job` (the session FSM), `transform2d`, `config`,
  `correspondence`, `pending_alignment`.
- **`src/blau_drill/control/`** — the serial control state machine:
  `controller` (effectful shell), `printer` (pure core), `transport`
  (`web_serial()` and `simulator()` backends), `protocol` (Marlin framing).
- **`src/blau_drill/ui/`** — the Lustre views (`shell`, `stages`,
  `board_canvas`), the flat `model` (model + `Msg`), the `bridge`
  (domain/control ↔ UI translation), `storage` (localStorage persistence),
  `sample` (a built-in board), and the FFI shims (`*_ffi.mjs`).
- **`src/blau_drill/app.gleam`** — the orchestrator (`lustre.application`): wires
  the UI `Msg` vocabulary onto controller commands + domain calls, threading
  effects, and bridges controller events back into the update loop.

## Hard requirements

- **Chromium-only browser**: Chrome / Edge / Opera **89+** (Web Serial is not in
  Firefox or Safari). The simulator path works in any modern browser; only the
  real-hardware path needs Web Serial.
- **Secure context**: Web Serial is only available over **HTTPS**, **localhost**,
  or a **`file://`** page. (The dev server and a localhost static server both
  qualify.)
- **User gesture to connect**: `navigator.serial.requestPort()` must be called
  from a user gesture, so connecting to a real device only works from the
  **Connect** button click (it cannot be auto-connected).

## Develop

Gleam lives in the Nix dev shell. Enter it (or let direnv load it):

```sh
nix develop          # from the repo root
cd web/app
```

Then, inside the shell:

```sh
gleam build          # compile (JS target)
gleam test           # run the test suite (domain + control + integration)
gleam run -m lustre/dev start   # watch + serve on http://localhost:1234
```

> The dev server does **not** hot-rebuild hand-written `.mjs` FFI files. After
> editing a `*_ffi.mjs`, rebuild and **hard-reload** (ES modules cache
> aggressively).

## Build (static, self-contained)

```sh
gleam run -m lustre/dev build
```

This emits three self-contained files into **`web/app/dist/`**:

- `index.html`
- `blau_drill.js` (the whole app + all FFI, ~380 KB)
- `styles.css`

Serve the `dist/` directory from **any static host** (or a local static server):

```sh
cd dist && python3 -m http.server 8000   # then open http://localhost:8000
```

> **Opening directly via `file://`**: the generated `index.html` references
> `/blau_drill.js` and `/styles.css` with **absolute** paths, which resolve to
> the filesystem root under `file://`. To open the build as a local file, either
> serve `dist/` over `http://localhost` (recommended), or rewrite those two
> `href`/`src` paths to be relative (`./blau_drill.js`, `./styles.css`). Web
> Serial itself is available under `file://`.

## Running against the simulator vs real hardware

The transport is chosen in the sidebar **Connection** card:

- **Simulator** (default) — an in-browser Marlin stand-in (`sim_ffi.mjs`). It
  connects instantly, acks streamed lines incrementally so progress animates, and
  answers `M114` with its integrated position. The **entire flow runs with no
  hardware** — load a board, connect, align, dry-run, drill, complete.
- **Web Serial (CNC)** — the real port (`serial_ffi.mjs`). Selecting it and
  clicking **Connect** opens `navigator.serial.requestPort()` (the browser shows
  its device picker). Requires a Chromium browser + a secure context + the user
  gesture above.

A built-in **"Load sample board (segby_v1)"** button on Stage 1 parses the
bundled sample so you can drive the flow without a file dialog. The real **file
pickers** (the dropzone for `.drl`, and the optional Edge.Cuts `.svg` row) open a
native file dialog and read the chosen file as text.

## Persistence (localStorage)

The operator **Config** (the settings screen) and the **selected backend** are
persisted to `localStorage` and restored on load:

- `blau_drill.config` — all settings fields (port, baud, motion limits, spindle
  G-code commands, PWM, and the generator tunables: zdrill/zsafe/zchange/feed/
  hover). Saved when you click **Apply Configuration**. Restored at startup,
  falling back to safe defaults for any missing field.
- `blau_drill.backend` — `sim` or `real`, saved when you change the device
  picker.

On a run, the generator tunables are coerced + validated into a
`domain/config.GcodeConfig` and applied as an **immutable snapshot** (taken when
alignment begins / on Apply), mirroring the Elixir's mount-time snapshot — so
mid-run settings edits never change the program being streamed. Machine-specific
fields (port, baud, motion limits, spindle G-code, PWM) are operator/hardware
settings, never hardcoded product defaults.

## Safety gates (enforced end-to-end)

- **Energize-before-jog** — jog/move/spindle do nothing until motors are
  energized; the pure control core refuses motion outside `Jogging` and writes
  nothing.
- **Retract-before-XY** and **spindle-before-plunge** — structural invariants in
  `gcode_program`; the app streams its output **unmodified**.
- **Linear flow** — drilling is reachable only via dry-run → confirm (the `job`
  FSM has no Aligned → Drilling edge); the e-stop/abort is reachable from every
  motion stage; a fault is loud (banner) with an explicit reconnect.
- **M112 abort** — always reachable during streaming.
