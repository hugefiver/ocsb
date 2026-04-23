{ pkgs
, lib ? pkgs.lib
, ironclaw-src
, version ? "unstable"
}:
let
  # Hash table for known git dependencies across all tracked releases. Entries
  # are filtered against the actual Cargo.lock so versions that don't include
  # a given dep evaluate cleanly (rustPlatform errors if you list a hash for
  # an absent crate). Add a new entry here when a release introduces a new
  # git dep — extra (unmatched) entries are silently dropped.
  cargoLockText = builtins.readFile "${ironclaw-src}/Cargo.lock";
  allOutputHashes = {
    "monty-0.0.11" = "sha256-PRP8XcgeNVnc+2dWHxpizjvAtSjfqtkEXckXjPCRoJI=";
    "monty-0.0.9" = "sha256-lIuPWXuovY4TB5M7JUCDAIN97bo1X8B6MhL3UjFTnqA=";
    "ruff_python_ast-0.0.0" = "sha256-nVQC4ZaLWiZBUEReLqzpXKxXVxCdUW6b+mda9J8JSA0=";
    "ruff_python_parser-0.0.0" = "sha256-nVQC4ZaLWiZBUEReLqzpXKxXVxCdUW6b+mda9J8JSA0=";
    "ruff_python_trivia-0.0.0" = "sha256-nVQC4ZaLWiZBUEReLqzpXKxXVxCdUW6b+mda9J8JSA0=";
    "ruff_source_file-0.0.0" = "sha256-nVQC4ZaLWiZBUEReLqzpXKxXVxCdUW6b+mda9J8JSA0=";
    "ruff_text_size-0.0.0" = "sha256-nVQC4ZaLWiZBUEReLqzpXKxXVxCdUW6b+mda9J8JSA0=";
  };
  outputHashes = lib.filterAttrs (key: _:
    let
      parts = lib.splitString "-" key;
      crateName = lib.concatStringsSep "-" (lib.init parts);
      crateVersion = lib.last parts;
      # Check name AND version appear on adjacent lines in Cargo.lock so we
      # don't claim a hash for a crate at a version that isn't actually a git
      # dep in this release. rustPlatform errors if any listed key is absent.
      newline = "\n";
      pattern = ''name = "${crateName}"${newline}version = "${crateVersion}"'';
      hits = builtins.split pattern cargoLockText;
    in
    builtins.length hits > 1
  ) allOutputHashes;
in
pkgs.rustPlatform.buildRustPackage {
  pname = "ironclaw";
  inherit version;

  src = ironclaw-src;

  cargoLock = {
    lockFile = "${ironclaw-src}/Cargo.lock";
    inherit outputHashes;
  };

  # Workaround: monty crate uses `#[doc = include_str!("../../../README.md")]`
  # which references files outside its own crate dir. nix's git-dep cargo vendor
  # only ships the crate subtree, so the include path doesn't exist in the
  # vendor dir. Provide an empty README at the expected location.
  preBuild = ''
    touch /build/README.md || true
    for d in /build/cargo-vendor-dir/monty-*; do
      if [ -d "$d" ]; then
        mkdir -p "$d/../../.." 2>/dev/null || true
        touch "$d/../../../README.md" 2>/dev/null || true
      fi
    done
  '';

  nativeBuildInputs = [
    pkgs.pkg-config
    pkgs.python3
  ];

  buildInputs = [
    pkgs.openssl
    pkgs.python3
  ];

  # Skip cargo test in nix sandbox: ironclaw's test suite needs network,
  # NEAR AI account env vars, and writable home — all unavailable here. Run
  # the upstream test suite outside this derivation if needed.
  doCheck = false;

  meta = with lib; {
    description = "NEAR AI Ironclaw runtime (v${version})";
    homepage = "https://github.com/nearai/ironclaw";
    license = licenses.mit;
    mainProgram = "ironclaw";
    platforms = platforms.linux;
  };
}
