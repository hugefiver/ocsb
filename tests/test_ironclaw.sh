#!/usr/bin/env bash
set -euo pipefail

WRAPPER="${1:?Usage: $0 <path-to-ocsb-ironclaw-binary>}"
PERSIST_DIR="$(mktemp -d)"
cleanup() {
  find "$PERSIST_DIR" -type d -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$PERSIST_DIR"
}
trap cleanup EXIT

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "SKIP: GitHub Actions runners restrict bwrap netns (RTM_NEWADDR)"
  exit 0
fi

echo "=== ironclaw sandbox test ==="

echo "--- wrapper + binary version smoke ---"
"$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_DIR" -- --version

echo "--- sandbox probes ---"
EXPECTED_STATE_DIR="$PERSIST_DIR/state/ironclaw"
PROBE_SCRIPT="$PERSIST_DIR/home/ironclaw-probe.sh"
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

    if [[ "$OCSB_STATE_DIR" != "$expected_state_dir" ]]; then
      echo "expected OCSB_STATE_DIR=$expected_state_dir, got $OCSB_STATE_DIR" >&2
      exit 1
    fi

    if [[ "$OCSB_NETWORK" != "host" ]]; then
      echo "expected OCSB_NETWORK=host, got $OCSB_NETWORK" >&2
      exit 1
    fi

    curl -s --max-time 10 https://example.com >/dev/null
EOF
chmod +x "$PROBE_SCRIPT"
OCSB_EXEC_OVERRIDE=1 "$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_DIR" -- bash /home/sandbox/ironclaw-probe.sh "$EXPECTED_STATE_DIR"

echo "--- stable sandbox state check ---"
if [[ ! -d "$EXPECTED_STATE_DIR/chroot/merged/nix/store" ]]; then
  echo "expected chroot merged nix store at $EXPECTED_STATE_DIR/chroot/merged/nix/store" >&2
  exit 1
fi
if [[ -e "$EXPECTED_STATE_DIR/chroot/nix" ]]; then
  echo "legacy chroot layout still exists at $EXPECTED_STATE_DIR/chroot/nix" >&2
  exit 1
fi

echo "=== ironclaw sandbox test: PASS ==="
