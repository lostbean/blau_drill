// Reliable test gate for blau_drill. gleeunit's main() runs tests in a sequential
// `for await` loop; a single hanging async test stalls the loop so it never
// reaches exit(status) — leaving `gleam test` to exit 0 with no failure summary
// (a BLIND gate). This runner imports every compiled test module, runs each
// `*_test` fn, AWAITS async tests with a per-test timeout (a hang = a failure,
// not a stall), catches throws, prints the failures, and exits non-zero on any
// failure. Run: `nix develop -c bash -c 'gleam build && node scripts/test_gate.mjs'`.
import { readdirSync, writeFileSync } from "fs";
import { pathToFileURL } from "url";
import { resolve } from "path";
// Resolve against CWD (project root), as an absolute file:// URL, so dynamic
// import() doesn't resolve relative to this script's own directory (scripts/).
const dir = resolve(process.cwd(), "build/dev/javascript/blau_drill/blau_drill") + "/";
const importUrl = (f) => pathToFileURL(dir + f).href;
const TIMEOUT_MS = Number(process.env.GATE_TIMEOUT_MS || 8000);
const REPORT = process.env.GATE_REPORT || "/tmp/blau_gate_report.txt";
const withTimeout = (p, ms) => {
  let timer;
  const t = new Promise((_, rej) => { timer = setTimeout(() => rej(new Error(`TIMEOUT ${ms}ms`)), ms); });
  return Promise.race([Promise.resolve(p), t]).finally(() => clearTimeout(timer));
};
// A hung test's original promise stays pending and may later settle with no
// handler — swallow that so it can't abort the runner.
process.on("unhandledRejection", () => {});
let pass = 0, fail = 0; const fails = [];
for (const f of readdirSync(dir).filter(f => f.endsWith("_test.mjs"))) {
  let mod;
  try { mod = await import(importUrl(f)); }
  catch (e) { fail++; fails.push(`${f} :: IMPORT FAILED :: ${String(e && e.message || e).split("\n")[0]}`); continue; }
  for (const name of Object.keys(mod)) {
    if (typeof mod[name] !== "function" || !name.endsWith("_test")) continue;
    try {
      const r = mod[name]();
      if (r && typeof r.then === "function") await withTimeout(r, TIMEOUT_MS);
      pass++;
    } catch (e) {
      fail++; fails.push(`${f.replace(".mjs", "")}.${name} :: ${String(e && e.message || e).split("\n")[0] || "(no message)"}`);
    }
  }
}
const out = ["=== blau_drill test gate ==="];
for (const x of fails) out.push("FAIL " + x);
out.push(`TOTAL: ${pass} passed, ${fail} failed`);
const report = out.join("\n") + "\n";
writeFileSync(REPORT, report);            // durable: survives the process.exit stdout race
process.stdout.write(report);
process.exitCode = fail > 0 ? 1 : 0;      // let the loop drain naturally (timers cleared)
