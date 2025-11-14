{
  description = "High-performance tool for parsing strace output and loading into DuckDB";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    git-hooks-nix.url = "github:cachix/git-hooks.nix";
    git-hooks-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, rust-overlay, ... }:
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
        let
          overlays = [ (import rust-overlay) ];
          pkgs = import inputs.nixpkgs {
            inherit system overlays;
          };
          rustToolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [
              "rust-src"
              "rust-analyzer"
              "clippy"
            ];
          };
        in
        {
          # Package definition
          packages.default = pkgs.rustPlatform.buildRustPackage {
            pname = "strace-to-duckdb";
            version = "0.1.0";
            src = ./.;
            cargoLock.lockFile = ./Cargo.lock;
          };

          # Checks
          checks.default = self'.packages.default.overrideAttrs (old: {
            doCheck = true;
          });

          # Development shell with Rust toolchain
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.pre-commit.devShell
            ];
            buildInputs = with pkgs; [
              rustToolchain
              cargo-watch
              cargo-edit
              pkg-config
              openssl
              duckdb
            ];

            shellHook = ''
              echo "Rust development environment loaded"
              echo "Rust version: $(rustc --version)"
              echo "Cargo version: $(cargo --version)"
            '';
          };

          # Formatting configuration
          treefmt = {
            projectRootFile = "flake.nix";
            programs.rustfmt.enable = true;
            programs.nixfmt.enable = true;
          };

          # Pre-commit hooks configuration
          pre-commit.settings.hooks = {
            treefmt.enable = true;
          };
        };
      flake = {
        # The usual flake attributes can be defined here, including system-
        # agnostic ones like nixosModule and system-enumerating ones, although
        # those are more easily expressed in perSystem.

      };
    };
}
