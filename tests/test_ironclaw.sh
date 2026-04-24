#!/usr/bin/env bash
set -euo pipefail

WRAPPER="${1:?Usage: $0 <path-to-ocsb-ironclaw-binary>}"
PERSIST_DIR="$(mktemp -d)"
trap 'rm -rf "$PERSIST_DIR"' EXIT

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "SKIP: GitHub Actions runners restrict bwrap netns (RTM_NEWADDR)"
  exit 0
fi

echo "=== ironclaw sandbox test ==="

echo "--- wrapper + binary version smoke ---"
"$WRAPPER" --strategy direct --overwrite --persist-dir "$PERSIST_DIR" -- ironclaw --version

echo "--- pgvector extension check ---"
VECTOR_VERSION="$("$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_DIR" -- bash -lc "psql -h /run/postgresql -d ironclaw -Atqc \"SELECT extversion FROM pg_extension WHERE extname='vector';\"" | tr -d '[:space:]')"
if [[ -z "$VECTOR_VERSION" ]]; then
  echo "vector extension missing" >&2
  exit 1
fi

echo "--- nix command check ---"
"$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_DIR" -- bash -lc "nix --version >/dev/null"

echo "--- filtered network private range blocked ---"
if "$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_DIR" -- bash -lc "curl -s --max-time 3 http://10.0.0.1 >/dev/null"; then
  echo "expected private range curl to fail" >&2
  exit 1
fi

echo "--- filtered network public internet reachable ---"
"$WRAPPER" --strategy direct --continue --persist-dir "$PERSIST_DIR" -- bash -lc "curl -s --max-time 10 https://example.com >/dev/null"

echo "=== ironclaw sandbox test: PASS ==="
