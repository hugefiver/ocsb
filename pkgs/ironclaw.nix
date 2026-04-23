{ pkgs, lib ? pkgs.lib, ironclaw-src ? pkgs.fetchFromGitHub {
    owner = "nearai";
    repo = "ironclaw";
    # TODO: keep this in sync with flake input pin if used standalone.
    rev = "9dcd8969a659f91f47f6d13d5bc5c5ff8f19f6d6";
    hash = lib.fakeHash;
  }
}:
pkgs.rustPlatform.buildRustPackage {
  pname = "ironclaw";
  version = "unstable";

  src = ironclaw-src;

  cargoLock = {
    lockFile = "${ironclaw-src}/Cargo.lock";
    outputHashes = {
      "monty-0.0.11" = "sha256-PRP8XcgeNVnc+2dWHxpizjvAtSjfqtkEXckXjPCRoJI=";
      "ruff_python_ast-0.0.0" = "sha256-nVQC4ZaLWiZBUEReLqzpXKxXVxCdUW6b+mda9J8JSA0=";
      "ruff_python_parser-0.0.0" = "sha256-nVQC4ZaLWiZBUEReLqzpXKxXVxCdUW6b+mda9J8JSA0=";
      "ruff_python_trivia-0.0.0" = "sha256-nVQC4ZaLWiZBUEReLqzpXKxXVxCdUW6b+mda9J8JSA0=";
      "ruff_source_file-0.0.0" = "sha256-nVQC4ZaLWiZBUEReLqzpXKxXVxCdUW6b+mda9J8JSA0=";
      "ruff_text_size-0.0.0" = "sha256-nVQC4ZaLWiZBUEReLqzpXKxXVxCdUW6b+mda9J8JSA0=";
    };
  };

  # Workaround: monty crate uses `#[doc = include_str!("../../../README.md")]`
  # which references files outside its own crate dir. nix's git-dep cargo vendor
  # only ships the crate subtree, so the include path doesn't exist in the
  # vendor dir. Provide an empty README at the expected location.
  preBuild = ''
    touch /build/README.md || true
    if [ -d /build/cargo-vendor-dir/monty-0.0.11 ]; then
      touch /build/cargo-vendor-dir/monty-0.0.11/../../../README.md 2>/dev/null || true
      mkdir -p /build/cargo-vendor-dir/monty-0.0.11/../../.. 2>/dev/null || true
      touch /build/cargo-vendor-dir/monty-0.0.11/../../../README.md 2>/dev/null || true
    fi
  '';

  nativeBuildInputs = [
    pkgs.pkg-config
    pkgs.python3
  ];

  buildInputs = [
    pkgs.openssl
    pkgs.python3
  ];

  meta = with lib; {
    description = "NEAR AI Ironclaw runtime";
    homepage = "https://github.com/nearai/ironclaw";
    license = licenses.mit;
    mainProgram = "ironclaw";
    platforms = platforms.linux;
  };
}
