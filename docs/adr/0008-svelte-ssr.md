# 8. (Superseded) Server-side rendering of the board canvas

- **Status:** Superseded by the move to a pure-browser Gleam/Lustre app
- **Date:** 2026-06-18 (superseded 2026-06-19)

## Note

This ADR recorded a server-side-rendering decision for the board-canvas component
in the original server-rendered architecture. That architecture has been replaced
by a **pure-browser application** (Gleam compiled to JavaScript via Lustre, with
no backend server — see [ADR-0005](0005-app-owns-live-serial-link.md) and
[`../../CONTEXT.md`](../../CONTEXT.md)).

There is no server, so there is no server-side rendering: the app is a static
bundle that mounts and renders entirely in the browser, and the board canvas is a
Lustre SVG view (`src/blau_drill/ui/board_canvas.gleam`). The original decision
no longer applies and is retained only as history.
