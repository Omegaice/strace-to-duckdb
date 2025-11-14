{
  lib,
  stdenv,
  zig,
  duckdb,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "strace-to-duckdb";
  version = "0.1.0";

  src = ../..;

  nativeBuildInputs = [
    zig.hook
  ];

  buildInputs = [
    duckdb
  ];

  postUnpack =
    let
      deps = zig.fetchDeps {
        inherit (finalAttrs)
          src
          pname
          version
          ;
        hash = "sha256-KJHK6mQNohtaF2G7sWqLiFxGyRFbwMqYDk5sWFg1m3s=";
      };
    in
    ''
      ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p
    '';

  meta = with lib; {
    description = "High-performance tool for parsing strace output and loading into DuckDB";
    homepage = "https://github.com/omegaice/strace-to-duckdb";
    license = licenses.mit; # Adjust as needed
    maintainers = [ ];
    platforms = platforms.unix;
    mainProgram = "strace-to-duckdb";
  };
})
