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

The app **owns a live serial link** to Marlin directly (via `circuits_uart`) for
the duration of a drilling session. `PrinterConnection` is a supervised
GenServer and the system's **single stateful identity**; everything else is an
immutable value. It hides the entire Marlin protocol behind four verbs —
`jog/2`, `where/1` (M114), `stream/2` (ok-handshake inside), `halt/1`
(M112-class abort) — and exposes a mode of `:idle | :jogging | :streaming |
:faulted`. This is explicitly **not** an OctoPrint replacement: it claims the
port only for the session.

## Consequences

- The interactive alignment loop (jog → capture → fit → re-jog) is first-class
  and low-latency; live head position drives the canvas overlay.
- All reliability concerns (line numbering, checksums, resend) are encapsulated
  in one deep module — callers and the `Job` FSM stay readable and never
  re-implement the handshake. Exposing a raw `send_gcode(line)` to LiveView was
  rejected for exactly this reason.
- A serial disconnect mid-stream transitions `PrinterConnection` to `:faulted`,
  halts the stream, and surfaces in the UI; the supervisor restarts cleanly to
  `:idle`. The failure is local and supervised, not a silent stall.
- **Trade-off:** the app must hold the port exclusively, so it cannot share the
  printer with another host during a session. Acceptable — it is a single-bench,
  single-operator instrument. **Reconsider if** the printer must serve other jobs
  concurrently, which contradicts the single-session premise.
