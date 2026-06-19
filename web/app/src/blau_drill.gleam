//// Package-root entry module. The Lustre dev server (`gleam run -m lustre/dev
//// start`) bootstraps the package-named module's `main`, so this is the thin
//// shim that hands off to the Phase-3 demo app in `blau_drill/app`.
////
//// All UI lives under `blau_drill/ui/` and the orchestration/mock state in
//// `blau_drill/app`; this module only exists to satisfy the entry-point
//// convention.

import blau_drill/app

pub fn main() {
  app.main()
}
