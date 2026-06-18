<script>
  // Svelte 5 runes. `live` is injected by LiveSvelte and lets the component
  // push events back to the LiveView; it is unused in this placeholder.
  let {name = "world", live} = $props()
</script>

<div class="hello">
  <span class="dot"></span>
  Svelte is live — hello, {name}.
</div>

<style>
  .hello {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    font-family: "JetBrains Mono", ui-monospace, monospace;
    font-size: 0.875rem;
    color: #e5e2e1;
  }
  .dot {
    width: 0.5rem;
    height: 0.5rem;
    border-radius: 9999px;
    background: #40e56c;
  }
</style>
