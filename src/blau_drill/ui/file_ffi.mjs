// File-picker FFI for Stage 1. Opens a hidden `<input type=file>`, lets the
// operator choose ONE file, reads it as TEXT, and resolves a Gleam
// Result(String, String). Bridged to a Lustre Effect the same way the serial
// open is (Promise -> dispatch). Pure browser, no server.
//
// Returns Error("cancelled") if the operator dismisses the dialog without a
// pick, and Error(message) if the read fails.

import { Ok, Error } from "../../gleam.mjs";

// Pick a single file whose name matches `accept` (e.g. ".drl" or ".svg") and
// resolve its text content. The hidden input is created per call and removed
// after; the focus/cancel heuristic resolves "cancelled" when the dialog closes
// with no selection.
export function pickFileText(accept) {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = accept;
    input.style.position = "fixed";
    input.style.left = "-10000px";
    document.body.appendChild(input);

    let settled = false;
    const cleanup = () => {
      try {
        document.body.removeChild(input);
      } catch (_) {}
      window.removeEventListener("focus", onFocus, true);
    };

    const onChange = () => {
      if (settled) return;
      const file = input.files && input.files[0];
      if (!file) {
        settled = true;
        cleanup();
        resolve(new Error("cancelled"));
        return;
      }
      const reader = new FileReader();
      reader.onload = () => {
        settled = true;
        cleanup();
        resolve(new Ok(String(reader.result)));
      };
      reader.onerror = () => {
        settled = true;
        cleanup();
        resolve(new Error("could not read file"));
      };
      reader.readAsText(file);
    };

    // If the window regains focus and no file was chosen, treat it as cancel.
    const onFocus = () => {
      setTimeout(() => {
        if (settled) return;
        if (!input.files || input.files.length === 0) {
          settled = true;
          cleanup();
          resolve(new Error("cancelled"));
        }
      }, 400);
    };

    input.addEventListener("change", onChange);
    window.addEventListener("focus", onFocus, true);
    input.click();
  });
}
