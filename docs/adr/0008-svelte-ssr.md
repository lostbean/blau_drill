# 8. LiveSvelte SSR with explicit imports and a RenderOutput flatten

- **Status:** Accepted
- **Date:** 2026-06-18

## Context

The Svelte components (`Hello`, `BoardCanvas`) are bundled by `assets/build.js`
into two targets: a client bundle (`priv/static/assets/js/app.js`, svelte
`generate: "client"`) that hydrates via LiveSvelte's `SvelteHook`, and an SSR
bundle (`priv/svelte/server.js`, svelte `generate: "server"`) that the NodeJS
pool invokes via `{"server", "render"}` for the initial dead render. The pool is
started conditionally in `application.ex` only when `ssr: true` and the bundle
exists.

SSR was configured **off** because `render("BoardCanvas", …)` came back to Elixir
as `{}` instead of HTML, so `@ssr_render["html"]` was `nil` and no server markup
was emitted. The scaffold blamed `esbuild-plugin-import-glob` /
`normalizeComponents`, but that was a misdiagnosis.

### Actual root cause

The component registry was fine — both the glob output and `normalizeComponents`
mapped `"BoardCanvas"`/`"Hello"` to the right components. The failure is in the
**return shape of Svelte 5's server `render()`**.

Under Svelte 5 (here 5.56), `render()` from `svelte/server` returns a
`RenderOutput` whose `head` / `html` / `body` are **non-enumerable getters**
(see `svelte/src/internal/server/renderer.js` — the props are defined via
`Object.defineProperties` without `enumerable: true`, deliberately, "so that
console.logging doesn't trigger a sync render"). LiveSvelte 0.15's
`getRender` (`deps/live_svelte/.../render.js`) returns that object verbatim. When
LiveSvelte's NodeJS bridge (`LiveSvelte.SSR.NodeJS`) JSON-serialises it to hand
back to Elixir, **non-enumerable properties are dropped**, so Elixir receives
`{}`. The markup was always being produced — it just never survived the
JSON round-trip.

## Decision

Two changes, both confined to `assets/**` and config:

1. **Flatten the RenderOutput in the SSR entry.** `assets/js/server.js` wraps
   LiveSvelte's `getRender` and copies the getters into a plain object —
   `{head: out.head, html: out.html}` — before returning, so the keys are
   enumerable and survive JSON serialisation across the bridge. These are exactly
   the two keys `deps/live_svelte/lib/component.ex` reads.

2. **Register components explicitly instead of via import-glob.** Both
   `assets/js/app.js` (client) and `assets/js/server.js` (SSR) now do
   `import Hello from "../svelte/Hello.svelte"` / `import BoardCanvas …` and build
   a `{Hello, BoardCanvas}` map. For a two-component app this is as terse as a
   glob, keeps the client and SSR registries provably in sync, and removes
   `esbuild-plugin-import-glob` (and its glob-resolution + `normalizeComponents`
   shape contract) as a moving part. `normalizeComponents` passes a plain map
   through untouched, so both `getHooks` (client) and `getRender` (SSR) keep
   working. The plugin and its dependency were dropped from `build.js` and
   `package.json`.

With these, `LiveSvelte.SSR.render("BoardCanvas", props, %{})` returns
`%{"head" => …, "html" => …}` with real `board-canvas` SVG markup, and
`config :live_svelte, ssr: true` is enabled for the default/dev config. The dead
render now carries server-rendered markup inside the `phx-hook="SvelteHook"` div,
and the client hydrates it (the hook branches on the `data-ssr` attribute:
`hydrate` when present, `mount` otherwise).

## Consequences

- SSR is **on** for the default and dev configs. Test config keeps `ssr: false`
  (no Node process in the unit suite). Production keeps `ssr: false` by an
  independent, deliberate choice (single-operator loopback app; a Node sidecar is
  not worth it for first paint) — flip it there if server-rendered first paint is
  wanted and the SSR build is deployed.
- The `<.svelte name="…" />` call sites are unchanged.
- **Maintenance:** new components must be added to the explicit map in *both*
  `app.js` and `server.js`. A component missing from `server.js` SSR-renders as
  nothing (and `getRender` would throw on an unknown name); missing from `app.js`
  fails to hydrate. The two short lists are the price of dropping the glob.
- **Trade-off / reconsider if:** the component count grows large enough that the
  manual lists become error-prone, reintroduce a glob — but keep the
  RenderOutput flatten regardless, since that is the real SSR fix and is
  independent of how components are registered. LiveSvelte ≥0.16 moved its
  pipeline to Vite/`phoenix_vite`; a future toolchain bump there would replace
  this esbuild setup wholesale and likely fold the flatten upstream.
