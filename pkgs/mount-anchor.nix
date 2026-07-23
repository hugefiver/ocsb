{ stdenv
, lib
}:
stdenv.mkDerivation {
  pname = "ocsb-mount-anchor";
  version = "1.0.0";
  src = ./.;

  strictDeps = true;
  dontConfigure = true;
  # PIE is the stdenv default in the pinned nixpkgs and is no longer a valid
  # explicit hardening flag there.
  hardeningEnable = [ "fortify" "stackprotector" "relro" ];

  buildPhase = ''
    runHook preBuild
    $CC -std=c17 -Wall -Wextra -Werror $NIX_CFLAGS_COMPILE \
      -o ocsb-mount-anchor ocsb-mount-anchor.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0755 ocsb-mount-anchor "$out/bin/ocsb-mount-anchor"
    runHook postInstall
  '';

  meta = {
    description = "Private mount namespace anchor helper for ocsb";
    platforms = lib.platforms.linux;
  };
}
