# Used by "mix format".
#
# NOTE: We inline Phoenix's `locals_without_parens` rather than using
# `import_deps: [:phoenix, :phoenix_live_view]`. `import_deps` forces the
# formatter to evaluate this project's `mix.exs` (resolving dep SCMs and the
# `elixir: "~> 1.20"` requirement), which fails inside the hermetic treefmt/Nix
# sandbox (it ships its own Elixir and has no fetched deps). Inlining keeps both
# `mix format` (dev shell) and `nix fmt` / `nix flake check` working.
phoenix_locals_without_parens = [
  # Phoenix.Router
  connect: 3,
  connect: 4,
  delete: 3,
  delete: 4,
  forward: 2,
  forward: 3,
  forward: 4,
  get: 3,
  get: 4,
  head: 3,
  head: 4,
  match: 4,
  match: 5,
  options: 3,
  options: 4,
  patch: 3,
  patch: 4,
  pipeline: 2,
  pipe_through: 1,
  post: 3,
  post: 4,
  put: 3,
  put: 4,
  resources: 2,
  resources: 3,
  resources: 4,
  trace: 4,
  # Phoenix.Controller
  action_fallback: 1,
  # Phoenix.Endpoint
  plug: 1,
  plug: 2,
  socket: 2,
  socket: 3,
  # Phoenix.Socket
  channel: 2,
  channel: 3,
  # Phoenix.Channel
  intercept: 1,
  # Phoenix.LiveView / Phoenix.Component
  attr: 2,
  attr: 3,
  embed_templates: 1,
  embed_templates: 2,
  live: 2,
  live: 3,
  live: 4,
  on_mount: 1,
  slot: 1,
  slot: 2,
  slot: 3,
  # Phoenix.{Conn,Channel,LiveView}Test
  assert_error_sent: 2,
  assert_broadcast: 2,
  assert_broadcast: 3,
  assert_push: 2,
  assert_push: 3,
  assert_reply: 2,
  assert_reply: 3,
  assert_reply: 4,
  refute_broadcast: 2,
  refute_broadcast: 3,
  refute_push: 2,
  refute_push: 3,
  refute_reply: 2,
  refute_reply: 3,
  refute_reply: 4,
  assert_patch: 1,
  assert_patch: 2,
  assert_patch: 3,
  assert_patched: 2,
  assert_push_event: 3,
  assert_push_event: 4,
  assert_redirect: 1,
  assert_redirect: 2,
  assert_redirect: 3,
  assert_redirected: 2,
  refute_redirected: 1,
  refute_redirected: 2,
  refute_patched: 1,
  refute_patched: 2,
  refute_push_event: 3,
  refute_push_event: 4
]

# The Phoenix.LiveView.HTMLFormatter plugin (for .heex) is intentionally NOT
# enabled here: loading it requires the `phoenix_live_view` dependency to be
# compiled, which is unavailable in the hermetic `nix flake check` / treefmt
# sandbox (no network, no fetched deps) and would break `nix fmt`. HEEx files
# are hand-formatted; run `mix format` with the plugin locally if/when desired.
[
  locals_without_parens: phoenix_locals_without_parens,
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
