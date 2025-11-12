{
  lib,
  stdenv,
  zig,
  duckdb,
}:

stdenv.mkDerivation {
  pname = "strace-to-duckdb";
  version = "0.1.0";

  src = ../..;

  nativeBuildInputs = [
    zig
  ];

  buildInputs = [
    duckdb
  ];

  # Zig cache and global cache directories
  XDG_CACHE_HOME = ".cache";

  doCheck = true;

  buildPhase = ''
    runHook preBuild

    zig build -Doptimize=ReleaseSafe

    runHook postBuild
  '';

  checkPhase = ''
    runHook preCheck

    zig build test --summary all

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp zig-out/bin/strace-to-duckdb $out/bin/

    runHook postInstall
  '';

  meta = with lib; {
    description = "High-performance tool for parsing strace output and loading into DuckDB";
    homepage = "https://github.com/omegaice/strace-to-duckdb";
    license = licenses.mit; # Adjust as needed
    maintainers = [ ];
    platforms = platforms.unix;
    mainProgram = "strace-to-duckdb";
  };
}
