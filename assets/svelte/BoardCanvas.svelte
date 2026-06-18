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
  // The SVG viewBox is sized to the board's OWN aspect ratio (plus padding), so
  // `preserveAspectRatio="xMidYMid meet"` fits the whole board into whatever
  // shape the container is — width AND height — without cropping. A square
  // viewBox letterboxed inside a non-square container was what clipped the board
  // vertically before. One board unit (mm) maps to one viewBox unit, so marks
  // keep a consistent on-screen size regardless of board dimensions.
  const PAD = 8 // viewBox padding in board units (mm), so edge marks aren't clipped

  const box = $derived.by(() => {
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

  // Board span in mm, padded. The viewBox is exactly this size, so aspect ratio
  // is preserved by the SVG itself.
  const span = $derived.by(() => {
    const b = box
    const w = Math.max(b.maxx - b.minx, 0.001) + 2 * PAD
    const h = Math.max(b.maxy - b.miny, 0.001) + 2 * PAD
    return { w, h, b }
  })

  // ── zoom + pan ──────────────────────────────────────────────────────────────
  // zoom 1 = whole board fits. >1 zooms in. The visible window is the full span
  // divided by zoom, centred on a pan point (cx, cy) expressed as a fraction of
  // the span. The viewBox is recomputed from these so vector marks stay crisp.
  const MIN_ZOOM = 1
  const MAX_ZOOM = 12
  let zoom = $state(1)
  let panX = $state(0.5) // centre, as a 0..1 fraction of the (padded) span
  let panY = $state(0.5)

  const viewBox = $derived.by(() => {
    const { w, h } = span
    const vw = w / zoom
    const vh = h / zoom
    // Clamp the pan so the window stays inside the board span.
    const cx = Math.min(Math.max(panX, vw / 2 / w), 1 - vw / 2 / w)
    const cy = Math.min(Math.max(panY, vh / 2 / h), 1 - vh / 2 / h)
    const x = cx * w - vw / 2
    const y = cy * h - vh / 2
    return { x, y, vw, vh }
  })

  const viewBoxStr = $derived.by(
    () => `${viewBox.x.toFixed(2)} ${viewBox.y.toFixed(2)} ${viewBox.vw.toFixed(2)} ${viewBox.vh.toFixed(2)}`,
  )

  function zoomBy(factor) {
    zoom = Math.min(Math.max(zoom * factor, MIN_ZOOM), MAX_ZOOM)
    if (zoom === MIN_ZOOM) {
      panX = 0.5
      panY = 0.5
    }
  }

  function resetView() {
    zoom = MIN_ZOOM
    panX = 0.5
    panY = 0.5
  }

  function onWheel(e) {
    e.preventDefault()
    zoomBy(e.deltaY < 0 ? 1.15 : 1 / 1.15)
  }

  // Board point -> viewBox point. Y is flipped: board +Y is up, SVG +Y is down.
  // The padded span places (minx - PAD, ...) at viewBox origin.
  function project(x, y) {
    const { b, h } = span
    const px = x - b.minx + PAD
    const py = h - (y - b.miny + PAD)
    return [px, py]
  }

  // A constant on-screen size for marks regardless of zoom: divide by zoom so a
  // 5mm-radius dot doesn't balloon when you zoom in.
  const mark = $derived(1 / zoom)

  const projectedHoles = $derived(
    holes.map((hole) => {
      const [px, py] = project(hole.x, hole.y)
      // Draw each hole near its TRUE physical size (tool diameter in mm), with a
      // readable floor so tiny bits don't vanish. This keeps dense rows legible
      // instead of overlapping blobs.
      const dia = tools[hole.tool]
      const trueR = dia ? dia / 2 : 0.4
      return { ...hole, px, py, baseR: trueR, color: toolColor[hole.tool] || "#00ffff" }
    }),
  )

  const outlinePath = $derived.by(() => {
    if (!outline || !outline.length) return null
    return (
      outline
        .map((pt, i) => {
          const [px, py] = project(pt[0], pt[1])
          return `${i === 0 ? "M" : "L"}${px.toFixed(2)},${py.toFixed(2)}`
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

  const projectedHead = $derived.by(() => {
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
  <svg
    viewBox={viewBoxStr}
    preserveAspectRatio="xMidYMid meet"
    role="img"
    aria-label="PCB board view"
    onwheel={onWheel}
  >
    <!-- substrate: covers the full padded board span -->
    <rect x="0" y="0" width={span.w} height={span.h} fill="#0a2e14" />
    <rect x="0" y="0" width={span.w} height={span.h} fill="url(#grid)" />
    <defs>
      <!-- 5mm grid in board units -->
      <pattern id="grid" width="5" height="5" patternUnits="userSpaceOnUse">
        <path d="M5 0 L0 0 0 5" fill="none" stroke="#0e3a1b" stroke-width={0.15 * mark} />
      </pattern>
    </defs>

    <!-- board outline -->
    {#if outlinePath}
      <path d={outlinePath} fill="none" stroke="#40e56c" stroke-width={0.2 * mark} opacity="0.5" />
    {/if}

    <!-- holes: drawn at their true tool diameter (mm), floored so they stay
         visible, with a thin zoom-compensated stroke. -->
    {#each projectedHoles as hole}
      <circle
        cx={hole.px}
        cy={hole.py}
        r={Math.max(hole.baseR, 0.35 * mark) * (hole.status === "active" ? 1.5 : 1)}
        fill={hole.status === "pending" || hole.status === undefined ? "none" : holeFill(hole)}
        stroke={holeFill(hole)}
        stroke-width={0.18 * mark}
        class:done={hole.status === "done"}
        class:active={hole.status === "active"}
      />
    {/each}

    <!-- fiducials -->
    {#each projectedFids as fid}
      <g class="fid {fid.state}">
        <circle cx={fid.px} cy={fid.py} r={1.6 * mark} fill="none" stroke-width={0.3 * mark} />
        {#if fid.state === "captured"}
          <path
            d="M{fid.px - 0.7 * mark},{fid.py} l{0.45 * mark},{0.55 * mark} l{0.8 * mark},{-1.1 * mark}"
            fill="none"
            stroke="#40e56c"
            stroke-width={0.3 * mark}
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        {:else}
          <circle cx={fid.px} cy={fid.py} r={0.4 * mark} fill="#ffb300" />
        {/if}
      </g>
    {/each}

    <!-- live head crosshair -->
    {#if projectedHead}
      {@const hd = projectedHead}
      {@const arm = 2.5 * mark}
      <g class="head">
        <line x1={hd.px - arm} y1={hd.py} x2={hd.px + arm} y2={hd.py} stroke="#22d3ee" stroke-width={0.2 * mark} />
        <line x1={hd.px} y1={hd.py - arm} x2={hd.px} y2={hd.py + arm} stroke="#22d3ee" stroke-width={0.2 * mark} />
        <circle cx={hd.px} cy={hd.py} r={1.8 * mark} fill="none" stroke="#22d3ee" stroke-width={0.2 * mark} opacity="0.6" />
        <circle cx={hd.px} cy={hd.py} r={0.4 * mark} fill="#22d3ee" />
      </g>
    {/if}
  </svg>

  <!-- zoom controls -->
  <div class="zoom-controls">
    <button type="button" onclick={() => zoomBy(1.3)} aria-label="Zoom in" title="Zoom in">+</button>
    <button type="button" onclick={() => zoomBy(1 / 1.3)} aria-label="Zoom out" title="Zoom out">−</button>
    <button type="button" class="reset" onclick={resetView} aria-label="Fit board" title="Fit board">⤢</button>
    <span class="zoom-level">{Math.round(zoom * 100)}%</span>
  </div>

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
    touch-action: none;
  }
  .zoom-controls {
    position: absolute;
    right: 1rem;
    top: 1rem;
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: 0.25rem;
    z-index: 2;
  }
  .zoom-controls button {
    width: 2rem;
    height: 2rem;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 1.1rem;
    line-height: 1;
    color: #e5e2e1;
    background: rgba(19, 19, 19, 0.85);
    border: 1px solid #514532;
    border-radius: 0.25rem;
    cursor: pointer;
    font-family: "JetBrains Mono", ui-monospace, monospace;
  }
  .zoom-controls button:hover {
    border-color: #ffb300;
    color: #ffb300;
  }
  .zoom-controls .reset {
    font-size: 0.9rem;
  }
  .zoom-level {
    text-align: center;
    font-family: "JetBrains Mono", ui-monospace, monospace;
    font-size: 0.6rem;
    color: #d6c4ac;
    background: rgba(19, 19, 19, 0.85);
    border: 1px solid #514532;
    border-radius: 0.25rem;
    padding: 0.1rem 0;
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
