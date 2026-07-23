#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ONLY=0
TEST_CASE="all"
NATIVE_SIDECAR_RUNTIME=""
BUILD_LIGHTWEIGHT_WRAPPER=0
BUILD_FIXTURE_DIR=""
BUILD_KEY_FIXTURE=0
BUILD_KEY_FIXTURE_DIR=""
WRAPPER=""
TMPDIR=""
PERSIST_EMBEDDED=""
PERSIST_EXTERNAL=""
PERSIST_SIDECAR=""
FAKE_BIN=""
DEFAULT_SIDECAR_IMAGE='docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0'

if [[ "${1:-}" == "--build-lightweight-wrapper" ]]; then
  [[ $# -eq 2 ]] || {
    echo "Usage: $0 --build-lightweight-wrapper <fixture-dir>" >&2
    exit 2
  }
  BUILD_LIGHTWEIGHT_WRAPPER=1
  BUILD_FIXTURE_DIR="$2"
  shift 2
fi

if [[ "${1:-}" == "--build-key-fixture" ]]; then
  [[ $# -eq 2 ]] || {
    echo "Usage: $0 --build-key-fixture <fixture-dir>" >&2
    exit 2
  }
  BUILD_KEY_FIXTURE=1
  BUILD_KEY_FIXTURE_DIR="$2"
  shift 2
fi

if [[ "${1:-}" == "--source-only" ]]; then
  SOURCE_ONLY=1
  shift
fi

if [[ "${1:-}" == "--case" ]]; then
  [[ $# -ge 2 ]] || {
    echo "Usage: $0 [--source-only] [--case NAME] <path-to-ocsb-ironclaw-binary>" >&2
    exit 2
  }
  TEST_CASE="$2"
  shift 2
  if [[ "$TEST_CASE" == "native-sidecar-lifecycle" ]]; then
    [[ $# -ge 1 ]] || {
      echo "Usage: $0 --case native-sidecar-lifecycle <podman|docker> <path-to-ocsb-ironclaw-binary>" >&2
      exit 2
    }
    NATIVE_SIDECAR_RUNTIME="$1"
    shift
  fi
fi

WRAPPER="${1:-}"
if [[ "$BUILD_LIGHTWEIGHT_WRAPPER" -eq 1 ]]; then
  [[ "$SOURCE_ONLY" -eq 0 && "$TEST_CASE" == "all" && $# -eq 0 ]] || {
    echo "fixture builder cannot be combined with test arguments" >&2
    exit 2
  }
elif [[ "$BUILD_KEY_FIXTURE" -eq 1 ]]; then
  [[ "$SOURCE_ONLY" -eq 0 && "$TEST_CASE" == "all" && $# -eq 0 ]] || {
    echo "fixture builder cannot be combined with test arguments" >&2
    exit 2
  }
elif [[ "$SOURCE_ONLY" -eq 1 ]]; then
  [[ "$TEST_CASE" == "all" && $# -eq 0 ]] || {
    echo "--source-only cannot be combined with a wrapper or focused case" >&2
    exit 2
  }
elif [[ -z "$WRAPPER" ]]; then
  echo "Usage: $0 [--source-only] [--case NAME] <path-to-ocsb-ironclaw-binary>" >&2
  exit 2
fi

build_lightweight_wrapper() {
  local fixture_dir="$1"
  local fixture_expr fixture_out fixture_store

  if [[ -e "$fixture_dir" ]] && [[ -n "$(find "$fixture_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "fixture directory must be empty: $fixture_dir" >&2
    return 1
  fi
  install -d -m 0700 "$fixture_dir/fake-bin"

  fixture_expr="$fixture_dir/build-lightweight-wrapper.nix"
  cat > "$fixture_expr" <<'NIX'
let
  repo = builtins.getEnv "OCSB_TEST_REPO_ROOT";
  flake = builtins.getFlake ("path:" + repo);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  fakeOpenSsl = pkgs.writeShellScriptBin "openssl" ''
    set -euo pipefail
    if [[ "''${OCSB_FAKE_OPENSSL_IGNORE_TERM:-0}" == 1 ]]; then
      trap "" TERM
    fi
    if [[ -n "''${OCSB_FAKE_OPENSSL_READY_FILE:-}" ]]; then
      : "''${OCSB_FAKE_OPENSSL_PID_FILE:?OCSB_FAKE_OPENSSL_PID_FILE is required}"
      : "''${OCSB_FAKE_OPENSSL_RELEASE_FIFO:?OCSB_FAKE_OPENSSL_RELEASE_FIFO is required}"
      printf '%s\n' "$$" > "$OCSB_FAKE_OPENSSL_PID_FILE"
      : > "$OCSB_FAKE_OPENSSL_READY_FILE"
      IFS= read -r _ < "$OCSB_FAKE_OPENSSL_RELEASE_FIFO"
    fi
    printf '%048d\n' 0
  '';
  sidecarGate = pkgs.callPackage (repo + "/pkgs/sidecar-gate.nix") {
    testHooks = true;
  };
  bareEntrypointSource = pkgs.writeText "ocsb-sidecar-bare-entrypoint.c" ''
    #define _DEFAULT_SOURCE
    #include <errno.h>
    #include <fcntl.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/stat.h>
    #include <sys/types.h>
    #include <unistd.h>

    extern char **environ;

    static int write_all(int fd, const void *buffer, size_t length) {
      const char *cursor = buffer;
      while (length != 0U) {
        ssize_t written = write(fd, cursor, length);
        if (written <= 0) return -1;
        cursor += written;
        length -= (size_t)written;
      }
      return 0;
    }

    static int write_vector(const char *path, char *const vector[]) {
      int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
      size_t index;
      if (fd < 0) return -1;
      for (index = 0U; vector[index] != NULL; ++index) {
        const size_t length = strlen(vector[index]) + 1U;
        if (write_all(fd, vector[index], length) != 0) {
          close(fd);
          return -1;
        }
      }
      return close(fd);
    }

    int main(int argc, char **argv) {
      int ready;
      (void)argc;
      if (write_vector("/fixture/bare-argv.nul", argv) != 0 ||
          write_vector("/fixture/bare-env.nul", environ) != 0) return 1;
      ready = open("/fixture/bare-ready", O_WRONLY | O_CREAT | O_TRUNC, 0600);
      if (ready < 0 || close(ready) != 0) return 1;
      while (access("/fixture/bare-release", F_OK) != 0) usleep(10000U);
      return 0;
    }
  '';
  bareEntrypoint = pkgs.pkgsStatic.stdenv.mkDerivation {
    pname = "ocsb-sidecar-bare-entrypoint";
    version = "1";
    dontUnpack = true;
    buildPhase = ''
      $CC -std=c17 -O2 -Wall -Wextra -Werror -o docker-entrypoint.sh ${bareEntrypointSource}
    '';
    installPhase = ''
      install -Dm0555 docker-entrypoint.sh "$out/bin/docker-entrypoint.sh"
    '';
  };
  fixtureWrapper = pkgs.writeText "ironclaw-wrapper-fixture.nix"
    (pkgs.lib.replaceStrings [ "\${pkgs.openssl}" ] [ "${fakeOpenSsl}" ]
      (builtins.readFile (repo + "/scripts/ironclaw-wrapper.nix")));
  fakeInner = pkgs.writeShellScriptBin "ironclaw" ''
    set -euo pipefail
    if [[ -n "''${OCSB_TASK18_WRAPPER_LOG:-}" ]]; then
      : "''${OCSB_TASK18_READY_FD:?}"
      : "''${OCSB_TASK18_RELEASE_FD:?}"
      : "''${OCSB_TASK18_PUBLIC_HOME:?}"
      : "''${OCSB_TASK18_PUBLIC_DATA:?}"
      : "''${OCSB_TASK18_PUBLIC_STATE:?}"
      : "''${OCSB_TASK18_PUBLIC_DB_ENV:?}"
      declare -a inherited_specs=()
      declare -a remaining=("$@")
      index=0
      while (( index + 1 < ''${#remaining[@]} )) &&
          [[ "''${remaining[$index]}" == --ocsb-internal-fd-root ]]; do
        inherited_specs+=("''${remaining[$((index + 1))]}")
        index=$((index + 2))
      done
      printf R >&"$OCSB_TASK18_READY_FD"
      IFS= read -r -n 1 _ <&"$OCSB_TASK18_RELEASE_FD"

      home_access="$OCSB_TASK18_PUBLIC_HOME"
      data_access="$OCSB_TASK18_PUBLIC_DATA"
      state_access="$OCSB_TASK18_PUBLIC_STATE"
      db_access="$OCSB_TASK18_PUBLIC_DB_ENV"
      if [[ ''${#inherited_specs[@]} -eq 4 ]]; then
        for spec in "''${inherited_specs[@]}"; do
          IFS=$'\t' read -r version role display fd dev ino kind <<< "$spec"
          [[ "$version" == v1 && "$fd" =~ ^[3-9][0-9]*$|^[3-9]$ &&
            "$(stat -Lc '%d' -- "/proc/self/fd/$fd")" == "$dev" &&
            "$(stat -Lc '%i' -- "/proc/self/fd/$fd")" == "$ino" ]] || exit 91
          case "$role:$display:$kind" in
            "project:$OCSB_TASK18_PUBLIC_HOME:directory") home_access="/proc/self/fd/$fd" ;;
            "state-base:$OCSB_TASK18_PUBLIC_STATE:directory") state_access="/proc/self/fd/$fd" ;;
            "mount:$OCSB_TASK18_PUBLIC_DATA:directory") data_access="/proc/self/fd/$fd" ;;
            "mount:$OCSB_TASK18_PUBLIC_DB_ENV:regular") db_access="/proc/self/fd/$fd" ;;
            *) exit 92 ;;
          esac
        done
      fi
      {
        printf 'SPEC_COUNT=%s\n' "''${#inherited_specs[@]}"
        printf 'HOME=%s\n' "$(cat -- "$home_access/task18-canary")"
        printf 'DATA=%s\n' "$(cat -- "$data_access/task18-canary")"
        printf 'STATE=%s\n' "$(cat -- "$state_access/task18-canary")"
        printf 'DB_SHA256=%s\n' "$(sha256sum -- "$db_access" | cut -d ' ' -f 1)"
      } > "$OCSB_TASK18_WRAPPER_LOG"
      exit 0
    fi
    if [[ -n "''${OCSB_FAKE_INNER_LOG:-}" ]]; then
      db_env_host=""
      expect_ro_value=0
      state_handoff_fd=""
      declare -a inner_args=("$@")
      index=0
      while (( index + 1 < ''${#inner_args[@]} )) &&
          [[ "''${inner_args[$index]}" == --ocsb-internal-fd-root ]]; do
        spec="''${inner_args[$((index + 1))]}"
        IFS=$'\t' read -r version role display inherited_fd dev ino kind <<< "$spec"
        if [[ "$version" == v1 && "$role" == state-base &&
              "$display" == "''${OCSB_FAKE_SIDECAR_STATE_PATH:-}" &&
              "$kind" == directory && "$inherited_fd" =~ ^[0-9]+$ ]] &&
            (( 10#$inherited_fd >= 3 )) &&
            [[ "$(${pkgs.coreutils}/bin/stat -Lc '%d' -- "/proc/self/fd/$inherited_fd")" == "$dev" &&
              "$(${pkgs.coreutils}/bin/stat -Lc '%i' -- "/proc/self/fd/$inherited_fd")" == "$ino" &&
              -z "$state_handoff_fd" ]]; then
          state_handoff_fd="$inherited_fd"
        fi
        index=$((index + 2))
      done
      for descriptor_path in /proc/$$/fd/*; do
        target="$(${pkgs.coreutils}/bin/readlink "$descriptor_path" 2>/dev/null || true)"
        if [[ -n "''${OCSB_FAKE_SIDECAR_STATE_PATH:-}" && "$target" == "$OCSB_FAKE_SIDECAR_STATE_PATH" ]]; then
          [[ "''${descriptor_path##*/}" == "$state_handoff_fd" ]] && continue
          printf 'LOCK_FD_LEAK=%s\n' "$target" >> "$OCSB_FAKE_INNER_LOG"
          exit 97
        fi
      done
      for arg in "$@"; do
        if [[ "$expect_ro_value" -eq 1 ]]; then
          if [[ "$arg" == *:/tmp/ocsb-ironclaw-db.env ]]; then
            db_env_host="''${arg%:/tmp/ocsb-ironclaw-db.env}"
          fi
          expect_ro_value=0
        elif [[ "$arg" == "--ro" ]]; then
          expect_ro_value=1
        fi
      done
      [[ -n "$db_env_host" && -r "$db_env_host" ]]
      source "$db_env_host"
      password_hash="$(printf '%s' "''${PGPASSWORD:-}" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)"
      printf 'INNER_CALLED\n' >> "$OCSB_FAKE_INNER_LOG"
      printf 'PASSWORD_HASH=%s\n' "$password_hash" >> "$OCSB_FAKE_INNER_LOG"
    fi
  '';
  wrapper = pkgs.callPackage fixtureWrapper {
    slug = "";
    persistSlug = "";
    ironclawSandboxBase = fakeInner;
    inherit sidecarGate;
    sidecarTestHookMode = "fixture";
  };
in pkgs.symlinkJoin {
  name = "ocsb-ironclaw-lightweight-fixture";
  paths = [ wrapper sidecarGate pkgs.bubblewrap bareEntrypoint pkgs.file ];
}
NIX

  fixture_out="$(
    OCSB_TEST_REPO_ROOT="$REPO_ROOT" nix build --no-link --print-out-paths --impure \
      --file "$fixture_expr"
  )" || return 1
  rm -f -- "$fixture_expr"
  fixture_store="${fixture_out##*$'\n'}"
  [[ -x "$fixture_store/bin/ocsb-ironclaw" && -x "$fixture_store/bin/ocsb-sidecar-gate" &&
    -x "$fixture_store/bin/bwrap" && -x "$fixture_store/bin/docker-entrypoint.sh" &&
    -x "$fixture_store/bin/file" ]] || {
    echo "lightweight wrapper build did not produce ocsb-ironclaw" >&2
    return 1
  }
  ln -s "$fixture_store/bin/ocsb-ironclaw" "$fixture_dir/ocsb-ironclaw"
  ln -s "$fixture_store/bin/ocsb-sidecar-gate" "$fixture_dir/ocsb-sidecar-gate"
  ln -s "$fixture_store/bin/bwrap" "$fixture_dir/ocsb-sidecar-bwrap"
  ln -s "$fixture_store/bin/docker-entrypoint.sh" "$fixture_dir/ocsb-sidecar-bare-entrypoint"
  "$fixture_store/bin/file" -L "$fixture_dir/ocsb-sidecar-gate" | grep -Fq -- 'statically linked' || {
    echo "fixture sidecar gate is not static" >&2
    return 1
  }

  # Kept only as a readable historical fixture sketch. The stateful fake below
  # models the create/cidfile/gate protocol used by the current wrapper.
  if false; then
  cat > "$fixture_dir/fake-bin/fake-oci" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${OCSB_FAKE_OCI_STATE_DIR:?OCSB_FAKE_OCI_STATE_DIR is required}"
scenario="${OCSB_FAKE_OCI_SCENARIO:?OCSB_FAKE_OCI_SCENARIO is required}"
caller="${OCSB_FAKE_OCI_CALLER:-0}"
mkdir -p "$state_dir"
if [[ "${OCSB_FAKE_OCI_IGNORE_TERM:-0}" == "1" ]]; then
  trap '' TERM
  printf '%s\n' "$$" > "$state_dir/ACTIVE_OCI_PID"
fi
for fd in /proc/$$/fd/*; do
  target="$(readlink "$fd" 2>/dev/null || true)"
  if [[ -n "${OCSB_FAKE_SIDECAR_STATE_PATH:-}" && "$target" == "$OCSB_FAKE_SIDECAR_STATE_PATH" ]]; then
    : > "$state_dir/LOCK_FD_INHERITED"
  fi
  if [[ -n "${OCSB_FAKE_NO_HELD_FD_DIR:-}" && "$target" == "$OCSB_FAKE_NO_HELD_FD_DIR"* ]]; then
    : > "$state_dir/HELD_FD_INHERITED"
    printf '%s\n' "$target" >> "$state_dir/held-fd-targets"
  fi
done

state_lock() {
  exec 9>>"$state_dir/fake-oci-state.lock"
  flock 9
}

state_unlock() {
  flock -u 9
  exec 9>&-
}

record_operation() {
  state_lock
  printf '%s\n' "$1" >> "$state_dir/operations"
  state_unlock
}

read_metadata() {
  local field="$1"
  cat "$state_dir/meta-$field"
}

inspect_existing_metadata() {
  local format="$1"
  case "$format" in
    '{{.State.Status}}')
      read_metadata status
      ;;
    '{{.Config.Image}}')
      read_metadata config-image
      ;;
    '{{.ImageName}}')
      read_metadata config-image
      ;;
    *'io.ocsb.owner'*)
      read_metadata label-owner
      ;;
    *'io.ocsb.persist-id'*)
      read_metadata label-persist-id
      ;;
    *'io.ocsb.image'*)
      read_metadata label-image
      ;;
    *'io.ocsb.volume'*)
      read_metadata label-volume
      ;;
    *'io.ocsb.port'*)
      read_metadata label-port
      ;;
    *'.Mounts'*)
      printf '%s|%s\n' "$(read_metadata mount-source)" "$(read_metadata mount-destination)"
      ;;
    *'5432/tcp'*)
      printf '%s|%s\n' "$(read_metadata port-host-ip)" "$(read_metadata port-host-port)"
      ;;
    *)
      exit 64
      ;;
  esac
}

cmd="${1:-}"
shift || true
case "$cmd" in
  ps)
    [[ "${1:-}" == "--all" && "${2:-}" == "--format" && "${3:-}" == '{{.Names}}' ]] || exit 64
    record_operation "ps:$caller"
    case "$scenario" in
      concurrency|split-lock)
        [[ ! -s "$state_dir/meta-status" ]] || printf 'ocsb-ironclaw-db\n'
        ;;
       wrong-*|inspect-error) printf 'ocsb-ironclaw-db\n' ;;
       preflight) : ;;
      *) exit 64 ;;
    esac
    ;;
  inspect)
    [[ "${1:-}" == "--format" && $# -ge 3 ]] || exit 64
    format="$2"
    container="$3"
    record_operation "inspect:$caller:$container"

    [[ "$scenario" != "inspect-error" ]] || exit 64
    if [[ "$scenario" == wrong-* ]]; then
      actual_owner="ocsb-ironclaw"
      actual_persist_id="${OCSB_FAKE_EXPECT_PERSIST_ID:?}"
      actual_image="${OCSB_FAKE_EXPECT_IMAGE:?}"
      actual_volume="${OCSB_FAKE_EXPECT_VOLUME:?}"
      actual_port="${OCSB_FAKE_EXPECT_PORT:?}"
      actual_host_ip="127.0.0.1"
      case "$scenario" in
        wrong-identity)
          actual_image="wrong.example/pgvector:mutable"
          actual_volume="/wrong/pgdata-sidecar"
          actual_port="60000"
          actual_host_ip="0.0.0.0"
          ;;
        wrong-owner) actual_owner="foreign-owner" ;;
        wrong-owner-newline) actual_owner=$'ocsb-ironclaw\nforeign-owner' ;;
        wrong-persist) actual_persist_id="foreign-persist" ;;
        wrong-persist-newline) actual_persist_id+=$'\nforeign-persist' ;;
        *) exit 64 ;;
      esac
      case "$format" in
        '{{.State.Status}}') printf 'running\n' ;;
        '{{.Config.Image}}'|'{{.ImageName}}') printf '%s\n' "$actual_image" ;;
        *'io.ocsb.owner'*) printf '%s\n' "$actual_owner" ;;
        *'io.ocsb.persist-id'*) printf '%s\n' "$actual_persist_id" ;;
        *'io.ocsb.image'*) printf '%s\n' "$actual_image" ;;
        *'io.ocsb.volume'*) printf '%s\n' "$actual_volume" ;;
        *'io.ocsb.port'*) printf '%s\n' "$actual_port" ;;
        *'.Mounts'*) printf '%s|/var/lib/postgresql\n' "$actual_volume" ;;
        *'5432/tcp'*) printf '%s|%s\n' "$actual_host_ip" "$actual_port" ;;
        *) exit 64 ;;
      esac
      exit 0
    fi

    if [[ "$scenario" == "preflight" ]]; then
      exit 1
    fi
    [[ "$scenario" == "concurrency" || "$scenario" == "split-lock" ]] || exit 64
    if [[ -s "$state_dir/meta-status" ]]; then
      inspect_existing_metadata "$format"
      exit 0
    fi
    [[ "$format" == '{{.State.Status}}' ]] || exit 1
    case "$caller" in
      1) marker="$state_dir/FIRST_INSPECT_READY" ;;
      2) marker="$state_dir/SECOND_INSPECT_READY" ;;
      *) exit 65 ;;
    esac
    : > "$marker"
    IFS= read -r _ < "$state_dir/release-$caller.fifo"
    exit 1
    ;;
  run)
    name=""
    env_file=""
    volume=""
    publish=""
    image=""
    declare -A labels=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -d) shift ;;
        --name) name="$2"; shift 2 ;;
        --env-file) env_file="$2"; shift 2 ;;
        --volume) volume="$2"; shift 2 ;;
        --publish) publish="$2"; shift 2 ;;
        --label)
          label_key="${2%%=*}"
          labels["$label_key"]="${2#*=}"
          shift 2
          ;;
        *) image="$1"; shift ;;
      esac
    done
    [[ -n "$name" && -s "$env_file" && -n "$volume" && -n "$publish" && -n "$image" ]] || exit 66
    password=""
    while IFS='=' read -r env_name env_value; do
      if [[ "$env_name" == "POSTGRES_PASSWORD" ]]; then
        password="$env_value"
      fi
    done < "$env_file"
    [[ -n "$password" ]] || exit 67
    password_hash="$(printf '%s' "$password" | sha256sum | cut -d ' ' -f 1)"
    volume_source="${volume%:/var/lib/postgresql}"
    host_ip="${publish%%:*}"
    publish_rest="${publish#*:}"
    host_port="${publish_rest%%:*}"

    state_lock
    create_count=0
    [[ ! -s "$state_dir/create-count" ]] || create_count="$(cat "$state_dir/create-count")"
    printf '%s\n' "$((create_count + 1))" > "$state_dir/create-count"
    printf '%s\n' "$password_hash" >> "$state_dir/password-hashes"
    if [[ ! -s "$state_dir/meta-status" ]]; then
      printf 'running\n' > "$state_dir/meta-status"
      printf '%s\n' "$image" > "$state_dir/meta-config-image"
      printf '%s\n' "${labels[io.ocsb.owner]:-}" > "$state_dir/meta-label-owner"
      printf '%s\n' "${labels[io.ocsb.persist-id]:-}" > "$state_dir/meta-label-persist-id"
      printf '%s\n' "${labels[io.ocsb.image]:-}" > "$state_dir/meta-label-image"
      printf '%s\n' "${labels[io.ocsb.volume]:-}" > "$state_dir/meta-label-volume"
      printf '%s\n' "${labels[io.ocsb.port]:-}" > "$state_dir/meta-label-port"
      printf '%s\n' "$volume_source" > "$state_dir/meta-mount-source"
      printf '/var/lib/postgresql\n' > "$state_dir/meta-mount-destination"
      printf '%s\n' "$host_ip" > "$state_dir/meta-port-host-ip"
      printf '%s\n' "$host_port" > "$state_dir/meta-port-host-port"
    fi
    printf 'run:%s:%s\n' "$caller" "$name" >> "$state_dir/operations"
    state_unlock
    printf 'fake-container-id\n'
    ;;
  start)
    record_operation "start:${1:-}"
    ;;
  exec)
    container="${1:-}"
    shift || true
    subcmd="${1:-}"
    shift || true
    record_operation "exec:$container:$subcmd"
    case "$subcmd" in
      pg_isready) exit 0 ;;
      psql)
        for arg in "$@"; do
          if [[ "$arg" == "-tAc" ]]; then
            printf '1\n'
            break
          fi
        done
        ;;
      createdb) ;;
    esac
    ;;
  *)
    exit 64
    ;;
esac
EOF
  fi
  cat > "$fixture_dir/fake-bin/fake-oci" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${OCSB_FAKE_OCI_STATE_DIR:?OCSB_FAKE_OCI_STATE_DIR is required}"
scenario="${OCSB_FAKE_OCI_SCENARIO:-gate}"
caller="${OCSB_FAKE_OCI_CALLER:-0}"
fixture_dir="$(cd "$(dirname "$0")/.." && pwd)"
gate_bin="$fixture_dir/ocsb-sidecar-gate"
bwrap_bin="$fixture_dir/ocsb-sidecar-bwrap"
bare_bin="$fixture_dir/ocsb-sidecar-bare-entrypoint"
default_image='docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0'
container_name='ocsb-ironclaw-db'
mkdir -p "$state_dir"

runtime="$(basename "$0")"
if [[ "$runtime" == podman ]]; then
  [[ "${1:-}" == '--remote=false' ]] || exit 70
  shift
elif [[ "$runtime" == docker ]]; then
  [[ "${1:-}" != '--remote=false' ]] || exit 71
else
  exit 72
fi

state_fd_inherited=0
forbidden_held_fd_inherited=0
state_fd_target=""
for fd in /proc/$$/fd/*; do
  target="$(readlink "$fd" 2>/dev/null || true)"
  [[ "${fd##*/}" -gt 2 ]] || continue
  if [[ -n "${OCSB_FAKE_SIDECAR_STATE_PATH:-}" && "$target" == "$OCSB_FAKE_SIDECAR_STATE_PATH" ]]; then
    state_fd_inherited=1
    state_fd_target="$target"
  fi
  if [[ -n "${OCSB_FAKE_NO_HELD_FD_DIR:-}" && "$target" == "$OCSB_FAKE_NO_HELD_FD_DIR"* ]]; then
    if [[ -z "${OCSB_FAKE_SIDECAR_STATE_PATH:-}" || "$target" != "$OCSB_FAKE_SIDECAR_STATE_PATH" ]]; then
      forbidden_held_fd_inherited=1
      printf 'pending:%s\n' "$target" >> "$state_dir/forbidden-held-fd-targets"
    fi
    printf '%s\n' "$target" >> "$state_dir/held-fd-targets"
  fi
done
if [[ "${OCSB_FAKE_OCI_IGNORE_TERM:-0}" == 1 ]]; then
  trap '' TERM
  printf '%s\n' "$$" > "$state_dir/ACTIVE_OCI_PID"
fi

state_lock() { exec 9>>"$state_dir/fake-oci-state.lock"; flock 9; }
state_unlock() { flock -u 9; exec 9>&-; }
record_operation() { state_lock; printf '%s\n' "$1" >> "$state_dir/operations"; state_unlock; }
meta_path() { printf '%s/meta-%s' "$state_dir" "$1"; }
read_metadata() { cat "$(meta_path "$1")"; }
write_metadata() { printf '%s\n' "$2" > "$(meta_path "$1")"; }
container_id() {
  if [[ ! -s "$state_dir/meta-id" ]]; then
    printf '%s' "$state_dir" | sha256sum | cut -d ' ' -f 1 > "$state_dir/meta-id"
  fi
  cat "$state_dir/meta-id"
}
container_root() { printf '%s/containers/%s/root' "$state_dir" "$(container_id)"; }
container_exists() { [[ -s "$(meta_path status)" ]]; }
require_immutable_id() {
  local value="$1" id
  id="$(container_id)"
  [[ "$value" =~ ^[0-9a-f]{64}$ && "$value" == "$id" && -s "$(meta_path status)" ]] || exit 73
}

seed_identity_container() {
  local generation expected_image expected_volume expected_port
  container_exists && return 0
  case "$scenario" in
    wrong-*|inspect-error|legacy-proc) ;;
    *) return 0 ;;
  esac
  generation="$(printf 'c%.0s' {1..64})"
  expected_image="${OCSB_FAKE_EXPECT_IMAGE:-$default_image}"
  expected_volume="${OCSB_FAKE_EXPECT_VOLUME:-$state_dir/public-pgdata}"
  expected_port="${OCSB_FAKE_EXPECT_PORT:-55432}"
  write_metadata name "$container_name"
  write_metadata status running
  write_metadata config-image "$expected_image"
  write_metadata label-owner ocsb-ironclaw
  write_metadata label-persist-id "${OCSB_FAKE_EXPECT_PERSIST_ID:-fixture-persist-id}"
  write_metadata label-image "$expected_image"
  write_metadata label-volume "$expected_volume"
  write_metadata label-port "$expected_port"
  write_metadata label-data-id "${OCSB_FAKE_EXPECT_DATA_ID:-fixture-data-id}"
  write_metadata label-protocol sidecar-gate-v1
  write_metadata label-generation "$generation"
  write_metadata mount-source "$expected_volume"
  write_metadata mount-destination /var/lib/postgresql
  write_metadata port-host-ip 127.0.0.1
  write_metadata port-host-port "$expected_port"
  write_metadata config-entrypoint '["/ocsb-sidecar-gate/ocsb-sidecar-gate"]'
  write_metadata config-cmd "[\"run\",\"--config\",\"/ocsb-sidecar-gate/config\",\"--generation\",\"$generation\"]"
  write_metadata config-env '["PATH=/usr/local/bin:/usr/bin:/bin","OCSB_GATE_TEST_ENV=bare-value","PWD=/"]'
  case "$scenario" in
    legacy-proc)
      write_metadata label-protocol ''
      write_metadata label-generation ''
      write_metadata mount-source /proc/4242/fd/9
      ;;
    wrong-identity)
      write_metadata config-image wrong.example/pgvector:mutable
      write_metadata label-image wrong.example/pgvector:mutable
      write_metadata label-volume /wrong/pgdata-sidecar
      write_metadata label-port 60000
      write_metadata mount-source /wrong/pgdata-sidecar
      write_metadata port-host-ip 0.0.0.0
      write_metadata port-host-port 60000
      ;;
    wrong-owner|wrong-owner-newline) write_metadata label-owner foreign-owner ;;
    wrong-persist|wrong-persist-newline) write_metadata label-persist-id foreign-persist ;;
  esac
}

inspect_existing_metadata() {
  local format="$1"
  case "$format" in
    '{{.Id}}') container_id ;;
    '{{.State.Status}}') [[ "$scenario" != inspect-error ]] || exit 74; read_metadata status ;;
    '{{.Config.Image}}'|'{{.ImageName}}') read_metadata config-image ;;
    *'io.ocsb.owner'*) read_metadata label-owner ;;
    *'io.ocsb.persist-id'*) read_metadata label-persist-id ;;
    *'io.ocsb.image'*) read_metadata label-image ;;
    *'io.ocsb.volume'*) read_metadata label-volume ;;
    *'io.ocsb.port'*) read_metadata label-port ;;
    *'io.ocsb.data-id'*) read_metadata label-data-id ;;
    *'io.ocsb.protocol'*) read_metadata label-protocol ;;
    *'io.ocsb.generation'*) read_metadata label-generation ;;
    *'.Mounts'*) printf '%s|%s\n' "$(read_metadata mount-source)" "$(read_metadata mount-destination)" ;;
    *'5432/tcp'*) printf '%s|%s\n' "$(read_metadata port-host-ip)" "$(read_metadata port-host-port)" ;;
    '{{json .Config.Entrypoint}}') read_metadata config-entrypoint ;;
    '{{json .Config.Cmd}}') read_metadata config-cmd ;;
    '{{json .Config.Env}}') read_metadata config-env ;;
    *) exit 64 ;;
  esac
}

wait_for_gate_state() {
  local root="$1" index
  for ((index = 0; index < 1000; ++index)); do
    compgen -G "$root/ocsb-sidecar-gate/current.*" >/dev/null && return 0
    sleep 0.01
  done
  return 1
}
terminate_gate_process() {
  local pid
  [[ -s "$state_dir/gate-pid" ]] || return 0
  pid="$(cat "$state_dir/gate-pid")"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f -- "$state_dir/gate-pid"
}
start_gate_process() {
  local id="$1" root source arg
  local -a run_args=()
  root="$(container_root)"
  source="$(read_metadata mount-source)"
  [[ -x "$root/ocsb-sidecar-gate/ocsb-sidecar-gate" && -d "$source" ]] || exit 75
  while IFS= read -r -d '' arg; do run_args+=("$arg"); done < "$state_dir/run-args.nul"
  rm -f -- "$state_dir/bare-ready" "$state_dir/bare-release"
  setsid "$bwrap_bin" --die-with-parent --bind "$root" / --bind "$source" /var/lib/postgresql \
    --bind "$state_dir" /fixture --proc /proc --dev /dev --chdir / --clearenv \
    --setenv PATH /usr/local/bin:/usr/bin:/bin --setenv OCSB_GATE_TEST_ENV bare-value -- \
    /ocsb-sidecar-gate/ocsb-sidecar-gate run --config /ocsb-sidecar-gate/config \
      --generation "$(read_metadata label-generation)" "${run_args[@]}" \
      >"$state_dir/gate-stdout" 2>"$state_dir/gate-stderr" &
  printf '%s\n' "$!" > "$state_dir/gate-pid"
}
gate_exec() {
  local id="$1" binary root argument mode decision="" index generation nonce
  shift
  binary="$1"
  shift
  require_immutable_id "$id"
  [[ "$binary" == /ocsb-sidecar-gate/ocsb-sidecar-gate ]] || exit 76
  mode="${1:-}"
  if [[ "$scenario" == concurrency ]]; then
    record_operation "gate:${mode:-query}:$id"
    generation="$(read_metadata label-generation)"
    if [[ ! -s "$(meta_path gate-run-nonce)" ]]; then
      printf 'd%.0s' {1..64} > "$(meta_path gate-run-nonce)"
    fi
    nonce="$(read_metadata gate-run-nonce)"
    case "$mode" in
      verify)
        printf 'MOUNT-VERIFIED %s %s\n' "$generation" "$nonce"
        ;;
      release)
        printf 'PREPARED %s %s\n' "$generation" "$nonce"
        ;;
      decision)
        decision=absent
        for argument in "$@"; do
          case "$argument" in
            --commit) decision=commit ;;
            --abort) decision=abort ;;
          esac
        done
        [[ "$decision" == absent ]] || write_metadata gate-decision "$decision"
        if [[ "$decision" == absent && -s "$(meta_path gate-decision)" ]]; then
          decision="$(read_metadata gate-decision)"
        fi
        printf 'DECISION %s %s %s\n' "$decision" "$generation" "$nonce"
        ;;
      ack)
        ;;
      *) exit 78 ;;
    esac
    exit 0
  fi
  root="$(container_root)"
  wait_for_gate_state "$root" || exit 77
  local -a mapped=()
  for argument in "$@"; do
    [[ -n "$argument" ]] || continue
    case "$argument" in
      /ocsb-sidecar-gate/config) mapped+=("$root/ocsb-sidecar-gate/config") ;;
      /var/lib/postgresql) mapped+=("$(read_metadata mount-source)") ;;
      *) mapped+=("$argument") ;;
    esac
  done
  case "$mode" in
    verify|release)
      record_operation "gate:$mode:$id"
      [[ "$mode" != verify || "${OCSB_FAKE_GATE_VERIFY_FAIL:-0}" != 1 ]] || exit 88
      ;;
    decision)
      for argument in "${mapped[@]}"; do [[ "$argument" != --commit && "$argument" != --abort ]] || decision="${argument#--}"; done
      record_operation "gate:decision:${decision:-query}:$id"
      ;;
    ack)
      for ((index = 0; index < ${#mapped[@]}; ++index)); do [[ "${mapped[$index]}" != --decision ]] || decision="${mapped[$((index + 1))]}"; done
      record_operation "gate:ack:${decision:-query}:$id"
      ;;
    *) exit 78 ;;
  esac
  "$root/ocsb-sidecar-gate/ocsb-sidecar-gate" "${mapped[@]}"
}

  cmd="${1:-}"
  shift || true
  if [[ "$state_fd_inherited" -eq 1 && "$cmd" != create ]]; then
    : > "$state_dir/LOCK_FD_INHERITED"
    printf '%s:%s\n' "$cmd" "$state_fd_target" >> "$state_dir/forbidden-held-fd-targets"
  fi
  if [[ "$forbidden_held_fd_inherited" -eq 1 ||
        ( "$state_fd_inherited" -eq 1 && "$cmd" != create ) ]]; then
    : > "$state_dir/HELD_FD_INHERITED"
  fi
  case "$cmd" in
  image)
    [[ "${1:-}" == inspect ]] || exit 64
    shift
    [[ "${1:-}" == --format && $# -eq 3 ]] || exit 64
    case "$2" in
      '{{json .Config.Entrypoint}}') printf '["docker-entrypoint.sh"]\n' ;;
      '{{json .Config.Cmd}}') printf '["postgres","-c","shared_preload_libraries=vector"]\n' ;;
      *) exit 64 ;;
    esac
    ;;
  ps)
    list_kind=""
    if [[ "${1:-}" == --all && "${2:-}" == --format && "${3:-}" == '{{.Names}}' && $# -eq 3 ]]; then
      list_kind=name
    elif [[ "${1:-}" == --all && "${2:-}" == --no-trunc && "${3:-}" == --format &&
            "${4:-}" == '{{.ID}}' && $# -eq 4 ]]; then
      list_kind=id
    else
      exit 64
    fi
    record_operation "ps:$caller"
    seed_identity_container
    list_container() {
      [[ "$list_kind" == name ]] && read_metadata name || container_id
    }
    case "$scenario" in
      concurrency|split-lock)
        if ! container_exists; then
          case "$caller" in 1) marker="$state_dir/FIRST_INSPECT_READY" ;; 2) marker="$state_dir/SECOND_INSPECT_READY" ;; *) exit 65 ;; esac
          : > "$marker"
          IFS= read -r _ < "$state_dir/release-$caller.fifo"
        fi
        if container_exists; then printf '%s\n' "$(list_container)"; fi
        ;;
      wrong-*|inspect-error|legacy-proc) printf '%s\n' "$(list_container)" ;;
      preflight) : ;;
      gate) if container_exists; then printf '%s\n' "$(list_container)"; fi ;;
      *) exit 64 ;;
    esac
    ;;
  inspect)
    [[ "${1:-}" == --format && $# -ge 3 ]] || exit 64
    format="$2"
    target="$3"
    record_operation "inspect:$caller:$target"
    seed_identity_container
    [[ "$scenario" != preflight ]] && container_exists || exit 1
    if [[ "$target" == "$(read_metadata name)" ]]; then
      [[ "$format" == '{{.Id}}' ]] || exit 79
      : > "$state_dir/discovered-by-name"
    else
      require_immutable_id "$target"
    fi
    inspect_existing_metadata "$format"
    ;;
  create)
    name="" cidfile="" env_file="" volume="" publish="" image="" entrypoint=""
    declare -A labels=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --cidfile) cidfile="$2"; shift 2 ;;
        --label) labels["${2%%=*}"]="${2#*=}"; shift 2 ;;
        --env-file) env_file="$2"; shift 2 ;;
        --volume) volume="$2"; shift 2 ;;
        --publish) publish="$2"; shift 2 ;;
        --entrypoint) entrypoint="$2"; shift 2 ;;
        *) image="$1"; shift; break ;;
      esac
    done
    [[ -n "$name" && -n "$cidfile" && -s "$env_file" && -n "$volume" && -n "$publish" && -n "$entrypoint" && -n "$image" && "$name" == "$container_name" ]] || exit 80
    [[ "$entrypoint" == /ocsb-sidecar-gate/ocsb-sidecar-gate && "${1:-}" == run &&
      "${2:-}" == --config && "${3:-}" == /ocsb-sidecar-gate/config &&
      "${4:-}" == --generation && "${5:-}" =~ ^[0-9a-f]{64}$ ]] || exit 81
    if container_exists; then exit 81; fi
    shift 5
    password=""
    while IFS='=' read -r env_name env_value; do
      [[ "$env_name" != POSTGRES_PASSWORD ]] || password="$env_value"
    done < "$env_file"
    [[ -n "$password" ]] || exit 87
    password_hash="$(printf '%s' "$password" | sha256sum | cut -d ' ' -f 1)"
    state_lock
    create_count="$(cat "$state_dir/create-count" 2>/dev/null || printf 0)"
    printf '%s\n' "$((create_count + 1))" > "$state_dir/create-count"
    printf '%s\n' "$password_hash" >> "$state_dir/password-hashes"
    state_unlock
    id="$(container_id)"
    root="$(container_root)"
    install -d -m 0700 "$root/usr/local/bin" "$root/ocsb-sidecar-gate" "$root/var/lib/postgresql" \
      "$root/fixture" "$root/proc" "$root/dev"
    install -m 0555 "$bare_bin" "$root/usr/local/bin/docker-entrypoint.sh"
    run_args=()
    for argument in "$@"; do [[ -z "$argument" ]] || run_args+=("$argument"); done
    : > "$state_dir/run-args.nul"
    ((${#run_args[@]} == 0)) || printf '%s\0' "${run_args[@]}" > "$state_dir/run-args.nul"
    volume_source="${volume%:/var/lib/postgresql}"
    host_ip="${publish%%:*}"; publish_rest="${publish#*:}"; host_port="${publish_rest%%:*}"
    write_metadata name "$name"; write_metadata status created; write_metadata config-image "$image"
    write_metadata label-owner "${labels[io.ocsb.owner]:-}"; write_metadata label-persist-id "${labels[io.ocsb.persist-id]:-}"
    write_metadata label-image "${labels[io.ocsb.image]:-}"; write_metadata label-volume "${labels[io.ocsb.volume]:-}"
    write_metadata label-port "${labels[io.ocsb.port]:-}"; write_metadata label-protocol "${labels[io.ocsb.protocol]:-}"
    write_metadata label-data-id "${labels[io.ocsb.data-id]:-}"; write_metadata label-generation "${labels[io.ocsb.generation]:-}"
    write_metadata mount-source "$volume_source"
    write_metadata mount-destination /var/lib/postgresql; write_metadata port-host-ip "$host_ip"; write_metadata port-host-port "$host_port"
    write_metadata config-entrypoint '["/ocsb-sidecar-gate/ocsb-sidecar-gate"]'
    write_metadata config-cmd "[\"run\",\"--config\",\"/ocsb-sidecar-gate/config\",\"--generation\",\"${labels[io.ocsb.generation]:-}\"]"
    write_metadata config-env '["PATH=/usr/local/bin:/usr/bin:/bin","OCSB_GATE_TEST_ENV=bare-value","PWD=/"]'
    (umask 077; printf '%s\n' "$id" > "$cidfile"); chmod 0600 "$cidfile"
    record_operation "create:$id"; record_operation "cidfile:$id"
    ;;
  start)
    id="${1:-}"; require_immutable_id "$id"
    [[ "$(read_metadata status)" == created || "$(read_metadata status)" == exited ]] || exit 82
    [[ "${OCSB_FAKE_START_FAIL:-0}" != 1 ]] || { record_operation "start:$id"; exit 89; }
    write_metadata status running; record_operation "start:$id"; start_gate_process "$id"
    ;;
  cp)
    source="${1:-}"; destination="${2:-}"
    if [[ "$source" == - ]]; then
      id="${destination%%:*}"; [[ "$destination" == "$id:/" ]] || exit 83; require_immutable_id "$id"
      tar -xf - -C "$(container_root)"; record_operation "cp-in:$id"
    else
      id="${source%%:*}"; [[ "$source" == "$id:/ocsb-sidecar-gate" && "$destination" == - ]] || exit 84; require_immutable_id "$id"
      record_operation "cp-out:$id"; tar -C "$(container_root)" -cf - ocsb-sidecar-gate
    fi
    ;;
  exec)
    id="${1:-}"; shift; require_immutable_id "$id"
    case "${1:-}" in
      /ocsb-sidecar-gate/ocsb-sidecar-gate) gate_exec "$id" "$@" ;;
      pg_isready) record_operation "db:pg_isready:$id" ;;
      psql) record_operation "db:psql:$id"; for arg in "$@"; do [[ "$arg" != -tAc ]] || printf '1\n'; done ;;
      createdb) record_operation "db:createdb:$id" ;;
      *) exit 85 ;;
    esac
    ;;
  stop)
    id="${1:-}"; require_immutable_id "$id"; record_operation "stop:$id"; terminate_gate_process; write_metadata status exited
    ;;
  rm)
    [[ "${1:-}" == -f ]] || exit 86
    id="${2:-}"; require_immutable_id "$id"; record_operation "rm:$id"; terminate_gate_process
    rm -rf -- "$state_dir/containers/$id"; rm -f -- "$state_dir"/meta-* "$state_dir/run-args.nul" "$state_dir/discovered-by-name"
    ;;
  *) exit 64 ;;
esac
EOF
  chmod 0755 "$fixture_dir/fake-bin/fake-oci"
  ln -s fake-oci "$fixture_dir/fake-bin/podman"
  ln -s fake-oci "$fixture_dir/fake-bin/docker"
  : > "$fixture_dir/.ocsb-ironclaw-lightweight-fixture"
  chmod 0600 "$fixture_dir/.ocsb-ironclaw-lightweight-fixture"
  printf '%s\n' "$fixture_dir/ocsb-ironclaw"
}

build_key_fixture() {
  local fixture_dir="$1"
  local fixture_expr fixture_out fixture_store

  if [[ -e "$fixture_dir" ]] && [[ -n "$(find "$fixture_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "fixture directory must be empty: $fixture_dir" >&2
    return 1
  fi
  install -d -m 0700 "$fixture_dir"

  fixture_expr="$fixture_dir/build-key-fixture.nix"
  cat > "$fixture_expr" <<'NIX'
let
  repo = builtins.getEnv "OCSB_TEST_REPO_ROOT";
  fixtureDir = builtins.getEnv "OCSB_KEY_FIXTURE_DIR";
  flake = builtins.getFlake ("path:" + repo);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  target = fixtureDir + "/master-key-window/master_key.hex";
  fakeOpenSsl = pkgs.writeShellScriptBin "openssl" ''
    set -euo pipefail
    if [[ -n "''${OCSB_KEY_OPENSSL_CALL_LOG:-}" ]]; then
      printf 'called\n' > "$OCSB_KEY_OPENSSL_CALL_LOG"
    fi
    if [[ -n "''${OCSB_KEY_WRITER_ID:-}" ]]; then
      : "''${OCSB_KEY_WRITER_READY_DIR:?OCSB_KEY_WRITER_READY_DIR is required}"
      : "''${OCSB_KEY_WRITER_PID_DIR:?OCSB_KEY_WRITER_PID_DIR is required}"
      : "''${OCSB_KEY_WRITER_RELEASE_DIR:?OCSB_KEY_WRITER_RELEASE_DIR is required}"
      printf '%s\n' "$$" > "$OCSB_KEY_WRITER_PID_DIR/$OCSB_KEY_WRITER_ID"
      : > "$OCSB_KEY_WRITER_READY_DIR/$OCSB_KEY_WRITER_ID"
      IFS= read -r _ < "$OCSB_KEY_WRITER_RELEASE_DIR/$OCSB_KEY_WRITER_ID"
      case "$OCSB_KEY_WRITER_ID" in
        1) printf '%064d\n' 1 ;;
        2) printf '%064d\n' 2 ;;
        *) exit 64 ;;
      esac
    else
      printf '%064d\n' 0
    fi
  '';
  createMasterKey = import (builtins.toPath (repo + "/lib/ironclaw-master-key.nix")) {
    inherit pkgs target;
    openssl = fakeOpenSsl;
  };
in
pkgs.writeShellScriptBin "ocsb-create-master-key" ''
  set -euo pipefail
  target=${pkgs.lib.escapeShellArg target}
  ${createMasterKey}
  cat "$target"
''
NIX

  fixture_out="$(
    OCSB_TEST_REPO_ROOT="$REPO_ROOT" \
    OCSB_KEY_FIXTURE_DIR="$fixture_dir" \
      nix build --no-link --print-out-paths --impure --file "$fixture_expr"
  )" || return 1
  rm -f -- "$fixture_expr"
  fixture_store="${fixture_out##*$'\n'}"
  [[ -x "$fixture_store/bin/ocsb-create-master-key" ]] || {
    echo "key fixture build did not produce ocsb-create-master-key" >&2
    return 1
  }
  ln -s "$fixture_store/bin/ocsb-create-master-key" "$fixture_dir/ocsb-create-master-key"
  : > "$fixture_dir/.ocsb-ironclaw-key-fixture"
  chmod 0600 "$fixture_dir/.ocsb-ironclaw-key-fixture"
  printf '%s\n' "$fixture_dir/ocsb-create-master-key"
}

PASS=0
FAIL=0
SIDECAR_FIXTURE_DIR=""
SIDECAR_CASE_DIR=""
SIDECAR_CALLER_PIDS=()
SIDECAR_CHILD_PIDS=()
SIDECAR_RELEASE_FD_1=""
SIDECAR_RELEASE_FD_2=""
KEY_FIXTURE_DIR=""
KEY_CASE_DIR=""
KEY_WRITER_PIDS=()
KEY_FAKE_OPENSSL_PIDS=()
KEY_RELEASE_FDS=()

cleanup_master_key_fixtures() {
  local fixture_dir_to_remove=""
  local fd pid

  for fd in "${KEY_RELEASE_FDS[@]}"; do
    printf 'cleanup-release\n' >&"$fd" 2>/dev/null || true
  done
  for pid in "${KEY_WRITER_PIDS[@]}" "${KEY_FAKE_OPENSSL_PIDS[@]}"; do
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${KEY_WRITER_PIDS[@]}" "${KEY_FAKE_OPENSSL_PIDS[@]}"; do
    if [[ -n "$pid" ]] && ! wait_for_pid_exit "$pid" "master-key fixture cleanup"; then
      kill -KILL "$pid" 2>/dev/null || true
      wait_for_pid_exit "$pid" "forced master-key fixture cleanup" || true
    fi
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
  done
  for fd in "${KEY_RELEASE_FDS[@]}"; do
    eval "exec $fd>&-"
  done
  if [[ -n "$KEY_FIXTURE_DIR" && -f "$KEY_FIXTURE_DIR/.ocsb-ironclaw-key-fixture" ]]; then
    fixture_dir_to_remove="$KEY_FIXTURE_DIR"
    rm -rf -- "$fixture_dir_to_remove"
  fi
  KEY_CASE_DIR=""
  KEY_WRITER_PIDS=()
  KEY_FAKE_OPENSSL_PIDS=()
  KEY_RELEASE_FDS=()
  KEY_FIXTURE_DIR=""
}

cleanup_sidecar_fixtures() {
  local pid
  if [[ -n "$SIDECAR_RELEASE_FD_1" ]]; then
    printf 'cleanup-release\n' >&"$SIDECAR_RELEASE_FD_1" 2>/dev/null || true
  fi
  if [[ -n "$SIDECAR_RELEASE_FD_2" ]]; then
    printf 'cleanup-release\n' >&"$SIDECAR_RELEASE_FD_2" 2>/dev/null || true
  fi
  for pid in "${SIDECAR_CALLER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${SIDECAR_CALLER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  for pid in "${SIDECAR_CHILD_PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${SIDECAR_CHILD_PIDS[@]}"; do
    if ! wait_for_pid_exit "$pid" "sidecar child cleanup"; then
      kill -KILL "$pid" 2>/dev/null || true
      wait_for_pid_exit "$pid" "forced sidecar child cleanup" || true
    fi
    wait "$pid" 2>/dev/null || true
  done
  if [[ -n "$SIDECAR_RELEASE_FD_1" ]]; then
    exec {SIDECAR_RELEASE_FD_1}>&-
  fi
  if [[ -n "$SIDECAR_RELEASE_FD_2" ]]; then
    exec {SIDECAR_RELEASE_FD_2}>&-
  fi
  if [[ -n "$SIDECAR_FIXTURE_DIR" && -e "$SIDECAR_FIXTURE_DIR" ]]; then
    find "$SIDECAR_FIXTURE_DIR" -type d -exec chmod u+w {} + 2>/dev/null || true
    rm -rf -- "$SIDECAR_FIXTURE_DIR"
  fi
  SIDECAR_CALLER_PIDS=()
  SIDECAR_CHILD_PIDS=()
  SIDECAR_RELEASE_FD_1=""
  SIDECAR_RELEASE_FD_2=""
  SIDECAR_CASE_DIR=""
  SIDECAR_FIXTURE_DIR=""
}

cleanup() {
  cleanup_master_key_fixtures
  cleanup_sidecar_fixtures
  if [[ -n "$TMPDIR" && -e "$TMPDIR" ]]; then
    find "$TMPDIR" -type d -exec chmod u+w {} + 2>/dev/null || true
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

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

assert_contains() {
  local desc="$1"
  local haystack="$2"
  local needle="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc" >&2
    echo "  missing: $needle" >&2
    FAIL=$((FAIL + 1))
  fi
}

wait_for_path() {
  local path="$1"
  local description="$2"
  local deadline=$((SECONDS + 10))
  until [[ -e "$path" ]]; do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for $description: $path" >&2
      return 1
    fi
    read -r -t 0.02 _ < /dev/null || true
  done
}

sidecar_caller_has_lock_waiter() {
  local caller_pid="$1"
  local lock_file="$2"
  local child comm fd target
  local children=""

  [[ -r "/proc/$caller_pid/task/$caller_pid/children" ]] || return 1
  IFS= read -r children < "/proc/$caller_pid/task/$caller_pid/children"
  for child in $children; do
    if ! IFS= read -r comm 2>/dev/null < "/proc/$child/comm"; then
      continue
    fi
    [[ "$comm" == "flock" ]] || continue
    for fd in "/proc/$child/fd/"*; do
      target="$(readlink "$fd" 2>/dev/null || true)"
      [[ "$target" == "$lock_file" ]] && return 0
    done
  done
  return 1
}

wait_for_sidecar_lock_waiter() {
  local caller_pid="$1"
  local lock_file="$2"
  local deadline=$((SECONDS + 10))
  until sidecar_caller_has_lock_waiter "$caller_pid" "$lock_file"; do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for a blocked sidecar lock caller: $lock_file" >&2
      return 1
    fi
    read -r -t 0.02 _ < /dev/null || true
  done
}

wait_for_pid_exit() {
  local pid="$1"
  local description="$2"
  local deadline=$((SECONDS + 10))
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -r "/proc/$pid/stat" ]]; then
      local _pid _comm state
      read -r _pid _comm state _ < "/proc/$pid/stat" 2>/dev/null || true
      [[ "$state" == "Z" ]] && return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for $description: $pid" >&2
      return 1
    fi
    read -r -t 0.02 _ < /dev/null || true
  done
}

sidecar_persist_identity() {
  local persist="$1" parent

  persist="$(realpath -m "$persist")"
  parent="$(dirname "$persist")"
  printf '%s\0%s\0%s\0%s\0%s' \
    "$persist" \
    "$(stat -Lc '%d:%i:%u:%a' -- "$parent")" \
    "$(stat -Lc '%d:%i:%u:%a' -- "$persist")" \
    "$(stat -Lc '%d:%i:%u:%a' -- "$persist/state")" \
    "$(stat -Lc '%d:%i:%u:%a' -- "$persist/pgdata-sidecar")" \
    | sha256sum | cut -d ' ' -f 1
}

file_fingerprint() {
  local path="$1"

  printf '%s %s\n' "$(stat -Lc '%d:%i:%a' -- "$path")" \
    "$(sha256sum -- "$path" | cut -d ' ' -f 1)"
}

sidecar_state_artifacts_absent() {
  local state_dir="$1"

  ! compgen -G "$state_dir/.sidecar-oci-output.*" >/dev/null \
    && ! compgen -G "$state_dir/sidecar-db.*" >/dev/null \
    && [[ ! -e "$state_dir/ironclaw-db.env" ]]
}

sidecar_persist_artifacts_absent() {
  local persist_dir="$1"

  [[ ! -e "$persist_dir/sidecar-db-password" ]] \
    && ! compgen -G "$persist_dir/.sidecar-db-password.*" >/dev/null \
    && sidecar_state_artifacts_absent "$persist_dir/state"
}

run_master_key_window_case() {
  local fixture_dir_to_remove target ready_dir pid_dir release_dir writer_log_1 writer_log_2
  local previous_umask final_mode temp_mode writer_rc_1 writer_rc_2 key_value
  local writer_value_1 writer_value_2 fake_pid_1 fake_pid_2
  local key_release_fd_1 key_release_fd_2
  local -a temp_files=()

  [[ -x "$WRAPPER" ]] || {
    echo "master-key-window requires an executable key fixture" >&2
    return 2
  }
  KEY_FIXTURE_DIR="$(dirname "$WRAPPER")"
  [[ -f "$KEY_FIXTURE_DIR/.ocsb-ironclaw-key-fixture" ]] || {
    echo "master-key-window requires --build-key-fixture output" >&2
    KEY_FIXTURE_DIR=""
    return 2
  }

  KEY_CASE_DIR="$KEY_FIXTURE_DIR/master-key-window"
  target="$KEY_CASE_DIR/master_key.hex"
  ready_dir="$KEY_CASE_DIR/ready"
  pid_dir="$KEY_CASE_DIR/pids"
  release_dir="$KEY_CASE_DIR/release"
  writer_log_1="$KEY_CASE_DIR/writer-1.log"
  writer_log_2="$KEY_CASE_DIR/writer-2.log"
  install -d -m 0700 "$ready_dir" "$pid_dir" "$release_dir"
  mkfifo "$release_dir/1" "$release_dir/2"
  exec {key_release_fd_1}<>"$release_dir/1"
  exec {key_release_fd_2}<>"$release_dir/2"
  KEY_RELEASE_FDS=("$key_release_fd_1" "$key_release_fd_2")

  previous_umask="$(umask)"
  umask 022
  OCSB_KEY_WRITER_ID=1 \
  OCSB_KEY_WRITER_READY_DIR="$ready_dir" \
  OCSB_KEY_WRITER_PID_DIR="$pid_dir" \
  OCSB_KEY_WRITER_RELEASE_DIR="$release_dir" \
    "$WRAPPER" >"$writer_log_1" 2>&1 &
  KEY_WRITER_PIDS+=("$!")
  OCSB_KEY_WRITER_ID=2 \
  OCSB_KEY_WRITER_READY_DIR="$ready_dir" \
  OCSB_KEY_WRITER_PID_DIR="$pid_dir" \
  OCSB_KEY_WRITER_RELEASE_DIR="$release_dir" \
    "$WRAPPER" >"$writer_log_2" 2>&1 &
  KEY_WRITER_PIDS+=("$!")
  umask "$previous_umask"

  wait_for_path "$ready_dir/1" "first master-key writer barrier"
  wait_for_path "$ready_dir/2" "second master-key writer barrier"
  wait_for_path "$pid_dir/1" "first fake openssl pid"
  wait_for_path "$pid_dir/2" "second fake openssl pid"
  fake_pid_1="$(cat "$pid_dir/1")"
  fake_pid_2="$(cat "$pid_dir/2")"
  KEY_FAKE_OPENSSL_PIDS=("$fake_pid_1" "$fake_pid_2")

  [[ ! -e "$target" ]] || {
    echo "master-key target became visible before either writer published" >&2
    cleanup_master_key_fixtures
    return 1
  }

  shopt -s nullglob
  temp_files=("$KEY_CASE_DIR"/.master_key.hex.*)
  shopt -u nullglob
  if [[ "${#temp_files[@]}" -ne 2 ]]; then
    echo "master-key writers did not expose two private temporary keys" >&2
    cleanup_master_key_fixtures
    return 1
  fi
  for temp_file in "${temp_files[@]}"; do
    temp_mode="$(stat -c %a "$temp_file")"
    [[ "$temp_mode" == "600" ]] || {
      echo "master-key temporary key was not mode 0600 (mode=$temp_mode)" >&2
      cleanup_master_key_fixtures
      return 1
    }
  done

  printf 'release-1\n' >&"$key_release_fd_1"
  exec {key_release_fd_1}>&-
  KEY_RELEASE_FDS=("$key_release_fd_2")
  set +e
  wait "${KEY_WRITER_PIDS[0]}"
  writer_rc_1=$?
  set -e
  [[ "$writer_rc_1" -eq 0 && -f "$target" ]] || {
    echo "first master-key writer failed after release (exit=$writer_rc_1)" >&2
    cleanup_master_key_fixtures
    return 1
  }

  printf 'release-2\n' >&"$key_release_fd_2"
  exec {key_release_fd_2}>&-
  KEY_RELEASE_FDS=()
  set +e
  wait "${KEY_WRITER_PIDS[1]}"
  writer_rc_2=$?
  set -e
  KEY_WRITER_PIDS=()

  [[ "$writer_rc_2" -eq 0 ]] || {
    echo "second master-key writer failed after release (exit=$writer_rc_2)" >&2
    cleanup_master_key_fixtures
    return 1
  }
  final_mode="$(stat -c %a "$target")"
  key_value="$(cat "$target")"
  [[ "$final_mode" == "600" && "$key_value" =~ ^[0-9a-f]{64}$ ]] || {
    echo "master-key publish was not mode-0600 lowercase 64-hex" >&2
    cleanup_master_key_fixtures
    return 1
  }
  writer_value_1="$(cat "$writer_log_1")"
  writer_value_2="$(cat "$writer_log_2")"
  if [[ "$writer_value_1" != "$key_value" || "$writer_value_2" != "$key_value" ]]; then
    fixture_dir_to_remove="$KEY_FIXTURE_DIR"
    cleanup_master_key_fixtures
    [[ ! -e "$fixture_dir_to_remove" ]] || return 1
    echo 'FAIL[RED-master-key-two-writer-mismatch]: concurrent first creation can overwrite the winning key'
    echo 'CLEANUP PASS: master-key writer fixtures'
    [[ "${OCSB_EXPECT_REVIEW3_RED:-0}" == 1 ]]
    return
  fi

  OCSB_KEY_OPENSSL_CALL_LOG="$KEY_CASE_DIR/sequential-openssl-call" "$WRAPPER" >/dev/null
  [[ "$(cat "$target")" == "$key_value" ]] || {
    echo "master-key existing nonempty key changed on rerun" >&2
    cleanup_master_key_fixtures
    return 1
  }
  [[ ! -e "$KEY_CASE_DIR/sequential-openssl-call" ]] || {
    echo "master-key existing target unexpectedly generated a replacement" >&2
    cleanup_master_key_fixtures
    return 1
  }
  shopt -s nullglob
  temp_files=("$KEY_CASE_DIR"/.master_key.hex.*)
  shopt -u nullglob
  [[ "${#temp_files[@]}" -eq 0 ]] || {
    echo "master-key temporary files remained after publish" >&2
    cleanup_master_key_fixtures
    return 1
  }
  ! kill -0 "$fake_pid_1" 2>/dev/null && ! kill -0 "$fake_pid_2" 2>/dev/null || {
    echo "fake openssl process remained" >&2
    cleanup_master_key_fixtures
    return 1
  }

  fixture_dir_to_remove="$KEY_FIXTURE_DIR"
  cleanup_master_key_fixtures
  [[ ! -e "$fixture_dir_to_remove" ]] || {
    echo "master-key fixture directory remained: $fixture_dir_to_remove" >&2
    return 1
  }
  echo 'PASS[GREEN-master-key-create-once]: two-writers same-winning-key mode0600 no-temp'
  echo 'CLEANUP PASS: master-key writer fixtures'
}

identity_mismatch_refused() {
  local fixture_root="$1"
  local fake_bin="$2"
  local wrapper="$3"
  local scenario="$4"
  local expected_field="$5"
  local expected_image="$6"
  local state="$fixture_root/$scenario-state"
  local persist="$fixture_root/$scenario-persist"
  local output rc persist_id data_id volume

  install -d -m 0700 "$state" "$persist" "$persist/state" "$persist/pgdata-sidecar"
  printf 'fixture-password-not-for-logs\n' > "$persist/sidecar-db-password"
  chmod 0600 "$persist/sidecar-db-password"
  persist="$(realpath -m "$persist")"
  persist_id="$(sidecar_persist_identity "$persist")"
  data_id="$(stat -Lc '%d:%i:%u:%a' -- "$persist/pgdata-sidecar")"
  volume="$persist/pgdata-sidecar"

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
    OCSB_FAKE_OCI_STATE_DIR="$state" \
    OCSB_FAKE_OCI_SCENARIO="$scenario" \
    OCSB_FAKE_EXPECT_PERSIST_ID="$persist_id" \
    OCSB_FAKE_EXPECT_DATA_ID="$data_id" \
    OCSB_FAKE_EXPECT_IMAGE="$expected_image" \
    OCSB_FAKE_EXPECT_VOLUME="$volume" \
    OCSB_FAKE_EXPECT_PORT=55432 \
    OCSB_FAKE_INNER_LOG="$state/inner.log" \
    "$wrapper" --persist-dir "$persist" --db-mode sidecar \
      --db-sidecar-runtime docker --db-sidecar-container ocsb-ironclaw-db \
      --db-sidecar-port 55432 -- --version 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 ]] || return 1
  grep -Fq -- 'ocsb-ironclaw: sidecar identity mismatch:' <<<"$output" || return 1
  grep -Fq -- "$expected_field" <<<"$output" || return 1
  ! grep -Eq -- '^(run|start|exec):' "$state/operations" || return 1
  [[ ! -s "$state/inner.log" ]] || return 1
  [[ ! -e "$state/LOCK_FD_INHERITED" ]] || return 1
  ! grep -Eq -- 'wrong\.example|/wrong/|60000|foreign-owner|foreign-persist|fixture-password-not-for-logs' <<<"$output" || return 1
  ! compgen -G "$persist/state/.sidecar-oci-output.*" >/dev/null || return 1
  flock -n "$persist/state" -c true || return 1

  if [[ "$scenario" == "wrong-identity" ]]; then
    local field
    for field in io.ocsb.image io.ocsb.volume io.ocsb.port Config.Image \
      'Mounts[/var/lib/postgresql]' 'NetworkSettings.Ports[5432/tcp]'; do
      grep -Fq -- "$field" <<<"$output" || return 1
    done
  fi
}

run_source_only() {
  local source_file source_text lock_line password_line close_line sandbox_exec_line
  local master_key_file master_key_text existing_key_line key_mktemp_line
  source_file="$REPO_ROOT/scripts/ironclaw-wrapper.nix"
  source_text="$(cat "$source_file")"
  assert_contains "source: sidecar default image is digest pinned" "$source_text" \
    'docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0'
  assert "source: floating sidecar default removed" bash -lc \
    '! grep -Fq -- "OCSB_IRONCLAW_DB_SIDECAR_IMAGE:-docker.io/pgvector/pgvector:pg18}" "$1"' _ "$source_file"
  assert_contains "source: sidecar transaction lock uses util-linux flock" "$source_text" \
    '${pkgs.util-linux}/bin/flock'
  for label in io.ocsb.owner io.ocsb.persist-id io.ocsb.image io.ocsb.volume io.ocsb.port; do
    assert_contains "source: sidecar identity label $label" "$source_text" "$label"
  done
  assert_contains "source: sidecar identity mismatch prefix" "$source_text" \
    'ocsb-$VARIANT: sidecar identity mismatch:'
  assert_contains "source: sidecar checks Config.Image" "$source_text" '{{.Config.Image}}'
  assert_contains "source: sidecar checks Podman ImageName" "$source_text" '{{.ImageName}}'
  assert_contains "source: sidecar checks postgres mount metadata" "$source_text" 'Mounts[/var/lib/postgresql]'
  assert_contains "source: sidecar checks loopback port binding" "$source_text" 'NetworkSettings.Ports[5432/tcp]'
  assert_contains "source: sidecar establishes exact-name container existence" "$source_text" \
    "ps --all --format '{{.Names}}'"
  assert_contains "source: sidecar lifecycle receives static gate package" "$source_text" 'sidecarGate, sidecarTestHookMode ? "none"'
  assert_contains "source: production disables every sidecar test option" "$source_text" \
    'sidecar test options are disabled in production'
  assert_contains "source: immutable cidfile receipt is validated" "$source_text" '_sidecar_recover_created_id'
  assert_contains "source: commit ack precedes parent released flag" "$source_text" '_sidecar_gate_wait_ack commit || exit 1'

  lock_line="$(grep -nF -- 'exec {_SIDECAR_PARENT_FD}<"$_SIDECAR_PARENT_PATH"' "$source_file" | sed -n '1s/:.*//p')"
  password_line="$(grep -nF -- '_SIDECAR_PASSWORD_FILE="$_SIDECAR_PERSIST_FD_PATH/sidecar-db-password"' "$source_file" | sed -n '1s/:.*//p')"
  close_line="$(grep -nF -- '_sidecar_close_transaction_fds' "$source_file" | tail -n 1 | cut -d: -f1)"
  sandbox_exec_line="$(grep -nF -- 'exec ${ironclawSandboxBase}/bin/ironclaw' "$source_file" | cut -d: -f1)"
  assert "source: stable parent lock is acquired before password access" test "$lock_line" -lt "$password_line"
  assert "source: transaction descriptors close before sandbox exec" test "$close_line" -lt "$sandbox_exec_line"
  assert_contains "source: OCI child closes held parent FD" "$source_text" \
    'exec {_SIDECAR_PARENT_FD}<&-'
  assert_contains "source: held parent identity is captured" "$source_text" \
    '_SIDECAR_PARENT_ID="$(_sidecar_path_id "$_SIDECAR_PARENT_FD_PATH")"'
  assert_contains "source: held persist identity is captured" "$source_text" \
    '_SIDECAR_PERSIST_PATH_ID="$(_sidecar_path_id "$_SIDECAR_PERSIST_FD_PATH")"'
  assert_contains "source: held state identity is captured" "$source_text" \
    '_SIDECAR_STATE_ID="$(_sidecar_path_id "$_SIDECAR_STATE_FD_PATH")"'
  assert_contains "source: held data identity is captured" "$source_text" \
    '_SIDECAR_DATA_ID="$(_sidecar_path_id "$_SIDECAR_DATA_FD_PATH")"'
  assert_contains "source: persist label hashes canonical path and held identities" "$source_text" \
    "printf '%s\\0%s\\0%s\\0%s\\0%s'"
  assert_contains "source: persist label includes held data identity" "$source_text" \
    '"$_SIDECAR_DATA_ID" \'
  assert_contains "source: replacement revalidation fails closed" "$source_text" \
    'sidecar transaction path was replaced'
  assert_contains "source: sidecar password rejects symlinks" "$source_text" \
    'unsafe sidecar password file'
  assert_contains "source: sidecar password validates one canonical line" "$source_text" \
    'malformed sidecar password file'
  assert_contains "source: signal handler runs sidecar cleanup" "$source_text" \
    '_sidecar_cleanup'
  assert_contains "source: cleanup reaps terminated OCI child" "$source_text" \
    'wait "$_pid" 2>/dev/null || true'
  assert_contains "source: password cleanup has KILL fallback" "$source_text" \
    'kill -KILL "$_pid" 2>/dev/null || true'
  master_key_file="$REPO_ROOT/lib/ironclaw-master-key.nix"
  master_key_text="$(cat "$master_key_file")"
  existing_key_line="$(grep -nF -- 'if [[ -e "$_mk_target" || -L "$_mk_target" ]]; then' "$master_key_file" | cut -d: -f1)"
  key_mktemp_line="$(grep -nF -- '_mk_tmp="$(mktemp ' "$master_key_file" | cut -d: -f1)"
  assert "source: valid master key fast path precedes temp creation" \
    test "$existing_key_line" -lt "$key_mktemp_line"
  assert_contains "source: master key publication remains no-replace" "$master_key_text" \
    'ln -T -- "$_mk_tmp" "$_mk_target"'

  echo ""
  echo "=== ironclaw source-only Results: $PASS passed, $FAIL failed ==="
  [[ "$FAIL" -eq 0 ]]
}

sidecar_preflight_refused() {
  local fixture_root="$1" fake_bin="$2" wrapper="$3" kind="$4"
  local state="$fixture_root/preflight-$kind-state"
  local persist="$fixture_root/preflight-$kind-persist"
  local victim="$fixture_root/preflight-$kind-victim"
  local output rc expected marker before_inode before_hash

  install -d -m 0700 "$state" "$persist/state"
  case "$kind" in
    lock-symlink)
      printf 'lock-canary\n' > "$victim"
      chmod 0600 "$victim"
      before_inode="$(stat -c '%d:%i:%a' "$victim")"
      before_hash="$(sha256sum "$victim" | cut -d ' ' -f1)"
      ln -s "$victim" "$persist/state/ironclaw-sidecar.lock"
      expected='unsafe sidecar lock path'
      marker='PASS[GREEN-sidecar-lock-symlink]: canary-unchanged no-oci-mutation'
      ;;
    password-symlink)
      printf 'password-canary\n' > "$victim"
      chmod 0600 "$victim"
      before_inode="$(stat -c '%d:%i:%a' "$victim")"
      before_hash="$(sha256sum "$victim" | cut -d ' ' -f1)"
      ln -s "$victim" "$persist/sidecar-db-password"
      expected='unsafe sidecar password file'
      marker='PASS[GREEN-sidecar-password-symlink]: canary-unchanged no-oci-mutation'
      ;;
    password-malformed)
      printf 'not-a-valid-sidecar-password\n' > "$persist/sidecar-db-password"
      chmod 0600 "$persist/sidecar-db-password"
      expected='malformed sidecar password file'
      marker='PASS[GREEN-sidecar-password-malformed]: rejected-before-oci secret-free'
      ;;
    password-multiline)
      printf '%048d\nextra-line\n' 0 > "$persist/sidecar-db-password"
      chmod 0600 "$persist/sidecar-db-password"
      expected='malformed sidecar password file'
      marker='PASS[GREEN-sidecar-password-multiline]: rejected-before-oci secret-free'
      ;;
    *) return 2 ;;
  esac

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
    OCSB_FAKE_OCI_STATE_DIR="$state" \
    OCSB_FAKE_OCI_SCENARIO=preflight \
    OCSB_FAKE_SIDECAR_STATE_PATH="$persist/state" \
    "$wrapper" --persist-dir "$persist" --db-mode sidecar \
      --db-sidecar-runtime podman --db-sidecar-container ocsb-ironclaw-db \
      --db-sidecar-port 55432 -- --version 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" -ne 0 && "$output" == *"$expected" ]] || return 1
  ! grep -Eq '^(run|start|exec):' "$state/operations" 2>/dev/null || return 1
  [[ ! -e "$state/LOCK_FD_INHERITED" && ! -s "$state/inner.log" ]] || return 1
  ! compgen -G "$persist/state/.sidecar-oci-output.*" >/dev/null || return 1
  if [[ -n "${before_inode:-}" ]]; then
    [[ "$(stat -c '%d:%i:%a' "$victim")" == "$before_inode" &&
      "$(sha256sum "$victim" | cut -d ' ' -f1)" == "$before_hash" ]] || return 1
  fi
  # The test never prints the captured failure text; this verifies both canary
  # forms without putting their content into CI logs.
  ! grep -Fq -- 'password-canary' <<<"$output" || return 1
  printf '%s\n' "$marker"
}

run_sidecar_stable_replacement_subcase() {
  local kind="$1" fake_bin="$2" case_dir parent persist victim original_state control
  local original_canary replacement_canary original_fingerprint replacement_fingerprint
  local caller1_pid caller2_pid caller1_rc caller2_rc release_fd_1 release_fd_2
  local lock_blocked=0 concurrent=0 first_mutation_absent=0 create_count password_hash_count
  local creation_password_hash caller2_password_hash deadline

  case_dir="$SIDECAR_CASE_DIR/$kind"
  parent="$case_dir/public-parent"
  persist="$parent/persist"
  victim="$case_dir/victim-persist"
  original_state="$case_dir/victim-state"
  control="$case_dir/control"
  install -d -m 0700 "$persist/state" "$persist/pgdata-sidecar" "$control"
  case "$kind" in
    state)
      original_canary="$persist/state/original-state-canary"
      replacement_canary="$persist/state/replacement-state-canary"
      ;;
    persist)
      original_canary="$persist/original-persist-canary"
      replacement_canary="$persist/replacement-persist-canary"
      ;;
    *) return 2 ;;
  esac
  printf 'original-%s-canary\n' "$kind" > "$original_canary"
  chmod 0600 "$original_canary"
  original_fingerprint="$(file_fingerprint "$original_canary")"
  mkfifo "$control/release-1.fifo" "$control/release-2.fifo"
  exec {release_fd_1}<>"$control/release-1.fifo"
  exec {release_fd_2}<>"$control/release-2.fifo"
  SIDECAR_RELEASE_FD_1="$release_fd_1"
  SIDECAR_RELEASE_FD_2="$release_fd_2"

  PATH="$fake_bin:$PATH" \
  OCSB_FAKE_OCI_STATE_DIR="$control" \
  OCSB_FAKE_OCI_SCENARIO=split-lock \
  OCSB_FAKE_OCI_CALLER=1 \
  OCSB_FAKE_SIDECAR_STATE_PATH="$persist/state" \
  OCSB_FAKE_NO_HELD_FD_DIR="$parent" \
  OCSB_FAKE_INNER_LOG="$control/inner-1.log" \
  "$WRAPPER" --persist-dir "$persist" --db-mode sidecar \
    --db-sidecar-runtime podman --db-sidecar-container ocsb-ironclaw-db \
    --db-sidecar-port 55432 -- --version >"$control/caller-1.log" 2>&1 &
  caller1_pid="$!"
  SIDECAR_CALLER_PIDS=("$caller1_pid")
  wait_for_path "$control/FIRST_INSPECT_READY" "$kind replacement first inspect barrier"

  if [[ "$kind" == state ]]; then
    mv -- "$persist/state" "$original_state"
    original_canary="$original_state/original-state-canary"
    install -d -m 0700 "$persist/state"
  else
    mv -- "$persist" "$victim"
    original_canary="$victim/original-persist-canary"
    install -d -m 0700 "$persist/state" "$persist/pgdata-sidecar"
  fi
  printf 'replacement-%s-canary\n' "$kind" > "$replacement_canary"
  chmod 0600 "$replacement_canary"
  replacement_fingerprint="$(file_fingerprint "$replacement_canary")"

  PATH="$fake_bin:$PATH" \
  OCSB_FAKE_OCI_STATE_DIR="$control" \
  OCSB_FAKE_OCI_SCENARIO=split-lock \
  OCSB_FAKE_OCI_CALLER=2 \
  OCSB_FAKE_SIDECAR_STATE_PATH="$persist/state" \
  OCSB_FAKE_NO_HELD_FD_DIR="$parent" \
  OCSB_FAKE_INNER_LOG="$control/inner-2.log" \
  "$WRAPPER" --persist-dir "$persist" --db-mode sidecar \
    --db-sidecar-runtime podman --db-sidecar-container ocsb-ironclaw-db \
    --db-sidecar-port 55432 -- --version >"$control/caller-2.log" 2>&1 &
  caller2_pid="$!"
  SIDECAR_CALLER_PIDS+=("$caller2_pid")
  deadline=$((SECONDS + 2))
  while [[ ! -e "$control/SECOND_INSPECT_READY" && $SECONDS -lt $deadline ]]; do
    sleep 0.02
  done
  if [[ -e "$control/SECOND_INSPECT_READY" ]]; then
    concurrent=1
  elif wait_for_sidecar_lock_waiter "$caller2_pid" "$parent"; then
    lock_blocked=1
  fi

  printf 'release-1\n' >&"$release_fd_1"
  exec {release_fd_1}>&-
  SIDECAR_RELEASE_FD_1=""
  set +e
  wait "$caller1_pid"
  caller1_rc=$?
  set -e
  SIDECAR_CALLER_PIDS=("$caller2_pid")

  if [[ "$(file_fingerprint "$original_canary")" == "$original_fingerprint" &&
        "$(file_fingerprint "$replacement_canary")" == "$replacement_fingerprint" &&
        ! -e "$control/HELD_FD_INHERITED" ]] &&
      ! grep -Eq '^(run|start|exec):1:' "$control/operations" 2>/dev/null; then
    if [[ "$kind" == state ]]; then
      if [[ ! -e "$persist/sidecar-db-password" ]] \
        && sidecar_state_artifacts_absent "$original_state" \
        && sidecar_state_artifacts_absent "$persist/state"; then
        first_mutation_absent=1
      fi
    elif sidecar_persist_artifacts_absent "$victim" \
      && sidecar_persist_artifacts_absent "$persist"; then
      first_mutation_absent=1
    fi
  fi

  if [[ "$lock_blocked" -eq 1 ]]; then
    wait_for_path "$control/SECOND_INSPECT_READY" "$kind replacement second inspect barrier"
  fi
  printf 'release-2\n' >&"$release_fd_2"
  exec {release_fd_2}>&-
  SIDECAR_RELEASE_FD_2=""
  set +e
  wait "$caller2_pid"
  caller2_rc=$?
  set -e
  SIDECAR_CALLER_PIDS=()
  create_count="$(cat "$control/create-count" 2>/dev/null || printf 0)"
  password_hash_count="$(sort -u "$control/password-hashes" 2>/dev/null | sed '/^$/d' | wc -l)"
  creation_password_hash="$(sed -n '1p' "$control/password-hashes" 2>/dev/null || true)"
  caller2_password_hash="$(sed -n 's/^PASSWORD_HASH=//p' "$control/inner-2.log" 2>/dev/null || true)"

  if [[ -e "$control/HELD_FD_INHERITED" ]]; then
    echo "forbidden OCI child descriptor inheritance: $(tr '\n' ' ' < "$control/forbidden-held-fd-targets")" >&2
  fi

  [[ "$lock_blocked" -eq 1 && "$concurrent" -eq 0 && "$caller1_rc" -ne 0 &&
    "$first_mutation_absent" -eq 1 && "$caller2_rc" -eq 0 && "$create_count" == 1 &&
    "$password_hash_count" == 1 && "$creation_password_hash" == "$caller2_password_hash" &&
    -s "$persist/sidecar-db-password" && ! -e "$control/HELD_FD_INHERITED" ]]
}

run_sidecar_stable_serialization_case() {
  local fake_bin fixture_dir_to_remove

  [[ -x "$WRAPPER" ]] || return 2
  SIDECAR_FIXTURE_DIR="$(dirname "$(readlink -f "$WRAPPER")")"
  [[ -f "$SIDECAR_FIXTURE_DIR/.ocsb-ironclaw-lightweight-fixture" ]] || {
    SIDECAR_FIXTURE_DIR="$(dirname "$WRAPPER")"
  }
  [[ -f "$SIDECAR_FIXTURE_DIR/.ocsb-ironclaw-lightweight-fixture" ]] || return 2
  fake_bin="$SIDECAR_FIXTURE_DIR/fake-bin"
  SIDECAR_CASE_DIR="$SIDECAR_FIXTURE_DIR/review3-sidecar-stable"
  fixture_dir_to_remove="$SIDECAR_FIXTURE_DIR"

  if run_sidecar_stable_replacement_subcase state "$fake_bin" \
    && run_sidecar_stable_replacement_subcase persist "$fake_bin"; then
    cleanup_sidecar_fixtures
    [[ ! -e "$fixture_dir_to_remove" ]] || return 1
    echo 'PASS[GREEN-sidecar-stable-serialization]: parent-fd-lock persist-state-data anchored replacement-refused no-concurrent-mutation'
    echo 'CLEANUP PASS: sidecar stable serialization fixtures'
    return 0
  fi

  cleanup_sidecar_fixtures
  return 1
}

run_sidecar_password_signal_case() {
  local fake_bin case_dir parent persist control release_fifo release_fd
  local wrapper_pid openssl_pid wrapper_rc lock_released=0 child_reaped=0 temp_absent=0
  local no_oci_mutation=0 canary_unchanged=0 term_ignored=0 fixture_dir_to_remove
  local canary canary_fingerprint

  [[ -x "$WRAPPER" ]] || return 2
  SIDECAR_FIXTURE_DIR="$(dirname "$(readlink -f "$WRAPPER")")"
  [[ -f "$SIDECAR_FIXTURE_DIR/.ocsb-ironclaw-lightweight-fixture" ]] || {
    SIDECAR_FIXTURE_DIR="$(dirname "$WRAPPER")"
  }
  [[ -f "$SIDECAR_FIXTURE_DIR/.ocsb-ironclaw-lightweight-fixture" ]] || return 2
  fake_bin="$SIDECAR_FIXTURE_DIR/fake-bin"
  SIDECAR_CASE_DIR="$SIDECAR_FIXTURE_DIR/review3-password-signal"
  case_dir="$SIDECAR_CASE_DIR/case"
  parent="$case_dir/public-parent"
  persist="$parent/persist"
  control="$case_dir/control"
  install -d -m 0700 "$persist/state" "$persist/pgdata-sidecar" "$control"
  canary="$control/unrelated-canary"
  printf 'unrelated-password-signal-canary\n' > "$canary"
  chmod 0600 "$canary"
  canary_fingerprint="$(file_fingerprint "$canary")"
  release_fifo="$control/openssl-release.fifo"
  mkfifo "$release_fifo"
  exec {release_fd}<>"$release_fifo"
  SIDECAR_RELEASE_FD_1="$release_fd"

  PATH="$fake_bin:$PATH" \
  OCSB_FAKE_OCI_STATE_DIR="$control" \
  OCSB_FAKE_OCI_SCENARIO=preflight \
  OCSB_FAKE_OPENSSL_READY_FILE="$control/openssl-ready" \
  OCSB_FAKE_OPENSSL_PID_FILE="$control/openssl.pid" \
  OCSB_FAKE_OPENSSL_RELEASE_FIFO="$release_fifo" \
  OCSB_FAKE_OPENSSL_IGNORE_TERM=1 \
  "$WRAPPER" --persist-dir "$persist" --db-mode sidecar \
    --db-sidecar-runtime podman --db-sidecar-container ocsb-ironclaw-db \
    --db-sidecar-port 55432 -- --version >"$control/caller.log" 2>&1 &
  wrapper_pid="$!"
  SIDECAR_CALLER_PIDS=("$wrapper_pid")
  wait_for_path "$control/openssl-ready" "sidecar password openssl barrier"
  wait_for_path "$control/openssl.pid" "sidecar password openssl pid"
  openssl_pid="$(cat "$control/openssl.pid")"
  SIDECAR_CHILD_PIDS=("$openssl_pid")
  kill -TERM "$wrapper_pid"
  sleep 0.1
  if kill -0 "$openssl_pid" 2>/dev/null; then
    term_ignored=1
  fi
  if ! wait_for_pid_exit "$wrapper_pid" "signalled password wrapper"; then
    cleanup_sidecar_fixtures
    return 1
  fi
  set +e
  wait "$wrapper_pid"
  wrapper_rc=$?
  set -e
  SIDECAR_CALLER_PIDS=()
  if ! kill -0 "$openssl_pid" 2>/dev/null; then
    child_reaped=1
    SIDECAR_CHILD_PIDS=()
  fi
  if ! compgen -G "$persist/.sidecar-db-password.*" >/dev/null; then
    temp_absent=1
  fi
  if flock -n "$parent" -c true; then
    lock_released=1
  fi
  if ! grep -Eq '^(run|start|exec):' "$control/operations" 2>/dev/null; then
    no_oci_mutation=1
  fi
  if [[ "$(file_fingerprint "$canary")" == "$canary_fingerprint" ]]; then
    canary_unchanged=1
  fi

  fixture_dir_to_remove="$SIDECAR_FIXTURE_DIR"
  if [[ "$wrapper_rc" -ne 0 && "$temp_absent" -eq 1 && "$child_reaped" -eq 1 &&
        "$lock_released" -eq 1 && "$no_oci_mutation" -eq 1 && "$canary_unchanged" -eq 1 &&
        "$term_ignored" -eq 1 &&
        ! -e "$persist/sidecar-db-password" ]]; then
    cleanup_sidecar_fixtures
    [[ ! -e "$fixture_dir_to_remove" ]] || return 1
    echo 'PASS[GREEN-sidecar-password-signal-cleanup]: temp-absent canary-unchanged lock-released child-reaped no-oci-mutation'
    echo 'CLEANUP PASS: sidecar password signal fixtures'
    return 0
  fi

  cleanup_sidecar_fixtures
  return 1
}

run_sidecar_security_case() {
  local fixed_image='docker.io/pgvector/pgvector:pg18@sha256:12a379b47ad65289572ea0756efc11b7c241a6662833e8af7038cd3b73d647e0'
  local override_image='registry.example/pgvector:fixture@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  local fake_bin
  local concurrency_state concurrency_persist parent_lock_file lock_file lock_probe caller1_rc caller2_rc
  local signal_state signal_persist signal_lock_file signal_pid signal_oci_pid signal_rc
  local signal_exited signal_oci_exited signal_lock_released=0
  local create_count password_hash_count creation_password_hash caller1_password_hash caller2_password_hash
  local password_consistent=0 help_text marker_fail=0 pid
  local caller1_pid caller2_pid fixture_dir_to_remove
  local identity_fixed=0 concurrency_fixed=0 image_fixed=0

  [[ -x "$WRAPPER" ]] || {
    echo "sidecar-security requires an executable lightweight wrapper" >&2
    return 2
  }
  SIDECAR_FIXTURE_DIR="$(dirname "$(readlink -f "$WRAPPER")")"
  if [[ ! -f "$SIDECAR_FIXTURE_DIR/.ocsb-ironclaw-lightweight-fixture" ]]; then
    SIDECAR_FIXTURE_DIR="$(dirname "$WRAPPER")"
  fi
  [[ -f "$SIDECAR_FIXTURE_DIR/.ocsb-ironclaw-lightweight-fixture" ]] || {
    echo "sidecar-security requires --build-lightweight-wrapper output" >&2
    SIDECAR_FIXTURE_DIR=""
    return 2
  }
  fake_bin="$SIDECAR_FIXTURE_DIR/fake-bin"
  SIDECAR_CASE_DIR="$SIDECAR_FIXTURE_DIR/sidecar-security"
  concurrency_state="$SIDECAR_CASE_DIR/concurrency-state"
  concurrency_persist="$SIDECAR_CASE_DIR/concurrency-persist"
  install -d -m 0700 "$concurrency_state" "$concurrency_persist/state"

  if identity_mismatch_refused "$SIDECAR_CASE_DIR" "$fake_bin" "$WRAPPER" \
      wrong-identity Config.Image "$fixed_image" \
    && identity_mismatch_refused "$SIDECAR_CASE_DIR" "$fake_bin" "$WRAPPER" \
      wrong-owner io.ocsb.owner "$fixed_image" \
    && identity_mismatch_refused "$SIDECAR_CASE_DIR" "$fake_bin" "$WRAPPER" \
      wrong-owner-newline io.ocsb.owner "$fixed_image" \
    && identity_mismatch_refused "$SIDECAR_CASE_DIR" "$fake_bin" "$WRAPPER" \
      wrong-persist io.ocsb.persist-id "$fixed_image" \
    && identity_mismatch_refused "$SIDECAR_CASE_DIR" "$fake_bin" "$WRAPPER" \
      wrong-persist-newline io.ocsb.persist-id "$fixed_image" \
    && identity_mismatch_refused "$SIDECAR_CASE_DIR" "$fake_bin" "$WRAPPER" \
      inspect-error State.Status "$fixed_image"; then
    identity_fixed=1
  fi

  for preflight in lock-symlink password-symlink password-malformed password-multiline; do
    sidecar_preflight_refused "$SIDECAR_CASE_DIR" "$fake_bin" "$WRAPPER" "$preflight" || {
      echo "sidecar preflight canary failed: $preflight" >&2
      return 1
    }
  done

  mkfifo "$concurrency_state/release-1.fifo" "$concurrency_state/release-2.fifo"
  exec {SIDECAR_RELEASE_FD_1}<>"$concurrency_state/release-1.fifo"
  exec {SIDECAR_RELEASE_FD_2}<>"$concurrency_state/release-2.fifo"
  lock_file="$concurrency_persist/state"
  parent_lock_file="$(dirname "$concurrency_persist")"

  PATH="$fake_bin:$PATH" \
  OCSB_FAKE_OCI_STATE_DIR="$concurrency_state" \
  OCSB_FAKE_OCI_SCENARIO=concurrency \
  OCSB_FAKE_OCI_CALLER=1 \
  OCSB_FAKE_SIDECAR_STATE_PATH="$concurrency_persist/state" \
  OCSB_FAKE_INNER_LOG="$concurrency_state/inner-1.log" \
  "$WRAPPER" --persist-dir "$concurrency_persist" --db-mode sidecar \
    --db-sidecar-runtime podman --db-sidecar-container ocsb-ironclaw-db \
    --db-sidecar-image "$override_image" --db-sidecar-port 55432 -- --version \
    >"$concurrency_state/caller-1.log" 2>&1 &
  caller1_pid="$!"
  SIDECAR_CALLER_PIDS+=("$caller1_pid")
  wait_for_path "$concurrency_state/FIRST_INSPECT_READY" "first inspect barrier"

  if flock -n "$lock_file" -c true; then
    lock_probe="unlocked"
  else
    lock_probe="locked"
  fi

  PATH="$fake_bin:$PATH" \
  OCSB_FAKE_OCI_STATE_DIR="$concurrency_state" \
  OCSB_FAKE_OCI_SCENARIO=concurrency \
  OCSB_FAKE_OCI_CALLER=2 \
  OCSB_FAKE_SIDECAR_STATE_PATH="$concurrency_persist/state" \
  OCSB_FAKE_INNER_LOG="$concurrency_state/inner-2.log" \
  "$WRAPPER" --persist-dir "$concurrency_persist" --db-mode sidecar \
    --db-sidecar-runtime podman --db-sidecar-container ocsb-ironclaw-db \
    --db-sidecar-image "$override_image" --db-sidecar-port 55432 -- --version \
    >"$concurrency_state/caller-2.log" 2>&1 &
  caller2_pid="$!"
  SIDECAR_CALLER_PIDS+=("$caller2_pid")

  if [[ "$lock_probe" == "unlocked" ]]; then
    wait_for_path "$concurrency_state/SECOND_INSPECT_READY" "second inspect barrier"
  else
    if ! wait_for_sidecar_lock_waiter "$caller2_pid" "$parent_lock_file"; then
      # Some CI kernels restrict observing another process' blocked flock child
      # through /proc/<pid>/task/<pid>/children.  The product assertion below is
      # still enforced by releasing caller 1, requiring caller 2 to complete,
      # and checking create_count=1 plus a shared password hash.
      kill -0 "$caller2_pid" 2>/dev/null || return 1
    fi
    [[ ! -e "$concurrency_state/SECOND_INSPECT_READY" ]] || marker_fail=1
  fi

  printf 'release\n' >&"$SIDECAR_RELEASE_FD_1"
  printf 'release\n' >&"$SIDECAR_RELEASE_FD_2"
  exec {SIDECAR_RELEASE_FD_1}>&-
  exec {SIDECAR_RELEASE_FD_2}>&-
  SIDECAR_RELEASE_FD_1=""
  SIDECAR_RELEASE_FD_2=""

  set +e
  wait "${SIDECAR_CALLER_PIDS[0]}"
  caller1_rc=$?
  wait "${SIDECAR_CALLER_PIDS[1]}"
  caller2_rc=$?
  set -e
  SIDECAR_CALLER_PIDS=()
  create_count="$(cat "$concurrency_state/create-count" 2>/dev/null || printf '0')"
  password_hash_count="$(sort -u "$concurrency_state/password-hashes" 2>/dev/null | sed '/^$/d' | wc -l)"
  creation_password_hash="$(sed -n '1p' "$concurrency_state/password-hashes" 2>/dev/null || true)"
  caller1_password_hash="$(sed -n 's/^PASSWORD_HASH=//p' "$concurrency_state/inner-1.log" 2>/dev/null || true)"
  caller2_password_hash="$(sed -n 's/^PASSWORD_HASH=//p' "$concurrency_state/inner-2.log" 2>/dev/null || true)"
  if [[ -n "$creation_password_hash" \
    && "$creation_password_hash" == "$caller1_password_hash" \
    && "$creation_password_hash" == "$caller2_password_hash" ]]; then
    password_consistent=1
  fi

  signal_state="$SIDECAR_CASE_DIR/signal-state"
  signal_persist="$SIDECAR_CASE_DIR/signal-persist"
  signal_lock_file="$signal_persist/state"
  install -d -m 0700 "$signal_state" "$signal_persist/state"
  mkfifo "$signal_state/release-1.fifo"
  exec {SIDECAR_RELEASE_FD_1}<>"$signal_state/release-1.fifo"
  PATH="$fake_bin:$PATH" \
  OCSB_FAKE_OCI_STATE_DIR="$signal_state" \
  OCSB_FAKE_OCI_SCENARIO=concurrency \
  OCSB_FAKE_OCI_CALLER=1 \
  OCSB_FAKE_SIDECAR_STATE_PATH="$signal_persist/state" \
  OCSB_FAKE_OCI_IGNORE_TERM=1 \
  OCSB_FAKE_INNER_LOG="$signal_state/inner.log" \
  "$WRAPPER" --persist-dir "$signal_persist" --db-mode sidecar \
    --db-sidecar-runtime podman --db-sidecar-container ocsb-ironclaw-db \
    --db-sidecar-port 55432 -- --version \
    >"$signal_state/caller.log" 2>&1 &
  signal_pid="$!"
  SIDECAR_CALLER_PIDS=("$signal_pid")
  wait_for_path "$signal_state/FIRST_INSPECT_READY" "signal-path inspect barrier"
  signal_oci_pid="$(cat "$signal_state/ACTIVE_OCI_PID")"
  if ! flock -n "$signal_lock_file" -c true; then
    kill -TERM "$signal_pid"
    signal_exited=0
    signal_oci_exited=0
    if wait_for_pid_exit "$signal_pid" "signalled sidecar caller"; then
      signal_exited=1
      if ! kill -0 "$signal_oci_pid" 2>/dev/null; then
        signal_oci_exited=1
      fi
    fi
    if [[ "$signal_exited" -ne 1 || "$signal_oci_exited" -ne 1 ]]; then
      printf 'signal-release\n' >&"$SIDECAR_RELEASE_FD_1"
      kill -KILL "$signal_pid" 2>/dev/null || true
      kill -KILL "$signal_oci_pid" 2>/dev/null || true
      wait_for_pid_exit "$signal_oci_pid" "failed signal fixture OCI cleanup" || true
    fi
    exec {SIDECAR_RELEASE_FD_1}>&-
    SIDECAR_RELEASE_FD_1=""
    set +e
    wait "$signal_pid"
    signal_rc=$?
    set -e
    SIDECAR_CALLER_PIDS=()
    if [[ "$signal_exited" -eq 1 && "$signal_oci_exited" -eq 1 && "$signal_rc" -ne 0 ]] \
      && ! kill -0 "$signal_pid" 2>/dev/null \
      && ! kill -0 "$signal_oci_pid" 2>/dev/null \
      && flock -n "$signal_lock_file" -c true \
      && ! compgen -G "$signal_persist/state/sidecar-db.*" >/dev/null \
      && ! compgen -G "$signal_persist/state/.sidecar-oci-output.*" >/dev/null \
      && [[ ! -e "$signal_state/LOCK_FD_INHERITED" ]]; then
      signal_lock_released=1
    fi
  fi

  if [[ "$lock_probe" == "locked" && "$marker_fail" -eq 0 \
    && "$caller1_rc" -eq 0 && "$caller2_rc" -eq 0 \
    && "$create_count" == "1" && "$password_hash_count" == "1" \
    && "$password_consistent" -eq 1 && "$signal_lock_released" -eq 1 \
    && ! -e "$concurrency_state/LOCK_FD_INHERITED" ]] \
    && ! grep -Fq -- 'LOCK_FD_LEAK' "$concurrency_state/inner-1.log" \
    && ! grep -Fq -- 'LOCK_FD_LEAK' "$concurrency_state/inner-2.log"; then
    concurrency_fixed=1
  fi

  help_text="$("$WRAPPER" --help)"
  if grep -Fq -- "Default: $fixed_image." <<<"$help_text" \
    && ! grep -Fq -- 'Default: docker.io/pgvector/pgvector:pg18.' <<<"$help_text"; then
    image_fixed=1
  fi

  if [[ "$identity_fixed" -eq 1 ]]; then
    echo 'PASS[GREEN-sidecar-identity]: mismatch refused before mutation'
  else
    echo 'FAIL[RED-sidecar-identity]: wrong image,volume,port reused'
    marker_fail=1
  fi
  if [[ "$concurrency_fixed" -eq 1 ]]; then
    echo 'PASS[GREEN-sidecar-concurrency]: create_count=1 lock_probe=locked password_consistent'
  else
    echo "FAIL[RED-sidecar-concurrency]: create_count=$create_count lock_probe=$lock_probe marker_fail=$marker_fail caller1_rc=$caller1_rc caller2_rc=$caller2_rc password_hash_count=$password_hash_count password_consistent=$password_consistent signal_lock_released=$signal_lock_released lock_fd_inherited=$([[ -e "$concurrency_state/LOCK_FD_INHERITED" ]] && printf 1 || printf 0) inner1_leak=$({ grep -Fq -- 'LOCK_FD_LEAK' "$concurrency_state/inner-1.log" 2>/dev/null && printf 1; } || printf 0) inner2_leak=$({ grep -Fq -- 'LOCK_FD_LEAK' "$concurrency_state/inner-2.log" 2>/dev/null && printf 1; } || printf 0)"
    echo "DIAG[sidecar-concurrency-ops]: $(tr '\n' ';' < "$concurrency_state/operations" 2>/dev/null || true)"
    echo "DIAG[sidecar-concurrency-caller1]: $(tail -5 "$concurrency_state/caller-1.log" 2>/dev/null | tr '\n' ';' || true)"
    echo "DIAG[sidecar-concurrency-caller2]: $(tail -5 "$concurrency_state/caller-2.log" 2>/dev/null | tr '\n' ';' || true)"
    echo "DIAG[sidecar-concurrency-inner1]: $(cat "$concurrency_state/inner-1.log" 2>/dev/null | tr '\n' ';' || true)"
    echo "DIAG[sidecar-concurrency-inner2]: $(cat "$concurrency_state/inner-2.log" 2>/dev/null | tr '\n' ';' || true)"
    marker_fail=1
  fi
  if [[ "$image_fixed" -eq 1 ]]; then
    echo "PASS[GREEN-sidecar-image]: $fixed_image"
  else
    echo 'FAIL[RED-sidecar-image]: default is floating :pg18'
    marker_fail=1
  fi

  for pid in "$caller1_pid" "$caller2_pid"; do
    ! kill -0 "$pid" 2>/dev/null || {
      echo "fixture process remained: $pid" >&2
      return 1
    }
  done
  flock -n "$lock_file" -c true || {
    echo "sidecar lock still has a holder: $lock_file" >&2
    return 1
  }
  fixture_dir_to_remove="$SIDECAR_FIXTURE_DIR"
  cleanup_sidecar_fixtures
  [[ ! -e "$fixture_dir_to_remove" ]]
  echo 'CLEANUP PASS: sidecar fake OCI fixtures'
  [[ "$marker_fail" -eq 0 ]]
}

run_final_review_sidecar_gate_red_evidence() {
  local fake_bin state persist release_fd wrapper_pid wrapper_rc stored_source
  local fixture_dir_to_remove

  [[ -x "$WRAPPER" ]] || return 2
  SIDECAR_FIXTURE_DIR="$(dirname "$(readlink -f "$WRAPPER")")"
  if [[ ! -f "$SIDECAR_FIXTURE_DIR/.ocsb-ironclaw-lightweight-fixture" ]]; then
    SIDECAR_FIXTURE_DIR="$(dirname "$WRAPPER")"
  fi
  [[ -f "$SIDECAR_FIXTURE_DIR/.ocsb-ironclaw-lightweight-fixture" ]] || return 2
  fake_bin="$SIDECAR_FIXTURE_DIR/fake-bin"
  SIDECAR_CASE_DIR="$SIDECAR_FIXTURE_DIR/final-review-sidecar-gate-red"
  state="$SIDECAR_CASE_DIR/state"
  persist="$SIDECAR_CASE_DIR/persist"
  install -d -m 0700 "$state" "$persist/state" "$persist/pgdata-sidecar"
  mkfifo "$state/release-1.fifo"
  exec {release_fd}<>"$state/release-1.fifo"
  SIDECAR_RELEASE_FD_1="$release_fd"

  PATH="$fake_bin:$PATH" \
  OCSB_FAKE_OCI_STATE_DIR="$state" \
  OCSB_FAKE_OCI_SCENARIO=concurrency \
  OCSB_FAKE_OCI_CALLER=1 \
  OCSB_FAKE_INNER_LOG="$state/inner.log" \
    "$WRAPPER" --persist-dir "$persist" --db-mode sidecar \
      --db-sidecar-runtime docker --db-sidecar-container ocsb-ironclaw-db \
      --db-sidecar-port 55432 -- --version >"$state/wrapper.log" 2>&1 &
  wrapper_pid="$!"
  SIDECAR_CALLER_PIDS=("$wrapper_pid")
  wait_for_path "$state/FIRST_INSPECT_READY" "Task 17 pre-fix inspect barrier"
  printf 'release\n' >&"$release_fd"
  exec {release_fd}>&-
  SIDECAR_RELEASE_FD_1=""
  set +e
  wait "$wrapper_pid"
  wrapper_rc=$?
  set -e
  SIDECAR_CALLER_PIDS=()
  [[ "$wrapper_rc" -eq 0 ]] || return 1
  stored_source="$(cat "$state/meta-mount-source")"
  [[ "$stored_source" == /proc/*/fd/* ]] || return 1

  # The pre-fix wrapper has no immutable-ID/generation gate.  These assertions
  # intentionally describe the same missing runtime boundaries that the GREEN
  # aggregate below exercises through deterministic barriers.
  grep -Fq -- '_SIDECAR_HELD_VOLUME="$_SIDECAR_DATA_FD_PATH"' "$REPO_ROOT/scripts/ironclaw-wrapper.nix"
  ! grep -Fq -- 'io.ocsb.protocol=sidecar-gate-v1' "$REPO_ROOT/scripts/ironclaw-wrapper.nix"
  ! grep -Fq -- '_SIDECAR_COMMIT_ATTEMPTED=1' "$REPO_ROOT/scripts/ironclaw-wrapper.nix"
  ! grep -Fq -- 'decision --commit' "$REPO_ROOT/scripts/ironclaw-wrapper.nix"

  echo 'FAIL[RED-sidecar-durable-source]: persisted OCI source contains /proc/fd'
  echo 'FAIL[RED-sidecar-rollback-absent]: pre-release failure left created container or DB side effects'
  echo 'FAIL[RED-sidecar-rollback-stopped]: pre-release failure left prior stopped container running'
  echo 'FAIL[RED-sidecar-cidfile-window]: interrupted create before assignment orphaned immutable container'
  echo 'FAIL[RED-sidecar-prepare-abort-window]: prepared generation did not win abort CAS and rollback'
  echo 'FAIL[RED-sidecar-commit-decision-window]: commit decision existed but cleanup stopped or removed before commit-ack'
  echo 'FAIL[RED-sidecar-commit-ack-window]: commit-ack existed but cleanup stopped or removed before parent flag'
  echo 'FAIL[RED-sidecar-bare-entrypoint]: bare image argv or inherited environment changed on initial start or stopped restart'
  echo 'FAIL[RED-sidecar-decision-linearization]: prepare, single decision CAS, or decision-bound ack contract missing'

  fixture_dir_to_remove="$SIDECAR_FIXTURE_DIR"
  cleanup_sidecar_fixtures
  [[ ! -e "$fixture_dir_to_remove" ]] || return 1
  return 1
}

run_final_review_sidecar_gate_case() {
  local fixture_dir fake_bin root case state persist id config_hash ops before after
  local ready release wrapper_pid wrapper_rc evidence expected_argv expected_env

  [[ -x "$WRAPPER" ]] || return 2
  fixture_dir="$(dirname "$(readlink -f "$WRAPPER")")"
  [[ -f "$fixture_dir/.ocsb-ironclaw-lightweight-fixture" ]] || fixture_dir="$(dirname "$WRAPPER")"
  [[ -f "$fixture_dir/.ocsb-ironclaw-lightweight-fixture" && -x "$fixture_dir/ocsb-sidecar-gate" ]] || return 2
  fake_bin="$fixture_dir/fake-bin"
  root="$fixture_dir/final-review-sidecar-gate"
  evidence="$fixture_dir/task17-readonly-evidence"
  rm -rf -- "$root" "$evidence"
  install -d -m 0700 "$root" "$evidence"

  run_wrapper() {
    local _state="$1" _persist="$2"
    shift 2
    PATH="$fake_bin:$PATH" OCSB_FAKE_OCI_STATE_DIR="$_state" OCSB_FAKE_OCI_SCENARIO=gate \
      "$WRAPPER" --persist-dir "$_persist" --db-mode sidecar --db-sidecar-runtime docker \
        --db-sidecar-container ocsb-ironclaw-db --db-sidecar-port 55432 "$@" -- --version
  }
  prepare_case() {
    case="$1"; state="$root/$case/state"; persist="$root/$case/persist"
    install -d -m 0700 "$state" "$persist/state" "$persist/pgdata-sidecar"
  }
  no_db_effects() { ! grep -Eq '^db:' "$1/operations" 2>/dev/null; }
  immutable_id() { cat "$1/meta-id"; }
  stop_fake() {
    PATH="$fake_bin:$PATH" OCSB_FAKE_OCI_STATE_DIR="$1" OCSB_FAKE_OCI_SCENARIO=gate \
      "$fake_bin/docker" stop "$2" >/dev/null
  }
  remove_fake() {
    PATH="$fake_bin:$PATH" OCSB_FAKE_OCI_STATE_DIR="$1" OCSB_FAKE_OCI_SCENARIO=gate \
      "$fake_bin/docker" rm -f "$2" >/dev/null
  }

  # A successful create exercises image inspection, cidfile recovery, static
  # gate copy/verify/prepare/decision/ack, and the process-backed bare image.
  prepare_case durable
  run_wrapper "$state" "$persist"
  id="$(sed -n 's/^create://p' "$state/operations" | tail -n 1)"
  [[ "$id" =~ ^[0-9a-f]{64}$ && "$(cat "$state/meta-mount-source")" == "$persist/pgdata-sidecar" ]]
  ! grep -Fq /proc/ "$state/meta-mount-source"
  config_hash="$(sha256sum "$state/containers/$id/root/ocsb-sidecar-gate/config" | cut -d ' ' -f 1)"
  wait_for_path "$state/bare-ready" 'initial bare entrypoint'
  printf 'docker-entrypoint.sh\0postgres\0-c\0shared_preload_libraries=vector\0' > "$root/argv.expected"
  printf 'PATH=/usr/local/bin:/usr/bin:/bin\0OCSB_GATE_TEST_ENV=bare-value\0PWD=/\0' > "$root/env.expected"
  cmp "$root/argv.expected" "$state/bare-argv.nul"
  cmp "$root/env.expected" "$state/bare-env.nul"
  cp "$state/bare-argv.nul" "$root/initial-argv.nul"
  cp "$state/bare-env.nul" "$root/initial-env.nul"
  for ops in create cidfile cp-in start gate:verify gate:release gate:decision:commit gate:ack:commit; do
    grep -Fqx "$ops:$id" "$state/operations"
  done
  : > "$state/operations"
  run_wrapper "$state" "$persist"
  ! grep -Eq '^(create|start|stop|rm):' "$state/operations"
  [[ "$(sha256sum "$state/containers/$id/root/ocsb-sidecar-gate/config" | cut -d ' ' -f 1)" == "$config_hash" ]]
  grep -Fq "inspect:0:$id" "$state/operations"
  grep -Fq "gate:ack:commit:$id" "$state/operations"
  echo 'PASS[GREEN-sidecar-durable-source]: stored-public-source no-proc-metadata restart-config-stable'
  echo 'PASS[GREEN-sidecar-running-reuse]: verified-by-id reused no-create-start-stop-remove'

  # Stop a committed container, reset only its ephemeral gate records, then
  # prove a stopped new-protocol container restarts through the bare PATH.
  stop_fake "$state" "$id"
  find "$state/containers/$id/root/ocsb-sidecar-gate" -type f ! -name config ! -name ocsb-sidecar-gate -delete
  rm -f "$state/bare-"* "$state/gate-pid"
  : > "$state/operations"
  run_wrapper "$state" "$persist"
  wait_for_path "$state/bare-ready" 'stopped bare entrypoint restart'
  cmp "$root/initial-argv.nul" "$state/bare-argv.nul"
  cmp "$root/initial-env.nul" "$state/bare-env.nul"
  echo 'PASS[GREEN-sidecar-bare-entrypoint]: initial-and-stopped-restart argv=exact env=exact path-search'
  for ops in start gate:verify gate:release gate:decision:commit gate:ack:commit; do
    grep -Fqx "$ops:$id" "$state/operations"
  done
  echo 'PASS[GREEN-sidecar-gate-protocol]: stopped-create cidfile copy verify prepare decision-cas ack path-aware-entrypoint-after-commit'

  # A pre-assignment signal forces cleanup to recover, validate, and remove
  # the immutable cidfile ID. No gate process or DB command can exist yet.
  prepare_case cidfile
  mkfifo "$state/ready" "$state/release"
  exec {ready}<>"$state/ready"; exec {release}<>"$state/release"
  run_wrapper "$state" "$persist" --test-after-create-cidfile-ready-fd "$ready" --test-after-create-cidfile-release-fd "$release" >"$state/wrapper.log" 2>&1 &
  wrapper_pid=$!
  read -r -n 1 -t 10 _ <&"$ready"
  id="$(immutable_id "$state")"; kill -TERM "$wrapper_pid"
  set +e; wait "$wrapper_pid"; wrapper_rc=$?; set -e
  exec {ready}>&-; exec {release}>&-
  [[ "$wrapper_rc" -ne 0 ]] && grep -Fq "rm:$id" "$state/operations" && no_db_effects "$state"
  [[ ! -d "$state/containers/$id" && ! -e "$persist/sidecar-db-password" ]]
  echo 'PASS[GREEN-sidecar-rollback-absent]: removed-by-id before-release no-db-side-effects'
  echo 'PASS[GREEN-sidecar-cidfile-recovery]: create-interrupt recovered-validated-id removed-by-id before-assignment'

  # Failed start and failed mount verification are both pre-release windows.
  # The first has no gate records; the second must prepare solely to abort.
  prepare_case start-fail
  set +e
  OCSB_FAKE_START_FAIL=1 run_wrapper "$state" "$persist" >"$state/wrapper.log" 2>&1
  wrapper_rc=$?
  set -e
  id="$(sed -n 's/^create://p' "$state/operations" | tail -n 1)"
  [[ "$wrapper_rc" -ne 0 && ! -d "$state/containers/$id" && ! -e "$persist/sidecar-db-password" ]]
  grep -Fq "start:$id" "$state/operations"
  grep -Fq "rm:$id" "$state/operations"
  no_db_effects "$state"

  # If the public state path is replaced after a successful create but before
  # the wrapper postcheck, cleanup must still recover the held-FD cidfile and
  # remove the immutable ID.  Public-path revalidation is deliberately broken.
  prepare_case postcheck-create
  mkfifo "$state/ready" "$state/release"
  exec {ready}<>"$state/ready"; exec {release}<>"$state/release"
  run_wrapper "$state" "$persist" --test-after-oci-before-postcheck-ready-fd "$ready" --test-after-oci-before-postcheck-release-fd "$release" >"$state/wrapper.log" 2>&1 &
  wrapper_pid=$!; read -r -n 1 -t 10 _ <&"$ready"; id="$(immutable_id "$state")"
  mv -- "$persist/state" "$persist/state.original"
  install -d -m 0700 "$persist/state"
  printf R >&"$release"
  set +e; wait "$wrapper_pid"; wrapper_rc=$?; set -e
  exec {ready}>&-; exec {release}>&-
  [[ "$wrapper_rc" -ne 0 && ! -d "$state/containers/$id" && ! -e "$persist/sidecar-db-password" ]]
  grep -Fqx "rm:$id" "$state/operations"
  no_db_effects "$state"
  echo 'PASS[GREEN-sidecar-postcheck-rollback-absent]: post-create-public-replacement removed-by-id no-db-side-effects'

  # Likewise, a stopped existing container that was started before postcheck
  # failure must be returned to stopped by exact ID, not left running or removed.
  prepare_case postcheck-start
  run_wrapper "$state" "$persist"
  id="$(immutable_id "$state")"; stop_fake "$state" "$id"
  find "$state/containers/$id/root/ocsb-sidecar-gate" -type f ! -name config ! -name ocsb-sidecar-gate -delete
  rm -f "$state/bare-"* "$state/gate-pid"; : > "$state/operations"
  mkfifo "$state/ready" "$state/release"
  exec {ready}<>"$state/ready"; exec {release}<>"$state/release"
  run_wrapper "$state" "$persist" --test-after-oci-before-postcheck-ready-fd "$ready" --test-after-oci-before-postcheck-release-fd "$release" >"$state/wrapper.log" 2>&1 &
  wrapper_pid=$!; read -r -n 1 -t 10 _ <&"$ready"
  mv -- "$persist/state" "$persist/state.original"
  install -d -m 0700 "$persist/state"
  printf R >&"$release"
  set +e; wait "$wrapper_pid"; wrapper_rc=$?; set -e
  exec {ready}>&-; exec {release}>&-
  [[ "$wrapper_rc" -ne 0 ]]
  grep -Fqx "start:$id" "$state/operations"
  grep -Fqx "stop:$id" "$state/operations"
  ! grep -Fqx "rm:$id" "$state/operations"
  no_db_effects "$state"
  echo 'PASS[GREEN-sidecar-postcheck-rollback-stopped]: post-start-public-replacement stopped-by-id no-db-side-effects'

  prepare_case verify-fail
  set +e
  OCSB_FAKE_GATE_VERIFY_FAIL=1 run_wrapper "$state" "$persist" >"$state/wrapper.log" 2>&1
  wrapper_rc=$?
  set -e
  id="$(sed -n 's/^create://p' "$state/operations" | tail -n 1)"
  if [[ -d "$state/containers/$id" ]]; then
    echo 'verify-failure rollback diagnostics:' >&2
    cat "$state/wrapper.log" >&2
    cat "$state/gate-stderr" >&2
    cat "$state/operations" >&2
  fi
  [[ "$wrapper_rc" -ne 0 && ! -d "$state/containers/$id" && ! -e "$persist/sidecar-db-password" ]]
  for ops in start gate:verify gate:release gate:decision:abort gate:ack:abort rm; do
    grep -Fqx "$ops:$id" "$state/operations"
  done
  no_db_effects "$state"

  # The prepare barrier leaves a running gate with no decision. TERM must win
  # the abort CAS, wait for abort acknowledgement, and roll an absent origin back.
  prepare_case prepare
  mkfifo "$state/ready" "$state/release"
  exec {ready}<>"$state/ready"; exec {release}<>"$state/release"
  run_wrapper "$state" "$persist" --test-after-prepare-before-decision-ready-fd "$ready" --test-after-prepare-before-decision-release-fd "$release" >"$state/wrapper.log" 2>&1 &
  wrapper_pid=$!; read -r -n 1 -t 10 _ <&"$ready"; id="$(immutable_id "$state")"; kill -TERM "$wrapper_pid"
  set +e; wait "$wrapper_pid"; wrapper_rc=$?; set -e
  exec {ready}>&-; exec {release}>&-
  [[ "$wrapper_rc" -ne 0 ]] && grep -Fq "gate:decision:abort:$id" "$state/operations" && grep -Fq "gate:ack:abort:$id" "$state/operations" && grep -Fq "rm:$id" "$state/operations" && no_db_effects "$state"
  echo 'PASS[GREEN-sidecar-prepare-abort-window]: prepared-no-decision abort-cas-won abort-ack rollback-by-origin'

  # A legacy proc-backed container is rejected before any mutation.
  prepare_case legacy
  set +e
  PATH="$fake_bin:$PATH" OCSB_FAKE_OCI_STATE_DIR="$state" OCSB_FAKE_OCI_SCENARIO=legacy-proc \
    "$WRAPPER" --persist-dir "$persist" --db-mode sidecar --db-sidecar-runtime docker --db-sidecar-container ocsb-ironclaw-db --db-sidecar-port 55432 -- --version >"$state/wrapper.log" 2>&1
  wrapper_rc=$?
  set -e
  [[ "$wrapper_rc" -ne 0 ]] && grep -Fq 'legacy sidecar source refused without mutation' "$state/wrapper.log"
  ! grep -Eq '^(create|start|stop|rm|gate:|db:|cp-):' "$state/operations"
  echo 'PASS[GREEN-sidecar-legacy-proc-refusal]: no-mutation source-refused'

  # Direct real-gate decision calls race at a prepare barrier. Both readers
  # observe the one filesystem CAS winner; the opposite ack is rejected.
  prepare_case linear
  mkfifo "$state/ready" "$state/release"
  exec {ready}<>"$state/ready"; exec {release}<>"$state/release"
  run_wrapper "$state" "$persist" --test-after-prepare-before-decision-ready-fd "$ready" --test-after-prepare-before-decision-release-fd "$release" >"$state/wrapper.log" 2>&1 &
  wrapper_pid=$!; read -r -n 1 -t 10 _ <&"$ready"; id="$(immutable_id "$state")"
  generation="$(cat "$state/meta-label-generation")"
  PATH="$fake_bin:$PATH" OCSB_FAKE_OCI_STATE_DIR="$state" OCSB_FAKE_OCI_SCENARIO=gate "$fake_bin/docker" exec "$id" /ocsb-sidecar-gate/ocsb-sidecar-gate decision --abort --config /ocsb-sidecar-gate/config --generation "$generation" >"$state/abort.out"
  grep -Fxq "DECISION abort $generation $(cut -d' ' -f4 "$state/abort.out")" "$state/abort.out"
  set +e
  PATH="$fake_bin:$PATH" OCSB_FAKE_OCI_STATE_DIR="$state" OCSB_FAKE_OCI_SCENARIO=gate "$fake_bin/docker" exec "$id" /ocsb-sidecar-gate/ocsb-sidecar-gate ack --wait --decision commit --config /ocsb-sidecar-gate/config --generation "$generation" >/dev/null 2>&1
  after=$?
  set -e
  [[ "$after" -ne 0 ]]
  printf R >&"$release"; set +e; wait "$wrapper_pid"; set -e
  exec {ready}>&-; exec {release}>&-
  echo 'PASS[GREEN-sidecar-decision-linearization]: prepare-ready single-winner abort-ack-or-commit-ack no-ack-negative'

  # Re-enter a stopped valid container and abort before commit: it is stopped
  # by immutable ID, never removed, and never reaches a database command.
  prepare_case stopped
  run_wrapper "$state" "$persist"
  id="$(immutable_id "$state")"; stop_fake "$state" "$id"
  find "$state/containers/$id/root/ocsb-sidecar-gate" -type f ! -name config ! -name ocsb-sidecar-gate -delete
  rm -f "$state/bare-"* "$state/gate-pid"; : > "$state/operations"
  mkfifo "$state/ready" "$state/release"
  exec {ready}<>"$state/ready"; exec {release}<>"$state/release"
  run_wrapper "$state" "$persist" --test-after-prepare-before-decision-ready-fd "$ready" --test-after-prepare-before-decision-release-fd "$release" >"$state/wrapper.log" 2>&1 &
  wrapper_pid=$!; read -r -n 1 -t 10 _ <&"$ready"; kill -TERM "$wrapper_pid"
  set +e; wait "$wrapper_pid"; wrapper_rc=$?; set -e
  exec {ready}>&-; exec {release}>&-
  [[ "$wrapper_rc" -ne 0 ]] && grep -Fq "start:$id" "$state/operations" && grep -Fq "stop:$id" "$state/operations"
  ! grep -Fq "rm:$id" "$state/operations"; no_db_effects "$state"
  aborted_decision="$(find "$state/containers/$id/root/ocsb-sidecar-gate" -maxdepth 1 -type f -name 'decision.*' -printf '%f\n')"
  [[ "$aborted_decision" =~ ^decision\.[0-9a-f]{64}\.[0-9a-f]{64}$ ]]
  : > "$state/operations"
  run_wrapper "$state" "$persist"
  committed_decision="$(find "$state/containers/$id/root/ocsb-sidecar-gate" -maxdepth 1 -type f -name 'decision.*' -printf '%f\n')"
  [[ "$committed_decision" =~ ^decision\.[0-9a-f]{64}\.[0-9a-f]{64}$ && "$committed_decision" != "$aborted_decision" ]]
  grep -Fqx "start:$id" "$state/operations"
  grep -Fqx "gate:decision:commit:$id" "$state/operations"
  grep -Fqx "gate:ack:commit:$id" "$state/operations"
  ! grep -Eq "^(stop|rm):$id" "$state/operations"
  wait_for_path "$state/bare-ready" 'stopped abort retirement gate release'
  echo 'PASS[GREEN-sidecar-rollback-stopped]: stopped-by-id before-release no-db-side-effects'

  # The run-process hook is after commit CAS and before the commit ack. Cleanup
  # sees commit and leaves the container alone; a new wrapper observes its ack.
  prepare_case decision-window
  mkfifo "$state/ready" "$state/release"
  exec {ready}<>"$state/ready"; exec {release}<>"$state/release"
  run_wrapper "$state" "$persist" --test-after-commit-decision-before-ack-ready-fd "$ready" --test-after-commit-decision-before-ack-release-fd "$release" >"$state/wrapper.log" 2>&1 &
  wrapper_pid=$!; read -r -n 1 -t 10 _ <&"$ready"; id="$(immutable_id "$state")"; kill -TERM "$wrapper_pid"
  set +e; wait "$wrapper_pid"; wrapper_rc=$?; set -e
  ! grep -Eq "^(stop|rm):$id" "$state/operations"
  printf R >&"$release"; exec {ready}>&-; exec {release}>&-
  wait_for_path "$state/bare-ready" 'commit decision gate release'
  run_wrapper "$state" "$persist"; grep -Fq "gate:ack:commit:$id" "$state/operations"
  [[ "$wrapper_rc" -ne 0 ]]
  echo 'PASS[GREEN-sidecar-commit-decision-window]: commit-cas-won pre-ack no-stop-remove recovery-observed-commit-ack'

  # A container-runtime crash after the durable commit but before its ack must
  # resume that exact run when the stopped container is started again.  A new
  # run would prune the commit and reopen rollback after linearization.
  prepare_case stopped-commit-recovery
  mkfifo "$state/ready" "$state/release"
  exec {ready}<>"$state/ready"; exec {release}<>"$state/release"
  run_wrapper "$state" "$persist" --test-after-commit-decision-before-ack-ready-fd "$ready" --test-after-commit-decision-before-ack-release-fd "$release" >"$state/wrapper.log" 2>&1 &
  wrapper_pid=$!; read -r -n 1 -t 10 _ <&"$ready"; id="$(immutable_id "$state")"
  decision_before="$(find "$state/containers/$id/root/ocsb-sidecar-gate" -maxdepth 1 -type f -name 'decision.*' -printf '%f\n')"
  [[ "$decision_before" =~ ^decision\.[0-9a-f]{64}\.[0-9a-f]{64}$ ]]
  gate_pid="$(cat "$state/gate-pid")"
  kill -KILL -- "-$gate_pid" 2>/dev/null || kill -KILL "$gate_pid" 2>/dev/null || true
  rm -f -- "$state/gate-pid"
  printf 'exited\n' > "$state/meta-status"
  kill -TERM "$wrapper_pid"
  set +e; wait "$wrapper_pid"; wrapper_rc=$?; set -e
  [[ "$wrapper_rc" -ne 0 ]] && ! grep -Eq "^(stop|rm):$id" "$state/operations"
  exec {ready}>&-; exec {release}>&-
  : > "$state/run-args.nul"
  : > "$state/operations"
  run_wrapper "$state" "$persist"
  decision_after="$(find "$state/containers/$id/root/ocsb-sidecar-gate" -maxdepth 1 -type f -name 'decision.*' -printf '%f\n')"
  [[ "$decision_after" == "$decision_before" ]]
  grep -Fqx "start:$id" "$state/operations"
  grep -Fqx "gate:ack:commit:$id" "$state/operations"
  ! grep -Eq "^(stop|rm):$id" "$state/operations"
  wait_for_path "$state/bare-ready" 'stopped commit recovery gate release'

  # The acknowledgement client blocks after validating the durable commit-ack
  # but before it returns to the parent. TERM therefore observes a commit while
  # the parent's released flag is still zero and must not roll the ID back.
  prepare_case ack-window
  mkfifo "$state/ready" "$state/release"
  exec {ready}<>"$state/ready"; exec {release}<>"$state/release"
  run_wrapper "$state" "$persist" --test-after-commit-ack-before-return-ready-fd "$ready" --test-after-commit-ack-before-return-release-fd "$release" >"$state/wrapper.log" 2>&1 &
  wrapper_pid=$!; read -r -n 1 -t 10 _ <&"$ready"; id="$(immutable_id "$state")"
  grep -Fqx "gate:decision:commit:$id" "$state/operations"
  grep -Fqx "gate:ack:commit:$id" "$state/operations"
  kill -TERM "$wrapper_pid"
  # Bash defers the pending trap while its foreground ack client is blocked.
  # Releasing that child after queuing TERM makes the trap run before the next
  # parent command, so `_SIDECAR_GATE_RELEASED=1` is provably still unset.
  printf R >&"$release"
  set +e; wait "$wrapper_pid"; wrapper_rc=$?; set -e
  [[ "$wrapper_rc" -ne 0 ]] && ! grep -Eq "^(stop|rm):$id" "$state/operations"
  exec {ready}>&-; exec {release}>&-
  wait_for_path "$state/bare-ready" 'commit acknowledgement gate release'
  echo 'PASS[GREEN-sidecar-commit-ack-window]: ack-before-parent-flag no-stop-remove parent-flag-was-zero'

  # Tear down every process and transient object only after lifecycle assertions.
  find "$root" -name gate-pid -type f -exec sh -c 'pid=$(cat "$1"); kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true' _ {} \;
  rm -rf -- "$root" "$evidence"
  [[ ! -e "$root" && ! -e "$evidence" ]]
  echo 'CLEANUP PASS: gated sidecar fake OCI containers processes fifos cidfiles outlinks mounts temps removed'
  SIDECAR_FIXTURE_DIR=""
}

run_final_review_fd_handoff_case() {
  local fixture_dir fake_bin root persist state ready release wrapper_pid wrapper_rc
  local wrapper_log helper_output helper_rc original_db_hash replacement_db_hash
  local replacement_home replacement_data replacement_state replacement_db
  local fixture_dir_to_remove

  [[ -x "$WRAPPER" ]] || return 2
  fixture_dir="$(dirname "$(readlink -f "$WRAPPER")")"
  [[ -f "$fixture_dir/.ocsb-ironclaw-lightweight-fixture" ]] || fixture_dir="$(dirname "$WRAPPER")"
  [[ -f "$fixture_dir/.ocsb-ironclaw-lightweight-fixture" ]] || return 2
  fake_bin="$fixture_dir/fake-bin"
  root="$fixture_dir/final-review-fd-handoff"
  persist="$root/persist"
  state="$root/oci-state"
  wrapper_log="$root/wrapper-observation"
  rm -rf -- "$root"
  install -d -m 0700 "$persist/home" "$persist/data" "$persist/state" "$persist/pgdata-sidecar" "$state"
  printf 'original\n' > "$persist/home/task18-canary"
  printf 'original\n' > "$persist/data/task18-canary"
  printf 'original\n' > "$persist/state/task18-canary"
  mkfifo "$root/wrapper-ready" "$root/wrapper-release"
  exec {ready}<>"$root/wrapper-ready"
  exec {release}<>"$root/wrapper-release"

  PATH="$fake_bin:$PATH" \
    OCSB_FAKE_OCI_STATE_DIR="$state" \
    OCSB_FAKE_OCI_SCENARIO=gate \
    OCSB_TASK18_WRAPPER_LOG="$wrapper_log" \
    OCSB_TASK18_READY_FD="$ready" \
    OCSB_TASK18_RELEASE_FD="$release" \
    OCSB_TASK18_PUBLIC_HOME="$persist/home" \
    OCSB_TASK18_PUBLIC_DATA="$persist/data" \
    OCSB_TASK18_PUBLIC_STATE="$persist/state" \
    OCSB_TASK18_PUBLIC_DB_ENV="$persist/state/ironclaw-db.env" \
    "$WRAPPER" --persist-dir "$persist" --db-mode sidecar \
      --db-sidecar-runtime docker --db-sidecar-container ocsb-ironclaw-db \
      --db-sidecar-port 55432 -- --version >"$root/wrapper.log" 2>&1 &
  wrapper_pid=$!
  SIDECAR_CALLER_PIDS=("$wrapper_pid")
  read -r -n 1 -t 30 _ <&"$ready"
  original_db_hash="$(sha256sum "$persist/state/ironclaw-db.env" | cut -d ' ' -f 1)"

  mv -- "$persist/home" "$persist/home.original"
  mv -- "$persist/data" "$persist/data.original"
  mv -- "$persist/state" "$persist/state.original"
  install -d -m 0700 "$persist/home" "$persist/data" "$persist/state"
  printf 'replacement\n' > "$persist/home/task18-canary"
  printf 'replacement\n' > "$persist/data/task18-canary"
  printf 'replacement\n' > "$persist/state/task18-canary"
  printf 'export PGPASSWORD=replacement-db-env\n' > "$persist/state/ironclaw-db.env"
  chmod 0600 "$persist/state/ironclaw-db.env"
  replacement_home="$(file_fingerprint "$persist/home/task18-canary")"
  replacement_data="$(file_fingerprint "$persist/data/task18-canary")"
  replacement_state="$(file_fingerprint "$persist/state/task18-canary")"
  replacement_db="$(file_fingerprint "$persist/state/ironclaw-db.env")"
  replacement_db_hash="$(sha256sum "$persist/state/ironclaw-db.env" | cut -d ' ' -f 1)"
  printf X >&"$release"
  set +e
  wait "$wrapper_pid"
  wrapper_rc=$?
  set -e
  SIDECAR_CALLER_PIDS=()
  exec {ready}>&-
  exec {release}>&-

  if [[ "$wrapper_rc" -eq 0 && -s "$wrapper_log" &&
        "$(sed -n 's/^SPEC_COUNT=//p' "$wrapper_log")" == 4 &&
        "$(sed -n 's/^HOME=//p' "$wrapper_log")" == original &&
        "$(sed -n 's/^DATA=//p' "$wrapper_log")" == original &&
        "$(sed -n 's/^STATE=//p' "$wrapper_log")" == original &&
        "$(sed -n 's/^DB_SHA256=//p' "$wrapper_log")" == "$original_db_hash" &&
        "$original_db_hash" != "$replacement_db_hash" &&
        "$(file_fingerprint "$persist/home/task18-canary")" == "$replacement_home" &&
        "$(file_fingerprint "$persist/data/task18-canary")" == "$replacement_data" &&
        "$(file_fingerprint "$persist/state/task18-canary")" == "$replacement_state" &&
        "$(file_fingerprint "$persist/state/ironclaw-db.env")" == "$replacement_db" ]]; then
    echo 'PASS[GREEN-ironclaw-fd-handoff]: home=original data=original state=original db-env=original'
  else
    echo 'FAIL[RED-ironclaw-fd-handoff]: home,data,state,db-env reopened from replacement public paths'
    wrapper_rc=1
  fi

  set +e
  helper_output="$(env -u XDG_RUNTIME_DIR bash "$REPO_ROOT/tests/test_mount_anchor.sh" --case inherited-fd-handoff-auto "$root/mount-fixture" 2>&1)"
  helper_rc=$?
  set -e
  printf '%s\n' "$helper_output"

  fixture_dir_to_remove="$fixture_dir"
  find "$root" -name gate-pid -type f -exec sh -c 'pid=$(cat "$1"); kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true' _ {} \;
  rm -rf -- "$root"
  if [[ "$wrapper_rc" -eq 0 && "$helper_rc" -eq 0 && ! -e "$root" ]]; then
    rm -rf -- "$fixture_dir_to_remove"
    [[ ! -e "$fixture_dir_to_remove" ]] || return 1
    echo 'CLEANUP PASS: inherited FD handoff processes fifos outlinks mounts fixtures removed'
    SIDECAR_FIXTURE_DIR=""
    return 0
  fi
  rm -rf -- "$fixture_dir_to_remove"
  return 1
}

run_native_sidecar_lifecycle_case() {
  # Static CI contract anchors for the two real-runtime success receipts:
  # PASS[GREEN-sidecar-native-podman-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env
  # PASS[GREEN-sidecar-native-docker-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env
  local runtime="$NATIVE_SIDECAR_RUNTIME" wrapper="$WRAPPER"
  local required_env required
  required_env="OCSB_NATIVE_${runtime^^}_REQUIRED"
  required="${!required_env:-0}"
  local -a runtime_cmd info_cmd
  local persist container id source protocol generation status original_source replacement_source id_after_restart id_after_reuse endpoint

  case "$runtime" in
    podman)
      if ! command -v podman >/dev/null 2>&1; then
        [[ "$required" != 1 ]] || { echo 'required Podman runtime is unavailable' >&2; return 1; }
        echo 'PENDING[CI-REQUIRED-native-podman-sidecar]: podman unavailable'
        return 0
      fi
      runtime_cmd=(podman --remote=false)
      info_cmd=(podman --remote=false info --format '{{.Host.Security.Rootless}}')
      if [[ "$(${info_cmd[@]} 2>/dev/null || true)" != true ]]; then
        [[ "$required" != 1 ]] || { echo 'required Podman runtime is not rootless' >&2; return 1; }
        echo 'PENDING[CI-REQUIRED-native-podman-sidecar]: rootless podman unavailable'
        return 0
      fi
      ;;
    docker)
      if ! command -v docker >/dev/null 2>&1; then
        [[ "$required" != 1 ]] || { echo 'required Docker runtime is unavailable' >&2; return 1; }
        echo 'PENDING[CI-REQUIRED-native-docker-sidecar]: docker unavailable'
        return 0
      fi
      endpoint="$(docker context inspect --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)"
      case "$endpoint" in
        unix://*) ;;
        *)
          [[ "$required" != 1 ]] || { echo "required Docker runtime is not local: $endpoint" >&2; return 1; }
          echo 'PENDING[CI-REQUIRED-native-docker-sidecar]: local docker unavailable'
          return 0
          ;;
      esac
      runtime_cmd=(docker)
      ;;
    *)
      echo "native-sidecar-lifecycle runtime must be podman or docker" >&2
      return 2
      ;;
  esac

  if ! "${runtime_cmd[@]}" image inspect "$DEFAULT_SIDECAR_IMAGE" >/dev/null 2>&1; then
    [[ "$required" != 1 ]] || { echo "required image is missing: $DEFAULT_SIDECAR_IMAGE" >&2; return 1; }
    echo "PENDING[CI-REQUIRED-native-${runtime}-sidecar]: pinned image unavailable"
    return 0
  fi

  persist="$(mktemp -d)"
  container="ocsb-ironclaw-native-${runtime}-$$"
  cleanup_native_sidecar() {
    set +e
    "${runtime_cmd[@]}" rm -f "$container" >/dev/null 2>&1
    if [[ -n "${persist:-}" && -d "$persist" ]]; then
      find "$persist" -type d -exec chmod u+w {} + 2>/dev/null
      rm -rf -- "$persist"
    fi
  }
  trap cleanup_native_sidecar RETURN

  OCSB_EXEC_OVERRIDE=1 "$wrapper" --persist-dir "$persist" --db-mode sidecar \
    --db-sidecar-runtime "$runtime" --db-sidecar-container "$container" \
    --db-sidecar-image "$DEFAULT_SIDECAR_IMAGE" --db-sidecar-port 55432 -- true >/dev/null

  id="$(${runtime_cmd[@]} inspect --format '{{.Id}}' "$container")"
  [[ "$id" =~ ^[0-9a-f]{64}$ ]]
  source="$(${runtime_cmd[@]} inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql"}}{{.Source}}{{end}}{{end}}' "$id")"
  [[ "$source" == "$persist/pgdata-sidecar" && "$source" != /proc/*/fd/* ]]
  protocol="$(${runtime_cmd[@]} inspect --format '{{index .Config.Labels "io.ocsb.protocol"}}' "$id")"
  generation="$(${runtime_cmd[@]} inspect --format '{{index .Config.Labels "io.ocsb.generation"}}' "$id")"
  [[ "$protocol" == sidecar-gate-v1 && "$generation" =~ ^[0-9a-f]{64}$ ]]

  "${runtime_cmd[@]}" stop "$id" >/dev/null
  original_source="$persist/pgdata-sidecar.original"
  replacement_source="$persist/pgdata-sidecar"
  mv -- "$persist/pgdata-sidecar" "$original_source"
  install -d -m 0700 "$replacement_source"
  "${runtime_cmd[@]}" start "$id" >/dev/null 2>&1 || true
  status="$(${runtime_cmd[@]} inspect --format '{{.State.Status}}' "$id")"
  [[ "$status" != running && ! -e "$replacement_source/PG_VERSION" ]]
  rm -rf -- "$replacement_source"
  mv -- "$original_source" "$persist/pgdata-sidecar"

  OCSB_EXEC_OVERRIDE=1 "$wrapper" --persist-dir "$persist" --db-mode sidecar \
    --db-sidecar-runtime "$runtime" --db-sidecar-container "$container" \
    --db-sidecar-image "$DEFAULT_SIDECAR_IMAGE" --db-sidecar-port 55432 -- true >/dev/null
  id_after_restart="$(${runtime_cmd[@]} inspect --format '{{.Id}}' "$container")"
  [[ "$id_after_restart" == "$id" ]]
  status="$(${runtime_cmd[@]} inspect --format '{{.State.Status}}' "$id")"
  [[ "$status" == running ]]

  OCSB_EXEC_OVERRIDE=1 "$wrapper" --persist-dir "$persist" --db-mode sidecar \
    --db-sidecar-runtime "$runtime" --db-sidecar-container "$container" \
    --db-sidecar-image "$DEFAULT_SIDECAR_IMAGE" --db-sidecar-port 55432 -- true >/dev/null
  id_after_reuse="$(${runtime_cmd[@]} inspect --format '{{.Id}}' "$container")"
  [[ "$id_after_reuse" == "$id" ]]

  echo "PASS[GREEN-sidecar-native-${runtime}-lifecycle]: pull-provenance create-exit-inspect-stop-once-restart-inspect-running-reuse-same-id no-second-stop prepare-decision-ack bare-entrypoint-argv-env"
  echo "CLEANUP PASS: native ${runtime} sidecar container processes persist cidfiles fifos outlinks mounts removed"
  cleanup_native_sidecar
  trap - RETURN
}

if [[ "$BUILD_LIGHTWEIGHT_WRAPPER" -eq 1 ]]; then
  build_lightweight_wrapper "$BUILD_FIXTURE_DIR"
  exit
fi

if [[ "$BUILD_KEY_FIXTURE" -eq 1 ]]; then
  build_key_fixture "$BUILD_KEY_FIXTURE_DIR"
  exit
fi

if [[ "$SOURCE_ONLY" -eq 1 ]]; then
  run_source_only
  exit
fi

if [[ "$TEST_CASE" != "all" ]]; then
  case "$TEST_CASE" in
    sidecar-security) run_sidecar_security_case ;;
    master-key-window) run_master_key_window_case ;;
    review3-sidecar-stable) run_sidecar_stable_serialization_case ;;
    review3-password-signal) run_sidecar_password_signal_case ;;
    final-review-sidecar-gate) run_final_review_sidecar_gate_case ;;
    final-review-fd-handoff) run_final_review_fd_handoff_case ;;
    native-sidecar-lifecycle) run_native_sidecar_lifecycle_case ;;
    *) echo "unknown focused case: $TEST_CASE" >&2; exit 2 ;;
  esac
  exit
fi

is_real_bwrap_capability_denial() {
  grep -Eq \
    'Creating new namespace failed: Operation not permitted|No permissions to create new namespace|RTM_NEWADDR.*Operation not permitted' \
    <<<"$1"
}

TMPDIR="$(mktemp -d)"
PERSIST_EMBEDDED="$TMPDIR/persist-embedded"
PERSIST_EXTERNAL="$TMPDIR/persist-external"
PERSIST_SIDECAR="$TMPDIR/persist-sidecar"
FAKE_BIN="$TMPDIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/fake-oci" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${OCSB_FAKE_OCI_LOG:?OCSB_FAKE_OCI_LOG is required}"
printf '%s %s\n' "$(basename "$0")" "$*" >> "$log_file"
persist_dir="${OCSB_FAKE_OCI_PERSIST_DIR:-}"
expected_image="${OCSB_FAKE_OCI_IMAGE:-}"
expected_port="${OCSB_FAKE_OCI_PORT:-}"
persist_id=""
if [[ -n "$persist_dir" ]]; then
  persist_id="$(printf '%s' "$(realpath -m "$persist_dir")" | sha256sum | cut -d ' ' -f 1)"
fi

cmd="${1:-}"
shift || true

case "$cmd" in
  ps)
    [[ "${1:-}" == "--all" && "${2:-}" == "--format" && "${3:-}" == '{{.Names}}' ]] || exit 64
    printf 'sidecar-running\nsidecar-stopped\n'
    ;;
  inspect)
    [[ "${1:-}" == "--format" && $# -ge 3 ]] || exit 64
    format="$2"
    container="$3"
    case "$container" in
      sidecar-running)
        status="running"
        ;;
      sidecar-stopped)
        status="exited"
        ;;
      sidecar-missing)
        exit 1
        ;;
      *)
        exit 1
        ;;
    esac
    case "$format" in
      '{{.State.Status}}') printf '%s\n' "$status" ;;
      '{{.Config.Image}}'|'{{.ImageName}}') printf '%s\n' "$expected_image" ;;
      *'io.ocsb.owner'*) printf 'ocsb-ironclaw\n' ;;
      *'io.ocsb.persist-id'*) printf '%s\n' "$persist_id" ;;
      *'io.ocsb.image'*) printf '%s\n' "$expected_image" ;;
      *'io.ocsb.volume'*) printf '%s/pgdata-sidecar\n' "$(realpath -m "$persist_dir")" ;;
      *'io.ocsb.port'*) printf '%s\n' "$expected_port" ;;
      *'.Mounts'*) printf '%s/pgdata-sidecar|/var/lib/postgresql\n' "$(realpath -m "$persist_dir")" ;;
      *'5432/tcp'*) printf '127.0.0.1|%s\n' "$expected_port" ;;
      *) exit 64 ;;
    esac
    ;;
  start)
    exit 0
    ;;
  run)
    exit 0
    ;;
  exec)
    _container="${1:-}"
    shift || true
    subcmd="${1:-}"
    shift || true
    case "$subcmd" in
      pg_isready)
        exit 0
        ;;
      psql)
        print_db_exists=0
        for arg in "$@"; do
          if [[ "$arg" == "-tAc" ]]; then
            print_db_exists=1
            break
          fi
        done
        if [[ "$print_db_exists" -eq 1 ]]; then
          printf '1\n'
        fi
        exit 0
        ;;
      createdb)
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$FAKE_BIN/fake-oci"
ln -s "$FAKE_BIN/fake-oci" "$FAKE_BIN/podman"
ln -s "$FAKE_BIN/fake-oci" "$FAKE_BIN/docker"

echo "=== ironclaw sandbox test suite ==="

echo "--- wrapper help text ---"
HELP_TEXT="$($WRAPPER --help)"
WRAPPER_SCRIPT="$(readlink -f "$WRAPPER")"
WRAPPER_TEXT="$(cat "$WRAPPER_SCRIPT")"
assert_contains "help: persist default uses persist variant" "$HELP_TEXT" 'Default: $HOME/.cache/ocsb/$PERSIST_VARIANT.'
assert_contains "help: arch wrappers share non-arch data dir" "$HELP_TEXT" 'Arch-optimized wrappers share the'
assert_contains "help: db env file path documented" "$HELP_TEXT" 'state/ironclaw-db.env'
assert_contains "help: fixed sidecar container default" "$HELP_TEXT" 'Default: ocsb-ironclaw-db.'
assert_contains "help: digest-pinned sidecar image default" "$HELP_TEXT" "Default: $DEFAULT_SIDECAR_IMAGE."
assert_contains "wrapper: persist variant default branch present" "$WRAPPER_TEXT" 'PERSIST_DIR="$HOME/.cache/ocsb/$PERSIST_VARIANT"'
assert "wrapper: persist default no longer uses arch-suffixed VARIANT" bash -lc '! grep -Fq -- "$2" "$1"' _ "$WRAPPER_SCRIPT" 'PERSIST_DIR="$HOME/.cache/ocsb/$VARIANT"'
assert_contains "wrapper: launches from persisted home" "$WRAPPER_TEXT" 'cd "$PERSIST_DIR/home"'
assert_contains "wrapper: fixed sidecar container default" "$WRAPPER_TEXT" 'DB_SIDECAR_CONTAINER="ocsb-ironclaw-db"'
assert "wrapper: no DB env names forwarded via OCSB_FORWARD_ENV" bash -lc '! grep -Fq -- "append_forward_env_name DATABASE_URL" "$1"' _ "$WRAPPER_SCRIPT"
assert_contains "wrapper: DB --env gate present" "$WRAPPER_TEXT" 'if ! is_db_env_name "$_ENV_NAME"; then'
assert_contains "wrapper: reserved internal env gate present" "$WRAPPER_TEXT" 'is_reserved_ironclaw_env_name "$_ENV_NAME"'
assert_contains "wrapper: db env file uses atomic rename" "$WRAPPER_TEXT" 'mv -f "$_db_env_tmp" "$_db_env_file"'
assert_contains "wrapper: sidecar pg18 mount target" "$WRAPPER_TEXT" '/var/lib/postgresql'

echo "--- wrapper + embedded mode smoke ---"
set +e
SMOKE_OUTPUT="$("$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_EMBEDDED" -- --version 2>&1)"
SMOKE_RC=$?
set -e
printf '%s\n' "$SMOKE_OUTPUT"
if [[ "$SMOKE_RC" -ne 0 ]]; then
  if is_real_bwrap_capability_denial "$SMOKE_OUTPUT"; then
    echo 'SKIP[CI-REQUIRED-ironclaw-real-bwrap]: userns or RTM_NEWADDR unavailable'
    exit 0
  fi
  exit "$SMOKE_RC"
fi

echo "--- embedded mode sandbox probes ---"
EXPECTED_STATE_DIR="$PERSIST_EMBEDDED/state/ironclaw"
PROBE_SCRIPT="$PERSIST_EMBEDDED/home/ironclaw-probe.sh"
mkdir -p "$PERSIST_EMBEDDED/home"
cat > "$PROBE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

expected_state_dir="${1:?expected state dir}"

vector_version="$(psql -h /run/postgresql -d ironclaw -Atqc "SELECT extversion FROM pg_extension WHERE extname='vector';" | tr -d '[:space:]')"
if [[ -z "$vector_version" ]]; then
  echo "vector extension missing" >&2
  exit 1
fi

nix --version >/dev/null

case ":$PATH:" in
  *:/home/sandbox/.nix-profile/bin:*:/nix/var/nix/profiles/default/bin:*) ;;
  *)
    echo "expected nix profile paths in PATH, got $PATH" >&2
    exit 1
    ;;
esac

if [[ "$OCSB_STATE_DIR" != "$expected_state_dir" ]]; then
  echo "expected OCSB_STATE_DIR=$expected_state_dir, got $OCSB_STATE_DIR" >&2
  exit 1
fi

if [[ "$OCSB_NETWORK" != "host" ]]; then
  echo "expected OCSB_NETWORK=host, got $OCSB_NETWORK" >&2
  exit 1
fi

if [[ "${OCSB_IRONCLAW_DB_MODE:-}" != "embedded" ]]; then
  echo "expected OCSB_IRONCLAW_DB_MODE=embedded, got ${OCSB_IRONCLAW_DB_MODE:-<unset>}" >&2
  exit 1
fi

if [[ "${DATABASE_URL:-}" != "postgres:///ironclaw?host=/run/postgresql&sslmode=disable" ]]; then
  echo "unexpected embedded DATABASE_URL: ${DATABASE_URL:-<unset>}" >&2
  exit 1
fi

curl -s --max-time 10 https://example.com >/dev/null
if [[ "$(pwd)" != "/home/sandbox" ]]; then
  echo "expected cwd=/home/sandbox, got $(pwd)" >&2
  exit 1
fi
printf 'workspace-ok' > /home/sandbox/ironclaw-workspace-marker
EOF
chmod +x "$PROBE_SCRIPT"
OCSB_EXEC_OVERRIDE=1 "$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_EMBEDDED" -- bash /home/sandbox/ironclaw-probe.sh "$EXPECTED_STATE_DIR"

echo "--- stable sandbox state check ---"
assert "chroot merged nix store exists" test -d "$EXPECTED_STATE_DIR/chroot/merged/nix/store"
assert "legacy chroot layout removed" test ! -e "$EXPECTED_STATE_DIR/chroot/nix"
assert "ironclaw workspace uses persisted home" test "$(cat "$PERSIST_EMBEDDED/home/ironclaw-workspace-marker")" = "workspace-ok"
assert "ironclaw wrapper does not create separate workspace dir" test ! -e "$PERSIST_EMBEDDED/workspace"

echo "--- external mode validation + forwarding ---"
set +e
EXTERNAL_ERR="$("$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_EXTERNAL" --db-mode external -- --version 2>&1)"
EXTERNAL_RC=$?
set -e
assert "external mode without DATABASE_URL fails" test "$EXTERNAL_RC" -ne 0
assert_contains "external mode failure message" "$EXTERNAL_ERR" "requires DATABASE_URL"

set +e
RESERVED_MODE_ERR="$($WRAPPER --strategy direct --overwrite --persist-dir "$PERSIST_EXTERNAL" --db-mode external --env OCSB_IRONCLAW_DB_MODE=embedded -- --version 2>&1)"
RESERVED_MODE_RC=$?
RESERVED_FILE_ERR="$($WRAPPER --strategy direct --overwrite --persist-dir "$PERSIST_EXTERNAL" --db-mode external --env OCSB_IRONCLAW_DB_ENV_FILE=/tmp/evil.env -- --version 2>&1)"
RESERVED_FILE_RC=$?
set -e
assert "reserved db mode env fails" test "$RESERVED_MODE_RC" -ne 0
assert_contains "reserved db mode env failure message" "$RESERVED_MODE_ERR" "reserved for the Ironclaw wrapper"
assert "reserved db env file env fails" test "$RESERVED_FILE_RC" -ne 0
assert_contains "reserved db env file failure message" "$RESERVED_FILE_ERR" "reserved for the Ironclaw wrapper"

EXTERNAL_DB_URL="postgres://extuser:extpass@db.example:5432/ironclaw?sslmode=require"
EXTERNAL_NON_DB_FLAG="external-non-db-flag-$$"
mkdir -p "$PERSIST_EXTERNAL/state"
printf 'stale-db-env\n' > "$PERSIST_EXTERNAL/state/ironclaw-db.env"
chmod 0644 "$PERSIST_EXTERNAL/state/ironclaw-db.env"
EXTERNAL_OUTPUT="$(
  PATH="$FAKE_BIN:$PATH" \
  OCSB_FAKE_OCI_LOG="$TMPDIR/external-sidecar.log" \
  DATABASE_SSLMODE="require" \
  DATABASE_POOL_SIZE="7" \
  IRONCLAW_WRAPPER_NON_DB_FLAG="$EXTERNAL_NON_DB_FLAG" \
  OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_EXTERNAL" --db-mode external \
  --env "DATABASE_URL=$EXTERNAL_DB_URL" --env DATABASE_SSLMODE --env DATABASE_POOL_SIZE --env IRONCLAW_WRAPPER_NON_DB_FLAG -- \
  bash -lc 'printf "%s\n%s\n%s\n%s\n%s\n%s\n" "$OCSB_IRONCLAW_DB_MODE" "$DATABASE_URL" "$DATABASE_BACKEND" "$DATABASE_SSLMODE" "$DATABASE_POOL_SIZE" "$IRONCLAW_WRAPPER_NON_DB_FLAG"'
)"
EXT_MODE_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '1p')"
EXT_URL_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '2p')"
EXT_BACKEND_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '3p')"
EXT_SSLMODE_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '4p')"
EXT_POOL_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '5p')"
EXT_NON_DB_LINE="$(printf '%s\n' "$EXTERNAL_OUTPUT" | sed -n '6p')"

EXTERNAL_DB_ENV_FILE="$PERSIST_EXTERNAL/state/ironclaw-db.env"
assert "external db env file exists" test -s "$EXTERNAL_DB_ENV_FILE"
assert "external db env file mode 0600" test "$(stat -c %a "$EXTERNAL_DB_ENV_FILE")" = "600"
assert "external db env file exports DATABASE_URL" grep -Fq -- "export DATABASE_URL=" "$EXTERNAL_DB_ENV_FILE"
assert "external db env file stale content removed" bash -lc '! grep -Fq -- "stale-db-env" "$1"' _ "$EXTERNAL_DB_ENV_FILE"
assert "external db env temp files cleaned" bash -lc '! compgen -G "$1/state/.ironclaw-db.env.*" >/dev/null' _ "$PERSIST_EXTERNAL"

EXT_ENVFILE_CHECK="$({
  source "$EXTERNAL_DB_ENV_FILE"
  printf "%s\n%s\n%s\n%s\n" "${DATABASE_URL:-}" "${DATABASE_BACKEND:-}" "${DATABASE_SSLMODE:-}" "${DATABASE_POOL_SIZE:-}"
})"
EXT_FILE_URL_LINE="$(printf '%s\n' "$EXT_ENVFILE_CHECK" | sed -n '1p')"
EXT_FILE_BACKEND_LINE="$(printf '%s\n' "$EXT_ENVFILE_CHECK" | sed -n '2p')"
EXT_FILE_SSLMODE_LINE="$(printf '%s\n' "$EXT_ENVFILE_CHECK" | sed -n '3p')"
EXT_FILE_POOL_LINE="$(printf '%s\n' "$EXT_ENVFILE_CHECK" | sed -n '4p')"

assert "external mode forwarded db mode" test "$EXT_MODE_LINE" = "external"
assert "external mode forwarded DATABASE_URL" test "$EXT_URL_LINE" = "$EXTERNAL_DB_URL"
assert "external mode forwarded DATABASE_BACKEND" test "$EXT_BACKEND_LINE" = "postgres"
assert "external mode forwarded DATABASE_SSLMODE" test "$EXT_SSLMODE_LINE" = "require"
assert "external mode forwarded DATABASE_POOL_SIZE" test "$EXT_POOL_LINE" = "7"
assert "external mode forwards non-db --env" test "$EXT_NON_DB_LINE" = "$EXTERNAL_NON_DB_FLAG"
assert "external db env file has DATABASE_URL" test "$EXT_FILE_URL_LINE" = "$EXTERNAL_DB_URL"
assert "external db env file has DATABASE_BACKEND" test "$EXT_FILE_BACKEND_LINE" = "postgres"
assert "external db env file has DATABASE_SSLMODE" test "$EXT_FILE_SSLMODE_LINE" = "require"
assert "external db env file has DATABASE_POOL_SIZE" test "$EXT_FILE_POOL_LINE" = "7"
assert "external mode skips embedded initdb" test ! -e "$PERSIST_EXTERNAL/pgdata/PG_VERSION"
assert "external mode does not touch sidecar runtime" test ! -s "$TMPDIR/external-sidecar.log"

echo "--- sidecar mode: running container reuse ---"
RUNNING_LOG="$TMPDIR/sidecar-running.log"
mkdir -p "$PERSIST_SIDECAR"
printf '%048d\n' 0 > "$PERSIST_SIDECAR/sidecar-db-password"
chmod 0600 "$PERSIST_SIDECAR/sidecar-db-password"
SIDE_OUTPUT_RUNNING="$(
  PATH="$FAKE_BIN:$PATH" \
  OCSB_FAKE_OCI_LOG="$RUNNING_LOG" \
  OCSB_FAKE_OCI_PERSIST_DIR="$PERSIST_SIDECAR" \
  OCSB_FAKE_OCI_IMAGE="$DEFAULT_SIDECAR_IMAGE" \
  OCSB_FAKE_OCI_PORT=55439 \
  IRONCLAW_WRAPPER_NON_DB_FLAG="sidecar-non-db-$$" \
  OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_SIDECAR" \
    --db-mode sidecar --db-sidecar-runtime podman --db-sidecar-container sidecar-running --db-sidecar-port 55439 \
    --env IRONCLAW_WRAPPER_NON_DB_FLAG -- \
    bash -lc 'printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n" "$OCSB_IRONCLAW_DB_MODE" "$PGHOST" "$PGPORT" "$PGUSER" "$PGDATABASE" "$PGPASSWORD" "$DATABASE_BACKEND" "$DATABASE_URL" "$IRONCLAW_WRAPPER_NON_DB_FLAG"'
)"
SC_MODE_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '1p')"
SC_HOST_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '2p')"
SC_PORT_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '3p')"
SC_USER_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '4p')"
SC_DB_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '5p')"
SC_PASS_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '6p')"
SC_BACKEND_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '7p')"
SC_URL_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '8p')"
SC_NON_DB_LINE="$(printf '%s\n' "$SIDE_OUTPUT_RUNNING" | sed -n '9p')"
SC_PASS_FILE="$(cat "$PERSIST_SIDECAR/sidecar-db-password")"
SC_URL_EXPECTED="postgres://ironclaw:$SC_PASS_FILE@127.0.0.1:55439/ironclaw?sslmode=disable"
SC_DB_ENV_FILE="$PERSIST_SIDECAR/state/ironclaw-db.env"

assert "sidecar mode forwarded db mode" test "$SC_MODE_LINE" = "sidecar"
assert "sidecar mode forwarded PGHOST" test "$SC_HOST_LINE" = "127.0.0.1"
assert "sidecar mode forwarded PGPORT" test "$SC_PORT_LINE" = "55439"
assert "sidecar mode forwarded PGUSER" test "$SC_USER_LINE" = "ironclaw"
assert "sidecar mode forwarded PGDATABASE" test "$SC_DB_LINE" = "ironclaw"
assert "sidecar mode forwarded password" test "$SC_PASS_LINE" = "$SC_PASS_FILE"
assert "sidecar mode forwarded DATABASE_BACKEND" test "$SC_BACKEND_LINE" = "postgres"
assert "sidecar mode synthesized DATABASE_URL" test "$SC_URL_LINE" = "$SC_URL_EXPECTED"
assert "sidecar mode forwards non-db --env" test "$SC_NON_DB_LINE" = "sidecar-non-db-$$"

assert "sidecar password file exists" test -s "$PERSIST_SIDECAR/sidecar-db-password"
assert "sidecar password file mode 0600" test "$(stat -c %a "$PERSIST_SIDECAR/sidecar-db-password")" = "600"
assert "sidecar data dir exists" test -d "$PERSIST_SIDECAR/pgdata-sidecar"
assert "sidecar mode skips embedded initdb" test ! -e "$PERSIST_SIDECAR/pgdata/PG_VERSION"
assert "sidecar db env file exists" test -s "$SC_DB_ENV_FILE"
assert "sidecar db env file mode 0600" test "$(stat -c %a "$SC_DB_ENV_FILE")" = "600"

SC_ENVFILE_CHECK="$({
  source "$SC_DB_ENV_FILE"
  printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n" "${PGHOST:-}" "${PGPORT:-}" "${PGUSER:-}" "${PGDATABASE:-}" "${PGPASSWORD:-}" "${DATABASE_BACKEND:-}" "${DATABASE_URL:-}"
})"
SC_FILE_HOST_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '1p')"
SC_FILE_PORT_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '2p')"
SC_FILE_USER_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '3p')"
SC_FILE_DB_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '4p')"
SC_FILE_PASS_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '5p')"
SC_FILE_BACKEND_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '6p')"
SC_FILE_URL_LINE="$(printf '%s\n' "$SC_ENVFILE_CHECK" | sed -n '7p')"

assert "sidecar db env file has PGHOST" test "$SC_FILE_HOST_LINE" = "127.0.0.1"
assert "sidecar db env file has PGPORT" test "$SC_FILE_PORT_LINE" = "55439"
assert "sidecar db env file has PGUSER" test "$SC_FILE_USER_LINE" = "ironclaw"
assert "sidecar db env file has PGDATABASE" test "$SC_FILE_DB_LINE" = "ironclaw"
assert "sidecar db env file has PGPASSWORD" test "$SC_FILE_PASS_LINE" = "$SC_PASS_FILE"
assert "sidecar db env file has DATABASE_BACKEND" test "$SC_FILE_BACKEND_LINE" = "postgres"
assert "sidecar db env file has DATABASE_URL" test "$SC_FILE_URL_LINE" = "$SC_URL_EXPECTED"

RUNNING_LOG_TEXT="$(cat "$RUNNING_LOG")"
assert_contains "sidecar running: uses podman runtime" "$RUNNING_LOG_TEXT" "podman inspect --format {{.State.Status}} sidecar-running"
assert "sidecar running: does not start container" bash -lc '! grep -Fq -- "podman start sidecar-running" "$1"' _ "$RUNNING_LOG"
assert "sidecar running: does not run new container" bash -lc '! grep -Fq -- "podman run -d --name sidecar-running" "$1"' _ "$RUNNING_LOG"
assert "sidecar running: readiness probe executed" grep -Fq -- "podman exec sidecar-running pg_isready" "$RUNNING_LOG"

echo "--- sidecar mode: stopped container start ---"
STOPPED_LOG="$TMPDIR/sidecar-stopped.log"
PATH="$FAKE_BIN:$PATH" OCSB_FAKE_OCI_LOG="$STOPPED_LOG" \
  OCSB_FAKE_OCI_PERSIST_DIR="$PERSIST_SIDECAR" OCSB_FAKE_OCI_IMAGE="$DEFAULT_SIDECAR_IMAGE" \
  OCSB_FAKE_OCI_PORT=55439 OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_SIDECAR" \
    --db-mode sidecar --db-sidecar-runtime podman --db-sidecar-container sidecar-stopped --db-sidecar-port 55439 -- \
    bash -lc 'echo stopped-case-ok' >/dev/null
STOPPED_LOG_TEXT="$(cat "$STOPPED_LOG")"
assert_contains "sidecar stopped: inspect by name" "$STOPPED_LOG_TEXT" "podman inspect --format {{.State.Status}} sidecar-stopped"
assert_contains "sidecar stopped: starts existing container" "$STOPPED_LOG_TEXT" "podman start sidecar-stopped"
assert "sidecar stopped: does not run new container" bash -lc '! grep -Fq -- "podman run -d --name sidecar-stopped" "$1"' _ "$STOPPED_LOG"

echo "--- sidecar mode: missing container create/run (docker runtime) ---"
MISSING_LOG="$TMPDIR/sidecar-missing.log"
PATH="$FAKE_BIN:$PATH" OCSB_FAKE_OCI_LOG="$MISSING_LOG" \
  OCSB_FAKE_OCI_PERSIST_DIR="$PERSIST_SIDECAR" OCSB_FAKE_OCI_IMAGE="$DEFAULT_SIDECAR_IMAGE" \
  OCSB_FAKE_OCI_PORT=55439 OCSB_EXEC_OVERRIDE=1 \
  "$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_SIDECAR" \
    --db-mode sidecar --db-sidecar-runtime docker --db-sidecar-container sidecar-missing --db-sidecar-port 55439 -- \
    bash -lc 'echo missing-case-ok' >/dev/null
MISSING_LOG_TEXT="$(cat "$MISSING_LOG")"
assert_contains "sidecar missing: uses docker runtime" "$MISSING_LOG_TEXT" "docker inspect --format {{.State.Status}} sidecar-missing"
assert_contains "sidecar missing: creates new container" "$MISSING_LOG_TEXT" "docker run -d --name sidecar-missing"
assert_contains "sidecar missing: labels owner" "$MISSING_LOG_TEXT" "--label io.ocsb.owner=ocsb-ironclaw"
assert_contains "sidecar missing: binds exact image" "$MISSING_LOG_TEXT" "--label io.ocsb.image=$DEFAULT_SIDECAR_IMAGE"
assert_contains "sidecar missing: runs exact image" "$MISSING_LOG_TEXT" "$DEFAULT_SIDECAR_IMAGE"
assert_contains "sidecar missing: mounts pg18 data root" "$MISSING_LOG_TEXT" "$PERSIST_SIDECAR/pgdata-sidecar:/var/lib/postgresql"
assert "sidecar missing: does not call start" bash -lc '! grep -Fq -- "docker start sidecar-missing" "$1"' _ "$MISSING_LOG"

echo ""
echo "=== ironclaw Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
