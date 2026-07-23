#!/usr/bin/env bash
set -euo pipefail

: "${OCSB_FILTERED_CASE_DIR:?}"
: "${OCSB_FILTERED_SEARCH_ROOT:?}"

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

wait_for_info_fifo() {
  local attempt
  local -a fifos=()

  for ((attempt = 0; attempt < 1000; attempt++)); do
    mapfile -t fifos < <(find "$OCSB_FILTERED_SEARCH_ROOT" -type p -name info -print)
    if [[ "${#fifos[@]}" -eq 1 ]]; then
      printf '%s\n' "${fifos[0]}"
      return 0
    fi
    if [[ "${#fifos[@]}" -gt 1 ]]; then
      echo "fake-filtered-bwrap: multiple info FIFOs found" >&2
      return 1
    fi
    sleep 0.01
  done
  echo "fake-filtered-bwrap: info FIFO did not appear" >&2
  return 1
}

wait_for_barrier() {
  local barrier="$1"
  local attempt

  for ((attempt = 0; attempt < 3000; attempt++)); do
    [[ -e "$barrier" ]] && return 0
    sleep 0.01
  done
  echo "fake-filtered-bwrap: timed out waiting for $barrier" >&2
  return 1
}

self_pid="$$"
self_start="$(proc_field "$self_pid" 20)"
self_pgid="$(proc_field "$self_pid" 3)"
info_fifo="$(wait_for_info_fifo)"
net_tmp="${info_fifo%/info}"
ready_path="$net_tmp/MONITOR_READY"
ready_present=0
ready_version="-"
ready_monitor_pid=0
ready_monitor_start=0
ready_launcher_pid=0
ready_launcher_start=0
ready_launcher_pgid=0

if [[ -r "$ready_path" ]]; then
  IFS=$'\t' read -r ready_version ready_monitor_pid ready_monitor_start \
    ready_launcher_pid ready_launcher_start ready_launcher_pgid < "$ready_path"
  ready_present=1
fi

printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$self_pid" "$self_start" "$self_pgid" "$net_tmp" "$ready_present" \
  "$ready_version" "$ready_monitor_pid" "$ready_monitor_start" \
  "$ready_launcher_pid" "$ready_launcher_start" "$ready_launcher_pgid" \
  > "$OCSB_FILTERED_CASE_DIR/bwrap-record.tmp"
mv -f -- "$OCSB_FILTERED_CASE_DIR/bwrap-record.tmp" \
  "$OCSB_FILTERED_CASE_DIR/bwrap-record"

[[ -e /proc/self/fd/3 ]] || {
  echo "fake-filtered-bwrap: expected info fd 3" >&2
  exit 1
}
printf '{"child-pid":%s}\n' "$self_pid" >&3
exec 3>&-

: > "$OCSB_FILTERED_CASE_DIR/BWRAP_STARTED"
wait_for_barrier "$OCSB_FILTERED_CASE_DIR/BWRAP_EXIT_ALLOWED"
: > "$OCSB_FILTERED_CASE_DIR/BWRAP_EXITING"
