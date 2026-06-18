<script>
  // BoardCanvas — the top-down PCB view for blau-drill.
  //
  // Renders the board substrate, the drill holes (coloured by tool, or by
  // drilled/pending status during a run), the board outline, fiducial marks
  // (captured/pending), and a live machine-head crosshair. It is purely a
  // VIEW — all motion/gating lives server-side in the LiveView + domain core.
  // Data is projected from board coordinates into an SVG viewBox using the
  // board bbox (fit-to-view, Y flipped because board Y is up but SVG Y is down).
  //
  // Props (all plain JSON from the LiveView via <.svelte props={...}>):
  //   holes:    [{x, y, tool, status}]  status: "pending" | "done" | "active"
  //   outline:  [[x, y], ...] | null
  //   fiducials:[{x, y, state}]  state: "captured" | "pending"
  //   tools:    {"T1": 0.6, ...}        diameter in mm, for the colour legend
  //   bbox:     [minx, miny, maxx, maxy]
  //   head:     {x, y} | null           live head position in BOARD coords
  //   stage:    "align" | "dryrun" | "drill" | ...  (tweaks emphasis)
  let {
    holes = [],
    outline = null,
    fiducials = [],
    tools = {},
    bbox = null,
    head = null,
    stage = "align",
  } = $props()

  // A stable palette assigned to tools in id order (cyan-ish first).
  const PALETTE = ["#00ffff", "#ffb300", "#40e56c", "#c792ea", "#ff6e6e", "#82aaff"]

  const toolIds = $derived(Object.keys(tools).sort())
  const toolColor = $derived(
    Object.fromEntries(toolIds.map((t, i) => [t, PALETTE[i % PALETTE.length]])),
  )

  // ── projection ────────────────────────────────────────────────────────────
  const PAD = 24 // viewBox padding (board units), so marks near the edge show
  const VIEW = 1000 // square viewBox; we letterbox within it

  const box = $derived(() => {
    if (bbox && bbox.length === 4) {
      const [minx, miny, maxx, maxy] = bbox
      return { minx, miny, maxx, maxy }
    }
    // Fallback bbox from holes so the component still renders without bbox.
    if (holes.length) {
      const xs = holes.map((h) => h.x)
      const ys = holes.map((h) => h.y)
      return {
        minx: Math.min(...xs),
        miny: Math.min(...ys),
        maxx: Math.max(...xs),
        maxy: Math.max(...ys),
      }
    }
    return { minx: 0, miny: 0, maxx: 1, maxy: 1 }
  })

  const span = $derived(() => {
    const b = box()
    const w = Math.max(b.maxx - b.minx, 0.001)
    const h = Math.max(b.maxy - b.miny, 0.001)
    const s = (VIEW - 2 * PAD) / Math.max(w, h)
    // Centre the board in the square viewBox.
    const offX = PAD + (VIEW - 2 * PAD - w * s) / 2
    const offY = PAD + (VIEW - 2 * PAD - h * s) / 2
    return { s, offX, offY, w, h, b }
  })

  // Board point -> SVG point. Y is flipped: board +Y is up, SVG +Y is down.
  function project(x, y) {
    const { s, offX, offY, b, h } = span()
    const px = offX + (x - b.minx) * s
    const py = offY + (h - (y - b.miny)) * s
    return [px, py]
  }

  const projectedHoles = $derived(
    holes.map((hole) => {
      const [px, py] = project(hole.x, hole.y)
      return { ...hole, px, py, color: toolColor[hole.tool] || "#00ffff" }
    }),
  )

  const outlinePath = $derived(() => {
    if (!outline || !outline.length) return null
    return (
      outline
        .map((pt, i) => {
          const [px, py] = project(pt[0], pt[1])
          return `${i === 0 ? "M" : "L"}${px.toFixed(1)},${py.toFixed(1)}`
        })
        .join(" ") + " Z"
    )
  })

  const projectedFids = $derived(
    fiducials.map((f) => {
      const [px, py] = project(f.x, f.y)
      return { ...f, px, py }
    }),
  )

  const projectedHead = $derived(() => {
    if (!head) return null
    const [px, py] = project(head.x, head.y)
    return { px, py }
  })

  function holeFill(hole) {
    if (hole.status === "done") return "#00c853"
    if (hole.status === "active") return "#ffb4ab"
    return hole.color
  }
</script>

<div class="board-canvas" data-stage={stage}>
  <svg viewBox="0 0 {VIEW} {VIEW}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="PCB board view">
    <!-- substrate -->
    <rect x="0" y="0" width={VIEW} height={VIEW} fill="#0a2e14" />
    <rect x="0" y="0" width={VIEW} height={VIEW} fill="url(#grid)" />
    <defs>
      <pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">
        <path d="M40 0 L0 0 0 40" fill="none" stroke="#0e3a1b" stroke-width="1" />
      </pattern>
    </defs>

    <!-- board outline -->
    {#if outlinePath()}
      <path d={outlinePath()} fill="none" stroke="#40e56c" stroke-width="2" opacity="0.5" />
    {/if}

    <!-- holes -->
    {#each projectedHoles as hole}
      <circle
        cx={hole.px}
        cy={hole.py}
        r={hole.status === "active" ? 9 : 5}
        fill={hole.status === "pending" || hole.status === undefined ? "none" : holeFill(hole)}
        stroke={holeFill(hole)}
        stroke-width="2"
        class:done={hole.status === "done"}
        class:active={hole.status === "active"}
      />
    {/each}

    <!-- fiducials -->
    {#each projectedFids as fid}
      <g class="fid {fid.state}">
        <circle cx={fid.px} cy={fid.py} r="16" fill="none" stroke-width="3" />
        {#if fid.state === "captured"}
          <path
            d="M{fid.px - 7},{fid.py} l5,6 l9,-12"
            fill="none"
            stroke="#40e56c"
            stroke-width="3"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        {:else}
          <circle cx={fid.px} cy={fid.py} r="4" fill="#ffb300" />
        {/if}
      </g>
    {/each}

    <!-- live head crosshair -->
    {#if projectedHead()}
      {@const h = projectedHead()}
      <g class="head">
        <line x1={h.px - 28} y1={h.py} x2={h.px + 28} y2={h.py} stroke="#22d3ee" stroke-width="2" />
        <line x1={h.px} y1={h.py - 28} x2={h.px} y2={h.py + 28} stroke="#22d3ee" stroke-width="2" />
        <circle cx={h.px} cy={h.py} r="20" fill="none" stroke="#22d3ee" stroke-width="2" opacity="0.6" />
        <circle cx={h.px} cy={h.py} r="4" fill="#22d3ee" />
      </g>
    {/if}
  </svg>

  <!-- tool legend -->
  {#if toolIds.length}
    <div class="legend">
      <span class="legend-title">Tool Legend</span>
      {#each toolIds as t}
        <span class="legend-row">
          <span class="dot" style="background:{toolColor[t]}"></span>
          {t} — {tools[t]}mm
        </span>
      {/each}
    </div>
  {/if}
</div>

<style>
  .board-canvas {
    position: relative;
    width: 100%;
    height: 100%;
    min-height: 360px;
    display: flex;
  }
  svg {
    width: 100%;
    height: 100%;
    border-radius: 0.25rem;
    box-shadow: inset 0 0 60px rgba(0, 0, 0, 0.6);
  }
  circle.done {
    filter: drop-shadow(0 0 6px rgba(0, 200, 83, 0.6));
  }
  circle.active {
    filter: drop-shadow(0 0 8px rgba(255, 180, 171, 0.8));
    animation: pulse 1.2s ease-in-out infinite;
  }
  .fid.pending circle {
    stroke: #ffb300;
    animation: pulse 1.5s ease-in-out infinite;
  }
  .fid.captured circle {
    stroke: #40e56c;
  }
  .head {
    animation: spin 6s linear infinite;
    transform-origin: center;
    transform-box: fill-box;
  }
  @keyframes pulse {
    0%,
    100% {
      opacity: 1;
    }
    50% {
      opacity: 0.4;
    }
  }
  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
  .legend {
    position: absolute;
    left: 1rem;
    bottom: 1rem;
    background: rgba(19, 19, 19, 0.85);
    border: 1px solid #514532;
    border-radius: 0.25rem;
    padding: 0.5rem 0.75rem;
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
    font-family: "JetBrains Mono", ui-monospace, monospace;
    font-size: 0.7rem;
    color: #e5e2e1;
  }
  .legend-title {
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: #d6c4ac;
    font-size: 0.625rem;
  }
  .legend-row {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
  }
  .dot {
    width: 0.6rem;
    height: 0.6rem;
    border-radius: 9999px;
  }
</style>
