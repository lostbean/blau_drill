// Test-only fake transport that ENFORCES the WritableStream single-writer rule,
// so a unit test can catch the concurrent-write bug that disconnected the real
// port on the first jog (G91/G0/G90 burst). A real WritableStream throws if a
// second writer is acquired while one is active; this fake mimics that: while a
// write's promise is pending, the stream is "locked" and any overlapping write
// resolves to Error("stream is locked"). Writes that are properly serialized
// (each awaited before the next) all succeed and are recorded in order.
//
// `write(conn, line)` returns a Promise(Result(Nil, String)) — Ok or the lock
// Error — matching the real serial_ffi `write` contract.

import { Ok, Error } from "../gleam.mjs";

export function newLockedConn() {
  return { locked: false, written: [], hadLockError: false };
}

export function lockedWrite(conn, line) {
  return new Promise((resolve) => {
    if (conn.locked) {
      // A second writer while the first is still active — exactly what the real
      // WritableStream.getWriter() throws.
      conn.hadLockError = true;
      resolve(new Error("stream is locked"));
      return;
    }
    conn.locked = true;
    // Resolve on a microtask/macrotask so overlapping (non-awaited) calls collide
    // while this one holds the lock.
    setTimeout(() => {
      conn.written.push(line);
      conn.locked = false;
      resolve(new Ok(undefined));
    }, 0);
  });
}

export function writtenCount(conn) {
  return conn.written.length;
}

export function hadLockError(conn) {
  return conn.hadLockError;
}

// A deferred so the test can await until all expected writes have landed.
export function newDeferred() {
  let resolve;
  const promise = new Promise((r) => { resolve = r; });
  return { promise, resolve };
}
export function deferredPromise(d) { return d.promise; }
export function deferredResolve(d, value) { d.resolve(value); return value; }
