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

export function removeItem(key) {
  try {
    if (typeof localStorage === "undefined") return undefined;
    localStorage.removeItem(key);
  } catch (_) {}
  return undefined;
}

// ── URL hash (the current stage; back/forward + bookmark friendly) ────────────

// Read the hash without the leading '#', lowercased. "" when none.
export function getHash() {
  try {
    const h = (location.hash || "").replace(/^#/, "");
    return h.toLowerCase();
  } catch (_) {
    return "";
  }
}

// Set the hash WITHOUT pushing a new history entry for every stage change
// (replaceState keeps back/forward sane); empty string clears it.
export function setHash(value) {
  try {
    const url = value ? "#" + value : location.pathname + location.search;
    history.replaceState(null, "", url);
  } catch (_) {}
  return undefined;
}
