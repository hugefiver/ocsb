{ pkgs, testHooks ? false }:
pkgs.pkgsStatic.stdenv.mkDerivation {
  pname = "ocsb-sidecar-gate";
  version = "1.0.0";
  src = ./.;

  strictDeps = true;
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -std=c17 -O2 -Wall -Wextra -Werror $NIX_CFLAGS_COMPILE \
      ${if testHooks then "-DOCSB_SIDECAR_GATE_TEST_HOOKS=1" else ""} \
      -o ocsb-sidecar-gate ocsb-sidecar-gate.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0555 ocsb-sidecar-gate "$out/bin/ocsb-sidecar-gate"
    runHook postInstall
  '';
}
