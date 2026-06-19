// localStorage FFI for operator config persistence. Pure browser, no server.
// get returns "" when the key is missing or storage is unavailable (private
// mode / blocked); set is best-effort and never throws.

export function getItem(key) {
  try {
    if (typeof localStorage === "undefined") return "";
    const v = localStorage.getItem(key);
    return v == null ? "" : String(v);
  } catch (_) {
    return "";
  }
}

export function setItem(key, value) {
  try {
    if (typeof localStorage === "undefined") return undefined;
    localStorage.setItem(key, value);
  } catch (_) {}
  return undefined;
}
