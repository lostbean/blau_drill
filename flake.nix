{
  description = "blau-drill — pure-browser PCB drilling control app (Gleam → JavaScript via Lustre, Web Serial, no backend)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    flake-utils.url = "github:numtide/flake-utils";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # treefmt config — one formatter per language. See docs/agents/formatters.md.
        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true; # Nix    (nixfmt-rfc-style)
          programs.gleam.enable = true; # Gleam  (uses `gleam format`)
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            # Gleam toolchain. The app compiles to JavaScript (target = "javascript"
            # in gleam.toml); Node is its runtime. Pinned via nixos-26.05 (Gleam 1.17).
            pkgs.gleam
            pkgs.nodejs

            # rebar3 compiles lustre_dev_tools' Erlang-target deps (needed by the
            # `gleam run -m lustre/dev …` watch server / static builder).
            pkgs.rebar3

            pkgs.lefthook # git hook runner (pre-commit `nix fmt`)
          ];
        };

        # `nix fmt` runs treefmt across the repo.
        formatter = treefmtEval.config.build.wrapper;

        # `nix flake check` verifies everything is formatted.
        checks.formatting = treefmtEval.config.build.check ./.;
      }
    );
}
