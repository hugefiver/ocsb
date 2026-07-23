{ pkgs
, nohupCommand ? "${pkgs.coreutils}/bin/nohup"
, hermesCommand ? "hermes"
, candidateStartTimeCommand ? null
, childStartTimeCommand ? null
, childCleanupBarrierCommand ? null
}:

let
  runtimeProcess = import ./runtime-process.nix { inherit pkgs; };
in
pkgs.writeShellScriptBin "service" ''
  set -euo pipefail
  umask 077

  ${runtimeProcess.shellHelpers}

  usage() {
    cat >&2 <<'EOF'
  usage: service gateway start|stop|restart|status
         service gateway supervise [--candidate-token TOKEN]
  EOF
    exit 64
  }

  : ''${HERMES_HOME:=$HOME/.hermes}
  HERMES_HOME="$(${pkgs.coreutils}/bin/realpath -m -- "$HERMES_HOME")"
  export HERMES_HOME

  service_name="''${1:-}"
  action="''${2:-}"
  shift_count=2
  if [[ "$service_name" != "gateway" || -z "$action" ]]; then
    usage
  fi
  shift "$shift_count"

  candidate_token=""
  if [[ "$action" == "supervise" && "$#" -eq 2 && "$1" == "--candidate-token" && "$2" =~ ^[0-9a-f]{32}$ ]]; then
    candidate_token="$2"
  elif [[ "$#" -ne 0 ]]; then
    usage
  fi

  uid="$(${pkgs.coreutils}/bin/id -u)"
  state_parent="$HERMES_HOME/service"
  state_dir="$state_parent/gateway"
  log_dir="$HERMES_HOME/logs"
  stopped_file="$state_dir/stopped"
  log_file="$log_dir/gateway.log"

  runtime_dir="$(ocsb_runtime_dir)"
  supervisor_instance="$(ocsb_instance_digest hermes-gateway-supervisor "$HERMES_HOME")"
  child_instance="$(ocsb_instance_digest hermes-gateway-child "$HERMES_HOME")"
  supervisor_record="$(ocsb_process_record_path hermes-gateway-supervisor "$HERMES_HOME")"
  child_record="$(ocsb_process_record_path hermes-gateway-child "$HERMES_HOME")"
  lock_file="$runtime_dir/hermes-gateway-$supervisor_instance.lock"
  reservation_file="$runtime_dir/reservation-$supervisor_instance"

  GATEWAY_LOCK_HELD=0
  GATEWAY_RECORD_PID=""
  GATEWAY_RECORD_START=""
  GATEWAY_RECORD_INSTANCE=""
  GATEWAY_RECORD_LINE=""
  GATEWAY_RESERVATION_PID=""
  GATEWAY_RESERVATION_START=""
  GATEWAY_RESERVATION_TOKEN=""
  GATEWAY_RESERVATION_INSTANCE=""
  GATEWAY_RESERVATION_LINE=""
  GATEWAY_SPAWN_PID=""
  GATEWAY_SPAWN_START=""
  GATEWAY_SPAWN_LINE=""
  GATEWAY_SPAWN_STATE="none"
  SUPERVISOR_LINE=""
  supervisor_child_pid=""
  supervisor_child_start=""
  supervisor_child_line=""
  supervisor_child_is_parent=0
  supervisor_shutdown=0

  gateway_ensure_private_dir() {
    local path="$1"
    local owner mode
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      if ! ${pkgs.coreutils}/bin/mkdir -m 0700 -- "$path" 2>/dev/null; then
        [[ -d "$path" && ! -L "$path" ]] || {
          echo "gateway: cannot create private directory: $path" >&2
          return 1
        }
      fi
    fi
    if [[ -L "$path" || ! -d "$path" ]]; then
      echo "gateway: unsafe directory: $path is not a non-symlink directory" >&2
      return 1
    fi
    read -r owner mode < <(${pkgs.coreutils}/bin/stat -c '%u %a' -- "$path") || return 1
    if [[ "$owner" != "$uid" || "$mode" != "700" ]]; then
      echo "gateway: unsafe directory: $path must be owned by uid $uid with mode 0700" >&2
      return 1
    fi
  }

  gateway_ensure_owned_dir() {
    local path="$1"
    local owner mode mode_value
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      if ! ${pkgs.coreutils}/bin/mkdir -m 0700 -- "$path" 2>/dev/null; then
        [[ -d "$path" && ! -L "$path" ]] || {
          echo "gateway: cannot create owned directory: $path" >&2
          return 1
        }
      fi
    fi
    if [[ -L "$path" || ! -d "$path" ]]; then
      echo "gateway: unsafe directory: $path is not a non-symlink directory" >&2
      return 1
    fi
    read -r owner mode < <(${pkgs.coreutils}/bin/stat -c '%u %a' -- "$path") || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    if [[ "$owner" != "$uid" ]] || (( (mode_value & 0022) != 0 )); then
      echo "gateway: unsafe directory: $path must be owned by uid $uid and not group/world writable" >&2
      return 1
    fi
  }

  gateway_safe_file() {
    local path="$1"
    local expected_mode="$2"
    local owner mode
    if [[ -L "$path" || ! -f "$path" ]]; then
      echo "gateway: unsafe file: $path is not a non-symlink regular file" >&2
      return 1
    fi
    read -r owner mode < <(${pkgs.coreutils}/bin/stat -c '%u %a' -- "$path") || return 1
    if [[ "$owner" != "$uid" || "$mode" != "$expected_mode" ]]; then
      echo "gateway: unsafe file: $path must be owned by uid $uid with mode 0$expected_mode" >&2
      return 1
    fi
  }

  gateway_ensure_dirs() {
    if [[ -L "$HERMES_HOME" || ! -d "$HERMES_HOME" ]]; then
      echo "gateway: canonical HERMES_HOME must be a non-symlink directory: $HERMES_HOME" >&2
      return 1
    fi
    local home_owner
    home_owner="$(${pkgs.coreutils}/bin/stat -c %u -- "$HERMES_HOME")" || return 1
    if [[ "$home_owner" != "$uid" ]]; then
      echo "gateway: HERMES_HOME must be owned by uid $uid: $HERMES_HOME" >&2
      return 1
    fi
    gateway_ensure_owned_dir "$state_parent"
    gateway_ensure_private_dir "$state_dir"
    gateway_ensure_owned_dir "$log_dir"
    if [[ -e "$log_file" || -L "$log_file" ]]; then
      gateway_safe_file "$log_file" 600
    fi
  }

  gateway_lock() {
    local path_identity fd_identity
    gateway_ensure_dirs || return 1
    if [[ ! -e "$lock_file" && ! -L "$lock_file" ]]; then
      (umask 077; set -o noclobber; : > "$lock_file") 2>/dev/null || true
    fi
    gateway_safe_file "$lock_file" 600 || return 1
    path_identity="$(${pkgs.coreutils}/bin/stat -Lc '%d:%i' -- "$lock_file")" || return 1
    exec 9<> "$lock_file"
    fd_identity="$(${pkgs.coreutils}/bin/stat -Lc '%d:%i' -- "/proc/$$/fd/9")" || {
      exec 9>&-
      return 1
    }
    if [[ -L "$lock_file" || "$path_identity" != "$fd_identity" ]]; then
      echo "gateway: lock file changed while opening: $lock_file" >&2
      exec 9>&-
      return 1
    fi
    ${pkgs.util-linux}/bin/flock -x 9
    GATEWAY_LOCK_HELD=1
    gateway_safe_file "$lock_file" 600 || {
      gateway_unlock
      return 1
    }
    path_identity="$(${pkgs.coreutils}/bin/stat -Lc '%d:%i' -- "$lock_file")" || {
      gateway_unlock
      return 1
    }
    if [[ "$path_identity" != "$fd_identity" ]]; then
      echo "gateway: lock file replaced while waiting: $lock_file" >&2
      gateway_unlock
      return 1
    fi
  }

  gateway_unlock() {
    if [[ "$GATEWAY_LOCK_HELD" -eq 1 ]]; then
      ${pkgs.util-linux}/bin/flock -u 9 || true
      GATEWAY_LOCK_HELD=0
    fi
    exec 9>&- || true
  }

  gateway_identity_matches() {
    local pid="$1"
    local expected_start="$2"
    local actual_start state
    actual_start="$(ocsb_proc_start_time "$pid" 2>/dev/null)" || return 1
    [[ "$actual_start" == "$expected_start" ]] || return 1
    state="$(ocsb__proc_state "$pid" 2>/dev/null)" || return 1
    [[ "$state" != "Z" && "$state" != "X" && "$state" != "x" ]]
  }

  gateway_assert_unlocked() {
    if [[ "$GATEWAY_LOCK_HELD" -ne 0 ]]; then
      echo "gateway: blocking process operation attempted while holding the gateway lock" >&2
      return 1
    fi
  }

  gateway_sleep_unlocked() {
    gateway_assert_unlocked || return 1
    ${pkgs.coreutils}/bin/sleep "$1"
  }

  # Returns 0 for a valid live record, 1 for absent/stale (stale is CAS
  # removed), and 2 for an unsafe or malformed record. Must run under lock.
  gateway_load_process_record_locked() {
    local path="$1"
    local expected_instance="$2"
    local tab record_re line
    GATEWAY_RECORD_PID=""
    GATEWAY_RECORD_START=""
    GATEWAY_RECORD_INSTANCE=""
    GATEWAY_RECORD_LINE=""
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      return 1
    fi
    if ! ocsb__read_process_record_line "$path"; then
      return 2
    fi
    line="$OCSB_RECORD_LINE"
    tab=$'\t'
    record_re="^v1''${tab}([1-9][0-9]*)''${tab}([1-9][0-9]*)''${tab}([0-9a-f]{64})$"
    if [[ ! "$line" =~ $record_re || "''${BASH_REMATCH[3]:-}" != "$expected_instance" ]]; then
      echo "gateway: malformed or mismatched typed process record: $path" >&2
      return 2
    fi
    GATEWAY_RECORD_PID="''${BASH_REMATCH[1]}"
    GATEWAY_RECORD_START="''${BASH_REMATCH[2]}"
    GATEWAY_RECORD_INSTANCE="''${BASH_REMATCH[3]}"
    GATEWAY_RECORD_LINE="$line"
    if ! gateway_identity_matches "$GATEWAY_RECORD_PID" "$GATEWAY_RECORD_START"; then
      if ! ocsb_remove_matching_process_record "$path" "$line"; then
        echo "gateway: stale process record changed during CAS cleanup: $path" >&2
        return 2
      fi
      GATEWAY_RECORD_PID=""
      GATEWAY_RECORD_START=""
      GATEWAY_RECORD_INSTANCE=""
      GATEWAY_RECORD_LINE=""
      return 1
    fi
  }

  # Reservation schema: v1, candidate pid, /proc start time, 128-bit token,
  # and the canonical-HERMES_HOME supervisor instance digest.
  gateway_load_reservation_locked() {
    local tab reservation_re line
    GATEWAY_RESERVATION_PID=""
    GATEWAY_RESERVATION_START=""
    GATEWAY_RESERVATION_TOKEN=""
    GATEWAY_RESERVATION_INSTANCE=""
    GATEWAY_RESERVATION_LINE=""
    if [[ ! -e "$reservation_file" && ! -L "$reservation_file" ]]; then
      return 1
    fi
    if ! ocsb__read_process_record_line "$reservation_file"; then
      return 2
    fi
    line="$OCSB_RECORD_LINE"
    tab=$'\t'
    reservation_re="^v1''${tab}([1-9][0-9]*)''${tab}([1-9][0-9]*)''${tab}([0-9a-f]{32})''${tab}([0-9a-f]{64})$"
    if [[ ! "$line" =~ $reservation_re || "''${BASH_REMATCH[4]:-}" != "$supervisor_instance" ]]; then
      echo "gateway: malformed or mismatched reservation: $reservation_file" >&2
      return 2
    fi
    GATEWAY_RESERVATION_PID="''${BASH_REMATCH[1]}"
    GATEWAY_RESERVATION_START="''${BASH_REMATCH[2]}"
    GATEWAY_RESERVATION_TOKEN="''${BASH_REMATCH[3]}"
    GATEWAY_RESERVATION_INSTANCE="''${BASH_REMATCH[4]}"
    GATEWAY_RESERVATION_LINE="$line"
    if ! gateway_identity_matches "$GATEWAY_RESERVATION_PID" "$GATEWAY_RESERVATION_START"; then
      if ! ocsb_remove_matching_process_record "$reservation_file" "$line"; then
        echo "gateway: stale reservation changed during CAS cleanup" >&2
        return 2
      fi
      GATEWAY_RESERVATION_PID=""
      GATEWAY_RESERVATION_START=""
      GATEWAY_RESERVATION_TOKEN=""
      GATEWAY_RESERVATION_INSTANCE=""
      GATEWAY_RESERVATION_LINE=""
      return 1
    fi
  }

  gateway_write_reservation_locked() {
    local pid="$1"
    local start="$2"
    local token="$3"
    local tmp
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$start" =~ ^[1-9][0-9]*$ && \
      "$token" =~ ^[0-9a-f]{32}$ ]] || return 1
    if [[ -e "$reservation_file" || -L "$reservation_file" ]]; then
      gateway_safe_file "$reservation_file" 600 || return 1
    fi
    tmp="$(umask 077; ${pkgs.coreutils}/bin/mktemp "$runtime_dir/.gateway-reservation.XXXXXX")" || return 1
    if ! printf 'v1\t%s\t%s\t%s\t%s\n' "$pid" "$start" "$token" "$supervisor_instance" > "$tmp" || \
      ! ${pkgs.coreutils}/bin/chmod 0600 -- "$tmp" || \
      ! ${pkgs.coreutils}/bin/mv -T -- "$tmp" "$reservation_file"; then
      ${pkgs.coreutils}/bin/rm -f -- "$tmp"
      return 1
    fi
    GATEWAY_SPAWN_LINE="v1"$'\t'"$pid"$'\t'"$start"$'\t'"$token"$'\t'"$supervisor_instance"
  }

  gateway_stopped_locked() {
    local size
    if [[ ! -e "$stopped_file" && ! -L "$stopped_file" ]]; then
      return 1
    fi
    gateway_safe_file "$stopped_file" 600 || return 2
    size="$(${pkgs.coreutils}/bin/stat -c %s -- "$stopped_file")" || return 2
    if [[ "$size" -ne 0 ]]; then
      echo "gateway: malformed stopped marker: $stopped_file" >&2
      return 2
    fi
  }

  gateway_set_stopped_locked() {
    local tmp
    if gateway_stopped_locked; then
      return 0
    else
      local rc=$?
      [[ "$rc" -eq 1 ]] || return "$rc"
    fi
    tmp="$(umask 077; ${pkgs.coreutils}/bin/mktemp "$state_dir/.stopped.XXXXXX")" || return 1
    if ! ${pkgs.coreutils}/bin/chmod 0600 -- "$tmp" || \
      ! ${pkgs.coreutils}/bin/mv -T -- "$tmp" "$stopped_file"; then
      ${pkgs.coreutils}/bin/rm -f -- "$tmp"
      return 1
    fi
  }

  gateway_clear_stopped_locked() {
    if gateway_stopped_locked; then
      ${pkgs.coreutils}/bin/rm -f -- "$stopped_file"
    else
      local rc=$?
      [[ "$rc" -eq 1 ]] || return "$rc"
    fi
  }

  gateway_new_token() {
    local token
    token="$(${pkgs.coreutils}/bin/od -An -N16 -tx1 /dev/urandom | ${pkgs.coreutils}/bin/tr -d ' \n')" || return 1
    [[ "$token" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf '%s\n' "$token"
  }

  gateway_candidate_start_time() {
    ${if candidateStartTimeCommand == null then ''
      ocsb_proc_start_time "$1"
    '' else ''
      ${candidateStartTimeCommand} "$1"
    ''}
  }

  gateway_child_start_time() {
    ${if childStartTimeCommand == null then ''
      ocsb_proc_start_time "$1"
    '' else ''
      ${childStartTimeCommand} "$1"
    ''}
  }

  gateway_child_cleanup_barrier() {
    ${if childCleanupBarrierCommand == null then ''
      :
    '' else ''
      ${childCleanupBarrierCommand} "$1"
    ''}
  }

  gateway_write_child_process_record_locked() {
    local pid="$1"
    local start="$2"
    local tmp
    [[ "$GATEWAY_LOCK_HELD" -eq 1 ]] || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$start" =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ -e "$child_record" || -L "$child_record" ]]; then
      ocsb__record_file_is_safe "$child_record" || return 1
    fi
    tmp="$(umask 077; ${pkgs.coreutils}/bin/mktemp "$runtime_dir/.gateway-child-record.XXXXXX")" || return 1
    if ! printf 'v1\t%s\t%s\t%s\n' "$pid" "$start" "$child_instance" > "$tmp" || \
      ! ${pkgs.coreutils}/bin/chmod 0600 -- "$tmp" || \
      ! ${pkgs.coreutils}/bin/mv -T -- "$tmp" "$child_record"; then
      ${pkgs.coreutils}/bin/rm -f -- "$tmp"
      return 1
    fi
  }

  gateway_spawn_candidate_locked() {
    local token pid start
    GATEWAY_SPAWN_PID=""
    GATEWAY_SPAWN_START=""
    GATEWAY_SPAWN_LINE=""
    GATEWAY_SPAWN_STATE="none"
    token="$(gateway_new_token)" || return 1
    ${nohupCommand} "$0" gateway supervise --candidate-token "$token" 9>&- > /dev/null 2>&1 &
    pid=$!
    GATEWAY_SPAWN_PID="$pid"
    GATEWAY_SPAWN_STATE="spawned"
    start="$(gateway_candidate_start_time "$pid" 2>/dev/null)" || return 1
    GATEWAY_SPAWN_START="$start"
    GATEWAY_SPAWN_STATE="captured"
    gateway_write_reservation_locked "$pid" "$start" "$token"
  }

  gateway_signal_exact() {
    local pid="$1"
    local start="$2"
    local signal="''${3:-TERM}"
    gateway_identity_matches "$pid" "$start" || return 1
    kill -"$signal" "$pid" 2>/dev/null
  }

  gateway_wait_identity_gone() {
    local pid="$1"
    local start="$2"
    local i
    gateway_assert_unlocked || return 1
    for ((i = 0; i < 50; i++)); do
      if ! gateway_identity_matches "$pid" "$start"; then
        return 0
      fi
      gateway_sleep_unlocked 0.1
    done
    return 1
  }

  gateway_terminate_exact() {
    local pid="$1"
    local start="$2"
    gateway_assert_unlocked || return 1
    gateway_signal_exact "$pid" "$start" TERM || return 0
    if gateway_wait_identity_gone "$pid" "$start"; then
      return 0
    fi
    gateway_signal_exact "$pid" "$start" KILL || return 0
    gateway_wait_identity_gone "$pid" "$start" || true
  }

  gateway_wait_direct_child() {
    local pid="$1"
    local wait_rc
    gateway_assert_unlocked || return 1
    set +e
    wait "$pid" 2>/dev/null
    wait_rc=$?
    set -e
    [[ "$wait_rc" -ne 127 ]]
  }

  gateway_recover_uncaptured_direct_child() {
    local pid="$1"
    local role="$2"
    local recovered_start=""
    if recovered_start="$(ocsb_proc_start_time "$pid" 2>/dev/null)"; then
      gateway_terminate_exact "$pid" "$recovered_start"
    fi
    gateway_wait_direct_child "$pid" || {
      echo "gateway: spawned $role was not a direct child" >&2
      return 1
    }
    echo "gateway: $role start time unavailable; $role reaped" >&2
  }

  gateway_finish_failed_supervisor_child() {
    local pid="$1"
    local start="$2"
    local record_line="$3"
    local cleanup_rc=0
    gateway_assert_unlocked || return 1
    gateway_child_cleanup_barrier "$pid" || cleanup_rc=1
    if [[ -n "$start" ]]; then
      gateway_terminate_exact "$pid" "$start" || cleanup_rc=1
      gateway_wait_direct_child "$pid" || cleanup_rc=1
    else
      gateway_recover_uncaptured_direct_child "$pid" child || cleanup_rc=1
    fi
    if [[ -n "$record_line" ]]; then
      if gateway_lock; then
        ocsb_remove_matching_process_record "$child_record" "$record_line" 2>/dev/null || true
        gateway_unlock
      else
        cleanup_rc=1
      fi
    fi
    return "$cleanup_rc"
  }

  gateway_wait_for_claim() {
    local expected_line="$1"
    local pid="$2"
    local start="$3"
    local owner="$4"
    local i rc
    [[ "$owner" == 0 || "$owner" == 1 ]] || return 1
    gateway_confirm_expected_supervisor() {
      local confirmed=1
      gateway_assert_unlocked || return 1
      gateway_sleep_unlocked 0.1 || return 1
      gateway_lock || return 1
      if gateway_load_process_record_locked "$supervisor_record" "$supervisor_instance" \
        && [[ "$GATEWAY_RECORD_PID" == "$pid" && "$GATEWAY_RECORD_START" == "$start" ]]; then
        confirmed=0
      fi
      gateway_unlock
      return "$confirmed"
    }

    gateway_assert_unlocked || return 1
    for ((i = 0; i < 50; i++)); do
      gateway_lock || return 1
      if gateway_load_process_record_locked "$supervisor_record" "$supervisor_instance"; then
        if [[ "$GATEWAY_RECORD_PID" == "$pid" && "$GATEWAY_RECORD_START" == "$start" ]]; then
          gateway_unlock
          if gateway_confirm_expected_supervisor; then
            return 0
          fi
          echo "gateway: exact supervisor claim was not live on confirmation" >&2
          return 1
        fi
        gateway_unlock
        return 1
      else
        rc=$?
        [[ "$rc" -eq 1 ]] || {
          gateway_unlock
          return 1
        }
      fi
      if gateway_load_reservation_locked; then
        if [[ "$GATEWAY_RESERVATION_LINE" != "$expected_line" || \
              "$GATEWAY_RESERVATION_PID" != "$pid" || \
              "$GATEWAY_RESERVATION_START" != "$start" ]]; then
          gateway_unlock
          return 1
        fi
      else
        # A missing/stale reservation with no validated exact supervisor means
        # the candidate died or another claimant won; neither is success.
        gateway_unlock
        return 1
      fi
      gateway_unlock
      gateway_sleep_unlocked 0.1
    done

    gateway_lock || return 1
    if gateway_load_process_record_locked "$supervisor_record" "$supervisor_instance"; then
      if [[ "$GATEWAY_RECORD_PID" == "$pid" && "$GATEWAY_RECORD_START" == "$start" ]]; then
        gateway_unlock
        if gateway_confirm_expected_supervisor; then
          return 0
        fi
        echo "gateway: exact supervisor claim was not live on confirmation" >&2
        return 1
      fi
      gateway_unlock
      return 1
    else
      rc=$?
      [[ "$rc" -eq 1 ]] || {
        gateway_unlock
        return 1
      }
    fi
    if gateway_load_reservation_locked; then
      if [[ "$GATEWAY_RESERVATION_LINE" != "$expected_line" || \
            "$GATEWAY_RESERVATION_PID" != "$pid" || \
            "$GATEWAY_RESERVATION_START" != "$start" ]]; then
        gateway_unlock
        return 1
      fi
      if [[ "$owner" -eq 1 ]]; then
        ocsb_remove_matching_process_record "$reservation_file" "$expected_line" || {
          gateway_unlock
          return 1
        }
      fi
    else
      gateway_unlock
      return 1
    fi
    gateway_unlock
    echo "gateway: supervisor reservation was not claimed within 5 seconds" >&2
    return 1
  }

  gateway_start_or_reserve_locked() {
    local rc
    if gateway_load_process_record_locked "$supervisor_record" "$supervisor_instance"; then
      echo "gateway already running (supervisor pid $GATEWAY_RECORD_PID)"
      return 10
    else
      rc=$?
      [[ "$rc" -eq 1 ]] || return 1
    fi
    if gateway_load_reservation_locked; then
      echo "reservation already active"
      return 11
    else
      rc=$?
      [[ "$rc" -eq 1 ]] || return 1
    fi
    gateway_spawn_candidate_locked
  }

  start_gateway() {
    local rc spawn_pid spawn_start spawn_line spawn_state claim_pid claim_start claim_line claim_owner=0
    gateway_lock
    gateway_clear_stopped_locked || {
      gateway_unlock
      return 1
    }
    set +e
    gateway_start_or_reserve_locked
    rc=$?
    set -e
    spawn_pid="$GATEWAY_SPAWN_PID"
    spawn_start="$GATEWAY_SPAWN_START"
    spawn_line="$GATEWAY_SPAWN_LINE"
    spawn_state="$GATEWAY_SPAWN_STATE"
    if [[ "$rc" -eq 0 ]]; then
      claim_pid="$spawn_pid"
      claim_start="$spawn_start"
      claim_line="$spawn_line"
      claim_owner=1
    elif [[ "$rc" -eq 11 ]]; then
      claim_pid="$GATEWAY_RESERVATION_PID"
      claim_start="$GATEWAY_RESERVATION_START"
      claim_line="$GATEWAY_RESERVATION_LINE"
    fi
    gateway_unlock
    if [[ "$rc" -eq 10 ]]; then
      return 0
    fi
    if [[ "$rc" -ne 0 && "$rc" -ne 11 ]]; then
      if [[ -n "$spawn_pid" && -n "$spawn_start" ]]; then
        gateway_terminate_exact "$spawn_pid" "$spawn_start"
        gateway_wait_direct_child "$spawn_pid" || true
      elif [[ -n "$spawn_pid" && "$spawn_state" == "spawned" ]]; then
        gateway_recover_uncaptured_direct_child "$spawn_pid" candidate || true
      fi
      return 1
    fi
    if ! gateway_wait_for_claim "$claim_line" "$claim_pid" "$claim_start" "$claim_owner"; then
      if [[ "$claim_owner" -eq 1 ]]; then
        gateway_terminate_exact "$claim_pid" "$claim_start" || true
        gateway_wait_direct_child "$claim_pid" || true
      fi
      return 1
    fi
    if [[ "$claim_owner" -eq 1 ]]; then
      echo "gateway started"
    fi
  }

  stop_gateway() {
    local child_pid="" child_start="" rc
    gateway_lock
    gateway_set_stopped_locked || {
      gateway_unlock
      return 1
    }
    if gateway_load_process_record_locked "$child_record" "$child_instance"; then
      child_pid="$GATEWAY_RECORD_PID"
      child_start="$GATEWAY_RECORD_START"
    else
      rc=$?
      if [[ "$rc" -ne 1 ]]; then
        gateway_unlock
        return 1
      fi
    fi
    if gateway_load_reservation_locked; then
      :
    else
      rc=$?
      if [[ "$rc" -ne 1 ]]; then
        gateway_unlock
        return 1
      fi
    fi
    gateway_unlock
    if [[ -n "$child_pid" ]]; then
      gateway_terminate_exact "$child_pid" "$child_start"
    fi
    echo "gateway stopped"
  }

  status_gateway() {
    local enabled_state="enabled" child_pid="" rc
    gateway_lock
    if gateway_stopped_locked; then
      enabled_state="disabled"
    else
      rc=$?
      if [[ "$rc" -ne 1 ]]; then
        gateway_unlock
        return 1
      fi
    fi
    if gateway_load_process_record_locked "$child_record" "$child_instance"; then
      child_pid="$GATEWAY_RECORD_PID"
    else
      rc=$?
      if [[ "$rc" -ne 1 ]]; then
        gateway_unlock
        return 1
      fi
    fi
    if gateway_load_process_record_locked "$supervisor_record" "$supervisor_instance"; then
      :
    else
      rc=$?
      if [[ "$rc" -ne 1 ]]; then
        gateway_unlock
        return 1
      fi
    fi
    if gateway_load_reservation_locked; then
      :
    else
      rc=$?
      if [[ "$rc" -ne 1 ]]; then
        gateway_unlock
        return 1
      fi
    fi
    gateway_unlock
    if [[ -n "$child_pid" ]]; then
      echo "gateway running $enabled_state (pid $child_pid)"
      return 0
    fi
    echo "gateway stopped $enabled_state"
    return 1
  }

  restart_gateway() {
    local old_pid="" old_start="" old_line="" spawn_pid="" spawn_start="" spawn_line="" spawn_state=""
    local claim_pid="" claim_start="" claim_line="" claim_owner=0 rc i current_line
    gateway_lock
    gateway_clear_stopped_locked || {
      gateway_unlock
      return 1
    }
    if gateway_load_process_record_locked "$child_record" "$child_instance"; then
      old_pid="$GATEWAY_RECORD_PID"
      old_start="$GATEWAY_RECORD_START"
      old_line="$GATEWAY_RECORD_LINE"
    else
      rc=$?
      if [[ "$rc" -ne 1 ]]; then
        gateway_unlock
        return 1
      fi
    fi
    set +e
    gateway_start_or_reserve_locked >/dev/null
    rc=$?
    set -e
    spawn_pid="$GATEWAY_SPAWN_PID"
    spawn_start="$GATEWAY_SPAWN_START"
    spawn_line="$GATEWAY_SPAWN_LINE"
    spawn_state="$GATEWAY_SPAWN_STATE"
    if [[ "$rc" -eq 0 ]]; then
      claim_pid="$spawn_pid"
      claim_start="$spawn_start"
      claim_line="$spawn_line"
      claim_owner=1
    elif [[ "$rc" -eq 11 ]]; then
      claim_pid="$GATEWAY_RESERVATION_PID"
      claim_start="$GATEWAY_RESERVATION_START"
      claim_line="$GATEWAY_RESERVATION_LINE"
    fi
    gateway_unlock
    if [[ "$rc" -ne 0 && "$rc" -ne 10 && "$rc" -ne 11 ]]; then
      if [[ -n "$spawn_pid" && -n "$spawn_start" ]]; then
        gateway_terminate_exact "$spawn_pid" "$spawn_start"
        gateway_wait_direct_child "$spawn_pid" || true
      elif [[ -n "$spawn_pid" && "$spawn_state" == "spawned" ]]; then
        gateway_recover_uncaptured_direct_child "$spawn_pid" candidate || true
      fi
      return 1
    fi
    if [[ "$rc" -eq 0 || "$rc" -eq 11 ]]; then
      if ! gateway_wait_for_claim "$claim_line" "$claim_pid" "$claim_start" "$claim_owner"; then
        if [[ "$claim_owner" -eq 1 ]]; then
          gateway_terminate_exact "$claim_pid" "$claim_start" || true
          gateway_wait_direct_child "$claim_pid" || true
        fi
        return 1
      fi
    fi
    if [[ -n "$old_pid" ]]; then
      gateway_signal_exact "$old_pid" "$old_start" TERM || true
    fi

    for ((i = 0; i < 50; i++)); do
      gateway_lock
      if gateway_stopped_locked; then
        gateway_unlock
        echo "gateway restart superseded by stop"
        return 0
      else
        rc=$?
        if [[ "$rc" -ne 1 ]]; then
          gateway_unlock
          return 1
        fi
      fi
      current_line=""
      if gateway_load_process_record_locked "$child_record" "$child_instance"; then
        current_line="$GATEWAY_RECORD_LINE"
      else
        rc=$?
        if [[ "$rc" -ne 1 ]]; then
          gateway_unlock
          return 1
        fi
      fi
      gateway_unlock
      if [[ -n "$current_line" && "$current_line" != "$old_line" ]]; then
        echo "gateway restart requested"
        return 0
      fi
      gateway_sleep_unlocked 0.1
    done
    echo "gateway: restart did not observe a replacement child" >&2
    return 1
  }

  supervisor_register() {
    local token="$1"
    local self_start rc
    self_start="$(ocsb_proc_start_time "$$")" || return 1
    while true; do
      gateway_lock || return 1
      if gateway_load_process_record_locked "$supervisor_record" "$supervisor_instance"; then
        if [[ "$GATEWAY_RECORD_PID" == "$$" && "$GATEWAY_RECORD_START" == "$self_start" ]]; then
          SUPERVISOR_LINE="$GATEWAY_RECORD_LINE"
          gateway_unlock
          return 0
        fi
        gateway_unlock
        if [[ -n "$token" ]]; then
          return 1
        fi
        gateway_sleep_unlocked 1
        continue
      else
        rc=$?
        if [[ "$rc" -ne 1 ]]; then
          gateway_unlock
          return 1
        fi
      fi

      if [[ -n "$token" ]]; then
        if gateway_load_reservation_locked; then
          :
        else
          gateway_unlock
          return 1
        fi
        if [[ "$GATEWAY_RESERVATION_TOKEN" != "$token" || \
          "$GATEWAY_RESERVATION_PID" != "$$" || \
          "$GATEWAY_RESERVATION_START" != "$self_start" || \
          "$GATEWAY_RESERVATION_INSTANCE" != "$supervisor_instance" ]]; then
          gateway_unlock
          return 1
        fi
      else
        if gateway_load_reservation_locked; then
          gateway_unlock
          gateway_sleep_unlocked 1
          continue
        else
          rc=$?
          if [[ "$rc" -ne 1 ]]; then
            gateway_unlock
            return 1
          fi
        fi
      fi

      ocsb_write_process_record "$supervisor_record" "$$" "$supervisor_instance" || {
        gateway_unlock
        return 1
      }
      ocsb__read_process_record_line "$supervisor_record" || {
        gateway_unlock
        return 1
      }
      SUPERVISOR_LINE="$OCSB_RECORD_LINE"
      if [[ -n "$token" ]]; then
        ocsb_remove_matching_process_record "$reservation_file" "$GATEWAY_RESERVATION_LINE" || {
          ocsb_remove_matching_process_record "$supervisor_record" "$SUPERVISOR_LINE" || true
          gateway_unlock
          return 1
        }
      fi
      gateway_unlock
      return 0
    done
  }

  supervise_gateway() {
    local token="$1"
    local rc child_setup_rc child_cleanup_line
    local recorded_child_version recorded_child_pid recorded_child_start recorded_child_instance
    SUPERVISOR_LINE=""
    supervisor_child_pid=""
    supervisor_child_start=""
    supervisor_child_line=""
    supervisor_child_is_parent=0
    supervisor_shutdown=0

    supervisor_capture_and_signal_child() {
      local signal_pid="" signal_start="" signal_rc
      [[ "$GATEWAY_LOCK_HELD" -eq 0 ]] || return 0
      gateway_lock || return 0
      if gateway_load_process_record_locked "$supervisor_record" "$supervisor_instance"; then
        if [[ "$GATEWAY_RECORD_LINE" == "$SUPERVISOR_LINE" ]]; then
          if gateway_load_process_record_locked "$child_record" "$child_instance"; then
            signal_pid="$GATEWAY_RECORD_PID"
            signal_start="$GATEWAY_RECORD_START"
          else
            signal_rc=$?
            [[ "$signal_rc" -eq 1 ]] || true
          fi
        fi
      fi
      gateway_unlock
      if [[ -n "$signal_pid" ]]; then
        gateway_signal_exact "$signal_pid" "$signal_start" TERM || true
      fi
    }

    supervisor_on_signal() {
      supervisor_shutdown=1
      supervisor_capture_and_signal_child
    }

    supervisor_cleanup() {
      local cleanup_pid="" cleanup_start="" cleanup_line="" cleanup_rc owner_valid=0
      if [[ "$GATEWAY_LOCK_HELD" -eq 1 ]]; then
        gateway_unlock
      fi
      if gateway_lock; then
        if gateway_load_process_record_locked "$supervisor_record" "$supervisor_instance"; then
          if [[ "$GATEWAY_RECORD_LINE" == "$SUPERVISOR_LINE" ]]; then
            owner_valid=1
          fi
        fi
        if [[ "$owner_valid" -eq 1 && -n "$supervisor_child_line" ]]; then
          cleanup_pid="$supervisor_child_pid"
          cleanup_start="$supervisor_child_start"
          cleanup_line="$supervisor_child_line"
        elif [[ "$owner_valid" -eq 1 ]] && gateway_load_process_record_locked "$child_record" "$child_instance"; then
          if [[ -z "$supervisor_child_pid" || "$GATEWAY_RECORD_PID" == "$supervisor_child_pid" ]]; then
            cleanup_pid="$GATEWAY_RECORD_PID"
            cleanup_start="$GATEWAY_RECORD_START"
            cleanup_line="$GATEWAY_RECORD_LINE"
          fi
        else
          cleanup_rc=$?
          [[ "$cleanup_rc" -eq 1 ]] || true
        fi
        gateway_unlock
      fi
      if [[ -z "$cleanup_pid" && "$supervisor_child_is_parent" -eq 1 ]]; then
        cleanup_pid="$supervisor_child_pid"
        cleanup_start="$supervisor_child_start"
      fi
      if [[ -n "$cleanup_pid" ]]; then
        gateway_terminate_exact "$cleanup_pid" "$cleanup_start"
      fi
      if [[ "$supervisor_child_is_parent" -eq 1 && -n "$supervisor_child_pid" ]]; then
        gateway_wait_direct_child "$supervisor_child_pid" || true
      fi
      if [[ "$owner_valid" -eq 1 ]] && gateway_lock; then
        if [[ -n "$cleanup_line" ]]; then
          ocsb_remove_matching_process_record "$child_record" "$cleanup_line" 2>/dev/null || true
        fi
        if [[ -n "$SUPERVISOR_LINE" ]]; then
          ocsb_remove_matching_process_record "$supervisor_record" "$SUPERVISOR_LINE" 2>/dev/null || true
        fi
        gateway_unlock
      fi
    }

    supervisor_register "$token" || return 1
    trap supervisor_cleanup EXIT
    trap supervisor_on_signal INT TERM HUP

    while [[ "$supervisor_shutdown" -eq 0 ]]; do
      supervisor_child_pid=""
      supervisor_child_start=""
      supervisor_child_line=""
      supervisor_child_is_parent=0
      child_cleanup_line=""
      child_setup_rc=0
      gateway_lock || return 1
      if gateway_load_process_record_locked "$supervisor_record" "$supervisor_instance"; then
        :
      else
        rc=$?
        gateway_unlock
        [[ "$rc" -eq 1 ]] || return 1
        return 0
      fi
      if [[ "$GATEWAY_RECORD_LINE" != "$SUPERVISOR_LINE" ]]; then
        gateway_unlock
        return 0
      fi
      if gateway_stopped_locked; then
        gateway_unlock
        gateway_sleep_unlocked 1
        continue
      else
        rc=$?
        if [[ "$rc" -ne 1 ]]; then
          gateway_unlock
          return 1
        fi
      fi
      if gateway_load_process_record_locked "$child_record" "$child_instance"; then
        supervisor_child_pid="$GATEWAY_RECORD_PID"
        supervisor_child_start="$GATEWAY_RECORD_START"
        supervisor_child_line="$GATEWAY_RECORD_LINE"
      else
        rc=$?
        if [[ "$rc" -ne 1 ]]; then
          gateway_unlock
          return 1
        fi
        if [[ -e "$log_file" || -L "$log_file" ]]; then
          gateway_safe_file "$log_file" 600 || {
            gateway_unlock
            return 1
          }
        fi
        ${hermesCommand} gateway run --replace >> "$log_file" 2>&1 9>&- &
        supervisor_child_pid=$!
        supervisor_child_is_parent=1
        if supervisor_child_start="$(gateway_child_start_time "$supervisor_child_pid" 2>/dev/null)"; then
          if gateway_write_child_process_record_locked "$supervisor_child_pid" "$supervisor_child_start"; then
            printf -v child_cleanup_line 'v1\t%s\t%s\t%s' \
              "$supervisor_child_pid" "$supervisor_child_start" "$child_instance"
            if ocsb__read_process_record_line "$child_record"; then
              supervisor_child_line="$OCSB_RECORD_LINE"
              child_cleanup_line="$supervisor_child_line"
              IFS=$'\t' read -r recorded_child_version recorded_child_pid \
                recorded_child_start recorded_child_instance <<< "$supervisor_child_line"
              if [[ "$recorded_child_version" != "v1" || \
                "$recorded_child_pid" != "$supervisor_child_pid" || \
                "$recorded_child_start" != "$supervisor_child_start" || \
                "$recorded_child_instance" != "$child_instance" ]]; then
                child_setup_rc=1
              fi
            else
              child_setup_rc=1
            fi
          else
            child_setup_rc=1
          fi
        else
          child_setup_rc=1
        fi
        if [[ "$child_setup_rc" -ne 0 ]]; then
          gateway_unlock
          gateway_finish_failed_supervisor_child "$supervisor_child_pid" \
            "$supervisor_child_start" "$child_cleanup_line" || true
          supervisor_child_pid=""
          supervisor_child_start=""
          supervisor_child_line=""
          supervisor_child_is_parent=0
          return 1
        fi
      fi
      gateway_unlock

      if [[ "$supervisor_shutdown" -ne 0 ]]; then
        gateway_signal_exact "$supervisor_child_pid" "$supervisor_child_start" TERM || true
      fi
      if [[ "$supervisor_child_is_parent" -eq 1 ]]; then
        gateway_assert_unlocked || return 1
        set +e
        wait "$supervisor_child_pid"
        set -e
        if [[ "$supervisor_shutdown" -ne 0 ]]; then
          gateway_terminate_exact "$supervisor_child_pid" "$supervisor_child_start"
          gateway_wait_direct_child "$supervisor_child_pid" || true
        fi
      else
        while [[ "$supervisor_shutdown" -eq 0 ]] && gateway_identity_matches "$supervisor_child_pid" "$supervisor_child_start"; do
          gateway_sleep_unlocked 1
        done
      fi

      gateway_lock || return 1
      if [[ -n "$supervisor_child_line" ]]; then
        ocsb_remove_matching_process_record "$child_record" "$supervisor_child_line" 2>/dev/null || true
      fi
      gateway_unlock
      supervisor_child_pid=""
      supervisor_child_start=""
      supervisor_child_line=""
      supervisor_child_is_parent=0
      if [[ "$supervisor_shutdown" -eq 0 ]]; then
        gateway_sleep_unlocked 1
      fi
    done
  }

  case "$action" in
    start)
      start_gateway
      ;;
    stop)
      stop_gateway
      ;;
    restart)
      restart_gateway
      ;;
    status)
      status_gateway
      ;;
    supervise)
      supervise_gateway "$candidate_token"
      ;;
    *)
      usage
      ;;
  esac
''
