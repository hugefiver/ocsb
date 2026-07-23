{ pkgs
, target
, openssl ? pkgs.openssl
}:

let
  targetArg = pkgs.lib.escapeShellArg target;
  directoryArg = pkgs.lib.escapeShellArg (builtins.dirOf target);
  baseArg = pkgs.lib.escapeShellArg (builtins.baseNameOf target);
in
''
  _mk_target=${targetArg}
  _mk_dir=${directoryArg}
  _mk_base=${baseArg}
  _mk_tmp=""
  _mk_validate_existing() {
    local _mk_owner _mk_mode _mk_value

    [[ ! -L "$_mk_target" && -f "$_mk_target" && -s "$_mk_target" ]] || return 1
    read -r _mk_owner _mk_mode < <(stat -Lc '%u %a' -- "$_mk_target") || return 1
    [[ "$_mk_owner" == "$(id -u)" && "$_mk_mode" == 600 ]] || return 1
    IFS= read -r _mk_value < "$_mk_target" || return 1
    [[ "$_mk_value" =~ ^[0-9a-f]{64}$ ]]
  }

  if [[ -e "$_mk_target" || -L "$_mk_target" ]]; then
    _mk_validate_existing || exit 1
  else
    umask 077
    _mk_tmp="$(mktemp "$_mk_dir/.$_mk_base.XXXXXX")"
    trap 'rm -f -- "$_mk_tmp"' EXIT HUP INT TERM
    ${openssl}/bin/openssl rand -hex 32 > "$_mk_tmp" || exit 1
    chmod 0600 "$_mk_tmp" || exit 1
    _mk_validate_generated_file() {
      local _mk_value

      [[ -s "$_mk_tmp" ]] || return 1
      IFS= read -r _mk_value < "$_mk_tmp" || return 1
      [[ "$_mk_value" =~ ^[0-9a-f]{64}$ ]]
    }
    _mk_validate_generated_file || exit 1
    if ln -T -- "$_mk_tmp" "$_mk_target" 2>/dev/null; then
      rm -f -- "$_mk_tmp"
      _mk_tmp=""
      _mk_validate_existing || exit 1
    else
      rm -f -- "$_mk_tmp"
      _mk_tmp=""
      _mk_validate_existing || exit 1
    fi
    trap - EXIT HUP INT TERM
  fi
''
