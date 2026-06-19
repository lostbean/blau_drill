# blau_drill

**blau-drill** is a single-operator application that controls a modified 3D
printer for precision **PCB drilling**. It translates digital circuit designs
(Excellon `.drl`, optional KiCad Edge.Cuts outline) into physical machine
movements, guiding the operator through a safe, strictly linear five-stage
workflow: **Load & Connect → Physical Alignment → Dry-run → Active Drilling →
Completion**. Safety gates lock critical actions (motor jogging, drilling) behind
explicit toggles, and the UI targets an industrial bench environment
(high-contrast dark theme, monospaced data readouts, high visibility from a
distance).

This is a **pure-browser Gleam application**: Gleam compiled to JavaScript via
the **Lustre** framework, with **no backend server and no install**. The operator
opens it in a Chromium browser and it talks to the printer **directly over the
Web Serial API**. See
[`docs/design_reference/blau_drill_project_brief.md`](docs/design_reference/blau_drill_project_brief.md)
for the product brief, `docs/design_reference/` for per-stage UI mockups, and
[`CONTEXT.md`](CONTEXT.md) for the domain glossary + invariants.

> **History:** blau-drill was migrated from an Elixir/Phoenix-LiveView server app
> to this pure-browser Gleam/Lustre app (see
> `.scratch/gleam-pure-web-migration/PRD.md`). The domain logic and safety
> invariants were ported 1:1; the prior Elixir implementation remains in git
> history.

## Hard runtime requirements (Web Serial)

- **Chromium only** — Chrome / Edge / Opera 89+. Firefox and Safari do not
  implement Web Serial and are unsupported.
- **Secure context** — the app must be served over **HTTPS**, `localhost`, or
  `file://`. Plain `http://` LAN addresses will not get serial access.
- **User gesture to connect** — `navigator.serial.requestPort()` must be called
  from a click (the Stage-1 Connect button). A `simulator` backend works with no
  hardware for development.

## Repository layout

- `src/blau_drill/` — application source, by layer:
  - `domain/` — pure core (board_model, alignment, gcode_program, job FSM,
    transform2d, config, correspondence, pending_alignment). No IO.
  - `control/` — serial control state machine (`printer.gleam` pure transitions,
    `controller.gleam` effects) over a Web-Serial / simulator `Backend` seam.
  - `ui/` — Lustre views (shell, stages, board_canvas) + the model + FFI.
  - `app.gleam` — the `lustre.application` entry wiring domain + control + UI.
- `test/` — gleeunit tests (mirrors `src/blau_drill/`).
- `assets/styles.css` — the Industrial Dark stylesheet (plain CSS).
- `docs/` — design reference (brief, per-stage mockups, design system) + ADRs.
- `gleam.toml` — project manifest. Targets the **JavaScript** backend.

## Tooling

Nix-native dev setup. The toolchain is **Gleam 1.17** on **Node**, pinned in
`flake.nix` (from the `nixos-26.05` channel).

- **Dev shell** — `nix develop` (or direnv: `direnv allow` once) gives Gleam,
  Node, rebar3, and lefthook. `rebar3` is required because `lustre_dev_tools`
  compiles Erlang-target deps for its watch server.
- **Build / test** — from inside the dev shell: `gleam deps download`,
  `gleam build`, `gleam test`.
- **Run (dev)** — `gleam run -m lustre/dev start` serves a watch server on
  http://localhost:1234. **Note:** it does NOT hot-rebuild hand-written `.mjs`
  FFI files — after editing a `.mjs`, rebuild and hard-reload.
- **Static build** — `gleam run -m lustre/dev build` emits self-contained static
  files to `dist/` (HTML/JS/CSS) for any static host.
- **Formatting** — `nix fmt` formats the repo via treefmt: Gleam through
  `gleam format`, Nix through `nixfmt`. `nix flake check` verifies formatting.
- **Commit gate** — a lefthook `pre-commit` hook runs `nix fmt` on staged files
  and re-stages them. Install once with `lefthook install`.

## Conventions

### Do

- Run code through `nix fmt` (or let the pre-commit hook do it) before pushing.
- Keep the Gleam version in sync between `flake.nix` and any tooling when bumping.
- Preserve the **safety-gate model**: actions that move the machine (jogging,
  drilling, spindle) must stay behind explicit enable gates — never auto-enable
  motion. Model gates with sum types so illegal states are unrepresentable.
- Treat the five-stage flow as **linear**: a stage's preconditions must hold
  before advancing (the `job` FSM enforces this — no `Aligned → Drilling` edge).
- Keep order-dependent multi-line serial writes in ONE effect — **never**
  `effect.batch` (it reverses synchronous order and corrupts `G91`/`G0`/`G90`).
- **Verify UI/layout changes in a real browser viewport, not by inspecting
  rendered output.** A correct-looking attribute (e.g. an SVG `viewBox`) is not
  proof the user sees the right thing — layout, overflow, and fit bugs only
  surface when the page is rendered at size. For the board canvas specifically,
  take a full-page screenshot and confirm the whole board is visible. Trust
  what's on screen over what the markup says.

### Don't

- **Do not add trailers, attribution, `Co-Authored-By`, or `Generated with`
  footers to commit messages.**
- Don't commit machine-specific configuration (motion limits, spindle G-code,
  serial port) as hardcoded product defaults — these are operator/hardware
  settings, persisted per-operator in `localStorage`.
- Don't introduce paths that stream G-code or enable motors without the
  corresponding safety gate and an abort/emergency-stop affordance.

## Agent skills

### Issue tracker

Issues and PRDs live as markdown files under `.scratch/<feature>/` in this repo
(no remote tracker). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `wontfix`), recorded as a `Status:` line per issue file. See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See
`docs/agents/domain.md`.
