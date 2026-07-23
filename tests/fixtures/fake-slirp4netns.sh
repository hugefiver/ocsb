#!/usr/bin/env bash
set -euo pipefail

: "${OCSB_FILTERED_CASE_DIR:?}"
: "${OCSB_FILTERED_LOCK_FILE:?}"

proc_field() {
  local pid="$1"
  local wanted="$2"
  local stat rest field index=1

  IFS= read -r stat < "/proc/$pid/stat"
  rest="${stat##*) }"
  for field in $rest; do
    if [[ "$index" -eq "$wanted" ]]; then
      printf '%s\n' "$field"
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

process_has_lock_fd() {
  local pid="$1"
  local fd target

  [[ -d "/proc/$pid/fd" ]] || return 1
  for fd in "/proc/$pid/fd"/*; do
    [[ -e "$fd" ]] || continue
    target="$(readlink -f -- "$fd" 2>/dev/null || true)"
    [[ "$target" == "$OCSB_FILTERED_LOCK_FILE" ]] && return 0
  done
  return 1
}

write_signal_marker_and_exit() {
  printf 'TERM\n' > "$OCSB_FILTERED_CASE_DIR/SLIRP_SIGNAL.tmp"
  mv -f -- "$OCSB_FILTERED_CASE_DIR/SLIRP_SIGNAL.tmp" \
    "$OCSB_FILTERED_CASE_DIR/SLIRP_SIGNAL"
  exit 0
}

trap write_signal_marker_and_exit TERM HUP INT

self_pid="$$"
self_start="$(proc_field "$self_pid" 20)"
self_ppid="$(proc_field "$self_pid" 2)"
self_pgid="$(proc_field "$self_pid" 3)"
self_lock=closed
parent_lock=closed
process_has_lock_fd "$self_pid" && self_lock=open
process_has_lock_fd "$self_ppid" && parent_lock=open

printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$self_pid" "$self_start" "$self_ppid" "$self_pgid" \
  "$self_lock" "$parent_lock" \
  > "$OCSB_FILTERED_CASE_DIR/slirp-record.tmp"
mv -f -- "$OCSB_FILTERED_CASE_DIR/slirp-record.tmp" \
  "$OCSB_FILTERED_CASE_DIR/slirp-record"
: > "$OCSB_FILTERED_CASE_DIR/SLIRP_STARTED"

while :; do
  sleep 1
done
