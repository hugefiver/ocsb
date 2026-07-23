#!/usr/bin/env bash
# Deterministic TOCTOU harness for the mount-anchor helper.  Fixture content is
# always external to the checkout so this test never leaves generated files in
# the repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SKIP_MARKER="SKIP[CI-REQUIRED-mount-anchor]: user namespace unavailable"

CASE_DIR=""
ACTIVE_FIXTURE=""
TEMP_FIXTURE=""
CI_FAKE_MODE=0
declare -a FIXTURE_PIDS=()

usage() {
  cat >&2 <<'EOF'
usage:
  tests/test_mount_anchor.sh --prepare FIXTURE
  tests/test_mount_anchor.sh --case deterministic-swap FIXTURE [--helper PATH]
  tests/test_mount_anchor.sh --case optional-source-absent FIXTURE
  tests/test_mount_anchor.sh --case nested-symlink FIXTURE
  tests/test_mount_anchor.sh --case real-runtime-secondary FIXTURE
  tests/test_mount_anchor.sh --case real-rootless-podman OCSB
  tests/test_mount_anchor.sh --case workspace-mutation-parent-swap FIXTURE
  tests/test_mount_anchor.sh --case git-mid-command-swap FIXTURE
  tests/test_mount_anchor.sh --case receipt-consume-cas FIXTURE
  tests/test_mount_anchor.sh --case receipt-retain-retire FIXTURE
  tests/test_mount_anchor.sh --case test-evidence FIXTURE
  tests/test_mount_anchor.sh --case workspace-post-mutation-swap FIXTURE
  tests/test_mount_anchor.sh --case inherited-fd-handoff-auto FIXTURE
  tests/test_mount_anchor.sh --ci-fake

FIXTURE must be an absolute path outside this checkout.  --prepare uses the
locked Nix toolchain to compile the fake runtime and manifest-unit helper,
then Nix-builds lightweight ocsb launchers.
Without --helper, deterministic-swap exercises those generated launchers.
With --helper, it calls the helper directly with the fixture mount manifest;
that mode is the stable helper-interface probe for the post-fix implementation.
EOF
  exit 2
}

cleanup() {
  local original_status=$?
  local signal_status="${1:-}"
  local cleanup_status=0
  local final_status
  local pid

  # Do not re-enter the EXIT handler while reporting an invariant failure.
  trap - EXIT HUP INT TERM
  for pid in "${FIXTURE_PIDS[@]}"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${FIXTURE_PIDS[@]}"; do
    [[ -n "$pid" ]] || continue
    wait "$pid" 2>/dev/null || true
  done
  remove_case_dir
  if [[ -n "$ACTIVE_FIXTURE" ]]; then
    clear_mount_sources "$ACTIVE_FIXTURE"
    rm -rf -- "$ACTIVE_FIXTURE/rootfs" "$ACTIVE_FIXTURE/project/.ocsb" \
      "$ACTIVE_FIXTURE/project/.ocsb-original"
    rm -rf -- "$ACTIVE_FIXTURE/runtime/anchors"/unit-*
    rm -f -- "$ACTIVE_FIXTURE/runtime/ocsb"/process-*.pid 2>/dev/null || true
    if [[ -d "$ACTIVE_FIXTURE/runtime/anchors" && -d "$ACTIVE_FIXTURE/runtime/ocsb/anchors" ]]; then
      if ! assert_host_anchors_empty "$ACTIVE_FIXTURE"; then
        cleanup_status=1
      fi
    fi
  fi
  if [[ -n "$TEMP_FIXTURE" ]]; then
    rm -rf -- "$TEMP_FIXTURE"
  fi
  if [[ -n "$signal_status" ]]; then
    final_status="$signal_status"
  elif [[ "$original_status" -ne 0 ]]; then
    final_status="$original_status"
  else
    final_status="$cleanup_status"
  fi
  exit "$final_status"
}
trap 'cleanup' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

canonical_external_fixture() {
  local requested="${1:?fixture path is required}"
  local resolved

  [[ "$requested" == /* ]] || {
    echo "test_mount_anchor: fixture path must be absolute" >&2
    return 2
  }
  resolved="$(realpath -m -- "$requested")"
  case "$resolved" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
      echo "test_mount_anchor: refusing fixture inside the repository" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$resolved"
}

write_fake_backend() {
  local path="$1"
  local backend="$2"
  local runtime="$3"

  printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$runtime" "$backend" > "$path"
  chmod 0755 "$path"
}

write_fake_podman() {
  local path="$1"
  local runtime="$2"

  cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == --remote=false && "\${2:-}" == unshare ]]; then
  shift 2
  helper="\${1:?fake podman unshare requires a helper}"
  shift
  if [[ "\$(id -u)" -ne 0 ]]; then
    exec unshare --user --map-root-user -- "\$helper" "\$@"
  fi
  exec "\$helper" "\$@"
fi

exec ${runtime@Q} podman "\$@"
EOF
  chmod 0755 "$path"
}

clear_mount_sources() {
  local fixture="$1"

  rm -rf -- "$fixture/mount-directory"
  rm -f -- "$fixture/mount-file"
}

assert_host_anchors_empty() {
  local fixture="$1"
  local anchor_dir

  for anchor_dir in "$fixture/runtime/anchors" "$fixture/runtime/ocsb/anchors"; do
    [[ -d "$anchor_dir" ]] || {
      echo "test_mount_anchor: missing host anchor directory: $anchor_dir" >&2
      return 1
    }
    if find "$anchor_dir" -mindepth 1 -print -quit | grep -q .; then
      echo "test_mount_anchor: private runtime anchors leaked into the host namespace: $anchor_dir" >&2
      return 1
    fi
  done
}

assert_workspace_receipts_consumed() {
  local state="$1"
  local entry kind count=0 guard_count=0 spent_count=0

  while IFS= read -r -d '' entry; do
    count=$((count + 1))
    if [[ -L "$entry" || ! -f "$entry" || "$(stat -c %u -- "$entry")" != "$(id -u)" ||
          "$(stat -c %a -- "$entry")" != 600 || "$(stat -c %s -- "$entry")" != 0 ]]; then
      echo "test_mount_anchor: live workspace receipt or unsafe consumption guard remained: $entry" >&2
      return 1
    fi
    kind="${entry##*/}"
    case "$kind" in
      *.guard.[0-9][0-9]) guard_count=$((guard_count + 1)) ;;
      *.spent.[0-9][0-9]) spent_count=$((spent_count + 1)) ;;
      *)
        echo "test_mount_anchor: workspace receipt has an unexpected retained name: $entry" >&2
        return 1
        ;;
    esac
  done < <(find "$state" -maxdepth 1 -name '.workspace-receipt-*' -print0)
  if [[ "$count" -ne 0 &&
    ( "$count" -ne 2 || "$guard_count" -ne 1 || "$spent_count" -ne 1 ) ]]; then
    echo "test_mount_anchor: consumed receipt did not retain one guard and one spent artifact: $state" >&2
    return 1
  fi
}

remove_case_dir() {
  if [[ -n "$CASE_DIR" ]]; then
    find "$CASE_DIR" -type d -exec chmod u+w {} + 2>/dev/null || true
    rm -rf -- "$CASE_DIR"
    CASE_DIR=""
  fi
}

prepare_fixture() {
  local fixture
  local build_file
  local output

  fixture="$(canonical_external_fixture "$1")"
  command -v nix >/dev/null 2>&1 || {
    echo "test_mount_anchor: nix is required to build lightweight launchers" >&2
    return 1
  }

  install -d -m 0700 "$fixture/fake-bin" "$fixture/runtime" "$fixture/project"
  install -d -m 0700 "$fixture/runtime/anchors" "$fixture/runtime/ocsb" \
    "$fixture/runtime/ocsb/anchors"

  build_file="$fixture/build-mount-anchor-launchers.nix"
  cat > "$build_file" <<'EOF'
let
  flake = builtins.getFlake ("path:" + builtins.getEnv "OCSB_MOUNT_ANCHOR_REPO");
  sourceDirectory = builtins.getEnv "OCSB_FAKE_ANCHOR_DIRECTORY";
  sourceFile = builtins.getEnv "OCSB_FAKE_ANCHOR_FILE";
  pkgs = import flake.inputs.nixpkgs {
    system = builtins.currentSystem;
  };
  mkStrictC = name: source: extraFlags:
    pkgs.stdenv.mkDerivation {
      inherit name;
      src = flake.outPath;
      nativeBuildInputs = [ pkgs.coreutils ];
      dontConfigure = true;
      buildPhase = ''
        $CC -std=c17 -Wall -Wextra -Werror ${extraFlags} \
          ${pkgs.lib.escapeShellArg "${flake.outPath}/${source}"} -o "$name"
      '';
      installPhase = ''
        install -Dm0755 "$name" "$out/bin/$name"
      '';
    };
  fakeRuntime = mkStrictC "fake-anchor-runtime" "tests/fixtures/fake-anchor-runtime.c" "";
  manifestUnitHelper = mkStrictC "ocsb-mount-anchor-manifest-unit" "pkgs/ocsb-mount-anchor.c" "-DOCSB_MOUNT_ANCHOR_MANIFEST_UNIT=1";
   testHooksHelperBinary = mkStrictC "ocsb-mount-anchor-test-hooks" "pkgs/ocsb-mount-anchor.c" "-DOCSB_MOUNT_ANCHOR_TEST_HOOKS=1";
   testHooksManifestHelperBinary = mkStrictC "ocsb-mount-anchor-test-hooks-manifest" "pkgs/ocsb-mount-anchor.c" "-DOCSB_MOUNT_ANCHOR_TEST_HOOKS=1 -DOCSB_MOUNT_ANCHOR_MANIFEST_UNIT=1";
  testHooksHelper = pkgs.runCommand "ocsb-mount-anchor-test-hooks-helper" { } ''
    mkdir -p "$out/bin"
    ln -s ${testHooksHelperBinary}/bin/ocsb-mount-anchor-test-hooks "$out/bin/ocsb-mount-anchor"
  '';
  mountAnchor = pkgs.callPackage (flake.outPath + "/pkgs/mount-anchor.nix") { };
  fakeBubblewrap = pkgs.writeShellScriptBin "bwrap" ''
      exec ${fakeRuntime}/bin/fake-anchor-runtime bubblewrap "$@"
    '';
  fakePkgs = import flake.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ (_: _: { bubblewrap = fakeBubblewrap; }) ];
  };
  mkSandbox = selectedPkgs: helper: hookMode: import (flake.outPath + "/lib/mkSandbox.nix") {
    pkgs = selectedPkgs;
    lib = selectedPkgs.lib;
    mountAnchorHelper = helper;
    mountAnchorTestHookMode = hookMode;
  };
  mk = selectedPkgs: backend: name: helper: hookMode: (mkSandbox selectedPkgs helper hookMode) {
    app.name = name;
    packages = [ selectedPkgs.coreutils ];
    workspace = {
      strategy = "direct";
      baseDir = ".ocsb";
      name = "mount-anchor";
    };
    backend.type = backend;
    network.enable = false;
    env = { };
    mounts = {
      ro = [ sourceDirectory sourceFile ];
      rw = [ ];
    };
    experimental.nixStoreMode = "closure";
  };
in {
  bundle = pkgs.symlinkJoin {
    name = "ocsb-mount-anchor-fixture-launchers";
    paths = [
      fakeRuntime
      manifestUnitHelper
      testHooksHelperBinary
      testHooksManifestHelperBinary
      mountAnchor
      (mk fakePkgs "bubblewrap" "ocsb-mount-anchor-bubblewrap" null "none")
      (mk fakePkgs "podman" "ocsb-mount-anchor-podman" null "none")
      (mk fakePkgs "systemd-nspawn" "ocsb-mount-anchor-nspawn" null "none")
      (mk pkgs "bubblewrap" "ocsb-mount-anchor-real-bubblewrap" null "none")
      (mk fakePkgs "bubblewrap" "ocsb-mount-anchor-workspace-mutation" testHooksHelper "mutation")
      (mk fakePkgs "bubblewrap" "ocsb-mount-anchor-workspace-post-mutation" testHooksHelper "final")
    ];
  };
}
EOF

  output="$(OCSB_MOUNT_ANCHOR_REPO="$REPO_ROOT" \
    OCSB_FAKE_ANCHOR_DIRECTORY="$fixture/mount-directory" \
    OCSB_FAKE_ANCHOR_FILE="$fixture/mount-file" \
    nix build --impure --no-link --print-out-paths --file "$build_file" bundle)"
  rm -f -- "$fixture/launchers"
  ln -s -- "$output" "$fixture/launchers"
  write_fake_backend "$fixture/fake-bin/bwrap" bubblewrap "$fixture/launchers/bin/fake-anchor-runtime"
  write_fake_podman "$fixture/fake-bin/podman" "$fixture/launchers/bin/fake-anchor-runtime"
  write_fake_backend "$fixture/fake-bin/systemd-nspawn" nspawn "$fixture/launchers/bin/fake-anchor-runtime"
  verify_test_hook_helper_abi "$fixture"
  printf '%s\n' "$fixture"
}

require_prepared_fixture() {
  local fixture="$1"

  [[ -x "$fixture/launchers/bin/fake-anchor-runtime" &&
    -x "$fixture/launchers/bin/ocsb-mount-anchor" &&
    -x "$fixture/launchers/bin/ocsb-mount-anchor-manifest-unit" &&
    -x "$fixture/launchers/bin/ocsb-mount-anchor-test-hooks" &&
    -x "$fixture/launchers/bin/ocsb-mount-anchor-test-hooks-manifest" &&
    -d "$fixture/fake-bin" &&
    -x "$fixture/launchers/bin/ocsb-mount-anchor-bubblewrap" &&
    -x "$fixture/launchers/bin/ocsb-mount-anchor-podman" &&
    -x "$fixture/launchers/bin/ocsb-mount-anchor-nspawn" &&
    -x "$fixture/launchers/bin/ocsb-mount-anchor-real-bubblewrap" &&
    -x "$fixture/launchers/bin/ocsb-mount-anchor-workspace-mutation" &&
    -x "$fixture/launchers/bin/ocsb-mount-anchor-workspace-post-mutation" ]] || {
    echo "test_mount_anchor: fixture is not prepared; run --prepare first" >&2
    return 2
  }
}

verify_test_hook_helper_abi() {
  local fixture="$1"
  local option output

  if output="$("$fixture/launchers/bin/ocsb-mount-anchor" \
    --test-before-receipt-open-ready-fd 5 2>&1)"; then
    echo 'test_mount_anchor: production mount-anchor accepted a test-only option' >&2
    return 1
  fi
  [[ "$output" == *'unknown option: --test-before-receipt-open-ready-fd'* ]] || {
    echo 'test_mount_anchor: production mount-anchor did not reject the test-only option as unknown' >&2
    return 1
  }

  if output="$("$fixture/launchers/bin/ocsb-mount-anchor" \
    --test-before-mutation-ready-fd 3 2>&1)"; then
    echo 'test_mount_anchor: production mount-anchor accepted a mutation test-only option' >&2
    return 1
  fi
  [[ "$output" == *'unknown option: --test-before-mutation-ready-fd'* ]] || {
    echo 'test_mount_anchor: production mount-anchor did not reject the mutation test-only option as unknown' >&2
    return 1
  }

  if output="$("$fixture/launchers/bin/ocsb-mount-anchor" \
    --test-before-receipt-consume-ready-fd 3 2>&1)"; then
    echo 'test_mount_anchor: production mount-anchor accepted a receipt-consume test-only option' >&2
    return 1
  fi
  [[ "$output" == *'unknown option: --test-before-receipt-consume-ready-fd'* ]] || {
    echo 'test_mount_anchor: production mount-anchor did not reject receipt-consume test controls' >&2
    return 1
  }

  for option in \
    --test-before-inherited-mutation-open-ready-fd \
    --test-before-inherited-mutation-open-release-fd \
    --test-before-inherited-final-open-ready-fd \
    --test-before-inherited-final-open-release-fd \
    --test-after-moved-guard-validation-ready-fd \
    --test-after-moved-guard-validation-release-fd \
    --test-after-quarantined-receipt-validation-ready-fd \
    --test-after-quarantined-receipt-validation-release-fd; do
    if output="$("$fixture/launchers/bin/ocsb-mount-anchor" "$option" 3 2>&1)"; then
      echo "test_mount_anchor: production mount-anchor accepted test-only option: $option" >&2
      return 1
    fi
    [[ "$output" == *"unknown option: $option"* ]] || {
      echo "test_mount_anchor: production mount-anchor did not reject test-only option: $option" >&2
      return 1
    }
  done

  if output="$("$fixture/launchers/bin/ocsb-mount-anchor-test-hooks" \
    --test-before-mutation-ready-fd 3 \
    --test-before-mutation-release-fd 4 \
    --test-before-receipt-open-ready-fd 5 \
    --test-before-receipt-open-release-fd 6 \
    --test-after-moved-guard-validation-ready-fd 7 \
    --test-after-moved-guard-validation-release-fd 8 \
    --test-after-quarantined-receipt-validation-ready-fd 9 \
    --test-after-quarantined-receipt-validation-release-fd 10 2>&1)"; then
    echo 'test_mount_anchor: test-hooks mount-anchor unexpectedly accepted an incomplete manifest' >&2
    return 1
  fi
  [[ "$output" != *'unknown option:'* && "$output" == *'missing required mount-anchor arguments'* ]] || {
    echo 'test_mount_anchor: test-hooks mount-anchor did not parse every test-only option' >&2
    return 1
  }
}

inherited_fd_spec() {
  local role="$1" display="$2" fd="$3" kind="$4"
  local device inode
  device="$(stat -Lc %d -- "/proc/self/fd/$fd")"
  inode="$(stat -Lc %i -- "/proc/self/fd/$fd")"
  printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s' "$role" "$display" "$fd" "$device" "$inode" "$kind"
}

task18_tree_fingerprint() {
  local root="$1"
  {
    find "$root" -xdev -printf '%P\t%y\t%i\t%m\n'
    find "$root" -xdev -type f -exec sha256sum {} \;
  } | LC_ALL=C sort | sha256sum | cut -d ' ' -f 1
}

task18_replacement_fingerprint() {
  local home="$1" data="$2" state="$3"

  {
    task18_tree_fingerprint "$home"
    task18_tree_fingerprint "$data"
    task18_tree_fingerprint "$state"
  } | sha256sum | cut -d ' ' -f 1
}

write_task18_backend() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
for arg in "${args[@]}"; do
  [[ ! "$arg" =~ /proc/(self|[0-9]+)/fd/ ]] || exit 81
done
for fd_path in /proc/"$BASHPID"/fd/*; do
  fd="${fd_path##*/}"
  [[ "$fd" =~ ^[0-9]+$ && "$fd" -gt 2 ]] || continue
  target="$(readlink "$fd_path" 2>/dev/null || true)"
  case "$target" in
    "$OCSB_TASK18_ORIGINAL_HOME"|"$OCSB_TASK18_ORIGINAL_DATA"|"$OCSB_TASK18_ORIGINAL_STATE"|"$OCSB_TASK18_ORIGINAL_DB") exit 82 ;;
  esac
done
(
  for fd in $(seq 3 255); do eval "exec $fd>&-" 2>/dev/null || :; done
  declare -A sources=()
  index=0
  while (( index < ${#args[@]} )); do
    if [[ "${args[$index]}" == --ro-bind ]]; then
      source="${args[$((index + 1))]}"
      destination="${args[$((index + 2))]}"
      [[ "$source" == "$FAKE_ANCHOR_PRIVATE_PREFIX"* && "$source" != /proc/* ]] || exit 83
      sources["$destination"]="$source"
      index=$((index + 3))
    else
      index=$((index + 1))
    fi
  done
  [[ "$(cat "${sources[/workspace]}/task18-canary")" == original ]]
  [[ "$(cat "${sources[/data]}/task18-canary")" == original ]]
  [[ "$(cat "${sources[/state]}/task18-canary")" == original ]]
  [[ "$(cat "${sources[/db-env]}")" == original-db-env ]]
  printf 'home=original\ndata=original\nstate=original\ndb-env=original\nargv=no-proc\nanchors=private\nfds=closed\n' > "$OCSB_TASK18_BACKEND_RESULT"
)
EOF
  chmod 0755 "$path"
}

inherited_fd_handoff_case() {
  local fixture="$1" helper case_root public home data state db workspace nonce receipt git_bin
  local home_spec state_spec data_spec db_spec mutation_spec mutation_ready mutation_release
  local final_ready final_release mutation_pid final_pid mutation_rc final_rc backend result
  local home_source data_source state_source db_source home_source_spec data_source_spec
  local state_source_spec db_source_spec uid gid replacement1_before replacement1_after
  local replacement2_before replacement2_after source_text
  local home_fd data_fd state_fd db_fd mrfd mlfd frfd flfd
  local -a inherited_args mutation_args final_args payload

  if [[ ! -x "$fixture/launchers/bin/ocsb-mount-anchor-test-hooks" ]]; then
    prepare_fixture "$fixture" >/dev/null
  fi
  require_prepared_fixture "$fixture"
  ACTIVE_FIXTURE="$fixture"
  helper="$fixture/launchers/bin/ocsb-mount-anchor-test-hooks"
  set +e
  "$helper" --inherited-fd-spec invalid >"$fixture/task18-capability.out" 2>&1
  local capability_rc=$?
  set -e
  if grep -Fq 'unknown option: --inherited-fd-spec' "$fixture/task18-capability.out"; then
    echo 'FAIL[RED-inherited-mutation-helper]: mutation helper reopened public project or state roots'
    echo 'FAIL[RED-inherited-final-helper]: final helper reopened public home,data,state,db-env roots'
    echo 'FAIL[RED-inherited-spec-forwarding]: mutation or final helper omitted the all-four inherited spec set'
    return 1
  fi
  [[ "$capability_rc" -ne 0 ]] || return 1

  require_user_namespace || return $?
  case_root="$(mktemp -d "$fixture/inherited-fd.XXXXXX")"
  CASE_DIR="$case_root"
  public="$case_root/public"
  home="$public/home"; data="$public/data"; state="$public/state"; db="$state/ironclaw-db.env"
  workspace=task18-workspace
  nonce=1818181818181818181818181818181818181818181818181818181818181818
  install -d -m 0700 "$home/.ocsb/$workspace" "$data" "$state/$workspace" "$fixture/runtime/ocsb/anchors"
  printf 'original\n' > "$home/task18-canary"
  printf 'original-workspace\n' > "$home/.ocsb/$workspace/original-marker"
  printf 'original\n' > "$data/task18-canary"
  printf 'original\n' > "$state/task18-canary"
  printf 'original-db-env\n' > "$db"; chmod 0600 "$db"

  exec {home_fd}<"$home"; exec {data_fd}<"$data"; exec {state_fd}<"$state"; exec {db_fd}<"$db"
  home_spec="$(inherited_fd_spec project "$home" "$home_fd" directory)"
  state_spec="$(inherited_fd_spec state-base "$state" "$state_fd" directory)"
  data_spec="$(inherited_fd_spec mount "$data" "$data_fd" directory)"
  db_spec="$(inherited_fd_spec mount "$db" "$db_fd" regular)"
  inherited_args=(--inherited-fd-spec "$home_spec" --inherited-fd-spec "$state_spec"
    --inherited-fd-spec "$data_spec" --inherited-fd-spec "$db_spec")
  receipt="$state/$workspace/.workspace-receipt-$nonce"
  printf -v mutation_spec 'v1\t%s\t%s\t%s\t%s\t.ocsb\t%s\toverwrite\tdirect\tdirect\tbubblewrap\t%s' \
    "$nonce" "$home" "$(stat -Lc %d /proc/self/fd/$home_fd)" "$(stat -Lc %i /proc/self/fd/$home_fd)" \
    "$workspace" "$state/$workspace"
  git_bin="$(command -v git)"
  mutation_ready="$case_root/mutation.ready"; mutation_release="$case_root/mutation.release"
  mkfifo "$mutation_ready" "$mutation_release"
  exec {mrfd}<>"$mutation_ready"; exec {mlfd}<>"$mutation_release"
  mutation_args=(--mutation-only "${inherited_args[@]}" --mutation-spec "$mutation_spec"
    --workspace-receipt "$receipt" --git-bin "$git_bin"
    --test-before-inherited-mutation-open-ready-fd "$mrfd"
    --test-before-inherited-mutation-open-release-fd "$mlfd")
  "$helper" "${mutation_args[@]}" >"$case_root/mutation.stdout" 2>"$case_root/mutation.stderr" &
  mutation_pid=$!; track_fixture_pid "$mutation_pid"
  read -r -n 1 -t 30 _ <&"$mrfd"

  mv "$home" "$public/home.original"; mv "$data" "$public/data.original"; mv "$state" "$public/state.original"
  install -d -m 0700 "$home/.ocsb/$workspace" "$data" "$state/$workspace"
  printf 'replacement-1\n' > "$home/task18-canary"
  printf 'replacement-1-workspace\n' > "$home/.ocsb/$workspace/replacement-marker"
  printf 'replacement-1\n' > "$data/task18-canary"
  printf 'replacement-1\n' > "$state/task18-canary"
  printf 'replacement-1-db-env\n' > "$db"; chmod 0600 "$db"
  replacement1_before="$(task18_replacement_fingerprint "$home" "$data" "$state")"
  printf X >&"$mlfd"; exec {mrfd}>&-; exec {mlfd}>&-
  set +e; wait "$mutation_pid"; mutation_rc=$?; set -e; forget_fixture_pid "$mutation_pid"
  [[ "$mutation_rc" -eq 0 ]] || { cat "$case_root/mutation.stderr" >&2; return 1; }
  replacement1_after="$(task18_replacement_fingerprint "$home" "$data" "$state")"
  [[ "$replacement1_after" == "$replacement1_before" &&
    ! -e "$public/home.original/.ocsb/$workspace/original-marker" &&
    -s "$public/state.original/$workspace/.workspace-receipt-$nonce" ]] || return 1

  home_source="$home"; data_source="$data"; state_source="$state"; db_source="$db"
  home_source_spec="$(source_spec '@OCSB_SOURCE_0@' "$home_source" / directory)"
  data_source_spec="$(source_spec '@OCSB_SOURCE_1@' "$data_source" / directory)"
  state_source_spec="$(source_spec '@OCSB_SOURCE_2@' "$state_source" / directory)"
  db_source_spec="$(source_spec '@OCSB_SOURCE_3@' "$db_source" / regular)"
  # Source identities are the held objects, not the replacement display paths.
  IFS=$'\t' read -r -a _fields <<< "$home_source_spec"; _fields[3]="$(stat -Lc %d /proc/self/fd/$home_fd)"; _fields[4]="$(stat -Lc %i /proc/self/fd/$home_fd)"; home_source_spec="$(IFS=$'\t'; echo "${_fields[*]}")"
  IFS=$'\t' read -r -a _fields <<< "$data_source_spec"; _fields[3]="$(stat -Lc %d /proc/self/fd/$data_fd)"; _fields[4]="$(stat -Lc %i /proc/self/fd/$data_fd)"; data_source_spec="$(IFS=$'\t'; echo "${_fields[*]}")"
  IFS=$'\t' read -r -a _fields <<< "$state_source_spec"; _fields[3]="$(stat -Lc %d /proc/self/fd/$state_fd)"; _fields[4]="$(stat -Lc %i /proc/self/fd/$state_fd)"; state_source_spec="$(IFS=$'\t'; echo "${_fields[*]}")"
  IFS=$'\t' read -r -a _fields <<< "$db_source_spec"; _fields[3]="$(stat -Lc %d /proc/self/fd/$db_fd)"; _fields[4]="$(stat -Lc %i /proc/self/fd/$db_fd)"; db_source_spec="$(IFS=$'\t'; echo "${_fields[*]}")"

  backend="$case_root/task18-backend"; result="$case_root/backend.result"; write_task18_backend "$backend"
  uid="$(id -u)"; gid="$(id -g)"
  payload=("$backend" --uid "$uid" --gid "$gid"
    --ro-bind '@OCSB_SOURCE_0@' /workspace --ro-bind '@OCSB_SOURCE_1@' /data
    --ro-bind '@OCSB_SOURCE_2@' /state --ro-bind '@OCSB_SOURCE_3@' /db-env -- /bin/true)
  final_ready="$case_root/final.ready"; final_release="$case_root/final.release"
  mkfifo "$final_ready" "$final_release"; exec {frfd}<>"$final_ready"; exec {flfd}<>"$final_release"
  final_args=(--backend bubblewrap --namespace bubblewrap-user --host-uid "$uid" --host-gid "$gid"
    --anchor-root "$fixture/runtime/ocsb" "${inherited_args[@]}"
    --workspace-receipt "$receipt" --workspace-nonce "$nonce" --workspace-project "$home"
    --workspace-base .ocsb --workspace-name "$workspace"
    --test-before-inherited-final-open-ready-fd "$frfd"
    --test-before-inherited-final-open-release-fd "$flfd"
    --source-spec "$home_source_spec" --replace '6:@OCSB_SOURCE_0@'
    --source-spec "$data_source_spec" --replace '9:@OCSB_SOURCE_1@'
    --source-spec "$state_source_spec" --replace '12:@OCSB_SOURCE_2@'
    --source-spec "$db_source_spec" --replace '15:@OCSB_SOURCE_3@')
  FAKE_ANCHOR_PRIVATE_PREFIX="$fixture/runtime/ocsb/anchors/mount-" \
    OCSB_TASK18_BACKEND_RESULT="$result" \
    OCSB_TASK18_ORIGINAL_HOME="$public/home.original" \
    OCSB_TASK18_ORIGINAL_DATA="$public/data.original" \
    OCSB_TASK18_ORIGINAL_STATE="$public/state.original" \
    OCSB_TASK18_ORIGINAL_DB="$public/state.original/ironclaw-db.env" \
    "$helper" "${final_args[@]}" -- "${payload[@]}" >"$case_root/final.stdout" 2>"$case_root/final.stderr" &
  final_pid=$!; track_fixture_pid "$final_pid"; read -r -n 1 -t 30 _ <&"$frfd"

  mv "$home" "$public/home.replacement-1"; mv "$data" "$public/data.replacement-1"; mv "$state" "$public/state.replacement-1"
  install -d -m 0700 "$home/.ocsb/$workspace" "$data" "$state/$workspace"
  printf 'replacement-2\n' > "$home/task18-canary"
  printf 'replacement-2-workspace\n' > "$home/.ocsb/$workspace/replacement-marker"
  printf 'replacement-2\n' > "$data/task18-canary"
  printf 'replacement-2\n' > "$state/task18-canary"
  printf 'replacement-2-db-env\n' > "$db"; chmod 0600 "$db"
  replacement2_before="$(task18_replacement_fingerprint "$home" "$data" "$state")"
  printf X >&"$flfd"; exec {frfd}>&-; exec {flfd}>&-
  set +e; wait "$final_pid"; final_rc=$?; set -e; forget_fixture_pid "$final_pid"
  [[ "$final_rc" -eq 0 ]] || { cat "$case_root/final.stderr" >&2; return 1; }
  replacement2_after="$(task18_replacement_fingerprint "$home" "$data" "$state")"
  [[ "$replacement2_after" == "$replacement2_before" && -s "$result" ]] || return 1
  for expected in home=original data=original state=original db-env=original argv=no-proc anchors=private fds=closed; do
    grep -Fxq "$expected" "$result"
  done

  source_text="$(cat "$REPO_ROOT/lib/mkSandbox.nix")"
  [[ "$source_text" == *'WORKSPACE_MUTATION_ARGS=('* && "$source_text" == *'MOUNT_ANCHOR_ARGS=('* ]]
  [[ "$(grep -F '"${INHERITED_FD_ARGS[@]}"' "$REPO_ROOT/lib/mkSandbox.nix" | wc -l)" -ge 2 ]]
  exec {home_fd}>&-; exec {data_fd}>&-; exec {state_fd}>&-; exec {db_fd}>&-
  echo 'PASS[GREEN-inherited-mutation-helper]: project-tree=original public-identity=original receipt-parent=original workspace-state=original replacement-set-1-unchanged'
  echo 'PASS[GREEN-inherited-final-helper]: home=original data=original state=original db-env=original replacement-set-2-unchanged'
  echo 'PASS[GREEN-inherited-spec-forwarding]: mutation=all-four final=all-four'
  echo 'PASS[GREEN-inherited-fd-backend-boundary]: all-handoff-fds-closed argv=no-proc private-anchors-only'
  remove_case_dir
}

inherited_fd_handoff_auto_case() {
  local fixture="$1"
  if [[ ! -x "$fixture/launchers/bin/ocsb-mount-anchor-test-hooks" ]]; then
    prepare_fixture "$fixture" >/dev/null
  fi
  inherited_fd_handoff_case "$fixture"
}

require_user_namespace() {
  if command -v unshare >/dev/null 2>&1 && unshare --user --map-root-user true >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$CI_FAKE_MODE" -eq 1 ]]; then
    echo 'test_mount_anchor: user namespace unavailable for required deterministic fake suite' >&2
    return 1
  fi
  printf '%s\n' "$SKIP_MARKER"
  return 77
}

track_fixture_pid() {
  FIXTURE_PIDS+=("$1")
}

forget_fixture_pid() {
  local pid="$1"
  local index

  for ((index = 0; index < ${#FIXTURE_PIDS[@]}; ++index)); do
    if [[ "${FIXTURE_PIDS[$index]}" == "$pid" ]]; then
      FIXTURE_PIDS[$index]=""
      return 0
    fi
  done
}

reap_fixture_pid() {
  local pid="$1"

  if ! wait "$pid"; then
    echo "test_mount_anchor: barrier launcher exited unsuccessfully: $pid" >&2
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    echo "test_mount_anchor: barrier launcher was not reaped: $pid" >&2
    return 1
  fi
  forget_fixture_pid "$pid"
}

hold_barrier_release_fifo() {
  local release_fifo="$1"

  (sleep 600 > "$release_fifo") &
  BARRIER_RELEASE_GUARD_PID=$!
  track_fixture_pid "$BARRIER_RELEASE_GUARD_PID"
}

reap_barrier_release_guard() {
  local pid="$1"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if kill -0 "$pid" 2>/dev/null; then
    echo "test_mount_anchor: barrier release guard was not reaped: $pid" >&2
    return 1
  fi
  forget_fixture_pid "$pid"
}

await_barrier_ready() {
  local ready_fifo="$1"
  local received="$ready_fifo.received"

  if ! timeout 10 dd if="$ready_fifo" of="$received" bs=1 count=1 status=none; then
    echo "test_mount_anchor: barrier ready byte timed out" >&2
    return 1
  fi
  [[ "$(wc -c < "$received")" -eq 1 && "$(cat -- "$received")" == R ]] || {
    echo "test_mount_anchor: barrier emitted an invalid ready byte" >&2
    return 1
  }
}

release_barrier() {
  local release_fifo="$1"

  if ! timeout 10 bash -c 'printf "X\\n" > "$1"' bash "$release_fifo"; then
    echo "test_mount_anchor: barrier release byte timed out" >&2
    return 1
  fi
}

record_workspace_victim_state() {
  local victim="$1"
  local workspace="$2"

  WORKSPACE_VICTIM_ROOT_INODE_MODE="$(stat -c '%i:%a' -- "$victim")"
  WORKSPACE_VICTIM_MARKER_SHA256="$(sha256sum -- "$victim/$workspace/marker" | cut -d ' ' -f 1)"
  [[ -n "$WORKSPACE_VICTIM_ROOT_INODE_MODE" && "$WORKSPACE_VICTIM_MARKER_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    echo 'test_mount_anchor: could not record workspace victim state' >&2
    return 1
  }
}

assert_workspace_victim_unchanged() {
  local victim="$1"
  local workspace="$2"

  [[ "$(stat -c '%i:%a' -- "$victim")" == "$WORKSPACE_VICTIM_ROOT_INODE_MODE" &&
    "$(sha256sum -- "$victim/$workspace/marker" | cut -d ' ' -f 1)" == "$WORKSPACE_VICTIM_MARKER_SHA256" &&
    "$(cat -- "$victim/$workspace/marker")" == replacement ]] || {
    echo 'test_mount_anchor: workspace victim changed' >&2
    return 1
  }
}

prepare_workspace_parent_swap() {
  local fixture="$1"
  local workspace="$2"

  WORKSPACE_SWAP_PROJECT="$fixture/project"
  WORKSPACE_SWAP_VICTIM="$CASE_DIR/victim"
  WORKSPACE_SWAP_STATE="$CASE_DIR/state"
  WORKSPACE_SWAP_ORIGINAL="$WORKSPACE_SWAP_PROJECT/.ocsb-original"
  rm -rf -- "$WORKSPACE_SWAP_PROJECT/.ocsb" "$WORKSPACE_SWAP_ORIGINAL" \
    "$WORKSPACE_SWAP_VICTIM" "$WORKSPACE_SWAP_STATE"
  install -d -m 0700 "$WORKSPACE_SWAP_PROJECT/.ocsb/$workspace" \
    "$WORKSPACE_SWAP_VICTIM/$workspace"
  printf 'original\n' > "$WORKSPACE_SWAP_PROJECT/.ocsb/$workspace/marker"
  printf 'replacement\n' > "$WORKSPACE_SWAP_VICTIM/$workspace/marker"
  WORKSPACE_ORIGINAL_ROOT_INODE="$(stat -c %i -- "$WORKSPACE_SWAP_PROJECT/.ocsb/$workspace")"
  record_workspace_victim_state "$WORKSPACE_SWAP_VICTIM" "$workspace"
}

launch_workspace_mutation_barrier() {
  local fixture="$1"
  local launcher="$2"
  local workspace="$3"
  local ready_fifo="$4"
  local release_fifo="$5"
  local sentinel="$6"
  local pid

  (
    cd "$WORKSPACE_SWAP_PROJECT"
    env \
      XDG_RUNTIME_DIR="$fixture/runtime" \
      OCSB_STATE_BASE_DIR="$WORKSPACE_SWAP_STATE" \
      OCSB_MUTATION_BACKEND_SENTINEL="$sentinel" \
      FAKE_ANCHOR_PRIVATE_PREFIX="$fixture/runtime/ocsb/anchors/mount-" \
      "$launcher" -w "$workspace" --strategy direct --overwrite -- -c true \
      3>"$ready_fifo" 4<"$release_fifo"
  ) &
  pid=$!
  track_fixture_pid "$pid"
  BARRIER_PID="$pid"
}

reap_fixture_pid_failure() {
  local pid="$1"
  local rc

  set +e
  wait "$pid"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "test_mount_anchor: fail-closed barrier launcher unexpectedly succeeded: $pid" >&2
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    echo "test_mount_anchor: fail-closed barrier launcher was not reaped: $pid" >&2
    return 1
  fi
  forget_fixture_pid "$pid"
}

launch_workspace_final_barrier() {
  local fixture="$1"
  local launcher="$2"
  local workspace="$3"
  local ready_fifo="$4"
  local release_fifo="$5"
  local sentinel="$6"
  local pid

  (
    cd "$WORKSPACE_SWAP_PROJECT"
    env \
      XDG_RUNTIME_DIR="$fixture/runtime" \
      OCSB_STATE_BASE_DIR="$WORKSPACE_SWAP_STATE" \
      OCSB_MUTATION_BACKEND_SENTINEL="$sentinel" \
      FAKE_ANCHOR_PRIVATE_PREFIX="$fixture/runtime/ocsb/anchors/mount-" \
      "$launcher" -w "$workspace" --strategy direct --overwrite -- -c true \
      5>"$ready_fifo" 6<"$release_fifo"
  ) &
  pid=$!
  track_fixture_pid "$pid"
  BARRIER_PID="$pid"
}

swap_workspace_parent() {
  mv -- "$WORKSPACE_SWAP_PROJECT/.ocsb" "$WORKSPACE_SWAP_ORIGINAL" || {
    echo 'test_mount_anchor: could not preserve original workspace parent during swap' >&2
    return 1
  }
  ln -s -- "$WORKSPACE_SWAP_VICTIM" "$WORKSPACE_SWAP_PROJECT/.ocsb" || {
    echo 'test_mount_anchor: could not install victim workspace parent symlink' >&2
    return 1
  }
}

workspace_mutation_parent_swap_first_case() {
  local fixture="$1"
  local workspace='workspace-mutation-parent-swap'
  local launcher sentinel ready_fifo release_fifo pid

  require_prepared_fixture "$fixture"
  require_user_namespace || return $?
  CASE_DIR="$(mktemp -d "$fixture/workspace-mutation.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"
  prepare_workspace_parent_swap "$fixture" "$workspace"
  launcher="$fixture/launchers/bin/ocsb-mount-anchor-workspace-mutation"
  sentinel="$CASE_DIR/backend-sentinel"
  ready_fifo="$CASE_DIR/mkdir-ready"
  release_fifo="$CASE_DIR/mkdir-release"
  mkfifo "$ready_fifo" "$release_fifo"

  hold_barrier_release_fifo "$release_fifo"
  local guard_pid="$BARRIER_RELEASE_GUARD_PID"
  launch_workspace_mutation_barrier "$fixture" "$launcher" "$workspace" "$ready_fifo" "$release_fifo" "$sentinel"
  pid="$BARRIER_PID"
  set +e
  await_barrier_ready "$ready_fifo"
  local barrier_rc=$?
  set -e
  if [[ "$barrier_rc" -ne 0 ]]; then
    cat -- "$CASE_DIR/helper.stderr" >&2 || true
    return 1
  fi
  swap_workspace_parent || return 1
  release_barrier "$release_fifo" || return 1
  reap_barrier_release_guard "$guard_pid" || return 1
  reap_fixture_pid_failure "$pid" || return 1
  [[ ! -e "$sentinel" ]] || {
    echo 'test_mount_anchor: mutation barrier invoked the backend after identity failure' >&2
    return 1
  }
  assert_workspace_victim_unchanged "$WORKSPACE_SWAP_VICTIM" "$workspace" || return 1
  [[ -d "$WORKSPACE_SWAP_ORIGINAL/$workspace" &&
    "$(stat -c %i -- "$WORKSPACE_SWAP_ORIGINAL/$workspace")" == "$WORKSPACE_ORIGINAL_ROOT_INODE" &&
    ! -e "$WORKSPACE_SWAP_ORIGINAL/$workspace/marker" ]] || {
    echo 'test_mount_anchor: mutation helper did not reset the fixed original workspace root' >&2
    return 1
  }
  assert_workspace_receipts_consumed "$WORKSPACE_SWAP_STATE" || return 1
  printf '%s\n' 'PASS[GREEN-workspace-mutation-parent-swap]: original-reset victim-unchanged backend-refused'
}

workspace_post_mutation_swap_case() {
  local fixture="$1"
  local workspace='workspace-post-mutation-swap'
  local launcher sentinel ready_fifo release_fifo pid

  require_prepared_fixture "$fixture"
  require_user_namespace || return $?
  CASE_DIR="$(mktemp -d "$fixture/workspace-post-mutation.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"
  prepare_workspace_parent_swap "$fixture" "$workspace"
  launcher="$fixture/launchers/bin/ocsb-mount-anchor-workspace-post-mutation"
  sentinel="$CASE_DIR/backend-sentinel"
  ready_fifo="$CASE_DIR/receipt-open-ready"
  release_fifo="$CASE_DIR/receipt-open-release"
  mkfifo "$ready_fifo" "$release_fifo"

  hold_barrier_release_fifo "$release_fifo"
  local guard_pid="$BARRIER_RELEASE_GUARD_PID"
  launch_workspace_final_barrier "$fixture" "$launcher" "$workspace" "$ready_fifo" "$release_fifo" "$sentinel"
  pid="$BARRIER_PID"
  await_barrier_ready "$ready_fifo" || return 1
  swap_workspace_parent || return 1
  release_barrier "$release_fifo" || return 1
  reap_barrier_release_guard "$guard_pid" || return 1
  reap_fixture_pid_failure "$pid" || return 1
  [[ ! -e "$sentinel" ]] || {
    echo 'test_mount_anchor: final barrier invoked the backend after identity mismatch' >&2
    return 1
  }
  assert_workspace_victim_unchanged "$WORKSPACE_SWAP_VICTIM" "$workspace" || return 1
  assert_workspace_receipts_consumed "$WORKSPACE_SWAP_STATE" || return 1
  printf '%s\n' 'PASS[GREEN-workspace-post-mutation-swap]: identity-mismatch victim-unchanged'
}

run_workspace_green_subcase() {
  local fixture="$1"
  local subcase="$2"
  local expected_marker="$3"
  local output

  output="$("$SCRIPT_DIR/test_mount_anchor.sh" --case "$subcase" "$fixture")"
  printf '%s\n' "$output"
  [[ "$output" == "$expected_marker" ]] || {
    echo "test_mount_anchor: $subcase did not produce its exact GREEN marker" >&2
    return 1
  }
}

workspace_mutation_parent_swap_case() {
  local fixture="$1"

  run_workspace_green_subcase "$fixture" workspace-mutation-parent-swap-first \
    'PASS[GREEN-workspace-mutation-parent-swap]: original-reset victim-unchanged backend-refused'
  run_workspace_green_subcase "$fixture" workspace-post-mutation-swap \
    'PASS[GREEN-workspace-post-mutation-swap]: identity-mismatch victim-unchanged'
  printf '%s\n' 'CLEANUP PASS: workspace mutation fixtures'
}

write_git_mutation_fake() {
  local fake_git="$1"

  cat > "$fake_git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${OCSB_GIT_ARGUMENTS:?}"
case "${1:-}:${2:-}" in
  worktree:add)
    mkdir -p worktree
    printf R > "${OCSB_GIT_READY:?}"
    IFS= read -r release < "${OCSB_GIT_RELEASE:?}"
    [[ "$release" == X ]] || exit 65
    printf '%s\n' add-success >> "${OCSB_GIT_RESULTS:?}"
    ;;
  worktree:remove)
    rm -rf -- worktree
    ;;
  worktree:prune)
    :
    ;;
  worktree:list)
    printf 'worktree %s\n' "$(pwd -P)/worktree"
    printf '%s\n' list-success >> "${OCSB_GIT_RESULTS:?}"
    ;;
  *)
    exit 64
    ;;
esac
EOF
  chmod 0755 "$fake_git"
}

git_mid_command_control_case() {
  local fixture="$1" project state workspace nonce receipt helper fake_git
  local ready_fifo release_fifo helper_pid project_dev project_ino spec args results

  CASE_DIR="$(mktemp -d "$fixture/git-mid-command-control.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"
  project="$CASE_DIR/project"
  state="$CASE_DIR/state"
  workspace="git-mid-command-control"
  nonce="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
  receipt="$state/.workspace-receipt-$nonce"
  helper="$fixture/launchers/bin/ocsb-mount-anchor-test-hooks"
  fake_git="$CASE_DIR/fake-git"
  ready_fifo="$CASE_DIR/git-ready"
  release_fifo="$CASE_DIR/git-release"
  results="$CASE_DIR/git-results"
  install -d -m 0700 "$project/.ocsb" "$state"
  project_dev="$(stat -c %d "$project")"
  project_ino="$(stat -c %i "$project")"
  spec="$(printf 'v1\t%s\t%s\t%s\t%s\t.ocsb\t%s\tcreate\tgit-worktree\tnone\tbubblewrap\t%s' \
    "$nonce" "$project" "$project_dev" "$project_ino" "$workspace" "$state")"
  mkfifo "$ready_fifo" "$release_fifo"
  write_git_mutation_fake "$fake_git"
  OCSB_GIT_ARGUMENTS="$CASE_DIR/git-arguments" OCSB_GIT_RESULTS="$results" \
  OCSB_GIT_READY="$ready_fifo" OCSB_GIT_RELEASE="$release_fifo" \
    "$helper" --mutation-only --mutation-spec "$spec" --workspace-receipt "$receipt" \
      --git-bin "$fake_git" >"$CASE_DIR/helper.stdout" 2>"$CASE_DIR/helper.stderr" &
  helper_pid=$!
  track_fixture_pid "$helper_pid"
  await_barrier_ready "$ready_fifo" || return 1
  release_barrier "$release_fifo" || return 1
  reap_fixture_pid "$helper_pid" || {
    cat -- "$CASE_DIR/helper.stderr" >&2 || true
    return 1
  }
  args="$(cat -- "$CASE_DIR/git-arguments")"
  grep -Fxq 'worktree add --detach worktree HEAD' "$CASE_DIR/git-arguments" &&
    grep -Fxq 'worktree list --porcelain' "$CASE_DIR/git-arguments" &&
    grep -Fxq add-success "$results" && grep -Fxq list-success "$results" &&
    [[ "$args" != *"$project/.ocsb"* && -f "$receipt" &&
    -d "$project/.ocsb/$workspace/worktree" ]] || {
    echo 'test_mount_anchor: git mid-command no-swap control did not validate add/list through held-relative paths' >&2
    return 1
  }
  remove_case_dir
  ACTIVE_FIXTURE=""
}

git_mid_command_swap_case() {
  local fixture="$1" project state victim original workspace nonce receipt helper fake_git
  local ready_fifo release_fifo helper_pid sentinel project_dev project_ino spec args_line results

  require_prepared_fixture "$fixture"
  git_mid_command_control_case "$fixture" || return 1
  CASE_DIR="$(mktemp -d "$fixture/git-mid-command.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"
  project="$CASE_DIR/project"
  state="$CASE_DIR/state"
  victim="$CASE_DIR/victim"
  original="$CASE_DIR/project-ocsb-original"
  workspace="git-mid-command-swap"
  nonce="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  receipt="$state/.workspace-receipt-$nonce"
  helper="$fixture/launchers/bin/ocsb-mount-anchor-test-hooks"
  fake_git="$CASE_DIR/fake-git"
  ready_fifo="$CASE_DIR/git-ready"
  release_fifo="$CASE_DIR/git-release"
  results="$CASE_DIR/git-results"
  sentinel="$CASE_DIR/backend-sentinel"
  install -d -m 0700 "$project/.ocsb" "$state" "$victim/$workspace"
  printf 'replacement\n' > "$victim/$workspace/marker"
  record_workspace_victim_state "$victim" "$workspace"
  project_dev="$(stat -c %d "$project")"
  project_ino="$(stat -c %i "$project")"
  spec="$(printf 'v1\t%s\t%s\t%s\t%s\t.ocsb\t%s\tcreate\tgit-worktree\tnone\tbubblewrap\t%s' \
    "$nonce" "$project" "$project_dev" "$project_ino" "$workspace" "$state")"
  mkfifo "$ready_fifo" "$release_fifo"
  write_git_mutation_fake "$fake_git"
  OCSB_GIT_ARGUMENTS="$CASE_DIR/git-arguments" OCSB_GIT_RESULTS="$results" \
  OCSB_GIT_READY="$ready_fifo" OCSB_GIT_RELEASE="$release_fifo" \
    "$helper" --mutation-only --mutation-spec "$spec" --workspace-receipt "$receipt" \
      --git-bin "$fake_git" >"$CASE_DIR/helper.stdout" 2>"$CASE_DIR/helper.stderr" &
  helper_pid=$!
  track_fixture_pid "$helper_pid"
  await_barrier_ready "$ready_fifo" || return 1
  mv -- "$project/.ocsb" "$original"
  ln -s -- "$victim" "$project/.ocsb"
  release_barrier "$release_fifo" || return 1
  reap_fixture_pid_failure "$helper_pid" || return 1
  grep -Fxq 'ocsb: workspace protocol: public workspace identity mismatch' "$CASE_DIR/helper.stderr" || {
    echo 'test_mount_anchor: git mid-command swap did not fail with the public workspace identity diagnostic' >&2
    cat -- "$CASE_DIR/helper.stderr" >&2
    return 1
  }
  args_line="$(sed -n '1p' "$CASE_DIR/git-arguments")"
  [[ "$args_line" == 'worktree add --detach worktree HEAD' &&
    "$args_line" != *"$project/.ocsb"* ]] || {
    echo 'test_mount_anchor: git worktree add did not receive the held-relative child path' >&2
    return 1
  }
  grep -Fxq add-success "$results" && ! grep -Fxq list-success "$results" || {
    echo 'test_mount_anchor: git mid-command swap did not prove add completed after release before post-add revalidation' >&2
    return 1
  }
  [[ ! -e "$sentinel" && ! -e "$victim/$workspace/worktree" &&
    ! -e "$original/$workspace" ]] || {
    echo 'test_mount_anchor: git mid-command swap touched the victim or left mutation artifacts' >&2
    return 1
  }
  grep -Fxq 'worktree remove --force worktree' "$CASE_DIR/git-arguments" &&
    grep -Fxq 'worktree prune' "$CASE_DIR/git-arguments" || {
    echo 'test_mount_anchor: git mid-command swap did not roll back through the held workspace' >&2
    return 1
  }
  assert_workspace_victim_unchanged "$victim" "$workspace" || return 1
  [[ ! -e "$receipt" && -z "$(find "$state" -name '.workspace-receipt-*' -print -quit)" ]] || {
    echo 'test_mount_anchor: git mid-command swap left a receipt artifact' >&2
    return 1
  }
  printf '%s\n' 'PASS[GREEN-git-mid-command-swap]: relative-argv victim-unchanged backend-refused rollback-clean'
  printf '%s\n' 'CLEANUP PASS: git mid-command swap fixture'
}

receipt_consume_cas_case() {
  local fixture="$1" project state workspace nonce receipt replacement helper backend
  local project_dev project_ino base_dev base_ino workspace_dev workspace_ino line replacement_inode
  local ready_fifo release_fifo ready_guard ready_reader ready_writer release_guard release_reader release_writer
  local helper_pid retained_replacement guard_artifact spent_artifact sentinel unrelated replacement_hash
  local cleanup_canary canary_inode canary_hash artifact old_artifact_count=0 retained_count=0
  local unexpected_artifact=0 canonical_absent=0

  require_prepared_fixture "$fixture"
  CASE_DIR="$(mktemp -d "$fixture/receipt-cas.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"
  project="$CASE_DIR/project"
  state="$CASE_DIR/state"
  workspace="receipt-cas"
  nonce="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  receipt="$state/.workspace-receipt-$nonce"
  replacement="$CASE_DIR/replacement-receipt"
  helper="$fixture/launchers/bin/ocsb-mount-anchor-test-hooks-manifest"
  backend="$CASE_DIR/fake-backend"
  ready_fifo="$CASE_DIR/receipt-ready"
  release_fifo="$CASE_DIR/receipt-release"
  sentinel="$CASE_DIR/backend-sentinel"
  unrelated="$CASE_DIR/unrelated"
  install -d -m 0700 "$project/.ocsb/$workspace" "$state"
  project_dev="$(stat -c %d "$project")"; project_ino="$(stat -c %i "$project")"
  base_dev="$(stat -c %d "$project/.ocsb")"; base_ino="$(stat -c %i "$project/.ocsb")"
  workspace_dev="$(stat -c %d "$project/.ocsb/$workspace")"; workspace_ino="$(stat -c %i "$project/.ocsb/$workspace")"
  line="$(printf 'v1\t%s\t%s\t.ocsb\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tdirect\tbubblewrap\tnone\t0\t0\tnone' \
    "$nonce" "$project" "$workspace" "$project_dev" "$project_ino" "$base_dev" "$base_ino" "$workspace_dev" "$workspace_ino")"
  printf '%s\n' "$line" > "$receipt"
  chmod 0600 "$receipt"
  printf '%s\n' "${line/v1/v2}" > "$replacement"
  chmod 0600 "$replacement"
  replacement_inode="$(stat -c '%d:%i' "$replacement")"
  replacement_hash="$(sha256sum "$replacement" | cut -d ' ' -f1)"
  printf 'unrelated\n' > "$unrelated"
  cat > "$backend" <<EOF
#!/usr/bin/env bash
: > "$sentinel"
EOF
  chmod 0755 "$backend"
  mkfifo "$ready_fifo" "$release_fifo"
  # Keep both FIFOs open while establishing dedicated one-way ends.  Opening a
  # FIFO directly in the helper command would otherwise block its shell before
  # the helper reaches the deterministic C barrier.
  exec {ready_guard}<>"$ready_fifo"
  exec {ready_reader}<"$ready_fifo"
  exec {ready_writer}>"$ready_fifo"
  exec {release_guard}<>"$release_fifo"
  exec {release_reader}<"$release_fifo"
  exec {release_writer}>"$release_fifo"
  OCSB_MOUNT_ANCHOR_RUN_MANIFEST_UNIT=1 \
    "$helper" --backend bubblewrap --namespace bubblewrap-user --host-uid "$(id -u)" --host-gid "$(id -g)" \
      --anchor-root "$fixture/runtime" --workspace-receipt "$receipt" --workspace-nonce "$nonce" \
      --workspace-project "$project" --workspace-base .ocsb --workspace-name "$workspace" \
      --test-before-receipt-consume-ready-fd "$ready_writer" \
      --test-before-receipt-consume-release-fd "$release_reader" \
      -- "$backend" >"$CASE_DIR/helper.stdout" 2>"$CASE_DIR/helper.stderr" &
  helper_pid=$!
  track_fixture_pid "$helper_pid"
  if ! timeout 10 bash -c 'IFS= read -r -n 1 _ <&"$1"' _ "$ready_reader"; then
    cat -- "$CASE_DIR/helper.stderr" >&2
    return 1
  fi
  cleanup_canary="$state/.receipt-cleanup-$helper_pid-0"
  printf 'in-range-cleanup-canary\n' > "$cleanup_canary"
  chmod 0600 "$cleanup_canary"
  canary_inode="$(stat -c '%d:%i' "$cleanup_canary")"
  canary_hash="$(sha256sum "$cleanup_canary" | cut -d ' ' -f1)"
  mv -f -- "$replacement" "$receipt"
  printf R >&"$release_writer"
  reap_fixture_pid_failure "$helper_pid" || return 1
  exec {ready_guard}>&- {ready_reader}<&- {ready_writer}>&-
  exec {release_guard}>&- {release_reader}<&- {release_writer}>&-
  retained_replacement=""
  guard_artifact=""
  spent_artifact=""
  while IFS= read -r candidate; do
    retained_count=$((retained_count + 1))
    case "${candidate##*/}" in
      *.guard.[0-9][0-9]) guard_artifact="$candidate" ;;
      *.spent.[0-9][0-9]) spent_artifact="$candidate" ;;
      *) unexpected_artifact=1 ;;
    esac
    if [[ "$(stat -c '%d:%i' "$candidate")" == "$replacement_inode" &&
          "$(sha256sum "$candidate" | cut -d ' ' -f1)" == "$replacement_hash" ]]; then
      retained_replacement="$candidate"
    fi
  done < <(find "$state" -maxdepth 1 -type f -name ".workspace-receipt-$nonce.*" -print)
  [[ ! -e "$receipt" ]] && canonical_absent=1
  while IFS= read -r artifact; do
    old_artifact_count=$((old_artifact_count + 1))
    if [[ "$artifact" == "$cleanup_canary" ]]; then
      continue
    fi
    unexpected_artifact=1
  done < <(find "$state" -maxdepth 1 -type f -name '.receipt-*' -print)
  if [[ "$canonical_absent" -eq 1 && ! -e "$sentinel" && -n "$retained_replacement" &&
    "$retained_replacement" == "$guard_artifact" && -n "$spent_artifact" &&
    "$(stat -c '%d:%i' "$retained_replacement")" == "$replacement_inode" &&
    "$(sha256sum "$retained_replacement" | cut -d ' ' -f1)" == "$replacement_hash" &&
    "$(stat -c '%u:%a:%s' "$spent_artifact")" == "$(id -u):600:0" &&
    "$(stat -c '%d:%i' "$cleanup_canary")" == "$canary_inode" &&
    "$(sha256sum "$cleanup_canary" | cut -d ' ' -f1)" == "$canary_hash" &&
    "$(cat "$cleanup_canary")" == in-range-cleanup-canary &&
    "$(cat "$unrelated")" == unrelated && "$retained_count" -eq 2 &&
    "$old_artifact_count" -eq 1 &&
    "$unexpected_artifact" -eq 0 ]]; then
    printf '%s\n' 'PASS[GREEN-receipt-retained-cas]: canonical-absent in-range-canary-unchanged replacement-retained two-artifacts'
    printf '%s\n' 'CLEANUP PASS: receipt CAS fixture'
    return 0
  fi
  printf '%s\n' 'FAIL[RED-receipt-retained-cas]: failed CAS did not retain the exact replacement and spent guard'
  printf '%s\n' 'CLEANUP PASS: receipt CAS fixture'
  if [[ "${OCSB_EXPECT_REVIEW3_RED:-0}" == 1 ]]; then
    return 0
  fi
  return 1
}

prepare_receipt_retire_fixture() {
  local fixture="$1"
  local label="$2"
  local nonce="$3"
  local project_dev project_ino base_dev base_ino workspace_dev workspace_ino

  CASE_DIR="$(mktemp -d "$fixture/receipt-retire.$label.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"
  RETAIN_PROJECT="$CASE_DIR/project"
  RETAIN_STATE="$CASE_DIR/state"
  RETAIN_WORKSPACE="receipt-retire-$label"
  RETAIN_NONCE="$nonce"
  RETAIN_RECEIPT="$RETAIN_STATE/.workspace-receipt-$RETAIN_NONCE"
  RETAIN_HELPER="$fixture/launchers/bin/ocsb-mount-anchor-test-hooks-manifest"
  RETAIN_BACKEND="$CASE_DIR/fake-backend"
  RETAIN_SENTINEL="$CASE_DIR/backend-sentinel"
  install -d -m 0700 "$RETAIN_PROJECT/.ocsb/$RETAIN_WORKSPACE" "$RETAIN_STATE"
  project_dev="$(stat -c %d -- "$RETAIN_PROJECT")"
  project_ino="$(stat -c %i -- "$RETAIN_PROJECT")"
  base_dev="$(stat -c %d -- "$RETAIN_PROJECT/.ocsb")"
  base_ino="$(stat -c %i -- "$RETAIN_PROJECT/.ocsb")"
  workspace_dev="$(stat -c %d -- "$RETAIN_PROJECT/.ocsb/$RETAIN_WORKSPACE")"
  workspace_ino="$(stat -c %i -- "$RETAIN_PROJECT/.ocsb/$RETAIN_WORKSPACE")"
  RETAIN_LINE="$(printf 'v1\t%s\t%s\t.ocsb\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tdirect\tbubblewrap\tnone\t0\t0\tnone' \
    "$RETAIN_NONCE" "$RETAIN_PROJECT" "$RETAIN_WORKSPACE" "$project_dev" "$project_ino" \
    "$base_dev" "$base_ino" "$workspace_dev" "$workspace_ino")"
  printf '%s\n' "$RETAIN_LINE" > "$RETAIN_RECEIPT"
  chmod 0600 "$RETAIN_RECEIPT"
  RETAIN_RECEIPT_INODE="$(stat -c '%d:%i' -- "$RETAIN_RECEIPT")"
  RETAIN_RECEIPT_STAT="$(stat -c '%d:%i:%u:%g:%a:%s:%Y' -- "$RETAIN_RECEIPT")"
  RETAIN_RECEIPT_HASH="$(sha256sum -- "$RETAIN_RECEIPT" | cut -d ' ' -f1)"
  cat > "$RETAIN_BACKEND" <<EOF
#!/usr/bin/env bash
: > "$RETAIN_SENTINEL"
EOF
  chmod 0755 "$RETAIN_BACKEND"
}

run_receipt_retire_helper() {
  OCSB_MOUNT_ANCHOR_RUN_MANIFEST_UNIT=1 \
    "$RETAIN_HELPER" --backend bubblewrap --namespace bubblewrap-user \
      --host-uid "$(id -u)" --host-gid "$(id -g)" --anchor-root "$ACTIVE_FIXTURE/runtime" \
      --workspace-receipt "$RETAIN_RECEIPT" --workspace-nonce "$RETAIN_NONCE" \
      --workspace-project "$RETAIN_PROJECT" --workspace-base .ocsb \
      --workspace-name "$RETAIN_WORKSPACE" "$@" -- "$RETAIN_BACKEND"
}

receipt_post_validation_swap_subcase() {
  local fixture="$1"
  local barrier="$2"
  local nonce="$3"
  local replacement ready_fifo release_fifo ready_guard ready_reader ready_writer
  local release_guard release_reader release_writer helper_pid candidate validated_path aside_path
  local replacement_stat replacement_hash replacement_bytes final_stat final_hash final_bytes
  local canonical_absent=0 backend_executed=0
  local -a hook_args

  prepare_receipt_retire_fixture "$fixture" "$barrier" "$nonce"
  replacement="$CASE_DIR/$barrier-replacement"
  printf 'task16-%s-replacement-bytes\n' "$barrier" > "$replacement"
  chmod 0600 "$replacement"
  replacement_stat="$(stat -c '%d:%i:%u:%g:%a:%s:%Y' -- "$replacement")"
  replacement_hash="$(sha256sum -- "$replacement" | cut -d ' ' -f1)"
  replacement_bytes="$(cat -- "$replacement")"
  ready_fifo="$CASE_DIR/$barrier-ready"
  release_fifo="$CASE_DIR/$barrier-release"
  mkfifo "$ready_fifo" "$release_fifo"
  exec {ready_guard}<>"$ready_fifo"
  exec {ready_reader}<"$ready_fifo"
  exec {ready_writer}>"$ready_fifo"
  exec {release_guard}<>"$release_fifo"
  exec {release_reader}<"$release_fifo"
  exec {release_writer}>"$release_fifo"
  case "$barrier" in
    moved-guard)
      hook_args=(--test-after-moved-guard-validation-ready-fd "$ready_writer"
        --test-after-moved-guard-validation-release-fd "$release_reader")
      ;;
    quarantined-receipt)
      hook_args=(--test-after-quarantined-receipt-validation-ready-fd "$ready_writer"
        --test-after-quarantined-receipt-validation-release-fd "$release_reader")
      ;;
    *)
      echo "test_mount_anchor: unknown receipt retirement barrier: $barrier" >&2
      return 1
      ;;
  esac
  run_receipt_retire_helper "${hook_args[@]}" \
    >"$CASE_DIR/helper.stdout" 2>"$CASE_DIR/helper.stderr" &
  helper_pid=$!
  track_fixture_pid "$helper_pid"
  if ! timeout 10 bash -c 'IFS= read -r -n 1 _ <&"$1"' _ "$ready_reader"; then
    cat -- "$CASE_DIR/helper.stderr" >&2
    return 1
  fi
  validated_path=""
  while IFS= read -r -d '' candidate; do
    if [[ "$barrier" == moved-guard && "$(stat -c %s -- "$candidate")" -eq 0 ]]; then
      [[ -z "$validated_path" ]] || {
        echo 'test_mount_anchor: moved-guard barrier exposed multiple zero-length candidates' >&2
        return 1
      }
      validated_path="$candidate"
    elif [[ "$barrier" == quarantined-receipt &&
      "$(stat -c '%d:%i' -- "$candidate")" == "$RETAIN_RECEIPT_INODE" ]]; then
      [[ -z "$validated_path" ]] || {
        echo 'test_mount_anchor: receipt barrier exposed multiple held-receipt candidates' >&2
        return 1
      }
      validated_path="$candidate"
    fi
  done < <(find "$RETAIN_STATE" -maxdepth 1 -type f -print0)
  [[ -n "$validated_path" && ! -e "$RETAIN_RECEIPT" ]] || {
    echo "test_mount_anchor: $barrier barrier did not expose the validated artifact with canonical absent" >&2
    return 1
  }
  aside_path="$CASE_DIR/$barrier-validated-aside"
  mv -- "$validated_path" "$aside_path"
  mv -- "$replacement" "$validated_path"
  [[ "$(stat -c '%d:%i:%u:%g:%a:%s:%Y' -- "$validated_path")" == "$replacement_stat" &&
    "$(sha256sum -- "$validated_path" | cut -d ' ' -f1)" == "$replacement_hash" &&
    "$(cat -- "$validated_path")" == "$replacement_bytes" ]] || {
    echo "test_mount_anchor: $barrier replacement changed before barrier release" >&2
    return 1
  }
  printf R >&"$release_writer"
  if ! reap_fixture_pid "$helper_pid"; then
    cat -- "$CASE_DIR/helper.stderr" >&2
    return 1
  fi
  exec {ready_guard}>&- {ready_reader}<&- {ready_writer}>&-
  exec {release_guard}>&- {release_reader}<&- {release_writer}>&-
  [[ ! -e "$RETAIN_RECEIPT" ]] && canonical_absent=1
  [[ -e "$RETAIN_SENTINEL" ]] && backend_executed=1
  if [[ "$canonical_absent" -ne 1 || "$backend_executed" -ne 1 ||
    -s "$CASE_DIR/helper.stdout" || -s "$CASE_DIR/helper.stderr" ]]; then
    cat -- "$CASE_DIR/helper.stderr" >&2
    echo "test_mount_anchor: $barrier race did not consume once and execute the backend cleanly" >&2
    return 1
  fi
  if [[ ! -f "$validated_path" || -L "$validated_path" ]]; then
    remove_case_dir
    return 16
  fi
  final_stat="$(stat -c '%d:%i:%u:%g:%a:%s:%Y' -- "$validated_path")"
  final_hash="$(sha256sum -- "$validated_path" | cut -d ' ' -f1)"
  final_bytes="$(cat -- "$validated_path")"
  if [[ "$final_stat" != "$replacement_stat" || "$final_hash" != "$replacement_hash" ||
    "$final_bytes" != "$replacement_bytes" ]]; then
    remove_case_dir
    return 16
  fi
  remove_case_dir
  return 0
}

receipt_slot_exhaustion_subcase() {
  local fixture="$1"
  local kind="$2"
  local nonce="$3"
  local slot path output canonical_stat canonical_hash count=0

  prepare_receipt_retire_fixture "$fixture" "$kind-slots" "$nonce"
  for ((slot = 0; slot < 100; ++slot)); do
    printf -v path '%s/.workspace-receipt-%s.%s.%02u' \
      "$RETAIN_STATE" "$RETAIN_NONCE" "$kind" "$slot"
    printf 'occupied-%s-%02u\n' "$kind" "$slot" > "$path"
    chmod 0600 "$path"
  done
  canonical_stat="$(stat -c '%d:%i:%u:%g:%a:%s:%Y' -- "$RETAIN_RECEIPT")"
  canonical_hash="$(sha256sum -- "$RETAIN_RECEIPT" | cut -d ' ' -f1)"
  if output="$(run_receipt_retire_helper 2>&1)"; then
    echo "test_mount_anchor: occupied $kind slots unexpectedly allowed receipt consumption" >&2
    return 1
  fi
  [[ "$output" == 'ocsb: workspace receipt: retained slot exhaustion:'* &&
    ! -e "$RETAIN_SENTINEL" && -f "$RETAIN_RECEIPT" && ! -L "$RETAIN_RECEIPT" &&
    "$(stat -c '%d:%i:%u:%g:%a:%s:%Y' -- "$RETAIN_RECEIPT")" == "$canonical_stat" &&
    "$(sha256sum -- "$RETAIN_RECEIPT" | cut -d ' ' -f1)" == "$canonical_hash" &&
    "$(cat -- "$RETAIN_RECEIPT")" == "$RETAIN_LINE" ]] || {
    echo "test_mount_anchor: $kind slot exhaustion did not fail closed with canonical preserved" >&2
    return 1
  }
  for ((slot = 0; slot < 100; ++slot)); do
    printf -v path '%s/.workspace-receipt-%s.%s.%02u' \
      "$RETAIN_STATE" "$RETAIN_NONCE" "$kind" "$slot"
    [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%a' -- "$path")" == "$(id -u):600" &&
      "$(cat -- "$path")" == "occupied-$kind-$(printf '%02u' "$slot")" ]] || {
      echo "test_mount_anchor: $kind slot exhaustion changed or removed an occupied slot" >&2
      return 1
    }
    count=$((count + 1))
  done
  [[ "$count" -eq 100 ]] || return 1
  remove_case_dir
}

receipt_normal_retirement_subcase() {
  local fixture="$1"
  local nonce="$2"
  local artifact guard='' spent='' count=0

  prepare_receipt_retire_fixture "$fixture" normal "$nonce"
  run_receipt_retire_helper >"$CASE_DIR/helper.stdout" 2>"$CASE_DIR/helper.stderr" || {
    cat -- "$CASE_DIR/helper.stderr" >&2
    return 1
  }
  while IFS= read -r -d '' artifact; do
    count=$((count + 1))
    case "${artifact##*/}" in
      *.guard.[0-9][0-9]) guard="$artifact" ;;
      *.spent.[0-9][0-9]) spent="$artifact" ;;
      *)
        echo "test_mount_anchor: normal retirement retained an unexpected artifact: $artifact" >&2
        return 1
        ;;
    esac
    [[ -f "$artifact" && ! -L "$artifact" &&
      "$(stat -c '%u:%a:%s' -- "$artifact")" == "$(id -u):600:0" ]] || {
      echo "test_mount_anchor: normal retirement retained an unsafe or nonempty artifact: $artifact" >&2
      return 1
    }
  done < <(find "$RETAIN_STATE" -maxdepth 1 -type f -name ".workspace-receipt-$RETAIN_NONCE.*" -print0)
  [[ "$count" -eq 2 && -n "$guard" && -n "$spent" &&
    "$(stat -c '%d:%i' -- "$guard")" == "$RETAIN_RECEIPT_INODE" &&
    ! -e "$RETAIN_RECEIPT" && -e "$RETAIN_SENTINEL" &&
    ! -s "$CASE_DIR/helper.stdout" && ! -s "$CASE_DIR/helper.stderr" ]] || {
    echo 'test_mount_anchor: normal retirement did not retire the held receipt FD into two artifacts' >&2
    return 1
  }
  remove_case_dir
}

receipt_consume_once_subcase() {
  local fixture="$1"
  local nonce="$2"
  local ready_fifo empty_release ready_guard ready_reader ready_writer release_reader helper_pid
  local artifact count=0 consume_errors

  prepare_receipt_retire_fixture "$fixture" consume-once "$nonce"
  ready_fifo="$CASE_DIR/consume-once-ready"
  empty_release="$CASE_DIR/empty-release"
  mkfifo "$ready_fifo"
  : > "$empty_release"
  exec {ready_guard}<>"$ready_fifo"
  exec {ready_reader}<"$ready_fifo"
  exec {ready_writer}>"$ready_fifo"
  exec {release_reader}<"$empty_release"
  run_receipt_retire_helper \
    --test-after-moved-guard-validation-ready-fd "$ready_writer" \
    --test-after-moved-guard-validation-release-fd "$release_reader" \
    >"$CASE_DIR/helper.stdout" 2>"$CASE_DIR/helper.stderr" &
  helper_pid=$!
  track_fixture_pid "$helper_pid"
  if ! timeout 10 bash -c 'IFS= read -r -n 1 _ <&"$1"' _ "$ready_reader"; then
    cat -- "$CASE_DIR/helper.stderr" >&2
    return 1
  fi
  reap_fixture_pid_failure "$helper_pid" || return 1
  exec {ready_guard}>&- {ready_reader}<&- {ready_writer}>&- {release_reader}<&-
  while IFS= read -r -d '' artifact; do
    count=$((count + 1))
    [[ -f "$artifact" && ! -L "$artifact" &&
      "$(stat -c '%u:%a' -- "$artifact")" == "$(id -u):600" ]] || return 1
  done < <(find "$RETAIN_STATE" -maxdepth 1 -type f -name ".workspace-receipt-$RETAIN_NONCE.*" -print0)
  consume_errors="$(awk 'index($0, "workspace receipt: cannot consume exact receipt") { count++ } END { print count + 0 }' \
    "$CASE_DIR/helper.stderr")"
  [[ "$count" -eq 2 && "$consume_errors" -eq 1 && ! -e "$RETAIN_RECEIPT" &&
    ! -e "$RETAIN_SENTINEL" && ! -s "$CASE_DIR/helper.stdout" &&
    "$(awk 'index($0, "retained slot exhaustion") { count++ } END { print count + 0 }' "$CASE_DIR/helper.stderr")" -eq 0 ]] || {
    cat -- "$CASE_DIR/helper.stderr" >&2
    echo 'test_mount_anchor: failed consumption was retried or changed retained artifacts' >&2
    return 1
  }
  remove_case_dir
}

assert_receipt_consume_source_has_zero_unlink() {
  local source="$REPO_ROOT/pkgs/ocsb-mount-anchor.c"
  local consume_segment free_segment

  consume_segment="$(sed -n \
    '/^static int create_retained_receipt_guard/,/^static const char \*strategy_child_name/p' \
    "$source")"
  free_segment="$(sed -n \
    '/^static void free_workspace_receipt/,/^static int load_workspace_receipt/p' "$source")"
  [[ -n "$consume_segment" && -n "$free_segment" ]] || {
    echo 'test_mount_anchor: cannot locate receipt retirement source boundaries' >&2
    return 1
  }
  if grep -Eq '(^|[^[:alnum:]_])(unlink|unlinkat)[[:space:]]*\(' \
    <<<"$consume_segment"$'\n'"$free_segment"; then
    echo 'test_mount_anchor: receipt consume/discard/free source contains pathname unlink cleanup' >&2
    return 1
  fi
  grep -Fq 'if (receipt->consume_attempted)' "$source" || {
    echo 'test_mount_anchor: receipt consumption lacks the EALREADY consume-once guard' >&2
    return 1
  }
}

receipt_retain_retire_case() {
  local fixture="$1"
  local moved_rc quarantine_rc

  require_prepared_fixture "$fixture"
  if receipt_post_validation_swap_subcase "$fixture" moved-guard \
    1111111111111111111111111111111111111111111111111111111111111111; then
    moved_rc=0
  else
    moved_rc=$?
  fi
  if receipt_post_validation_swap_subcase "$fixture" quarantined-receipt \
    2222222222222222222222222222222222222222222222222222222222222222; then
    quarantine_rc=0
  else
    quarantine_rc=$?
  fi
  if [[ "${OCSB_EXPECT_TASK16_RED:-0}" == 1 ]]; then
    [[ "$moved_rc" -eq 16 && "$quarantine_rc" -eq 16 ]] || {
      echo "test_mount_anchor: Task 16 RED control was not the validated-name unlink race ($moved_rc/$quarantine_rc)" >&2
      return 1
    }
    printf '%s\n' 'FAIL[RED-receipt-moved-guard-swap]: validated-name replacement was removed or changed'
    printf '%s\n' 'FAIL[RED-receipt-quarantine-swap]: validated-name replacement was removed or changed'
    printf '%s\n' 'FAIL[RED-receipt-retain-retire]: consume path pathname-unlinked a post-validation replacement'
    return 1
  fi
  [[ "$moved_rc" -eq 0 && "$quarantine_rc" -eq 0 ]] || {
    echo "test_mount_anchor: retained-name race subcases failed ($moved_rc/$quarantine_rc)" >&2
    return 1
  }
  printf '%s\n' 'PASS[GREEN-receipt-moved-guard-swap]: replacement-inode-bytes-unchanged canonical-absent backend=executed'
  printf '%s\n' 'PASS[GREEN-receipt-quarantine-swap]: replacement-inode-bytes-unchanged canonical-absent backend=executed'
  receipt_slot_exhaustion_subcase "$fixture" guard \
    3333333333333333333333333333333333333333333333333333333333333333
  receipt_slot_exhaustion_subcase "$fixture" spent \
    4444444444444444444444444444444444444444444444444444444444444444
  printf '%s\n' 'PASS[GREEN-receipt-slot-exhaustion]: canonical-preserved backend-refused no-pathname-cleanup'
  receipt_normal_retirement_subcase "$fixture" \
    5555555555555555555555555555555555555555555555555555555555555555
  receipt_consume_once_subcase "$fixture" \
    6666666666666666666666666666666666666666666666666666666666666666
  assert_receipt_consume_source_has_zero_unlink
  if find "$fixture" -maxdepth 1 -type d -name 'receipt-retire.*' -print -quit | grep -q .; then
    echo 'test_mount_anchor: receipt retain-retire case directories survived offline cleanup' >&2
    return 1
  fi
  printf '%s\n' 'PASS[GREEN-receipt-retain-retire]: receipt-fd-retired two-artifacts consume-once zero-unlink'
  printf '%s\n' 'CLEANUP PASS: receipt retain-retire fixtures offline-removed'
}

exit_cleanup_trigger_case() {
  local fixture="$1"

  require_prepared_fixture "$fixture"
  ACTIVE_FIXTURE="$fixture"
  install -d -m 0700 "$fixture/runtime/ocsb/anchors/leak-negative-control"
}

exit_cleanup_original_status_case() {
  local fixture="$1"

  require_prepared_fixture "$fixture"
  ACTIVE_FIXTURE="$fixture"
  assert_host_anchors_empty "$fixture" || return 1
  return 37
}

test_evidence_case() {
  local fixture="$1" output rc clean_output clean_rc
  local generic_stderr generic_victim generic_sentinel generic_state generic_hash

  require_prepared_fixture "$fixture"
  nested_symlink_case "$fixture"
  CASE_DIR="$(mktemp -d "$fixture/nested-generic-control.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"
  generic_stderr="$CASE_DIR/generic.stderr"
  generic_victim="$CASE_DIR/victim"
  generic_sentinel="$CASE_DIR/backend-sentinel"
  install -d -m 0700 "$generic_victim"
  printf 'pristine\n' > "$generic_victim/marker"
  generic_state="$(stat -c '%d:%i:%a' "$generic_victim")"
  generic_hash="$(sha256sum "$generic_victim/marker" | cut -d ' ' -f1)"
  printf 'workspace protocol\n' > "$generic_stderr"
  if nested_workspace_refusal_is_safe 1 \
    'workspace protocol: cannot open strategy child: worktree' "$generic_stderr" "$generic_sentinel" \
    "$generic_victim" "$generic_state" "$generic_hash" pristine; then
    echo 'test_mount_anchor: generic nested diagnostic unexpectedly passed exact control' >&2
    return 1
  fi
  remove_case_dir
  set +e
  output="$("$SCRIPT_DIR/test_mount_anchor.sh" --case exit-cleanup-trigger "$fixture" 2>&1)"
  rc=$?
  set -e
  rm -rf -- "$fixture/runtime/ocsb/anchors/leak-negative-control"
  [[ "$rc" -eq 1 && "$output" == *'private runtime anchors leaked into the host namespace'* ]] || {
    echo 'test_mount_anchor: EXIT cleanup negative control did not force failure' >&2
    return 1
  }
  assert_host_anchors_empty "$fixture"
  set +e
  clean_output="$("$SCRIPT_DIR/test_mount_anchor.sh" --case exit-cleanup-original-status "$fixture" 2>&1)"
  clean_rc=$?
  set -e
  [[ "$clean_rc" -eq 37 && "$clean_output" != *'private runtime anchors leaked into the host namespace'* ]] || {
    echo 'test_mount_anchor: EXIT cleanup did not preserve the clean original status' >&2
    return 1
  }
  printf '%s\n' 'PASS[GREEN-nested-symlink-boundary]: generic-control-rejected exact-worktree-snapshot-snap-state-diagnostics'
  printf '%s\n' 'PASS[GREEN-anchor-exit-cleanup]: leaked-anchor-forces-failure original-status-preserved'
  printf '%s\n' 'CLEANUP PASS: test-evidence negative controls'
}

result_value() {
  local result="$1"
  local name="$2"
  local value

  value="$(sed -n "s/^${name}=//p" "$result")"
  [[ -n "$value" ]] || {
    echo "test_mount_anchor: malformed fake-runtime result ($name)" >&2
    return 1
  }
  printf '%s\n' "$value"
}

make_source() {
  local fixture="$1"
  local kind="$2"
  local case_path="$3"
  local source victim

  clear_mount_sources "$fixture"
  rm -rf -- "$fixture/rootfs" "$case_path/held"
  install -d -m 0700 "$fixture/rootfs"

  case "$kind" in
    directory)
      source="$fixture/mount-directory"
      victim="$case_path/victim-directory"
      install -d -m 0700 "$source" "$victim"
      printf 'original\n' > "$source/marker"
      printf 'victim\n' > "$victim/marker"
      printf 'support\n' > "$fixture/mount-file"
      ;;
    regular)
      source="$fixture/mount-file"
      victim="$case_path/victim-file"
      printf 'original\n' > "$source"
      printf 'victim\n' > "$victim"
      install -d -m 0700 "$fixture/mount-directory"
      printf 'support\n' > "$fixture/mount-directory/marker"
      ;;
    *)
      echo "test_mount_anchor: unknown source kind: $kind" >&2
      return 2
      ;;
  esac
  printf '%s\t%s\n' "$source" "$victim"
}

source_spec() {
  local token="$1"
  local source="$2"
  local containment_root="$3"
  local kind="$4"
  local requiredness="${5:-required}"
  local drop_start="${6:-0}"
  local drop_count="${7:-0}"
  local device inode

  if [[ "$requiredness" == optional && ! -e "$source" ]]; then
    device=0
    inode=0
  else
    device="$(stat -c '%d' -- "$source")"
    inode="$(stat -c '%i' -- "$source")"
  fi
  # Fields are token, absolute path, containment root, dev, ino, expected
  # type, requiredness, optional argv drop start, optional argv drop count.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$token" "$source" "$containment_root" "$device" "$inode" "$kind" \
    "$requiredness" "$drop_start" "$drop_count"
}

run_nspawn_in_identity_namespace() {
  local uid gid

  uid="$(id -u)"
  gid="$(id -g)"
  if [[ "$uid" -eq 0 ]]; then
    exec "$@"
  fi
  exec unshare --user --map-current-user --mount --keep-caps --fork -- "$@"
}

run_helper_backend() {
  local helper="$1"
  local fixture="$2"
  local backend="$3"
  local source="$4"
  local kind="$5"
  local destination="$6"
  local token='@OCSB_SOURCE_0@'
  local root_token='@OCSB_SOURCE_1@'
  local rootfs="$fixture/rootfs"
  local uid gid spec root_spec namespace index root_index
  local -a payload helper_args

  uid="$(id -u)"
  gid="$(id -g)"
  spec="$(source_spec "$token" "$source" "$fixture" "$kind")"
  case "$backend" in
    bubblewrap)
      namespace='bubblewrap-user'
      payload=("$fixture/fake-bin/bwrap" --uid "$uid" --gid "$gid" --ro-bind "$token" "$destination" -- /bin/true)
      index=6
      ;;
    podman)
      namespace='current'
      root_spec="$(source_spec "$root_token" "$rootfs" "$fixture" directory)"
      payload=("$fixture/fake-bin/podman" run --rm --userns=keep-id --user "$uid:$gid" --volume "$token:$destination:ro" --rootfs "$root_token" /bin/true)
      index=7
      root_index=9
      ;;
    nspawn)
      namespace='current'
      root_spec="$(source_spec "$root_token" "$rootfs" "$fixture" directory)"
      payload=("$fixture/fake-bin/systemd-nspawn" --quiet --directory="$root_token" --user="$uid" --bind-ro="$token:$destination" -- /bin/true)
      index=4
      root_index=2
      ;;
    *)
      return 2
      ;;
  esac

  # --replace indexes the payload argv, including payload[0] (the backend
  # executable).  Keeping that definition here makes the helper's argv
  # rewriting contract independently testable instead of backend-parser magic.
  helper_args=(--backend "$backend" --namespace "$namespace" --host-uid "$uid" --host-gid "$gid"
    --anchor-root "$fixture/runtime" --source-spec "$spec" --replace "$index:$token")
  if [[ "$backend" != bubblewrap ]]; then
    helper_args+=(--source-spec "$root_spec" --replace "$root_index:$root_token")
  fi
  if [[ "$backend" == nspawn ]]; then
    run_nspawn_in_identity_namespace "$helper" "${helper_args[@]}" -- "${payload[@]}"
  elif [[ "$backend" == podman ]]; then
    "$fixture/fake-bin/podman" --remote=false unshare "$helper" \
      "${helper_args[@]}" -- "${payload[@]}"
  else
    "$helper" "${helper_args[@]}" -- "${payload[@]}"
  fi
}

run_prepared_backend() {
  local fixture="$1"
  local backend="$2"
  local kind="$3"
  local source="$4"
  local victim="$5"
  local case_path="$6"
  local result="$case_path/result"
  local launcher="$fixture/launchers/bin/ocsb-mount-anchor-$backend"

  (
    cd "$fixture/project"
    export \
      PATH="$fixture/fake-bin:$PATH" \
      XDG_RUNTIME_DIR="$fixture/runtime" \
      OCSB_STATE_BASE_DIR="$case_path/state" \
      FAKE_ANCHOR_PRIVATE_PREFIX="$fixture/runtime/ocsb/anchors/mount-" \
      FAKE_ANCHOR_DESTINATION="$source" \
      FAKE_ANCHOR_ORIGINAL="$source" \
      FAKE_ANCHOR_VICTIM="$victim" \
      FAKE_ANCHOR_HELD="$case_path/held" \
      FAKE_ANCHOR_FORKED="$case_path/forked" \
      FAKE_ANCHOR_RELEASE="$case_path/release" \
      FAKE_ANCHOR_RESULT="$result" \
      FAKE_ANCHOR_HOST_UID="$(id -u)" \
      FAKE_ANCHOR_HOST_GID="$(id -g)"
    if [[ "$backend" == nspawn ]]; then
      run_nspawn_in_identity_namespace "$launcher" -w "mount-anchor-$backend-$kind" \
        --strategy direct --overwrite -- -c true
    else
      "$launcher" -w "mount-anchor-$backend-$kind" --strategy direct --overwrite -- -c true
    fi
  )
}

run_one_swap() {
  local fixture="$1"
  local backend="$2"
  local kind="$3"
  local helper="$4"
  local case_path="$CASE_DIR/$backend-$kind"
  local source victim pair result observed actual_type backend_source
  local swapped_marker

  install -d -m 0700 "$case_path"
  pair="$(make_source "$fixture" "$kind" "$case_path")"
  source="${pair%%$'\t'*}"
  victim="${pair#*$'\t'}"
  result="$case_path/result"

  if [[ -n "$helper" ]]; then
    (
      export \
      FAKE_ANCHOR_DESTINATION="$source" \
      FAKE_ANCHOR_ORIGINAL="$source" \
      FAKE_ANCHOR_VICTIM="$victim" \
      FAKE_ANCHOR_HELD="$case_path/held" \
      FAKE_ANCHOR_FORKED="$case_path/forked" \
      FAKE_ANCHOR_RELEASE="$case_path/release" \
      FAKE_ANCHOR_RESULT="$result" \
      FAKE_ANCHOR_PRIVATE_PREFIX="$fixture/runtime/anchors/mount-" \
      FAKE_ANCHOR_HOST_UID="$(id -u)" \
      FAKE_ANCHOR_HOST_GID="$(id -g)"
      run_helper_backend "$helper" "$fixture" "$backend" "$source" "$kind" "$source"
    )
  else
    run_prepared_backend "$fixture" "$backend" "$kind" "$source" "$victim" "$case_path"
  fi

  [[ -f "$result" ]] || {
    echo "test_mount_anchor: fake $backend did not leave a result" >&2
    return 1
  }
  observed="$(result_value "$result" observed)"
  actual_type="$(result_value "$result" type)"
  backend_source="$(result_value "$result" source)"
  [[ "$actual_type" == "$kind" ]] || {
    echo "test_mount_anchor: fake $backend changed $kind source type to $actual_type" >&2
    return 1
  }
  if [[ "$kind" == directory ]]; then
    swapped_marker="$source/marker"
  else
    swapped_marker="$source"
  fi
  [[ -L "$source" && "$(cat -- "$swapped_marker")" == 'victim' ]] || {
    echo "test_mount_anchor: fake $backend did not complete the pathname swap" >&2
    return 1
  }
  if [[ "$kind" == directory ]]; then
    [[ "$(cat -- "$victim/marker")" == victim ]] || {
      echo "test_mount_anchor: fake $backend changed the directory victim" >&2
      return 1
    }
  else
    [[ "$(cat -- "$victim")" == victim ]] || {
      echo "test_mount_anchor: fake $backend changed the regular-file victim" >&2
      return 1
    }
  fi
  printf '%s\t%s\t%s\n' "$observed" "$backend_source" "$actual_type"
}

private_anchor_source() {
  local fixture="$1"
  local anchor_root="$2"
  local source="$3"

  [[ "$source" == "$anchor_root/anchors/mount-"*/* && "$source" != /proc/self/fd/* ]]
}

deterministic_swap_case() {
  local fixture="$1"
  local helper="$2"
  local backend kind result observed source actual_type anchor_root
  local -A observations=()
  local -A sources=()
  local -A types=()

  require_prepared_fixture "$fixture"
  require_user_namespace || return $?
  if [[ -n "$helper" && ! -x "$helper" ]]; then
    echo "test_mount_anchor: helper is not executable: $helper" >&2
    return 2
  fi
  CASE_DIR="$(mktemp -d "$fixture/case.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"
  rm -rf -- "$fixture/project/.ocsb"
  anchor_root="$fixture/runtime/ocsb"
  [[ -n "$helper" ]] && anchor_root="$fixture/runtime"

  for backend in bubblewrap podman nspawn; do
    for kind in directory regular; do
      result="$(run_one_swap "$fixture" "$backend" "$kind" "$helper")"
      observed="${result%%$'\t'*}"
      result="${result#*$'\t'}"
      source="${result%%$'\t'*}"
      actual_type="${result##*$'\t'}"
      observations["$backend:$kind"]="$observed"
      sources["$backend:$kind"]="$source"
      types["$backend:$kind"]="$actual_type"
    done
  done

  if [[ "${observations[bubblewrap:directory]}" == victim &&
    "${observations[podman:directory]}" == victim &&
    "${observations[nspawn:directory]}" == victim &&
    "${observations[bubblewrap:regular]}" == victim &&
    "${observations[podman:regular]}" == victim &&
    "${observations[nspawn:regular]}" == victim ]]; then
    printf '%s\n' 'FAIL[RED-mount-anchor-bubblewrap]: observed=victim'
    printf '%s\n' 'FAIL[RED-mount-anchor-podman]: observed=victim'
    printf '%s\n' 'FAIL[RED-mount-anchor-nspawn]: observed=victim'
    return 1
  fi

  for backend in bubblewrap podman nspawn; do
    for kind in directory regular; do
      [[ "${observations[$backend:$kind]}" == original ]] || {
        echo "test_mount_anchor: $backend/$kind observed ${observations[$backend:$kind]}, expected original" >&2
        return 1
      }
      private_anchor_source "$fixture" "$anchor_root" "${sources[$backend:$kind]}" || {
        echo "test_mount_anchor: $backend/$kind did not receive a private runtime anchor" >&2
        return 1
      }
    done
  done

  assert_host_anchors_empty "$fixture"
  printf '%s\n' 'PASS[GREEN-mount-anchor-bubblewrap]: observed=original source=private-runtime-anchor'
  printf '%s\n' 'PASS[GREEN-mount-anchor-podman]: observed=original source=private-runtime-anchor'
  printf '%s\n' 'PASS[GREEN-mount-anchor-nspawn]: observed=original source=private-runtime-anchor'
  printf '%s\n' 'PASS[GREEN-post-open-swap]: original pathname now victim; anchored marker still original'
  printf '%s\n' 'PASS[GREEN-anchor-types]: directory=directory regular=regular'
  printf 'PASS[GREEN-id-semantics]: bwrap=%s podman=%s nspawn=%s\n' "$(id -u)" "$(id -u)" "$(id -u)"
  clear_mount_sources "$fixture"
  rm -rf -- "$fixture/rootfs"
  rm -f -- "$fixture/runtime/ocsb"/process-*.pid 2>/dev/null || true
  remove_case_dir
  printf '%s\n' 'CLEANUP PASS: no host per-run mount anchors'
}

run_optional_manifest_backend() {
  local fixture="$1"
  local backend="$2"
  local helper="$fixture/launchers/bin/ocsb-mount-anchor-manifest-unit"
  local optional="$fixture/runtime/anchors/unit-optional-$backend"
  local required="$fixture/runtime/anchors/unit-required-$backend"
  local rootfs="$fixture/runtime/anchors/unit-rootfs-$backend"
  local optional_token='@OCSB_SOURCE_0@'
  local required_token='@OCSB_SOURCE_1@'
  local rootfs_token='@OCSB_SOURCE_2@'
  local uid gid namespace optional_spec required_spec rootfs_spec
  local -a payload helper_args

  rm -rf -- "$optional" "$required" "$rootfs"
  printf 'anchored\n' > "$required"
  install -d -m 0700 "$rootfs"
  uid="$(id -u)"
  gid="$(id -g)"
  optional_spec="$(source_spec "$optional_token" "$optional" "$fixture/runtime" regular optional 0 0)"
  required_spec="$(source_spec "$required_token" "$required" "$fixture/runtime" regular)"
  rootfs_spec="$(source_spec "$rootfs_token" "$rootfs" "$fixture/runtime" directory)"

  case "$backend" in
    bubblewrap)
      namespace=bubblewrap-user
      payload=("$fixture/fake-bin/bwrap" --uid "$uid" --gid "$gid" \
        --ro-bind-try "$optional_token" /optional --ro-bind "$required_token" /required -- /bin/true)
      optional_spec="$(source_spec "$optional_token" "$optional" "$fixture/runtime" regular optional 5 3)"
      helper_args=(--source-spec "$optional_spec" --replace "6:$optional_token"
        --source-spec "$required_spec" --replace "9:$required_token")
      ;;
    podman)
      namespace=current
      payload=("$fixture/fake-bin/podman" run --rm --userns=keep-id --user "$uid:$gid" \
        --volume "$optional_token:/optional:ro" --volume "$required_token:/required:ro" \
        --rootfs "$rootfs_token" /bin/true)
      optional_spec="$(source_spec "$optional_token" "$optional" "$fixture/runtime" regular optional 6 2)"
      helper_args=(--source-spec "$optional_spec" --replace "7:$optional_token"
        --source-spec "$required_spec" --replace "9:$required_token"
        --source-spec "$rootfs_spec" --replace "11:$rootfs_token")
      ;;
    nspawn)
      namespace=current
      payload=("$fixture/fake-bin/systemd-nspawn" --quiet --directory="$rootfs_token" --user="$uid" \
        --bind-ro="$optional_token:/optional" --bind-ro="$required_token:/required" -- /bin/true)
      optional_spec="$(source_spec "$optional_token" "$optional" "$fixture/runtime" regular optional 4 1)"
      helper_args=(--source-spec "$optional_spec" --replace "4:$optional_token"
        --source-spec "$required_spec" --replace "5:$required_token"
        --source-spec "$rootfs_spec" --replace "2:$rootfs_token")
      ;;
    *)
      echo "test_mount_anchor: unknown optional-manifest backend: $backend" >&2
      return 2
      ;;
  esac

  FAKE_ANCHOR_MANIFEST_UNIT=1 \
    FAKE_ANCHOR_PRIVATE_PREFIX="$fixture/runtime/anchors/unit-" \
    FAKE_ANCHOR_DESTINATION=/required \
    FAKE_ANCHOR_HOST_UID="$uid" \
    FAKE_ANCHOR_HOST_GID="$gid" \
    OCSB_MOUNT_ANCHOR_RUN_MANIFEST_UNIT=1 \
    "$helper" --backend "$backend" --namespace "$namespace" --host-uid "$uid" --host-gid "$gid" \
      --anchor-root "$fixture/runtime" "${helper_args[@]}" -- "${payload[@]}"

  rm -rf -- "$required" "$rootfs"
}

optional_source_absent_case() {
  local fixture="$1"
  local backend

  require_prepared_fixture "$fixture"
  CASE_DIR="$(mktemp -d "$fixture/optional.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"
  for backend in bubblewrap podman nspawn; do
    run_optional_manifest_backend "$fixture" "$backend"
  done
  assert_host_anchors_empty "$fixture"
  remove_case_dir
  printf '%s\n' 'PASS[GREEN-optional-mount]: bubblewrap=omitted podman=omitted nspawn=omitted required=anchored'
}

nested_workspace_refusal_is_safe() {
  local rc="$1"
  local expected_diagnostic="$2"
  local stderr_file="$3"
  local backend_sentinel="$4"
  local victim="$5"
  local victim_state="$6"
  local marker_hash="$7"
  local marker_content="$8"
  local expected_line="ocsb: $expected_diagnostic"
  local line suffix diagnostic_found=0

  [[ "$rc" -ne 0 && -f "$stderr_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$expected_line" ]]; then
      diagnostic_found=1
      break
    fi
    if [[ "$line" == "$expected_line: "* ]]; then
      suffix="${line#"$expected_line: "}"
      if [[ -n "$suffix" ]]; then
        diagnostic_found=1
        break
      fi
    fi
  done < "$stderr_file"
  [[ "$diagnostic_found" -eq 1 ]] || return 1
  [[ ! -e "$backend_sentinel" && "$(stat -c '%d:%i:%a' "$victim")" == "$victim_state" &&
    "$(sha256sum -- "$victim/marker" | cut -d ' ' -f1)" == "$marker_hash" &&
    "$(cat -- "$victim/marker")" == "$marker_content" ]]
}

run_nested_workspace_probe() {
  local fixture="$1"
  local name="$2"
  local nested_name="$3"
  local destination="$4"
  local victim="$CASE_DIR/victim-$nested_name"
  local state="$CASE_DIR/state-$nested_name"
  local project="$fixture/project"
  local nested_path expected_diagnostic backend_sentinel victim_state victim_marker_hash
  local existing_strategy
  local -a launcher_args

  rm -rf -- "$project/.ocsb" "$state" "$victim"
  clear_mount_sources "$fixture"
  install -d -m 0700 "$fixture/mount-directory"
  printf 'support\n' > "$fixture/mount-directory/marker"
  printf 'support\n' > "$fixture/mount-file"
  install -d -m 0700 "$project/.ocsb/$name" "$state" "$victim"
  printf 'pristine\n' > "$victim/marker"

  case "$nested_name" in
    worktree)
      existing_strategy=git-worktree
      nested_path="$project/.ocsb/$name/worktree"
      expected_diagnostic='workspace protocol: cannot open strategy child: worktree'
      ln -s -- "$victim" "$nested_path"
      launcher_args=(-w "$name" --strategy git-worktree --continue -- -c true)
      ;;
    snapshot)
      existing_strategy=btrfs
      nested_path="$project/.ocsb/$name/snapshot"
      expected_diagnostic='workspace protocol: cannot open strategy child: snapshot'
      ln -s -- "$victim" "$nested_path"
      launcher_args=(-w "$name" --strategy btrfs --continue -- -c true)
      ;;
    snap-state)
      existing_strategy=direct
      local source="$CASE_DIR/snap-source"
      local hash
      install -d -m 0700 "$source" "$state/$name/snapshots"
      hash="$(printf '%s' "$source" | sha256sum | cut -c1-12)"
      nested_path="$state/$name/snapshots/snap-$hash"
      expected_diagnostic="unsafe host path: symlink source refused: $nested_path"
      ln -s -- "$victim" "$nested_path"
      launcher_args=(-w "$name" --strategy direct --continue \
        --snap-mount "$source:$destination" -- -c true)
      ;;
    *) return 2 ;;
  esac

  install -d -m 0700 "$state/$name"
  printf '%s\n' "$existing_strategy" > "$state/$name/.strategy"
  printf '%s\n' bubblewrap > "$state/$name/.backend"
  backend_sentinel="$CASE_DIR/$nested_name.backend"
  victim_state="$(stat -c '%d:%i:%a' "$victim")"
  victim_marker_hash="$(sha256sum -- "$victim/marker" | cut -d ' ' -f1)"

  set +e
  (
    cd "$project"
    env \
      XDG_RUNTIME_DIR="$fixture/runtime" \
      OCSB_STATE_BASE_DIR="$state" \
      FAKE_ANCHOR_PRIVATE_PREFIX="$fixture/runtime/ocsb/anchors/mount-" \
      FAKE_ANCHOR_DESTINATION="$destination" \
      FAKE_ANCHOR_NESTED_VICTIM=1 \
      OCSB_MUTATION_BACKEND_SENTINEL="$backend_sentinel" \
      FAKE_ANCHOR_HOST_UID="$(id -u)" \
      FAKE_ANCHOR_HOST_GID="$(id -g)" \
      "$fixture/launchers/bin/ocsb-mount-anchor-bubblewrap" "${launcher_args[@]}"
  ) >"$CASE_DIR/$nested_name.stdout" 2>"$CASE_DIR/$nested_name.stderr"
  local rc=$?
  set -e

  if nested_workspace_refusal_is_safe "$rc" "$expected_diagnostic" "$CASE_DIR/$nested_name.stderr" \
      "$backend_sentinel" "$victim" "$victim_state" "$victim_marker_hash" pristine; then
    printf 'refused:%s\n' "$nested_name"
  elif [[ "$(cat -- "$victim/marker")" == modified ]]; then
    printf 'modified\n'
  else
    cat -- "$CASE_DIR/$nested_name.stderr" >&2
    echo "test_mount_anchor: nested $nested_name probe neither modified nor safely refused" >&2
    return 1
  fi
}

nested_symlink_case() {
  local fixture="$1"
  local worktree snapshot snap_state

  require_prepared_fixture "$fixture"
  require_user_namespace || return $?
  CASE_DIR="$(mktemp -d "$fixture/nested.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"

  worktree="$(run_nested_workspace_probe "$fixture" nested-worktree worktree /workspace)"
  snapshot="$(run_nested_workspace_probe "$fixture" nested-snapshot snapshot /workspace)"
  snap_state="$(run_nested_workspace_probe "$fixture" nested-snap-state snap-state /workspace/snap-data)"

  if [[ "$worktree" == modified && "$snapshot" == modified && "$snap_state" == modified ]]; then
    echo 'FAIL[RED-nested-workspace-symlink]: victim modified'
    return 1
  fi
  if [[ "$worktree" == refused:worktree && "$snapshot" == refused:snapshot && "$snap_state" == refused:snap-state ]]; then
    assert_host_anchors_empty "$fixture"
    clear_mount_sources "$fixture"
    remove_case_dir
    echo 'PASS[GREEN-nested-workspace-symlink]: worktree-child snapshot-child snap-state-path refused; victims unchanged backend-refused'
    return 0
  fi
  echo "test_mount_anchor: inconsistent nested results: worktree=$worktree snapshot=$snapshot snap-state=$snap_state" >&2
  return 1
}

prepare_real_sources() {
  local fixture="$1"

  clear_mount_sources "$fixture"
  rm -rf -- "$fixture/rootfs"
  install -d -m 0700 "$fixture/mount-directory" "$fixture/rootfs"
  printf 'real-anchor\n' > "$fixture/mount-directory/marker"
  printf 'support\n' > "$fixture/mount-file"
}

run_real_payload() {
  local fixture="$1"
  local launcher="$2"
  local backend="$3"
  local binary_path="$4"
  local uid gid script

  uid="$(id -u)"
  gid="$(id -g)"
  script='set -e; test "$(id -u)" = "$OCSB_TEST_UID"; test "$(id -g)" = "$OCSB_TEST_GID"; test "$(cat /home/sandbox/anchor/marker)" = real-anchor; printf "uid=%s gid=%s marker=%s\n" "$(id -u)" "$(id -g)" "$(cat /home/sandbox/anchor/marker)"'
  (
    cd "$fixture/project"
    PATH="$binary_path:$PATH" \
      XDG_RUNTIME_DIR="$fixture/runtime" \
      OCSB_STATE_BASE_DIR="$CASE_DIR/state-$backend" \
      "$launcher" -w "real-anchor-$backend" --strategy direct --overwrite \
        --ro "$fixture/mount-directory:/home/sandbox/anchor" \
        --env "OCSB_TEST_UID=$uid" --env "OCSB_TEST_GID=$gid" -- \
        -c "$script"
  )
}

require_remote_podman_refusal() {
  local fixture="$1"
  local launcher="$fixture/launchers/bin/ocsb-mount-anchor-podman"
  local rc

  set +e
  (
    cd "$fixture/project"
    env \
      PATH="$fixture/fake-bin:$PATH" \
      XDG_RUNTIME_DIR="$fixture/runtime" \
      OCSB_STATE_BASE_DIR="$CASE_DIR/remote-state" \
      CONTAINER_HOST='ssh://remote.invalid' \
      "$launcher" -w real-anchor-remote --strategy direct --overwrite -- -c true
  ) >"$CASE_DIR/remote-podman.stdout" 2>"$CASE_DIR/remote-podman.stderr"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] && grep -Fq 'refuses remote connections when private mount anchors are required' \
    "$CASE_DIR/remote-podman.stderr" || {
    cat "$CASE_DIR/remote-podman.stdout" "$CASE_DIR/remote-podman.stderr" >&2
    echo 'test_mount_anchor: remote Podman did not refuse before attempting a runtime connection' >&2
    return 1
  }
}

real_runtime_secondary_case() {
  local fixture="$1"
  local uid gid result podman_bin nspawn_bin
  local real_bwrap="$fixture/launchers/bin/ocsb-mount-anchor-real-bubblewrap"

  require_prepared_fixture "$fixture"
  require_user_namespace || return $?
  CASE_DIR="$(mktemp -d "$fixture/real.XXXXXX")"
  ACTIVE_FIXTURE="$fixture"
  prepare_real_sources "$fixture"
  uid="$(id -u)"
  gid="$(id -g)"

  result="$(run_real_payload "$fixture" "$real_bwrap" bubblewrap "$(dirname -- "$real_bwrap")")"
  [[ "$result" == "uid=$uid gid=$gid marker=real-anchor" ]] || {
    echo "test_mount_anchor: real bubblewrap payload mismatch: $result" >&2
    return 1
  }
  printf 'PASS[GREEN-real-bubblewrap-anchor]: uid=%s gid=%s marker=real-anchor\n' "$uid" "$gid"

  require_remote_podman_refusal "$fixture"
  printf '%s\n' 'PASS[GREEN-real-podman-remote-refusal]: refused'

  podman_bin="$(command -v podman || true)"
  if [[ -z "$podman_bin" ]]; then
    printf '%s\n' 'SKIP[CI-REQUIRED-real-podman-anchor]: podman unavailable'
  else
    result="$(run_real_payload "$fixture" "$fixture/launchers/bin/ocsb-mount-anchor-podman" podman "$(dirname -- "$podman_bin")")"
    [[ "$result" == "uid=$uid gid=$gid marker=real-anchor" ]] || {
      echo "test_mount_anchor: real Podman payload mismatch: $result" >&2
      return 1
    }
    printf 'PASS[GREEN-real-podman-anchor]: uid=%s gid=%s marker=real-anchor\n' "$uid" "$gid"
  fi

  if ! command -v unshare >/dev/null 2>&1 || ! unshare --mount true >/dev/null 2>&1; then
    printf '%s\n' 'SKIP[CI-REQUIRED-real-nspawn-anchor]: CAP_SYS_ADMIN unavailable'
  else
    nspawn_bin="$(command -v systemd-nspawn || true)"
    [[ -n "$nspawn_bin" ]] || {
      echo 'test_mount_anchor: systemd-nspawn is required when CAP_SYS_ADMIN is available' >&2
      return 1
    }
    result="$(run_real_payload "$fixture" "$fixture/launchers/bin/ocsb-mount-anchor-nspawn" nspawn "$(dirname -- "$nspawn_bin")")"
    [[ "$result" == "uid=$uid gid=$gid marker=real-anchor" ]] || {
      echo "test_mount_anchor: real nspawn payload mismatch: $result" >&2
      return 1
    }
    printf 'PASS[GREEN-real-nspawn-anchor]: uid=%s gid=%s marker=real-anchor\n' "$uid" "$gid"
  fi

  assert_host_anchors_empty "$fixture"
  clear_mount_sources "$fixture"
  rm -rf -- "$fixture/rootfs"
  remove_case_dir
}

real_rootless_podman_case() {
  local launcher="$1"
  local podman_bin uid source project state output payload_line

  [[ -x "$launcher" ]] || {
    echo "test_mount_anchor: ocsb launcher is not executable: $launcher" >&2
    return 2
  }
  podman_bin="$(command -v podman)" || {
    echo 'test_mount_anchor: real-rootless-podman requires Podman' >&2
    return 1
  }
  case "$podman_bin" in
    /nix/store/*/bin/podman) ;;
    *)
      echo "test_mount_anchor: Podman is not from the locked Nix store: $podman_bin" >&2
      return 1
      ;;
  esac
  [[ "$(podman info --format '{{.Host.Security.Rootless}}')" == true ]] || {
    echo 'test_mount_anchor: Podman is not running rootless' >&2
    return 1
  }
  [[ -z "${CONTAINER_HOST:-}" && -z "${PODMAN_HOST:-}" ]] || {
    echo 'test_mount_anchor: remote Podman environment is prohibited' >&2
    return 1
  }

  CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ocsb-real-rootless-podman.XXXXXX")"
  chmod 0700 "$CASE_DIR"
  source="$CASE_DIR/source"
  project="$CASE_DIR/project"
  state="$CASE_DIR/state"
  install -d -m 0700 -- "$source" "$project" "$state"
  printf 'original\n' > "$source/marker"
  chmod 0600 "$source/marker"
  uid="$(id -u)"

  output="$({
    cd -- "$project"
    OCSB_STATE_BASE_DIR="$state" "$launcher" \
      --backend podman \
      -w real-rootless-podman \
      --strategy direct \
      --overwrite \
      --ro "$source:/anchor" \
      -- -c 'printf "uid=%s source=%s\n" "$(id -u)" "$(cat /anchor/marker)"'
  })"
  printf '%s\n' "$output"
  payload_line="$(grep -E '^uid=[0-9]+ source=original$' <<<"$output" | tail -n 1)"
  [[ "$payload_line" == "uid=$uid source=original" ]] || {
    echo "test_mount_anchor: real rootless Podman payload mismatch: ${payload_line:-<missing>}" >&2
    return 1
  }

  remove_case_dir
  printf 'PASS[GREEN-real-rootless-podman-anchor]: uid=%s source=original\n' "$uid"
}

ci_fake_case() {
  CI_FAKE_MODE=1
  TEMP_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/ocsb-mount-anchor.XXXXXX")"
  prepare_fixture "$TEMP_FIXTURE" >/dev/null
  deterministic_swap_case "$TEMP_FIXTURE" ""
  optional_source_absent_case "$TEMP_FIXTURE"
  nested_symlink_case "$TEMP_FIXTURE"
  workspace_mutation_parent_swap_case "$TEMP_FIXTURE"
  git_mid_command_swap_case "$TEMP_FIXTURE"
  receipt_consume_cas_case "$TEMP_FIXTURE"
  receipt_retain_retire_case "$TEMP_FIXTURE"
  test_evidence_case "$TEMP_FIXTURE"
  inherited_fd_handoff_case "$TEMP_FIXTURE"
}

[[ $# -gt 0 ]] || usage
case "$1" in
  --prepare)
    [[ $# -eq 2 ]] || usage
    prepare_fixture "$2"
    ;;
  --case)
    [[ $# -ge 3 ]] || usage
    test_case="$2"
    if [[ "$test_case" == real-rootless-podman ]]; then
      [[ $# -eq 3 ]] || usage
      real_rootless_podman_case "$3"
      exit
    fi
    fixture="$(canonical_external_fixture "$3")"
    shift 3
    helper=""
    baseline=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --baseline)
          baseline=1
          shift
          ;;
        --helper)
          [[ $# -ge 2 && -z "$helper" ]] || usage
          helper="$2"
          shift 2
          ;;
        -* ) usage ;;
        *)
          [[ -z "$helper" ]] || usage
          helper="$1"
          shift
          ;;
      esac
    done
    case "$test_case" in
      deterministic-swap)
        [[ "$baseline" -eq 0 ]] || usage
        deterministic_swap_case "$fixture" "$helper"
        ;;
      optional-source-absent)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        optional_source_absent_case "$fixture"
        ;;
      nested-symlink|nested-workspace-symlink)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        nested_symlink_case "$fixture"
        ;;
      real-runtime-secondary)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        real_runtime_secondary_case "$fixture"
        ;;
      workspace-mutation-parent-swap)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        workspace_mutation_parent_swap_case "$fixture"
        ;;
      workspace-mutation-parent-swap-first)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        workspace_mutation_parent_swap_first_case "$fixture"
        ;;
      workspace-post-mutation-swap)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        workspace_post_mutation_swap_case "$fixture"
        ;;
      git-mid-command-swap)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        git_mid_command_swap_case "$fixture"
        ;;
      receipt-consume-cas)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        receipt_consume_cas_case "$fixture"
        ;;
      receipt-retain-retire)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        receipt_retain_retire_case "$fixture"
        ;;
      test-evidence)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        test_evidence_case "$fixture"
        ;;
      inherited-fd-handoff-auto)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        inherited_fd_handoff_auto_case "$fixture"
        ;;
      exit-cleanup-trigger)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        exit_cleanup_trigger_case "$fixture"
        ;;
      exit-cleanup-original-status)
        [[ -z "$helper" && "$baseline" -eq 0 ]] || usage
        exit_cleanup_original_status_case "$fixture"
        ;;
      *)
        echo "test_mount_anchor: unknown case: $test_case" >&2
        exit 2
        ;;
    esac
    ;;
  --ci-fake)
    [[ $# -eq 1 ]] || usage
    ci_fake_case
    ;;
  *) usage ;;
esac
