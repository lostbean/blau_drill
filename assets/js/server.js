// SSR entry for LiveSvelte. Built by build.js into priv/svelte/server.js and
// invoked by the NodeJS pool via {"server", "render"} (see application.ex and
// LiveSvelte.SSR.NodeJS). The Elixir side reads the `"head"` and `"html"` keys
// off the JSON result (deps/live_svelte/lib/component.ex).
//
// Components are imported explicitly (rather than via an import-glob) so the SSR
// bundle registers them in a stable, debuggable shape — `{BoardCanvas}`, keyed
// by the same name used at the `<.svelte name="..." />` call sites. An explicit
// map removes a moving part from the SSR pipeline.
import BoardCanvas from "../svelte/BoardCanvas.svelte"
import {getRender} from "live_svelte"

const components = {BoardCanvas}

const baseRender = getRender(components)

// Svelte 5 (≥5.x) returns a RenderOutput whose `head`/`html`/`body` are
// NON-ENUMERABLE getters (svelte/src/internal/server/renderer.js: the props are
// defined without `enumerable: true` "so that console.logging doesn't trigger a
// sync render"). When LiveSvelte's NodeJS bridge serialises that object to JSON
// to hand back to Elixir, non-enumerable props are dropped — so `render(...)`
// arrives in Elixir as `{}` and `@ssr_render["html"]` is nil (no SSR markup).
//
// LiveSvelte 0.15's getRender returns that RenderOutput verbatim, so we flatten
// it here into a plain object with enumerable `head`/`html` keys (exactly the
// keys component.ex reads) before it crosses the bridge. Accessing the getters
// performs the actual (synchronous) render.
export function render(name, props, slots) {
  const out = baseRender(name, props, slots)
  return {
    head: out.head,
    html: out.html,
  }
}
