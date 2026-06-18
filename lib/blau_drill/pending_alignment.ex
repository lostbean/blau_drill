defmodule BlauDrill.PendingAlignment do
  @moduledoc """
  The **in-progress** registration value: an append-only list of captured
  `BlauDrill.Correspondence`s that has not (yet) been solved into an
  `BlauDrill.Alignment`.

  `PendingAlignment` is a *structurally different type* from `Alignment`, not a
  flag on it (see `CONTEXT.md`: "PendingAlignment"). Crucially it has **no
  transform field** — so no downstream function that requires a transform (e.g.
  `BlauDrill.GcodeProgram.build/2`) can be handed an unsolved alignment. That is
  the type-level guarantee behind the invariant *"an `Alignment` exists only
  when solvable."*

  While the operator registers, correspondences accumulate here via `add/2`
  (order preserved — capture order is meaningful for review and undo). When the
  set reaches ≥3 non-collinear points, `BlauDrill.Alignment.fit/1` on
  `captured` promotes it to an `{:ok, %Alignment{}}`; until then it stays
  pending (`{:error, :too_few}`) or, if the points are collinear/coincident,
  fails the fit loudly (`{:error, :degenerate}`).
  """

  alias BlauDrill.Correspondence

  @enforce_keys [:captured]
  defstruct captured: []

  @typedoc """
  An append-only list of captured correspondences, in capture order.
  """
  @type t :: %__MODULE__{captured: [Correspondence.t()]}

  @doc """
  Append a correspondence to the pending set, preserving capture order.

  This is the only mutation — the list is append-only, so existing
  correspondences are never reordered or removed.

  ## Examples

      iex> alias BlauDrill.{Correspondence, PendingAlignment}
      iex> c = %Correspondence{board: {0.0, 0.0}, machine: {1.0, 1.0}}
      iex> p = PendingAlignment.add(%PendingAlignment{captured: []}, c)
      iex> p.captured
      [%BlauDrill.Correspondence{board: {0.0, 0.0}, machine: {1.0, 1.0}}]
  """
  @spec add(t(), Correspondence.t()) :: t()
  def add(%__MODULE__{captured: captured} = pending, %Correspondence{} = correspondence) do
    %{pending | captured: captured ++ [correspondence]}
  end

  @doc """
  The number of correspondences captured so far.

  ## Examples

      iex> alias BlauDrill.PendingAlignment
      iex> PendingAlignment.count(%PendingAlignment{captured: []})
      0
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{captured: captured}), do: length(captured)
end
