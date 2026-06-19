# 5. The app owns the live serial link to Marlin

- **Status:** Accepted
- **Date:** 2026-06-18

## Context

Driving the printer requires a two-way, stateful serial conversation with Marlin:
jog the head, read live position with `M114`, and stream a program with the
`ok`/`resend` handshake (line numbers, checksums, flow control). The old
workflow delegated this to **OctoPrint** as a general print host and uploaded
`.gcode` files to it. But blau-drill's alignment loop is *interactive* — it jogs
and captures `M114` in real time and overlays the live head position on the board
canvas — which a file-upload print host does not serve well.

## Decision

The app **owns a live serial link** to Marlin directly, in the browser, over the
**Web Serial API** (`navigator.serial`), for the duration of a drilling session.
The control layer (`src/blau_drill/control/`) is the system's **single stateful
identity**; everything else is an immutable value. It hides the entire Marlin
protocol behind a small set of verbs — `Energize`/`Release`, `Jog`, `MoveTo`,
`Where` (M114), `Stream` (ok-handshake inside), `Halt` (M112-class abort),
`Reconnect` — and exposes a mode of `Disconnected | Idle | Jogging | Streaming |
Faulted`. A `Backend` seam lets the same logic run against the real Web Serial
port or an in-browser simulator. This is explicitly **not** an OctoPrint
replacement: it claims the port only for the session.

## Consequences

- The interactive alignment loop (jog → capture → fit → re-jog) is first-class
  and low-latency; live head position drives the canvas overlay.
- All reliability concerns (line numbering, checksums, resend) are encapsulated
  in one deep module — callers and the `Job` FSM stay readable and never
  re-implement the handshake. Exposing a raw `write(line)` to the UI was rejected
  for exactly this reason.
- A serial disconnect mid-stream transitions the control machine to `Faulted`,
  halts the stream, and surfaces in the UI; `Reconnect` recovers cleanly to
  `Idle`. The failure is explicit and recoverable, not a silent stall.
- **Trade-off 1:** the app must hold the port exclusively, so it cannot share the
  printer with another host during a session. Acceptable — it is a single-bench,
  single-operator instrument. **Reconsider if** the printer must serve other jobs
  concurrently, which contradicts the single-session premise.
- **Trade-off 2:** Web Serial is **Chromium-only** and needs a secure context
  (HTTPS / localhost / file://) plus a user-gesture connect. Accepted: the bench
  operator runs a Chromium browser, which removes the install entirely.
