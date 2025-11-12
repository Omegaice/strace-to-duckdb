{
  description = "High-performance tool for parsing strace output and loading into DuckDB";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    git-hooks-nix.url = "github:cachix/git-hooks.nix";
    git-hooks-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.git-hooks-nix.flakeModule
      ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        {
          # Per-system attributes can be defined here. The self' and inputs'
          # module parameters provide easy access to attributes of the same
          # system.

          packages.default = pkgs.callPackage ./.nix/strace-to-duckdb { };

          checks.default = self'.packages.default;

          devShells.default = pkgs.mkShell {
            inputsFrom = [
              self'.packages.default
              config.pre-commit.devShell
            ];
          };

          # Formatting configuration
          treefmt = {
            projectRootFile = "flake.nix";
            programs.zig.enable = true;
            programs.nixfmt.enable = true;
          };

          # Pre-commit hooks configuration
          pre-commit.settings.hooks = {
            treefmt.enable = true;
          };
        };
    };
}
