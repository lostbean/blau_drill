{
  description = "blau-drill — PCB drilling control app (Elixir)";

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

        # Pin the BEAM package set to OTP 28 so Erlang and Elixir are built
        # against the same VM. `beam.packages.erlang_28` gives Erlang/OTP 28;
        # `elixir_1_20` within it is Elixir 1.20 compiled for that OTP.
        beam = pkgs.beam.packages.erlang_28;
        erlang = beam.erlang; # Erlang/OTP 28
        elixir = beam.elixir_1_20; # Elixir 1.20 on OTP 28

        # treefmt config — one formatter per language. See formatters.md.
        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true; # Nix     (nixfmt-rfc-style)
          programs.mix-format.enable = true; # Elixir  (uses .formatter.exs)
        };
      in
      {
        devShells.default = pkgs.mkShell {
          # Toolchains for the detected languages + shared dev tools.
          packages = [
            erlang
            elixir
            beam.elixir-ls # Elixir language server (matches the OTP/Elixir set)
            pkgs.lefthook
          ];

          # Keep Hex/Rebar/Mix state local to the project instead of $HOME.
          shellHook = ''
            export MIX_HOME="$PWD/.mix"
            export HEX_HOME="$PWD/.hex"
            export PATH="$MIX_HOME/bin:$HEX_HOME/bin:$PATH"
          '';
        };

        # `nix fmt` runs treefmt across the repo.
        formatter = treefmtEval.config.build.wrapper;

        # `nix flake check` verifies everything is formatted.
        checks.formatting = treefmtEval.config.build.check ./.;
      }
    );
}
