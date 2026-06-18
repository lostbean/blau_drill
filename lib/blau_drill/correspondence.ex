defmodule BlauDrill.Correspondence do
  @moduledoc """
  A single captured **board ↔ machine** pair — the raw material of alignment.

  A `Correspondence` records that a particular board feature point (`board`,
  e.g. a fiducial or distinctive hole in board coordinates) is physically
  located at a particular machine point (`machine`, the printer-head position
  the operator jogged onto it and read back via `M114`). See `CONTEXT.md`:
  "Correspondence".

  Correspondences accumulate as an **append-only list** during registration
  (held by `BlauDrill.PendingAlignment`) and are consumed by
  `BlauDrill.Alignment.fit/1`, which least-squares-fits them into a
  `BlauDrill.Transform2D`. A correspondence is inert data: it carries no
  transform and asserts nothing about quality — the honesty signal lives in the
  fitted `Alignment`'s residuals.

  Both fields are mandatory (`@enforce_keys`); a correspondence with a board
  point but no captured machine point (or vice versa) is meaningless and cannot
  be built.
  """

  alias BlauDrill.Transform2D

  @enforce_keys [:board, :machine]
  defstruct [:board, :machine]

  @typedoc """
  A captured registration pair.

  * `board` — the feature's location in **board coordinates** `{bx, by}`.
  * `machine` — where the head was when the operator located that feature, in
    **machine coordinates** `{mx, my}`.
  """
  @type t :: %__MODULE__{
          board: Transform2D.point(),
          machine: Transform2D.point()
        }
end
