#!/usr/bin/env bash
# Declarative programs API regression tests.
set -euo pipefail

FLAKE_DIR="$(realpath "${1:?Usage: $0 <path-to-ocsb-flake> [--case NAME]}")"
shift
TEST_CASE="all"
if [[ $# -gt 0 ]]; then
  if [[ $# -ne 2 || "$1" != "--case" ]]; then
    echo "Usage: $0 <path-to-ocsb-flake> [--case validation|runtime|backend-plan]" >&2
    exit 2
  fi
  TEST_CASE="$2"
fi

TEST_TMP="$(mktemp -d /tmp/ocsb-programs.XXXXXX)"
[[ "$TEST_TMP" == /tmp/ocsb-programs.* && -d "$TEST_TMP" ]] || {
  echo "test_programs: refusing unexpected temporary path: $TEST_TMP" >&2
  exit 1
}
cleanup() {
  [[ -n "${TEST_TMP:-}" && "$TEST_TMP" == /tmp/ocsb-programs.* && -d "$TEST_TMP" ]] || return 0
  find "$TEST_TMP" -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf -- "$TEST_TMP"
  if [[ -e "$TEST_TMP" || -L "$TEST_TMP" ]]; then
    echo "test_programs: fail-closed cleanup left $TEST_TMP" >&2
    return 1
  fi
}
trap cleanup EXIT

FIXTURE_NIX="$TEST_TMP/programs-fixture.nix"
cat > "$FIXTURE_NIX" <<'EOF'
{ flakeDir }:
let
  flake = builtins.getFlake "path:${flakeDir}";
  pkgs = import flake.inputs.nixpkgs { system = "x86_64-linux"; };
  lib = pkgs.lib;
  mkSandbox = import (flakeDir + "/lib/mkSandbox.nix") { inherit pkgs lib; };

  appPackage = pkgs.runCommand "ocsb-programs-app" { } ''
    mkdir -p "$out/libexec"
    cat > "$out/libexec/main" <<'SCRIPT'
#!${pkgs.bashInteractive}/bin/bash
set -euo pipefail

if ! IFS= read -r stdin_line; then
  stdin_line=""
fi

for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -f "$OCSB_DAEMON_MARKER" ]] && break
  sleep 0.05
done
[[ -f "$OCSB_DAEMON_MARKER" ]] || {
  printf '%s\n' 'daemon marker missing' >&2
  exit 80
}

mkdir -p /home/sandbox/.nix-profile/bin
printf '%s\n' '#!${pkgs.bashInteractive}/bin/bash' 'printf "%s\\n" PROFILE_PEER' \
  > /home/sandbox/.nix-profile/bin/peer
chmod 0755 /home/sandbox/.nix-profile/bin/peer

[[ "$(command -v peer)" == "/usr/bin/peer" ]] || {
  printf 'declared peer was shadowed: %s\n' "$(command -v peer)" >&2
  exit 81
}
[[ "$(peer call-main)" == "PEER_MAIN_HELPER" ]] || {
  printf '%s\n' 'peer could not call app-directory helper' >&2
  exit 82
}
if command -v hidden >/dev/null 2>&1; then
  printf '%s\n' 'undeclared package binary is visible' >&2
  exit 83
fi

set +e
peer_stdout="$(printf '%s\n' "$stdin_line" | PEER_EXIT_CODE=23 peer alpha beta)"
peer_rc=$?
set -e
[[ "$peer_stdout" == "PEER_STDOUT argv=alpha beta stdin=STDIN_PAYLOAD" ]] || {
  printf 'unexpected peer stdout: %s\n' "$peer_stdout" >&2
  exit 84
}
printf '%s\n' "$peer_stdout"
printf '%s\n' 'PROGRAMS_RUNTIME_OK'
exit "$peer_rc"
SCRIPT
    cat > "$out/libexec/main-helper" <<'SCRIPT'
#!${pkgs.bashInteractive}/bin/bash
printf '%s\n' 'DAEMON_MARKER' > "$OCSB_DAEMON_MARKER"
printf '%s\n' 'PEER_MAIN_HELPER'
SCRIPT
    chmod 0555 "$out/libexec/main" "$out/libexec/main-helper"
  '';

  peerPackage = pkgs.runCommand "ocsb-programs-peer-package" { } ''
    mkdir -p "$out/libexec"
    cat > "$out/libexec/name..with-dots" <<'SCRIPT'
#!${pkgs.bashInteractive}/bin/bash
set -euo pipefail

if [[ "''${1:-}" == "call-main" ]]; then
  exec main-helper
fi
if ! IFS= read -r stdin_line; then
  stdin_line=""
fi
printf 'PEER_STDOUT argv=%s %s stdin=%s\n' "''${1:-}" "''${2:-}" "$stdin_line"
printf '%s\n' 'PEER_STDERR' >&2
exit "''${PEER_EXIT_CODE:-0}"
SCRIPT
    cat > "$out/libexec/hidden" <<'SCRIPT'
#!${pkgs.bashInteractive}/bin/bash
printf '%s\n' 'HIDDEN'
SCRIPT
    chmod 0555 "$out/libexec/name..with-dots" "$out/libexec/hidden"
  '';

  directoryPackage = pkgs.runCommand "ocsb-programs-directory-package" { } ''
    mkdir -p "$out/bin/directory-target"
    chmod 0755 "$out/bin/directory-target"
  '';

  nonExecutablePackage = pkgs.runCommand "ocsb-programs-non-executable-package" { } ''
    mkdir -p "$out/bin"
    printf '%s\n' 'not executable' > "$out/bin/not-executable"
    chmod 0444 "$out/bin/not-executable"
  '';

  collisionPackage = pkgs.runCommand "ocsb-programs-collision-package" { } ''
    mkdir -p "$out/bin"
    cat > "$out/bin/collision" <<'SCRIPT'
#!${pkgs.bashInteractive}/bin/bash
exit 0
SCRIPT
    chmod 0555 "$out/bin/collision"
  '';

  danglingCollisionPackage = pkgs.runCommand "ocsb-programs-dangling-collision-package" { } ''
    mkdir -p "$out/bin"
    ln -s missing-target "$out/bin/dangling-collision"
  '';

  common = {
    app = {
      name = "programs-runtime";
      package = appPackage;
      binPath = "libexec/main";
      daemon = [ { command = "peer call-main"; restart = false; } ];
    };
    packages = [ pkgs.coreutils ];
    programs = {
      peer = { package = peerPackage; binPath = "libexec/name..with-dots"; };
    };
    workspace = {
      strategy = "direct";
      baseDir = ".ocsb";
      name = "_";
      sandboxDir = "/workspace";
    };
    backend.type = "bubblewrap";
    experimental.nixStoreMode = "closure";
    network.enable = null;
    env.OCSB_DAEMON_MARKER = "/workspace/daemon.marker";
    mounts.ro = [ ];
    mounts.rw = [ ];
  };

  withName = name: common // { app = common.app // { inherit name; }; };
in {
  runtime = mkSandbox common;
  backendPlanPodman = mkSandbox ((withName "programs-plan-podman") // {
    backend.type = "podman";
  });
  backendPlanNspawn = mkSandbox ((withName "programs-plan-nspawn") // {
    backend.type = "systemd-nspawn";
  });
  validation = {
    badName = mkSandbox (common // {
      programs."bad/name" = { package = peerPackage; binPath = "libexec/name..with-dots"; };
    });
    badDots = mkSandbox (common // {
      programs."bad..name" = { package = peerPackage; binPath = "libexec/name..with-dots"; };
    });
    whitespaceName = mkSandbox (common // {
      programs."white space" = { package = peerPackage; binPath = "libexec/name..with-dots"; };
    });
    leadingDashName = mkSandbox (common // {
      programs."-leading" = { package = peerPackage; binPath = "libexec/name..with-dots"; };
    });
    emptyPath = mkSandbox (common // {
      programs.empty = { package = peerPackage; binPath = ""; };
    });
    absolutePath = mkSandbox (common // {
      programs.absolute = { package = peerPackage; binPath = "/libexec/name..with-dots"; };
    });
    parentPath = mkSandbox (common // {
      programs.parent = { package = peerPackage; binPath = "libexec/../peer"; };
    });
    duplicate = mkSandbox (common // {
      programs = lib.mkMerge [
        { duplicate = { package = peerPackage; binPath = "libexec/name..with-dots"; }; }
        { duplicate = { package = appPackage; binPath = "libexec/main"; }; }
      ];
    });
    validDottedPath = mkSandbox (common // {
      programs.dotted = { package = peerPackage; binPath = "libexec/name..with-dots"; };
    });
    missing = mkSandbox (common // {
      programs.missing = { package = peerPackage; binPath = "libexec/absent"; };
    });
    directory = mkSandbox (common // {
      programs.directory = { package = directoryPackage; binPath = "bin/directory-target"; };
    });
    nonExecutable = mkSandbox (common // {
      programs.nonExecutable = { package = nonExecutablePackage; binPath = "bin/not-executable"; };
    });
    collision = mkSandbox (common // {
      packages = [ pkgs.coreutils collisionPackage ];
      programs.collision = { package = peerPackage; binPath = "libexec/name..with-dots"; };
    });
    danglingCollision = mkSandbox (common // {
      packages = [ pkgs.coreutils danglingCollisionPackage ];
      programs.dangling-collision = { package = peerPackage; binPath = "libexec/name..with-dots"; };
    });
  };
}
EOF

build_fixture() {
  local attr="$1"
  nix build --no-link --print-out-paths --impure \
    --file "$FIXTURE_NIX" --argstr flakeDir "$FLAKE_DIR" "$attr"
}

expect_fixture_failure() {
  local attr="$1"
  local expected="$2"
  local output rc
  set +e
  output="$(build_fixture "validation.$attr" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && grep -Fq -- "$expected" <<<"$output"; then
    return 0
  fi
  printf 'test_programs: validation.%s did not fail closed for %s\n' "$attr" "$expected" >&2
  printf '%s\n' "$output" >&2
  return 1
}

expect_fixture_success() {
  local attr="$1"
  local output
  output="$(build_fixture "validation.$attr" 2>&1)" || {
    printf 'test_programs: validation.%s unexpectedly failed\n%s\n' "$attr" "$output" >&2
    return 1
  }
}

validation_case() {
  echo "=== declarative programs validation ==="
  expect_fixture_failure badName "programs command names" || return 1
  expect_fixture_failure badDots "programs command names" || return 1
  expect_fixture_failure whitespaceName "programs command names" || return 1
  expect_fixture_failure leadingDashName "programs command names" || return 1
  expect_fixture_failure emptyPath "binPath" || return 1
  expect_fixture_failure absolutePath "binPath" || return 1
  expect_fixture_failure parentPath "binPath" || return 1
  expect_fixture_failure duplicate "programs.duplicate.package" || return 1
  expect_fixture_success validDottedPath || return 1
  expect_fixture_failure missing "target does not exist" || return 1
  expect_fixture_failure directory "target is not a regular file" || return 1
  expect_fixture_failure nonExecutable "target is not executable" || return 1
  expect_fixture_failure collision "collides with an existing /usr/bin command" || return 1
  expect_fixture_failure danglingCollision "collides with an existing /usr/bin command" || return 1
  echo 'PASS[GREEN-programs-validation]: names duplicates paths missing regular-file executability collisions dangling-collisions fail closed'
}

runtime_case() {
  local build_output runtime_store runtime_bin runtime_stdout runtime_stderr runtime_rc
  local closure named_programs_bin alias_count project state_base

  echo "=== declarative programs bubblewrap runtime ==="
  build_output="$(build_fixture runtime 2>&1)" || {
    printf '%s\n' "$build_output" >&2
    return 1
  }
  runtime_store="${build_output##*$'\n'}"
  runtime_bin="$runtime_store/bin/programs-runtime"
  project="$TEST_TMP/runtime-project"
  state_base="$TEST_TMP/runtime-state"
  runtime_stdout="$TEST_TMP/runtime.stdout"
  runtime_stderr="$TEST_TMP/runtime.stderr"
  mkdir -p "$project" "$state_base"

  set +e
  (
    cd "$project"
    printf '%s\n' 'STDIN_PAYLOAD' | OCSB_STATE_BASE_DIR="$state_base" "$runtime_bin" \
      --strategy direct --overwrite >"$runtime_stdout" 2>"$runtime_stderr"
  )
  runtime_rc=$?
  set -e

  [[ "$runtime_rc" -eq 23 ]] || {
    echo "test_programs: runtime exit was $runtime_rc, expected 23" >&2
    cat "$runtime_stdout" "$runtime_stderr" >&2
    return 1
  }
  grep -Fxq 'PEER_STDOUT argv=alpha beta stdin=STDIN_PAYLOAD' "$runtime_stdout"
  grep -Fxq 'PROGRAMS_RUNTIME_OK' "$runtime_stdout"
  grep -Fxq 'PEER_STDERR' "$runtime_stderr"
  grep -Fxq 'DAEMON_MARKER' "$project/daemon.marker"

  closure="$TEST_TMP/runtime.closure"
  nix-store -qR "$runtime_store" > "$closure"
  grep -Eq -- '-programs-runtime-package-bin$' "$closure"
  named_programs_bin="$(grep -E -- '-programs-runtime-named-programs-bin$' "$closure" | tail -n1)"
  grep -Eq -- '-programs-runtime-sandbox-bin$' "$closure"
  [[ -n "$named_programs_bin" && -d "$named_programs_bin/bin" ]] || {
    echo "test_programs: named command directory is absent from the closure" >&2
    return 1
  }
  alias_count="$(find "$named_programs_bin/bin" -mindepth 1 -maxdepth 1 -type l | wc -l)"
  [[ "$alias_count" -eq 1 && -L "$named_programs_bin/bin/peer" && ! -e "$named_programs_bin/bin/hidden" ]] || {
    echo "test_programs: named command directory exposed more than declared aliases" >&2
    return 1
  }

  echo 'PASS[GREEN-programs-runtime]: libexec-main peer-argv-stdin-stdout-stderr-exit-23 daemon-peer-main-helper hidden-absent profile-priority'
}

write_fake_backend() {
  local path="$1"
  cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--remote=false" && "${2:-}" == "unshare" ]]; then
  shift 2
  if [[ "$(id -u)" -ne 0 ]]; then
    exec unshare --user --map-root-user -- "$@"
  fi
  exec "$@"
fi
printf '%s\n' "$@" > "${OCSB_PROGRAMS_BACKEND_PLAN:?}"
SCRIPT
  chmod 0755 "$path"
}

run_backend_plan() {
  local backend="$1"
  local wrapper="$2"
  local project="$3"
  local state_base="$4"
  local fake_bin="$5"
  local plan="$6"
  local output rc

  set +e
  if [[ "$backend" == "systemd-nspawn" && "$(id -u)" -ne 0 ]]; then
    output="$(
      cd "$project"
      PATH="$fake_bin:$PATH" OCSB_STATE_BASE_DIR="$state_base" OCSB_PROGRAMS_BACKEND_PLAN="$plan" \
        unshare --user --map-current-user --mount --keep-caps --fork -- \
        "$wrapper" --strategy direct --overwrite -- ignored 2>&1
    )"
  else
    output="$(
      cd "$project"
      PATH="$fake_bin:$PATH" OCSB_STATE_BASE_DIR="$state_base" OCSB_PROGRAMS_BACKEND_PLAN="$plan" \
        "$wrapper" --strategy direct --overwrite -- ignored 2>&1
    )"
  fi
  rc=$?
  set -e
  if [[ "$rc" -ne 0 || ! -s "$plan" ]]; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

backend_plan_case() {
  local podman_output nspawn_output podman_store nspawn_store podman_bin nspawn_bin
  local project fake_bin podman_state nspawn_state podman_plan nspawn_plan podman_mounts nspawn_mounts

  echo "=== declarative programs backend plan ==="
  podman_output="$(build_fixture backendPlanPodman 2>&1)" || {
    printf '%s\n' "$podman_output" >&2
    return 1
  }
  nspawn_output="$(build_fixture backendPlanNspawn 2>&1)" || {
    printf '%s\n' "$nspawn_output" >&2
    return 1
  }
  podman_store="${podman_output##*$'\n'}"
  nspawn_store="${nspawn_output##*$'\n'}"
  podman_bin="$podman_store/bin/programs-plan-podman"
  nspawn_bin="$nspawn_store/bin/programs-plan-nspawn"
  project="$TEST_TMP/backend-project"
  fake_bin="$TEST_TMP/fake-backends"
  podman_state="$TEST_TMP/podman-state"
  nspawn_state="$TEST_TMP/nspawn-state"
  podman_plan="$TEST_TMP/podman.plan"
  nspawn_plan="$TEST_TMP/nspawn.plan"
  mkdir -p "$project" "$fake_bin" "$podman_state" "$nspawn_state"
  write_fake_backend "$fake_bin/podman"
  write_fake_backend "$fake_bin/systemd-nspawn"

  run_backend_plan podman "$podman_bin" "$project" "$podman_state" "$fake_bin" "$podman_plan" || return 1
  run_backend_plan systemd-nspawn "$nspawn_bin" "$project" "$nspawn_state" "$fake_bin" "$nspawn_plan" || return 1

  podman_mounts="$(grep -Ec ':/usr/bin:ro$' "$podman_plan")"
  nspawn_mounts="$(grep -Ec '^--bind-ro=.*:/usr/bin$' "$nspawn_plan")"
  [[ "$podman_mounts" -eq 1 && "$nspawn_mounts" -eq 1 ]] || {
    echo "test_programs: backends did not receive one shared /usr/bin mount" >&2
    cat "$podman_plan" "$nspawn_plan" >&2
    return 1
  }
  grep -Eq '^PATH=.*/libexec:/usr/bin:/home/sandbox/\.nix-profile/bin:/nix/var/nix/profiles/default/bin$' "$podman_plan"
  grep -Eq '^--setenv=PATH=.*/libexec:/usr/bin:/home/sandbox/\.nix-profile/bin:/nix/var/nix/profiles/default/bin$' "$nspawn_plan"

  echo 'PASS[GREEN-programs-backend-plan]: podman-and-nspawn-share-one-public-usr-bin-and-deterministic-path'
}

case "$TEST_CASE" in
  all)
    validation_case
    runtime_case
    backend_plan_case
    ;;
  validation)
    validation_case
    ;;
  runtime)
    runtime_case
    ;;
  backend-plan)
    backend_plan_case
    ;;
  *)
    echo "unknown test case: $TEST_CASE" >&2
    exit 2
    ;;
esac
