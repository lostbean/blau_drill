// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {getHooks} from "live_svelte"
// Svelte components are imported explicitly and registered as LiveView hooks.
// The map keys are the names used at the `<.svelte name="..." />` call sites and
// must match the registry in js/server.js (the SSR entry). An explicit map is
// preferred over an import-glob: for a small component set it is just as terse,
// keeps the client and SSR registries provably in sync, and removes the
// import-glob plugin as a moving part from the build.
import BoardCanvas from "../svelte/BoardCanvas.svelte"

const components = {BoardCanvas}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: getHooks(components),
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#ffb300"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client. Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => (keyDown = e.key))
    window.addEventListener("keyup", _e => (keyDown = null))
    window.addEventListener(
      "click",
      e => {
        if (keyDown === "c") {
          e.preventDefault()
          e.stopImmediatePropagation()
          reloader.openEditorAtCaller(e.target)
        } else if (keyDown === "d") {
          e.preventDefault()
          e.stopImmediatePropagation()
          reloader.openEditorAtDef(e.target)
        }
      },
      true
    )

    window.liveReloader = reloader
  })
}
