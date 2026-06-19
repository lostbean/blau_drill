// Real Web Serial transport. This is the riskiest path the Phase-0 spike proved:
// a pure-browser app driving a Marlin port directly over USB, no server.
//
// Connection lifecycle:
//   requestAndOpen(baud)  -> { port, writer } behind one user gesture
//   write(conn, line)     -> encode + writer.write
//   startReading(conn, onLine, onError) -> read loop, buffers into '\n' lines
//   close(conn)           -> release + close
//
// Gleam Result is represented by importing the generated Ok/Error constructors
// from the compiled stdlib so the externals can hand back a real `Result`.

import { Ok, Error } from "../../gleam.mjs";

export function hasSerial() {
  // Check truthiness, not just presence: a browser may expose `serial` as
  // undefined, and `requestPort` is only callable on a real SerialPort manager.
  return (
    typeof navigator !== "undefined" &&
    !!navigator.serial &&
    typeof navigator.serial.requestPort === "function"
  );
}

// Open behind a user gesture. Returns Promise(Result(conn, String)).
export async function requestAndOpen(baud) {
  if (!hasSerial()) {
    return new Error("Web Serial unavailable (use Chrome/Edge over HTTPS or localhost)");
  }
  try {
    const port = await navigator.serial.requestPort();
    await port.open({ baudRate: baud, dataBits: 8, stopBits: 1, parity: "none" });
    const encoder = new TextEncoder();
    const conn = { port, encoder, reader: null, closed: false };
    return new Ok(conn);
  } catch (e) {
    // AbortError = user dismissed the picker; surface everything as a string.
    return new Error(String(e && e.message ? e.message : e));
  }
}

// Open a PREVIOUSLY-AUTHORIZED port without a picker. `navigator.serial.getPorts()`
// returns only ports the user has already granted (in this or a past session),
// so this needs no user gesture. Used for auto-reconnect on load. Returns
// Promise(Result(conn, String)); Error("no granted port") when none is available.
export async function openExisting(baud) {
  if (!hasSerial() || typeof navigator.serial.getPorts !== "function") {
    return new Error("Web Serial unavailable");
  }
  try {
    const ports = await navigator.serial.getPorts();
    if (!ports || ports.length === 0) {
      return new Error("no granted port");
    }
    const port = ports[0];
    await port.open({ baudRate: baud, dataBits: 8, stopBits: 1, parity: "none" });
    const encoder = new TextEncoder();
    const conn = { port, encoder, reader: null, closed: false };
    return new Ok(conn);
  } catch (e) {
    return new Error(String(e && e.message ? e.message : e));
  }
}

export async function write(conn, line) {
  try {
    if (!conn.port || !conn.port.writable) {
      return new Error("port not writable");
    }
    const writer = conn.port.writable.getWriter();
    try {
      await writer.write(conn.encoder.encode(line));
    } finally {
      writer.releaseLock();
    }
    return new Ok(undefined);
  } catch (e) {
    return new Error(String(e && e.message ? e.message : e));
  }
}

// Start the inbound read loop. Marlin replies are newline-terminated; we buffer
// partial chunks and emit one onLine(line) per complete '\n'-delimited line.
export function startReading(conn, onLine, onError) {
  (async () => {
    const decoder = new TextDecoder();
    let buffer = "";
    try {
      while (conn.port && conn.port.readable && !conn.closed) {
        const reader = conn.port.readable.getReader();
        conn.reader = reader;
        try {
          while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            let idx;
            while ((idx = buffer.indexOf("\n")) >= 0) {
              const line = buffer.slice(0, idx).replace(/\r$/, "");
              buffer = buffer.slice(idx + 1);
              if (line.length > 0) onLine(line);
            }
          }
        } catch (e) {
          if (!conn.closed) onError(String(e && e.message ? e.message : e));
          break;
        } finally {
          try { reader.releaseLock(); } catch (_) {}
          conn.reader = null;
        }
      }
    } catch (e) {
      if (!conn.closed) onError(String(e && e.message ? e.message : e));
    }
  })();
}

export async function close(conn) {
  conn.closed = true;
  try { if (conn.reader) await conn.reader.cancel(); } catch (_) {}
  try { if (conn.port) await conn.port.close(); } catch (_) {}
  return undefined;
}
