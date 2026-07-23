#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  echo "Usage: $0 --prepare DIR OCSB" >&2
  echo "       $0 --case strategy-create DELEGATE" >&2
  exit 2
}

prepare_delegate() {
  local fixture_dir="$1"
  local ocsb="$2"
  local delegate

  [[ -x "$ocsb" ]] || {
    echo "ocsb launcher is not executable: $ocsb" >&2
    exit 1
  }

  install -d -m 0700 "$fixture_dir"
  fixture_dir="$(cd -- "$fixture_dir" && pwd -P)"
  delegate="$fixture_dir/ocsb-status-73"

  rm -f -- \
    "$fixture_dir/injected" \
    "$fixture_dir/injected-call" \
    "$fixture_dir/post-injection-call" \
    "$delegate"
  printf '%s\n' "$ocsb" > "$fixture_dir/real-ocsb"
  chmod 0600 "$fixture_dir/real-ocsb"

  cat > "$delegate" <<'DELEGATE'
#!/usr/bin/env bash
set -euo pipefail

DELEGATE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
IFS= read -r REAL_OCSB < "$DELEGATE_DIR/real-ocsb"
ARGS=("$@")
workspace=""
strategy=""
overwrite=0

if [[ -e "$DELEGATE_DIR/injected" ]]; then
  printf '%q ' "${ARGS[@]}" >> "$DELEGATE_DIR/post-injection-call"
  printf '\n' >> "$DELEGATE_DIR/post-injection-call"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)
      [[ $# -ge 2 ]] || exec "$REAL_OCSB" "${ARGS[@]}"
      workspace="$2"
      shift 2
      ;;
    --strategy)
      [[ $# -ge 2 ]] || exec "$REAL_OCSB" "${ARGS[@]}"
      strategy="$2"
      shift 2
      ;;
    --overwrite)
      overwrite=1
      shift
      ;;
    --)
      break
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$workspace" == "strat-test" && "$strategy" == "direct" && "$overwrite" -eq 1 && ! -e "$DELEGATE_DIR/injected" ]]; then
  : > "$DELEGATE_DIR/injected"
  printf '%q ' "${ARGS[@]}" > "$DELEGATE_DIR/injected-call"
  printf '\n' >> "$DELEGATE_DIR/injected-call"
  exit 73
fi

exec "$REAL_OCSB" "${ARGS[@]}"
DELEGATE

  chmod 0700 "$delegate"
  test -x "$delegate"
  printf '%s\n' "$delegate"
}

strategy_create_case() {
  local delegate="$1"
  local delegate_dir
  local status

  [[ -x "$delegate" ]] || {
    echo "delegate is not executable: $delegate" >&2
    exit 1
  }
  delegate_dir="$(cd -- "$(dirname -- "$delegate")" && pwd -P)"

  set +e
  bash "$SCRIPT_DIR/test_wrapper.sh" "$delegate"
  status=$?
  set -e

  if [[ "$status" -eq 73 ]] && \
    grep -Fqx -- "-w strat-test --strategy direct --overwrite -- -c true " "$delegate_dir/injected-call" 2>/dev/null && \
    [[ ! -e "$delegate_dir/post-injection-call" ]]; then
    echo "PASS[GREEN-swallowed-test-failure]: exact status 73 propagated"
    return 0
  fi
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL[RED-swallowed-test-failure]: expected=73 actual=0" >&2
    return 1
  fi

  if [[ "$status" -eq 73 ]]; then
    echo "FAIL[swallowed-test-failure]: status 73 did not propagate directly from initial strat-test create" >&2
    return 1
  fi

  echo "FAIL[swallowed-test-failure]: expected=73 actual=$status" >&2
  return 1
}

case "${1:-}" in
  --prepare)
    [[ $# -eq 3 ]] || usage
    prepare_delegate "$2" "$3"
    ;;
  --case)
    [[ $# -eq 3 && "$2" == "strategy-create" ]] || usage
    strategy_create_case "$3"
    ;;
  *)
    usage
    ;;
esac
