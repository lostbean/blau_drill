//// The **in-progress** registration value: an append-only list of captured
//// `Correspondence`s that has not (yet) been solved into an `Alignment`. Ported
//// from `BlauDrill.PendingAlignment`.
////
//// `PendingAlignment` is a *structurally different type* from `Alignment`, not
//// a flag on it. Crucially it has **no transform field** — so no downstream
//// function that requires a transform can be handed an unsolved alignment.

import blau_drill/domain/correspondence.{type Correspondence}
import gleam/list

/// An append-only list of captured correspondences, in capture order.
pub type PendingAlignment {
  PendingAlignment(captured: List(Correspondence))
}

/// A fresh, empty pending alignment.
pub fn new() -> PendingAlignment {
  PendingAlignment(captured: [])
}

/// Append a correspondence to the pending set, preserving capture order.
///
/// This is the only mutation — the list is append-only, so existing
/// correspondences are never reordered or removed.
pub fn add(
  pending: PendingAlignment,
  correspondence: Correspondence,
) -> PendingAlignment {
  PendingAlignment(captured: list.append(pending.captured, [correspondence]))
}

/// The number of correspondences captured so far.
pub fn count(pending: PendingAlignment) -> Int {
  list.length(pending.captured)
}
