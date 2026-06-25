// Tiny test-only helpers for the end-to-end control test: a mutable cell (so
// the async sim's read callback can fold inbound lines into the pure printer
// state) and a deferred Promise the test awaits until the stream completes.
//
// This is the ONLY JS in the control tests; all protocol/state logic stays in
// Gleam. It exists because the sim acks via setTimeout, so the handshake is
// genuinely asynchronous and needs a mutable bridge + a settle deadline.

export function newRef(value) {
  return { value };
}

export function refGet(ref) {
  return ref.value;
}

export function refSet(ref, value) {
  ref.value = value;
  return value;
}

// A deferred: returns { promise, resolve } so Gleam can resolve it from a
// callback. Used to signal "stream reached idle".
export function newDeferred() {
  let resolve;
  const promise = new Promise((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

export function deferredPromise(d) {
  return d.promise;
}

// Race a deferred against a wall-clock deadline so a never-resolving deferred
// (a regressed handshake that parks forever) FAILS LOUDLY within `ms` instead of
// stalling gleeunit's sequential loop forever. Resolves with the Gleam-side
// `ok(value)` when the deferred settles first, or `err()` on timeout. `ok`/`err`
// are passed in from Gleam (Ok/Error constructors) to keep the Result shape in
// Gleam's hands. The timer is cleared on settle so it can't keep the loop alive.
export function deferredPromiseWithTimeout(d, ms, ok, err) {
  let timer;
  const deadline = new Promise((res) => {
    timer = setTimeout(() => res(err()), ms);
  });
  return Promise.race([d.promise.then((v) => ok(v)), deadline]).finally(() =>
    clearTimeout(timer),
  );
}

export function deferredResolve(d, value) {
  d.resolve(value);
  return value;
}

// A macrotask "tick": a Promise that resolves on a 0ms timer. Awaiting it drains
// the ENTIRE microtask queue first (microtasks always run before the next
// macrotask), so any chained reply->write->reply microtasks the emulator backend
// scheduled have all flushed by the time it resolves. Used by the emulator e2e
// suite to settle a burst of the async handshake between discrete command phases.
export function tick() {
  return new Promise((res) => setTimeout(() => res(undefined), 0));
}
