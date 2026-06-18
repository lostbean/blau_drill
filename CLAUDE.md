# blau_drill

**blau-drill** is a single-operator desktop application that controls a modified
3D printer for precision **PCB drilling**. It translates digital circuit designs
(Gerber `.gbr` / Excellon `.drl`) into physical machine movements, guiding the
operator through a safe, strictly linear five-stage workflow: **Load & Connect →
Physical Alignment → Dry-run → Active Drilling → Completion**. Safety gates lock
critical actions (motor jogging, drilling) behind explicit toggles, and the UI
targets an industrial bench environment (high-contrast dark theme, monospaced
data readouts, high visibility from a distance).

This is an **Elixir** project (`mix` build). It is currently an early scaffold —
the implementation lives under `lib/` and the design intent is captured in
`docs/`. See [`docs/design_reference/blau_drill_project_brief.md`](docs/design_reference/blau_drill_project_brief.md)
for the full product brief and `docs/design_reference/` for per-stage UI mockups.

> The code is at an early stage; this overview reflects the *intended* product.
> Update it as the implementation takes shape.

## Repository layout

- `lib/` — application source (`blau_drill.ex` is the current entry module).
- `test/` — ExUnit tests.
- `docs/` — architecture notes and the design reference (project brief, per-stage
  screen mockups and HTML, design system spec).
- `mix.exs` — project manifest. Targets **Elixir `~> 1.20`**.

## Tooling

This repo uses a Nix-native dev setup. The toolchain is **Erlang/OTP 28** with
**Elixir 1.20**, pinned in `flake.nix` (built from the `nixos-26.05` channel via
`beam.packages.erlang_28`).

- **Dev shell** — run `nix develop` to enter a shell with Erlang, Elixir,
  ElixirLS, and lefthook, or let direnv load it automatically (`direnv allow`
  once). The shell keeps Mix/Hex state project-local under `.mix/` and `.hex/`.
- **Build / test** — standard Mix from inside the dev shell: `mix deps.get`,
  `mix compile`, `mix test`.
- **Formatting** — `nix fmt` formats the whole repo via treefmt: Elixir through
  `mix format` (using `.formatter.exs`) and Nix through `nixfmt`. `nix flake
  check` verifies everything is formatted.
- **Commit gate** — a lefthook `pre-commit` hook runs `nix fmt` on staged files
  and re-stages them, so commits are always formatted. Install hooks once with
  `lefthook install`. If a commit reformats files, it still succeeds — the
  formatted result is what gets committed.

## Conventions

### Do

- Run code through `nix fmt` (or let the pre-commit hook do it) before pushing.
- Keep Erlang/Elixir versions in sync between `flake.nix` and `mix.exs`'s
  `elixir:` requirement when bumping the toolchain.
- Preserve the **safety-gate model**: actions that move the machine (jogging,
  drilling, spindle) must stay behind explicit enable gates — never auto-enable
  motion.
- Treat the five-stage flow as **linear**: a stage's preconditions must hold
  before advancing.
- **Verify UI/layout changes in a real browser viewport, not by inspecting
  rendered output.** A correct-looking attribute (e.g. an SSR'd SVG `viewBox`)
  is not proof the user sees the right thing — layout, overflow, and fit bugs
  only surface when the page is actually rendered at size. For the board canvas
  specifically, take a full-page screenshot (the Svelte SVG lives in a shadow
  DOM, so `document.querySelector` can't reach it) and confirm the whole board
  is visible. Trust what's on screen over what the markup says.

### Don't

- **Do not add trailers, attribution, `Co-Authored-By`, or `Generated with`
  footers to commit messages.**
- Don't commit machine-specific configuration (motion limits, spindle G-code,
  serial port) as hardcoded defaults — these are operator/hardware settings.
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
