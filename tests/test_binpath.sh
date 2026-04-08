#!/usr/bin/env bash
# Negative eval test: app.binPath assertion must fire when app.package is set but binPath is empty
set -euo pipefail

PASS=0
FAIL=0

assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc" >&2
    FAIL=$((FAIL + 1))
  fi
}

FLAKE_DIR="${1:?Usage: $0 <path-to-ocsb-flake>}"

echo "=== app.binPath assertion test ==="

# Build an expression that sets app.package but NOT binPath — should fail
BUILD_OUTPUT=$(nix build --no-link --print-out-paths \
  --impure --expr "
    let
      flake = builtins.getFlake \"path:$FLAKE_DIR\";
      pkgs = import flake.inputs.nixpkgs { system = \"x86_64-linux\"; };
      mkSandbox = import $FLAKE_DIR/lib/mkSandbox.nix { inherit pkgs; lib = pkgs.lib; };
    in mkSandbox {
      app.name = \"test-binpath\";
      app.package = pkgs.hello;
    }
  " 2>&1) && BUILD_EXIT=0 || BUILD_EXIT=$?

assert "build fails when package set but binPath empty" [ "$BUILD_EXIT" -ne 0 ]

# Check that the error message mentions binPath
if echo "$BUILD_OUTPUT" | grep -q "binPath"; then
  echo "  PASS: error mentions binPath"
  PASS=$((PASS + 1))
else
  echo "  FAIL: error does not mention binPath" >&2
  FAIL=$((FAIL + 1))
fi

# Positive test: with binPath set, build should succeed
BUILD_OUTPUT2=$(nix build --no-link --print-out-paths \
  --impure --expr "
    let
      flake = builtins.getFlake \"path:$FLAKE_DIR\";
      pkgs = import flake.inputs.nixpkgs { system = \"x86_64-linux\"; };
      mkSandbox = import $FLAKE_DIR/lib/mkSandbox.nix { inherit pkgs; lib = pkgs.lib; };
    in mkSandbox {
      app.name = \"test-binpath-ok\";
      app.package = pkgs.hello;
      app.binPath = \"bin/hello\";
    }
  " 2>&1) && BUILD_EXIT2=0 || BUILD_EXIT2=$?

assert "build succeeds when package and binPath both set" [ "$BUILD_EXIT2" -eq 0 ]

echo ""
echo "=== binPath Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
