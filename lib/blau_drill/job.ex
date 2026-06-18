defmodule BlauDrill.Job do
  @moduledoc """
  The session **state machine** — a pure value, never a process.

  `Job` enforces the only legal order of a drilling session, so that illegal
  sequencing is *unrepresentable* rather than merely discouraged (see
  `CONTEXT.md`: "Job"; architecture §07; ADR-0007). Each event exists only in
  the states where it is legal — there is no "drill" in `:parsed`, and crucially
  **no straight edge from `:aligned` to `:drilling`** (the real run must route
  through `:dry_run`). A `transition/2` that does not match a legal edge returns
  a typed `{:error, :illegal_transition}`; it never crashes.

  ## ADR-0007: hand-written, pure, a value

  Per ADR-0007, `Job` is a hand-rolled pure `transition/2` — not a library, not a
  GenServer. It is held in LiveView assigns and threaded through events; a
  transition returns a *new* `Job` value. The legal graph reads top-to-bottom as
  one clause per edge.

  ## The legal transition graph

      parsed             --:start_registering-->     registering
      registering        --{:capture, corr}-->       registering   (accumulate)
      registering        --{:fit, tol}-->            aligned        (residuals.max ≤ tol)
      registering        --{:fit, tol}-->            alignment_rejected (residuals.max > tol)
      alignment_rejected --:recapture-->             registering
      aligned            --:run_dry_run-->           dry_run
      dry_run            --:redo_alignment-->        aligned
      dry_run            --:confirm_registration-->  drilling       (the ONLY path to drilling)
      drilling           --:complete-->              done
      drilling           --{:serial_loss, reason}--> faulted
      faulted            --:reconnect-->             aligned

  A `{:fit, tol}` whose fit *fails* — `:too_few` (< 3 points) or `:degenerate`
  (collinear/coincident board points) — does **not** transition: the job stays
  in `:registering` and the error is returned, so the operator keeps capturing.

  ## Invariants enforced structurally

    * **No `aligned → drilling` edge.** There is deliberately no clause taking
      `:aligned` to `:drilling`; you cannot drill without first passing through
      `:dry_run`. `:confirm_registration` from `:aligned` is `:illegal_transition`.
    * **No drill in pre-aligned states.** `:confirm_registration` / `:run_dry_run`
      / `:complete` from `:parsed`, `:registering`, or `:alignment_rejected` are
      illegal.
    * **Residual gate.** The `:registering → :aligned` edge is guarded by
      `residuals.max ≤ tol`; a fit over tolerance lands in `:alignment_rejected`,
      a state that exposes no dry-run or drill event.
    * **Terminal states.** `:done` accepts no events. `:faulted` accepts only
      `:reconnect`.

  ## Helpers for the UI

  `legal_events/1` and `can?/2` let a LiveView enable exactly the buttons whose
  events would succeed from the current state — the same no-shortcut invariant
  surfaces in the UI (no "Drill" button while merely `:aligned`).
  """

  alias BlauDrill.Alignment
  alias BlauDrill.BoardModel
  alias BlauDrill.Correspondence
  alias BlauDrill.PendingAlignment

  @default_tol 0.1

  @typedoc """
  The session lifecycle state.

  See the module doc for the full legal graph. `:alignment_rejected` and
  `:faulted` are the two off-ramps; `:done` is terminal.
  """
  @type state ::
          :parsed
          | :registering
          | :aligned
          | :alignment_rejected
          | :dry_run
          | :drilling
          | :done
          | :faulted

  @typedoc """
  An event drives a transition. Events carry the data their guards need.

    * `:start_registering` — `:parsed → :registering`.
    * `{:capture, correspondence}` — append a `Correspondence` while
      `:registering` (stays `:registering`).
    * `{:fit, tol}` — fit the captured correspondences while `:registering`;
      branches on the residual gate to `:aligned` or `:alignment_rejected`, or
      stays `:registering` on a failed fit.
    * `:recapture` — `:alignment_rejected → :registering`.
    * `:run_dry_run` — `:aligned → :dry_run`.
    * `:redo_alignment` — `:dry_run → :aligned`.
    * `:confirm_registration` — `:dry_run → :drilling` (the only path to drilling).
    * `:complete` — `:drilling → :done`.
    * `{:serial_loss, reason}` — `:drilling → :faulted`.
    * `:reconnect` — `:faulted → :aligned`.
  """
  @type event ::
          :start_registering
          | {:capture, Correspondence.t()}
          | {:fit, tol :: float()}
          | :recapture
          | :run_dry_run
          | :redo_alignment
          | :confirm_registration
          | :complete
          | {:serial_loss, reason :: term()}
          | :reconnect

  @typedoc """
  A transition failure.

    * `:illegal_transition` — the event is not legal from the current state.
    * `:too_few` — a `{:fit, tol}` with fewer than 3 captured correspondences;
      the job stays `:registering`.
    * `:degenerate` — a `{:fit, tol}` whose board points are collinear/coincident;
      the job stays `:registering`.
  """
  @type reason :: :illegal_transition | :too_few | :degenerate | term()

  @typedoc """
  The session value.

    * `state` — the current lifecycle state.
    * `board` — the parsed `BoardModel` carried for the whole session.
    * `pending` — the in-progress `PendingAlignment` accumulating captures.
    * `alignment` — the solved `Alignment`, once `:aligned` (else `nil`).
    * `residuals` — the fit residuals `%{rms, max}` of the last fit (else `nil`).
    * `tol` — the residual-gate tolerance in millimetres (the default tol for the
      session; the `{:fit, tol}` event's tolerance is what actually gates).
  """
  @type t :: %__MODULE__{
          state: state(),
          board: BoardModel.t() | term(),
          pending: PendingAlignment.t(),
          alignment: Alignment.t() | nil,
          residuals: Alignment.residuals() | nil,
          tol: float()
        }

  @enforce_keys [:board]
  defstruct state: :parsed,
            board: nil,
            pending: nil,
            alignment: nil,
            residuals: nil,
            tol: @default_tol

  @doc """
  Build a fresh `Job` for `board`, in `:parsed`, with an empty
  `PendingAlignment`.

  Options:

    * `:tol` — the session residual-gate tolerance in millimetres
      (default `#{@default_tol}`).

  The board is held opaque for the whole session; nothing past parsing touches a
  file again.

  ## Examples

      iex> {:ok, board} = BlauDrill.BoardModel.parse_drl("M48\\nMETRIC\\nT1C0.6\\n%\\nT1\\nX0Y0\\nM30\\n")
      iex> job = BlauDrill.Job.new(board, tol: 0.05)
      iex> {job.state, job.tol, BlauDrill.PendingAlignment.count(job.pending)}
      {:parsed, 0.05, 0}
  """
  @spec new(BoardModel.t() | term(), keyword()) :: t()
  def new(board, opts \\ []) do
    %__MODULE__{
      state: :parsed,
      board: board,
      pending: %PendingAlignment{captured: []},
      alignment: nil,
      residuals: nil,
      tol: Keyword.get(opts, :tol, @default_tol)
    }
  end

  @doc """
  Apply `event` to `job`, returning the next `Job` or a typed error.

  Each clause below is exactly one legal edge of the graph (see the module doc).
  The final catch-all keeps illegal sequencing a typed `{:error,
  :illegal_transition}` rather than a crash. There is deliberately **no clause
  taking `:aligned` to `:drilling`** — that edge is unrepresentable.
  """
  @spec transition(t(), event()) :: {:ok, t()} | {:error, reason()}

  # parsed -> registering
  def transition(%__MODULE__{state: :parsed} = job, :start_registering) do
    {:ok, %{job | state: :registering}}
  end

  # registering -> registering : accumulate a correspondence
  def transition(%__MODULE__{state: :registering} = job, {:capture, %Correspondence{} = corr}) do
    {:ok, %{job | pending: PendingAlignment.add(job.pending, corr)}}
  end

  # registering -> aligned / alignment_rejected : the residual gate.
  # A failed fit (:too_few / :degenerate) does NOT transition — the operator
  # stays in :registering and keeps capturing.
  def transition(%__MODULE__{state: :registering} = job, {:fit, tol}) do
    case Alignment.fit(job.pending.captured) do
      {:ok, %Alignment{residuals: %{max: max} = residuals} = alignment} ->
        if max <= tol do
          {:ok, %{job | state: :aligned, alignment: alignment, residuals: residuals}}
        else
          {:ok, %{job | state: :alignment_rejected, alignment: nil, residuals: residuals}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # alignment_rejected -> registering : recapture
  def transition(%__MODULE__{state: :alignment_rejected} = job, :recapture) do
    {:ok, %{job | state: :registering}}
  end

  # aligned -> dry_run : run the mandatory dry-run rehearsal
  def transition(%__MODULE__{state: :aligned} = job, :run_dry_run) do
    {:ok, %{job | state: :dry_run}}
  end

  # dry_run -> aligned : residuals look wrong, redo the dry-run later
  def transition(%__MODULE__{state: :dry_run} = job, :redo_alignment) do
    {:ok, %{job | state: :aligned}}
  end

  # dry_run -> drilling : confirm registration — the ONLY path to drilling
  def transition(%__MODULE__{state: :dry_run} = job, :confirm_registration) do
    {:ok, %{job | state: :drilling}}
  end

  # drilling -> done : all holes complete
  def transition(%__MODULE__{state: :drilling} = job, :complete) do
    {:ok, %{job | state: :done}}
  end

  # drilling -> faulted : serial loss
  def transition(%__MODULE__{state: :drilling} = job, {:serial_loss, _reason}) do
    {:ok, %{job | state: :faulted}}
  end

  # faulted -> aligned : reconnect & resume from the solved alignment
  def transition(%__MODULE__{state: :faulted} = job, :reconnect) do
    {:ok, %{job | state: :aligned}}
  end

  # Catch-all: illegal sequencing is a typed error, never a crash. In
  # particular there is NO :aligned + :confirm_registration clause above, so the
  # no-shortcut invariant (aligned -X-> drilling) lands here.
  def transition(%__MODULE__{}, _event), do: {:error, :illegal_transition}

  @doc """
  The event *names* that are legal from `job`'s current state.

  Event names are the bare atoms (`:capture`, `:fit`, `:serial_loss` for the
  tagged events); a LiveView uses this to enable exactly the right buttons. The
  no-shortcut invariant surfaces here too: `:confirm_registration` is never in
  the list while merely `:aligned`.

  ## Examples

      iex> {:ok, board} = BlauDrill.BoardModel.parse_drl("M48\\nMETRIC\\nT1C0.6\\n%\\nT1\\nX0Y0\\nM30\\n")
      iex> BlauDrill.Job.legal_events(BlauDrill.Job.new(board))
      [:start_registering]
  """
  @spec legal_events(t()) :: [atom()]
  def legal_events(%__MODULE__{state: :parsed}), do: [:start_registering]
  def legal_events(%__MODULE__{state: :registering}), do: [:capture, :fit]
  def legal_events(%__MODULE__{state: :alignment_rejected}), do: [:recapture]
  def legal_events(%__MODULE__{state: :aligned}), do: [:run_dry_run]
  def legal_events(%__MODULE__{state: :dry_run}), do: [:redo_alignment, :confirm_registration]
  def legal_events(%__MODULE__{state: :drilling}), do: [:complete, :serial_loss]
  def legal_events(%__MODULE__{state: :faulted}), do: [:reconnect]
  def legal_events(%__MODULE__{state: :done}), do: []

  @doc """
  Whether `event_name` (a bare atom) is legal from `job`'s current state.

  Pass the event *name*, not a tagged tuple: `can?(job, :capture)`, not
  `can?(job, {:capture, corr})`. Agrees with `legal_events/1`.

  ## Examples

      iex> {:ok, board} = BlauDrill.BoardModel.parse_drl("M48\\nMETRIC\\nT1C0.6\\n%\\nT1\\nX0Y0\\nM30\\n")
      iex> job = BlauDrill.Job.new(board)
      iex> {BlauDrill.Job.can?(job, :start_registering), BlauDrill.Job.can?(job, :confirm_registration)}
      {true, false}
  """
  @spec can?(t(), atom()) :: boolean()
  def can?(%__MODULE__{} = job, event_name) when is_atom(event_name) do
    event_name in legal_events(job)
  end
end
