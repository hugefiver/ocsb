{ pkgs, ... }:

{
  shellHelpers = ''
    ocsb_proc_start_time() {
      local _pid="$1"
      [[ "$_pid" =~ ^[1-9][0-9]*$ ]] || return 1
      [[ -r "/proc/$_pid/stat" ]] || return 1
      local _stat _rest _field _idx
      IFS= read -r _stat < "/proc/$_pid/stat" || return 1
      _rest="''${_stat##*) }"
      _idx=1
      for _field in $_rest; do
        if [[ $_idx -eq 20 ]]; then
          [[ "$_field" =~ ^[1-9][0-9]*$ ]] || return 1
          printf '%s\n' "$_field"
          return 0
        fi
        _idx=$((_idx + 1))
      done
      return 1
    }

    ocsb__proc_state() {
      local _pid="$1"
      [[ "$_pid" =~ ^[1-9][0-9]*$ ]] || return 1
      [[ -r "/proc/$_pid/stat" ]] || return 1
      local _stat _rest
      IFS= read -r _stat < "/proc/$_pid/stat" || return 1
      _rest="''${_stat##*) }"
      [[ -n "$_rest" ]] || return 1
      printf '%s\n' "''${_rest%% *}"
    }

    ocsb__stat_owner_mode() {
      ${pkgs.coreutils}/bin/stat -c '%u %a' -- "$1" 2>/dev/null
    }

    ocsb__validate_private_dir() {
      local _path="$1"
      local _uid="$2"
      local _owner _mode
      if [[ -L "$_path" || ! -d "$_path" ]]; then
        echo "ocsb: unsafe runtime directory: $_path is not a non-symlink directory" >&2
        return 1
      fi
      read -r _owner _mode < <(ocsb__stat_owner_mode "$_path") || {
        echo "ocsb: unsafe runtime directory: cannot stat $_path" >&2
        return 1
      }
      if [[ "$_owner" != "$_uid" || "$_mode" != "700" ]]; then
        echo "ocsb: unsafe runtime directory: $_path must be owned by uid $_uid with mode 0700" >&2
        return 1
      fi
    }

    ocsb__validate_xdg_parent() {
      local _path="$1"
      local _uid="$2"
      if [[ "$_path" != /* ]]; then
        echo "ocsb: unsafe runtime directory parent: XDG_RUNTIME_DIR must be absolute: $_path" >&2
        return 1
      fi
      ocsb__validate_private_dir "$_path" "$_uid" || return 1
    }

    ocsb__validate_fallback_parent() {
      local _path="$1"
      local _uid="$2"
      local _owner _mode _mode_value
      if [[ "$_path" != /* || -L "$_path" || ! -d "$_path" ]]; then
        echo "ocsb: unsafe runtime directory parent: $_path" >&2
        return 1
      fi
      read -r _owner _mode < <(ocsb__stat_owner_mode "$_path") || {
        echo "ocsb: unsafe runtime directory parent: cannot stat $_path" >&2
        return 1
      }
      [[ "$_mode" =~ ^[0-7]{3,4}$ ]] || {
        echo "ocsb: unsafe runtime directory parent mode: $_path" >&2
        return 1
      }
      _mode_value=$((8#$_mode))
      if [[ "$_owner" == "$_uid" ]] && (( (_mode_value & 0022) == 0 )); then
        return 0
      fi
      if [[ "$_owner" == "0" ]] && (( (_mode_value & 01000) != 0 )); then
        return 0
      fi
      echo "ocsb: unsafe runtime directory parent: $_path is neither private to uid $_uid nor root-owned sticky" >&2
      return 1
    }

    ocsb_runtime_dir() {
      local _uid _parent _runtime
      _uid="$(${pkgs.coreutils}/bin/id -u)" || return 1
      if [[ -n "''${XDG_RUNTIME_DIR:-}" ]]; then
        _parent="$XDG_RUNTIME_DIR"
        ocsb__validate_xdg_parent "$_parent" "$_uid" || return 1
        _runtime="$_parent/ocsb"
      else
        _parent="''${TMPDIR:-/tmp}"
        ocsb__validate_fallback_parent "$_parent" "$_uid" || return 1
        _runtime="$_parent/ocsb-$_uid"
      fi
      if [[ ! -e "$_runtime" && ! -L "$_runtime" ]]; then
        if ! (umask 077; ${pkgs.coreutils}/bin/mkdir -m 0700 -- "$_runtime") 2>/dev/null; then
          if [[ -L "$_runtime" || ! -d "$_runtime" ]]; then
            echo "ocsb: cannot create private runtime directory: $_runtime" >&2
            return 1
          fi
        fi
      fi
      ocsb__validate_private_dir "$_runtime" "$_uid" || return 1
      printf '%s\n' "$_runtime"
    }

    ocsb_instance_digest() {
      local _role="$1"
      local _path="$2"
      local _canonical _digest
      [[ -n "$_role" && "$_path" == /* ]] || {
        echo "ocsb: invalid process record identity" >&2
        return 1
      }
      _canonical="$(${pkgs.coreutils}/bin/realpath -m -- "$_path")" || return 1
      _digest="$({ printf '%s\0%s' "$_role" "$_canonical"; } | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1)" || return 1
      [[ "$_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
      printf '%s\n' "$_digest"
    }

    ocsb_process_record_path() {
      local _role="$1"
      local _path="$2"
      local _runtime _instance
      _runtime="$(ocsb_runtime_dir)" || return 1
      _instance="$(ocsb_instance_digest "$_role" "$_path")" || return 1
      printf '%s/process-%s.pid\n' "$_runtime" "$_instance"
    }

    ocsb__record_file_is_safe() {
      local _path="$1"
      local _uid _owner _mode
      _uid="$(${pkgs.coreutils}/bin/id -u)" || return 1
      if [[ -L "$_path" || ! -f "$_path" ]]; then
        echo "ocsb: unsafe process record: $_path is not a non-symlink regular file" >&2
        return 1
      fi
      read -r _owner _mode < <(ocsb__stat_owner_mode "$_path") || {
        echo "ocsb: unsafe process record: cannot stat $_path" >&2
        return 1
      }
      if [[ "$_owner" != "$_uid" || "$_mode" != "600" ]]; then
        echo "ocsb: unsafe process record: $_path must be owned by uid $_uid with mode 0600" >&2
        return 1
      fi
    }

    ocsb__read_process_record_line() {
      local _path="$1"
      local _size
      OCSB_RECORD_LINE=""
      ocsb__record_file_is_safe "$_path" || return 1
      IFS= read -r OCSB_RECORD_LINE < "$_path" || {
        echo "ocsb: malformed process record: $_path" >&2
        OCSB_RECORD_LINE=""
        return 1
      }
      _size="$(${pkgs.coreutils}/bin/stat -c %s -- "$_path" 2>/dev/null)" || return 1
      if [[ "$_size" -ne $((''${#OCSB_RECORD_LINE} + 1)) ]]; then
        echo "ocsb: malformed process record: $_path must contain exactly one newline-terminated line" >&2
        OCSB_RECORD_LINE=""
        return 1
      fi
    }

    # Serialize cooperative publish/remove operations on the already-opened
    # private runtime-directory inode, rather than on a replaceable lock path.
    ocsb__lock_process_record_dir() {
      local _runtime _uid _owner _mode _path_identity _fd_identity
      _runtime="$(ocsb_runtime_dir)" || return 1
      _uid="$(${pkgs.coreutils}/bin/id -u)" || return 1
      OCSB_PROCESS_RECORD_LOCK_FD=""
      OCSB_PROCESS_RECORD_LOCK_DIR=""
      _path_identity="$(${pkgs.coreutils}/bin/stat -Lc '%d:%i:%u:%a' -- "$_runtime")" || return 1
      exec {OCSB_PROCESS_RECORD_LOCK_FD}<"$_runtime" || return 1
      _fd_identity="$(${pkgs.coreutils}/bin/stat -Lc '%d:%i:%u:%a' -- "/proc/$$/fd/$OCSB_PROCESS_RECORD_LOCK_FD")" || {
        exec {OCSB_PROCESS_RECORD_LOCK_FD}<&-
        OCSB_PROCESS_RECORD_LOCK_FD=""
        return 1
      }
      IFS=: read -r _ _ _owner _mode <<< "$_fd_identity"
      if [[ "$_path_identity" != "$_fd_identity" || "$_owner" != "$_uid" || "$_mode" != "700" ]]; then
        echo "ocsb: unsafe runtime directory lock inode" >&2
        exec {OCSB_PROCESS_RECORD_LOCK_FD}<&-
        OCSB_PROCESS_RECORD_LOCK_FD=""
        return 1
      fi
      ${pkgs.util-linux}/bin/flock -x "$OCSB_PROCESS_RECORD_LOCK_FD" || {
        exec {OCSB_PROCESS_RECORD_LOCK_FD}<&-
        OCSB_PROCESS_RECORD_LOCK_FD=""
        return 1
      }
      OCSB_PROCESS_RECORD_LOCK_DIR="/proc/$$/fd/$OCSB_PROCESS_RECORD_LOCK_FD"
    }

    ocsb__unlock_process_record_dir() {
      if [[ -n "''${OCSB_PROCESS_RECORD_LOCK_FD:-}" ]]; then
        ${pkgs.util-linux}/bin/flock -u "$OCSB_PROCESS_RECORD_LOCK_FD" || true
        exec {OCSB_PROCESS_RECORD_LOCK_FD}<&- || true
      fi
      OCSB_PROCESS_RECORD_LOCK_FD=""
      OCSB_PROCESS_RECORD_LOCK_DIR=""
    }

    ocsb_write_process_record() {
      local _path="$1"
      local _pid="$2"
      local _instance="$3"
      local _runtime _dir _base _start _tmp
      [[ "$_pid" =~ ^[1-9][0-9]*$ && "$_instance" =~ ^[0-9a-f]{64}$ ]] || {
        echo "ocsb: invalid process record fields" >&2
        return 1
      }
      _runtime="$(ocsb_runtime_dir)" || return 1
      _dir="''${_path%/*}"
      _base="''${_path##*/}"
      if [[ "$_dir" != "$_runtime" || "$_base" != "process-$_instance.pid" ]]; then
        echo "ocsb: invalid process record path: $_path" >&2
        return 1
      fi
      _start="$(ocsb_proc_start_time "$_pid")" || {
        echo "ocsb: cannot read process start time for pid $_pid" >&2
        return 1
      }
      ocsb__lock_process_record_dir || return 1
      if [[ -e "$OCSB_PROCESS_RECORD_LOCK_DIR/$_base" || -L "$OCSB_PROCESS_RECORD_LOCK_DIR/$_base" ]]; then
        ocsb__record_file_is_safe "$OCSB_PROCESS_RECORD_LOCK_DIR/$_base" || {
          ocsb__unlock_process_record_dir
          return 1
        }
      fi
      _tmp="$(umask 077; ${pkgs.coreutils}/bin/mktemp "$OCSB_PROCESS_RECORD_LOCK_DIR/.process-record.XXXXXX")" || {
        ocsb__unlock_process_record_dir
        return 1
      }
      if ! printf 'v1\t%s\t%s\t%s\n' "$_pid" "$_start" "$_instance" > "$_tmp"; then
        ${pkgs.coreutils}/bin/rm -f -- "$_tmp"
        ocsb__unlock_process_record_dir
        return 1
      fi
      if ! ${pkgs.coreutils}/bin/chmod 0600 -- "$_tmp"; then
        ${pkgs.coreutils}/bin/rm -f -- "$_tmp"
        ocsb__unlock_process_record_dir
        return 1
      fi
      if ! ${pkgs.coreutils}/bin/mv -T -- "$_tmp" "$OCSB_PROCESS_RECORD_LOCK_DIR/$_base"; then
        ${pkgs.coreutils}/bin/rm -f -- "$_tmp"
        ocsb__unlock_process_record_dir
        return 1
      fi
      ocsb__unlock_process_record_dir
    }

    ocsb_validate_process_record() {
      local _path="$1"
      local _expected_instance="$2"
      local _tab _record_re _actual_start _state
      OCSB_RECORD_PID=""
      OCSB_RECORD_START=""
      OCSB_RECORD_INSTANCE=""
      OCSB_RECORD_LINE=""
      [[ "$_expected_instance" =~ ^[0-9a-f]{64}$ ]] || return 1
      ocsb__read_process_record_line "$_path" || return 1
      _tab=$'\t'
      _record_re="^v1''${_tab}([1-9][0-9]*)''${_tab}([1-9][0-9]*)''${_tab}([0-9a-f]{64})$"
      if [[ ! "$OCSB_RECORD_LINE" =~ $_record_re ]]; then
        echo "ocsb: malformed process record: $_path" >&2
        return 1
      fi
      OCSB_RECORD_PID="''${BASH_REMATCH[1]}"
      OCSB_RECORD_START="''${BASH_REMATCH[2]}"
      OCSB_RECORD_INSTANCE="''${BASH_REMATCH[3]}"
      if [[ "$OCSB_RECORD_INSTANCE" != "$_expected_instance" ]]; then
        echo "ocsb: process record instance mismatch: $_path" >&2
        return 1
      fi
      if ! kill -0 "$OCSB_RECORD_PID" 2>/dev/null; then
        echo "ocsb: process record pid is not live: $OCSB_RECORD_PID" >&2
        return 1
      fi
      _state="$(ocsb__proc_state "$OCSB_RECORD_PID")" || return 1
      if [[ "$_state" == "Z" || "$_state" == "X" || "$_state" == "x" ]]; then
        echo "ocsb: process record pid is not live: $OCSB_RECORD_PID" >&2
        return 1
      fi
      _actual_start="$(ocsb_proc_start_time "$OCSB_RECORD_PID")" || return 1
      if [[ "$_actual_start" != "$OCSB_RECORD_START" ]]; then
        echo "ocsb: process record start time changed: $_path" >&2
        return 1
      fi
    }

    ocsb_remove_matching_process_record() {
      local _path="$1"
      local _expected_line="$2"
      local _runtime _dir _base
      [[ -n "$_expected_line" ]] || return 1
      _runtime="$(ocsb_runtime_dir)" || return 1
      _dir="''${_path%/*}"
      _base="''${_path##*/}"
      [[ "$_dir" == "$_runtime" && ( "$_base" == process-*.pid || "$_base" == reservation-* ) ]] || return 1
      ocsb__lock_process_record_dir || return 1
      ocsb__read_process_record_line "$OCSB_PROCESS_RECORD_LOCK_DIR/$_base" || {
        ocsb__unlock_process_record_dir
        return 1
      }
      if [[ "$OCSB_RECORD_LINE" != "$_expected_line" ]]; then
        ocsb__unlock_process_record_dir
        return 1
      fi
      if ! ${pkgs.coreutils}/bin/rm -f -- "$OCSB_PROCESS_RECORD_LOCK_DIR/$_base"; then
        ocsb__unlock_process_record_dir
        return 1
      fi
      ocsb__unlock_process_record_dir
    }
  '';
}
