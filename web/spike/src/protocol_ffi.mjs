// Pure helpers backing `protocol.gleam`. No DOM / Web Serial here — kept tiny
// and side-effect-free so the protocol module stays unit-testable.

import { toList } from "./gleam.mjs";

// UTF-8 byte list of a string, for the Marlin XOR checksum. TextEncoder gives
// us the exact byte sequence Marlin checksums over the wire.
export function stringToBytes(s) {
  const bytes = new TextEncoder().encode(s);
  return toList(Array.from(bytes));
}

// Fixed-decimal float formatting, matching Erlang's
// `:erlang.float_to_binary(f, decimals: n)` for the values we produce (jog mm).
export function floatToDecimals(f, decimals) {
  return f.toFixed(decimals);
}
