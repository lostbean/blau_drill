// In-browser Marlin SIMULATOR — the "other end of the wire" so the spike works
// with NO hardware. Ported 1:1 from `lib/blau_drill/printer_connection/uart/sim.ex`.
//
// Behaviour replicated exactly:
//   * keeps a simulated head position (x,y,z, start 0,0,0) and a G90/G91
//     absolute/relative flag (start absolute);
//   * on each written line: G91 -> relative, G90 -> absolute, G0/G1 -> integrate
//     motion (G-words matched as tokens so G0/G1 don't match G04/G90/G91);
//   * M114 -> emit the position line then `ok` immediately;
//   * any other line -> emit one `ok` scheduled ~10ms ahead so a streamed
//     program acks incrementally and progress animates. One ack per line.

import { Ok } from "./gleam.mjs";

const ACK_DELAY_MS = 10;

export function makeConn() {
  return { x: 0, y: 0, z: 0, abs: true, onLine: null, ackDelay: ACK_DELAY_MS };
}

// Sim "connects" instantly. Async to share the Backend.open signature.
export async function open(_baud) {
  return new Ok(makeConn());
}

export function startReading(conn, onLine, _onError) {
  conn.onLine = onLine;
}

// Match a G-word as a token: G0/G1 must not match G04/G90, G91 not G91.1.
// Mirrors the Elixir `(?:^|\s)WORD(?![.\d])` regexp; framed lines arrive as
// `N<n> G0 X..*<cs>`, so the word is matched anywhere in the line.
function containsWord(line, word) {
  const re = new RegExp("(?:^|\\s)" + word + "(?![.\\d])");
  return re.test(line);
}

function axisValue(line, axis) {
  const m = line.match(new RegExp(axis + "(-?\\d+(?:\\.\\d+)?)"));
  return m ? parseFloat(m[1]) : null;
}

function applyMove(conn, line) {
  if (containsWord(line, "G91")) {
    conn.abs = false;
  } else if (containsWord(line, "G90")) {
    conn.abs = true;
  } else if (containsWord(line, "G0") || containsWord(line, "G1")) {
    const dx = axisValue(line, "X");
    const dy = axisValue(line, "Y");
    const dz = axisValue(line, "Z");
    if (conn.abs) {
      if (dx !== null) conn.x = dx;
      if (dy !== null) conn.y = dy;
      if (dz !== null) conn.z = dz;
    } else {
      conn.x += dx || 0;
      conn.y += dy || 0;
      conn.z += dz || 0;
    }
  }
}

function positionLine(conn) {
  const f = (v) => (v * 1.0).toFixed(2);
  return `X:${f(conn.x)} Y:${f(conn.y)} Z:${f(conn.z)} E:0.00 Count X:0 Y:0 Z:0`;
}

function emit(conn, line) {
  if (conn.onLine) conn.onLine(line);
}

// Write one (already-framed) line. Returns Promise(Result(Nil, String)).
export async function write(conn, raw) {
  const line = String(raw).trim();
  applyMove(conn, line);

  if (line.includes("M114")) {
    // M114 is answered immediately: position line then `ok`.
    emit(conn, positionLine(conn));
    emit(conn, "ok");
  } else {
    // Every other line acks ~10ms ahead so a long stream animates.
    setTimeout(() => emit(conn, "ok"), conn.ackDelay);
  }
  return new Ok(undefined);
}

export async function close(_conn) {
  return undefined;
}
