// blau-drill end-to-end ("n-gen") browser test driver.
//
// Not a unit test (those live in ../blau_drill/*.gleam and run under `gleam
// test`). This is a SCRIPT to paste into a Chromium DevTools console — or run via
// the Chrome DevTools MCP `evaluate_script` — against the running dev server
// (`gleam run -m lustre/dev start`, http://localhost:1234) to exercise the full
// operator flow on the SIMULATOR backend and assert state at each milestone.
//
// It drives the app by clicking real buttons (by visible text / aria-label), so
// it survives uid churn and re-renders. It covers:
//   1. Happy path: Load → Connect → Align (3 captures + fit) → Dry-run → Drill
//      (incl. bit-change pause) → Done.
//   2. Reload regression guard: reload into #align must re-parse the board,
//      reset connection + alignment, AND leave Capture working (the job must be
//      advanced to Registering on restore — the bug fixed in 0ab4a6a).
//   3. Safety cap: reloading into an unsafe hash (#drill) must NOT render the
//      drilling screen.
//
// Usage (DevTools console): paste this file, then `await runE2E()`.
// Returns { pass: bool, results: [...] }. Every entry's `ok` must be true.

async function runE2E() {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const txt = () => document.body.innerText;
  const has = (s) => txt().toLowerCase().includes(s.toLowerCase());
  const clickByText = (t) => {
    const tt = t.toLowerCase();
    const b = [...document.querySelectorAll("button")].find(
      (x) => (x.textContent || "").toLowerCase().includes(tt) && !x.disabled,
    );
    if (b) { b.click(); return true; }
    return false;
  };
  const clickByLabel = (lbl) => {
    const b = [...document.querySelectorAll("button")].find(
      (x) => (x.getAttribute("aria-label") || "") === lbl && !x.disabled,
    );
    if (b) { b.click(); return true; }
    return false;
  };
  const waitFor = async (pred, ms) => {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) { if (pred()) return true; await sleep(150); }
    return false;
  };
  const results = [];
  const log = (step, ok, extra) => results.push({ step, ok, ...(extra || {}) });

  // Clean slate.
  localStorage.clear();
  history.replaceState(null, "", location.pathname);
  await sleep(100);

  // ── 1. Happy path ──────────────────────────────────────────────────────────
  log("loadSample", clickByText("load sample board")); await sleep(300);
  log("boardParsed", has("130") && has("file valid"));
  log("connect", clickByText("connect")); await sleep(300);
  log("connected", has("machine ready") || has("connected"));
  log("proceedAlign", clickByText("proceed to align")); await sleep(300);
  log("atAlign", location.hash === "#align" && has("alignment setup"));
  log("energize", clickByText("enable motors")); await sleep(300);
  log("motorsOnline", has("online"));

  // capture 3 fiducials at distinct jogged positions
  log("capture1", clickByText("capture fiducial")); await sleep(200);
  log("count1", has("1/4") || has("1 / 4"));
  clickByLabel("Fiducial 2 — pending, select as target"); await sleep(120);
  clickByLabel("Jog +X →"); await sleep(150);
  log("capture2", clickByText("capture fiducial")); await sleep(200);
  log("count2", has("2/4") || has("2 / 4"));
  clickByLabel("Fiducial 3 — pending, select as target"); await sleep(120);
  clickByLabel("Jog ↑ +Y"); await sleep(150);
  log("capture3", clickByText("capture fiducial")); await sleep(200);
  log("count3", has("3/4") || has("3 / 4"));
  log("fit", clickByText("fit alignment")); await sleep(300);
  log("aligned", has("aligned") && (has("good") || has("quality")));

  log("proceedDryRun", clickByText("proceed to dry-run")); await sleep(200);
  log("atDryRun", location.hash === "#dryrun");
  log("dryRunComplete", await waitFor(() => has("130/130") || has("130 / 130"), 15000));

  log("confirm", clickByText("confirm registration")); await sleep(300);
  log("atDrill", location.hash === "#drill" && has("drilling in progress"));
  await waitFor(() => has("bit change required") || has("100%"), 8000);
  if (has("bit change required")) clickByText("resume drilling");
  log("drillComplete", await waitFor(() => has("100%") && (has("130 / 130") || has("130/130")), 15000));
  log("markComplete", clickByText("mark complete")); await sleep(300);
  log("atDone", has("drilling complete") && has("total holes"));

  // ── 2. Reload regression guard (#align must keep Capture working) ───────────
  history.replaceState(null, "", "#align");
  location.reload();
  // reload halts script execution; the caller re-invokes runReloadChecks() after.
  return { pass: results.every((r) => r.ok), results, note: "reloading; run runReloadChecks() next" };
}

// Run AFTER the reload triggered at the end of runE2E (page is at #align with a
// persisted board).
async function runReloadChecks() {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const txt = () => document.body.innerText;
  const has = (s) => txt().toLowerCase().includes(s.toLowerCase());
  const clickByText = (t) => {
    const tt = t.toLowerCase();
    const b = [...document.querySelectorAll("button")].find(
      (x) => (x.textContent || "").toLowerCase().includes(tt) && !x.disabled,
    );
    if (b) { b.click(); return true; }
    return false;
  };
  const results = [];
  const log = (step, ok, extra) => results.push({ step, ok, ...(extra || {}) });

  log("restoredToAlign", has("alignment setup"));
  log("boardRestored", has("t1") && has("t5"));
  log("connReset", has("disconnected"));
  log("alignReset", has("not yet located"));
  clickByText("connect"); await sleep(300);
  clickByText("enable motors"); await sleep(300);
  const before = has("0/4") || has("0 / 4");
  clickByText("capture fiducial"); await sleep(300);
  log("captureWorksAfterReload", before && (has("1/4") || has("1 / 4")));

  // safety cap: unsafe hash must not render the drilling screen
  history.replaceState(null, "", "#drill");
  location.reload();
  return { pass: results.every((r) => r.ok), results, note: "reloading to test #drill cap; check no drilling screen renders" };
}
