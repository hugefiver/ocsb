# mkSandbox — Core sandbox builder
#
# Evaluates user config through the Nix module system, then generates
# a wrapped script that launches a sandbox backend with proper isolation.
#
# Usage:
#   mkSandbox { packages = [ pkgs.coreutils ]; workspace.strategy = "overlayfs"; }
#   mkSandbox ({ pkgs, ... }: { packages = [ pkgs.coreutils ]; })

{ pkgs, lib, mountAnchorHelper ? null, mountAnchorTestHookMode ? "none" }:

config:

let
  # Normalize config: support both attrset and function forms
  configModule =
    if builtins.isFunction config
    then config
    else { ... }: config;

  # Evaluate through the module system
  evaluated = lib.evalModules {
    modules = [
      ../modules
      configModule
    ];
    specialArgs = { inherit pkgs; };
  };

  cfg = evaluated.config;
  runtimeProcess = import ./runtime-process.nix { inherit pkgs lib; };
  mountAnchor =
    if mountAnchorHelper != null
    then mountAnchorHelper
    else pkgs.callPackage ../pkgs/mount-anchor.nix { };
  # Shell invariant (mutation): "${INHERITED_FD_ARGS[@]}" is forwarded unchanged.
  # Shell invariant (final): "${INHERITED_FD_ARGS[@]}" is forwarded unchanged.
  mountAnchorMutationTestHookArgs =
    assert lib.assertMsg
      (builtins.elem mountAnchorTestHookMode [ "none" "mutation" "final" "inherited" ])
      "mountAnchorTestHookMode must be one of: none, mutation, final, inherited";
    if mountAnchorTestHookMode == "mutation"
    then [
      "--test-before-mutation-ready-fd"
      "3"
      "--test-before-mutation-release-fd"
      "4"
    ]
    else if mountAnchorTestHookMode == "inherited"
    then [
      "--test-before-inherited-mutation-open-ready-fd"
      "20"
      "--test-before-inherited-mutation-open-release-fd"
      "21"
    ]
    else [ ];
  mountAnchorFinalTestHookArgs =
    if mountAnchorTestHookMode == "final"
    then [
      "--test-before-receipt-open-ready-fd"
      "5"
      "--test-before-receipt-open-release-fd"
      "6"
    ]
    else if mountAnchorTestHookMode == "inherited"
    then [
      "--test-before-inherited-final-open-ready-fd"
      "22"
      "--test-before-inherited-final-open-release-fd"
      "23"
    ]
    else [ ];

  # --- Package PATH ---
  # Always include bash; user packages are additive
  sandboxBin = pkgs.symlinkJoin {
    name = "${cfg.app.name}-sandbox-bin";
    paths = [ pkgs.bashInteractive ] ++ cfg.packages;
  };

  # --- Closure-only /nix/store ---
  # Instead of exposing the entire /nix/store, compute the transitive
  # closure of only the packages we need and mount just those paths.
  closureInfoDrv = pkgs.closureInfo {
    rootPaths =
      [ sandboxBin pkgs.bubblewrap pkgs.cacert mountAnchor ]
      ++ lib.optional (cfg.app.package != null) cfg.app.package
      ++ lib.optional (preExecScript != null) preExecScript
      ++ lib.optional (preExecScript == null) envCaptureScript
      ++ lib.optional (daemonSupervisor != null) daemonSupervisor
      ++ lib.optional (networkMode == "filtered" && !dualLayerEnabled) networkSetupScript
      ++ lib.optional dualLayerEnabled sandboxShell
      ;
  };

  # --- Mount path helpers ---
  # At Nix eval time, we can't know $HOME. Generate bash code that
  # resolves ~ and $HOME at runtime via helper functions.
  #
  # resolve_host_path: expands ~ to host $HOME (for --ro-bind source)
  # resolve_sandbox_path: expands ~ to /home/sandbox (for --ro-bind dest)

  mkMountArrayEntries = flag: paths:
    lib.concatMapStringsSep "\n    "
      (path: ''BWRAP_ARGS+=("${flag}" "$(resolve_host_path ${lib.escapeShellArg path})" "$(resolve_sandbox_path ${lib.escapeShellArg path})")'')
      paths;

  # Environment variable flags (these are static strings, safe at eval time)
  envSetenvEntries = lib.concatMapStringsSep "\n    "
    (name: ''BWRAP_ARGS+=(--setenv ${lib.escapeShellArg name} ${lib.escapeShellArg cfg.env.${name}})'')
    (builtins.attrNames cfg.env);

  # App binary to exec inside sandbox
  appExec =
    assert lib.assertMsg
      (cfg.app.package == null || cfg.app.binPath != "")
      "app.binPath must be set when app.package is specified (e.g. \"bin/opencode\")";
    if cfg.app.package != null
    then "${cfg.app.package}/${cfg.app.binPath}"
    else "${sandboxBin}/bin/bash";

  # Extra arguments passed to the app binary at startup.
  appArgs = lib.escapeShellArgs cfg.app.args;

  # Daemon supervisor — generated when app.daemon is non-empty.
  # Runs as PID 1 inside bwrap, managing daemon processes + foreground app.
  daemonSupervisor =
    if cfg.app.daemon == []
    then null
    else pkgs.writeShellScript "${cfg.app.name}-supervisor" ''
      set -euo pipefail

      _DAEMON_PIDS=()

      spawn_daemon() {
        local _cmd="$1"
        local _restart="$2"
        local _pid
        while true; do
          eval "$_cmd" &
          _pid=$!
          echo "[ocsb] daemon started (pid $_pid): $_cmd" >&2
          wait "$_pid" 2>/dev/null || true
          echo "[ocsb] daemon exited (pid $_pid, rc=$?), cmd: $_cmd" >&2
          [[ "$_restart" == "true" ]] || break
          ${pkgs.coreutils}/bin/sleep 1
        done
      }

      ${lib.concatMapStringsSep "\n      " (d: ''
      spawn_daemon ${lib.escapeShellArg d.command} ${lib.boolToString d.restart} &
      _DAEMON_PIDS+=($!)
      '') cfg.app.daemon}

      exec "$@"
    '';

  # PATH inside sandbox: include app's bin dir if a package is configured,
  # plus common Nix profile locations so `nix profile install` binaries are
  # immediately callable in interactive sessions.
  nixProfilePath = "/home/sandbox/.nix-profile/bin:/nix/var/nix/profiles/default/bin";
  sandboxPath =
    if cfg.app.package != null
    then "${cfg.app.package}/bin:${nixProfilePath}:/usr/bin"
    else "${nixProfilePath}:/usr/bin";

  attachEnvPath = "/tmp/ocsb-attach.env";

  captureAttachEnv = ''
      _OCSB_ATTACH_ENV=${lib.escapeShellArg attachEnvPath}
      (
        umask 077
        export -p > "$_OCSB_ATTACH_ENV.tmp"
        ${pkgs.coreutils}/bin/mv -f "$_OCSB_ATTACH_ENV.tmp" "$_OCSB_ATTACH_ENV"
      ) 2>/dev/null || true
  '';

  preExecScript =
    if cfg.app.preExecHook != ""
    then pkgs.writeShellScript "${cfg.app.name}-pre-exec" ''
      set -euo pipefail
      ${cfg.app.preExecHook}
      ${captureAttachEnv}
      exec "$@"
    ''
    else null;

  envCaptureScript = pkgs.writeShellScript "${cfg.app.name}-env-capture" ''
    set -euo pipefail
    ${captureAttachEnv}
    exec "$@"
  '';

  # --- Network mode ---
  # null → host network, true → filtered (slirp4netns + iptables), false → no network
  networkMode =
    if cfg.network.enable == true then "filtered"
    else if cfg.network.enable == false then "blocked"
    else "host";

  # --- Dual-layer mode (experimental) ---
  # When enabled: outer sandbox has host network, inner sandbox (per-command)
  # has full isolation (--unshare-all).  Overrides network.enable.
  dualLayerEnabled = cfg.experimental.dualLayer;

  defaultBackend = cfg.backend.type;

  podmanExtraArgs = lib.concatMapStringsSep " " lib.escapeShellArg cfg.backend.podman.extraArgs;
  nspawnExtraArgs = lib.concatMapStringsSep " " lib.escapeShellArg cfg.backend.systemdNspawn.extraArgs;

  # Custom resolv.conf for slirp4netns (points to its virtual DNS at 10.0.2.3)
  customResolvConf = pkgs.writeText "ocsb-resolv.conf" "nameserver 10.0.2.3\n";

   # Network setup script — runs INSIDE sandbox as first command before payload.
   # Attempts iptables-based filtering (best-effort: requires kernel support for
   # netfilter in user namespaces, which some kernels like WSL2 restrict).
   # Even without iptables, network isolation is provided by:
   #   - Network namespace isolation (--unshare-net)
   #   - slirp4netns userspace NAT (--disable-host-loopback)
   #   - Custom resolv.conf (DNS through slirp4netns only)
   networkSetupScript = pkgs.writeShellScript "${cfg.app.name}-net-setup" ''
      # Wait for slirp4netns to create tap0 (parent starts it after reading child PID).
      # Uses /proc/net/dev which is always available — no external tools needed.
      _TAP_WAIT=0
      while [ "$_TAP_WAIT" -lt 50 ] && ! ${pkgs.gnugrep}/bin/grep -q tap0 /proc/net/dev 2>/dev/null; do
        ${pkgs.coreutils}/bin/sleep 0.1
        _TAP_WAIT=$((_TAP_WAIT + 1))
      done
      if ! ${pkgs.gnugrep}/bin/grep -q tap0 /proc/net/dev 2>/dev/null; then
        echo "ocsb: warning: tap0 not found after 5s — network may be unavailable" >&2
      fi

      _IPTABLES=""
      if ${pkgs.iptables}/bin/iptables-legacy -L -n >/dev/null 2>&1; then
        _IPTABLES="${pkgs.iptables}/bin/iptables-legacy"
      elif ${pkgs.iptables}/bin/iptables -L -n >/dev/null 2>&1; then
        _IPTABLES="${pkgs.iptables}/bin/iptables"
      fi

      if [ -n "$_IPTABLES" ]; then
        "$_IPTABLES" -A OUTPUT -d 10.0.2.0/24 -j ACCEPT || true
        ${lib.concatMapStringsSep "\n        "
          (range: ''"$_IPTABLES" -A OUTPUT -d ${lib.escapeShellArg range} -j DROP || true'')
          cfg.network.blockedRanges}
        # Verify ALL blocked ranges were installed (fail closed)
        ${lib.optionalString (cfg.network.blockedRanges != []) ''
        _RULES_OK=1
        ${lib.concatMapStringsSep "\n        "
          (range: ''if ! "$_IPTABLES" -C OUTPUT -d ${lib.escapeShellArg range} -j DROP 2>/dev/null; then _RULES_OK=0; fi'')
          cfg.network.blockedRanges}
        if [ "$_RULES_OK" -ne 1 ]; then
          echo "ocsb: error: iptables available but not all firewall rules could be verified — aborting" >&2
          exit 1
        fi
        ''}
      else
        echo "ocsb: warning: iptables not available in this user namespace — private range blocking disabled" >&2
        echo "ocsb: network isolation still active (namespace + slirp4netns + disable-host-loopback)" >&2
      fi

      # Drop capabilities (defense-in-depth). uid 0 inside an unprivileged
      # userns has no host privileges, so no uid switch is needed (and
      # would fail anyway: only uid 0 is mapped in the bwrap userns).
      if ! ${pkgs.gnugrep}/bin/grep -q 'CapEff:.*0000000000000000' /proc/self/status 2>/dev/null || \
         ! ${pkgs.gnugrep}/bin/grep -q 'CapPrm:.*0000000000000000' /proc/self/status 2>/dev/null; then
        exec ${pkgs.util-linux}/bin/setpriv --no-new-privs --bounding-set=-all -- "$@"
      fi
      exec "$@"
    '';

  # --- Dual-layer: inner sandbox shell wrapper ---
  # Drop-in $SHELL replacement that wraps EVERY invocation in a nested bwrap
  # with --unshare-all (no network, isolated namespaces).
  # Only --version/--help pass through to real bash (for shell detection).
  # NOTE: -h is NOT help — it's bash's hashall option and MUST be sandboxed.
  # Only built when experimental.dualLayer = true.
  sandboxShell = pkgs.writeShellScript "${cfg.app.name}-sandbox-shell" ''
    # Pass-through queries for shell detection (opencode checks $SHELL --version)
    # Only long-form info flags that print and exit. No short flags — they
    # can combine with -c to execute arbitrary commands unsandboxed.
    case "''${1:-}" in
      --version|--help)
        exec ${sandboxBin}/bin/bash "$@"
        ;;
    esac

    # All other invocations are wrapped in inner bwrap (full isolation)
    _INNER_ARGS=(
      --unshare-all
      --die-with-parent
      --new-session
      --uid 0 --gid 0
      --dev /dev
      --proc /proc
      --tmpfs /tmp
      --tmpfs /run
      --tmpfs /home
      --dir /home/sandbox
    )
    # Mount each store path from the outer sandbox individually.
    # The outer sandbox only has closure paths mounted, so this
    # naturally restricts the inner sandbox to the same set.
    for _store_path in /nix/store/*; do
      _INNER_ARGS+=(--ro-bind "$_store_path" "$_store_path")
    done

    _INNER_ARGS+=(
      --ro-bind /usr/bin /usr/bin
      --symlink /usr/bin /bin
      --symlink usr/lib /lib
      --symlink usr/lib64 /lib64
      --bind ${lib.escapeShellArg cfg.workspace.sandboxDir} ${lib.escapeShellArg cfg.workspace.sandboxDir}
      --ro-bind-try /etc/passwd /etc/passwd
      --ro-bind-try /etc/group /etc/group
      --clearenv
    )

    # Keep the inner shell useful while preserving its --clearenv boundary.
    # Read NUL-delimited entries so spaces, equals signs, and newlines in values
    # survive without evaluation. Only shell-valid names become bwrap argv.
    while IFS= read -r -d "" _inner_env_entry; do
      [[ "$_inner_env_entry" == *=* ]] || continue
      _inner_env_name="''${_inner_env_entry%%=*}"
      _inner_env_value="''${_inner_env_entry#*=}"
      [[ "$_inner_env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      case "$_inner_env_name" in
        HOME|PATH|TERM|SSL_CERT_FILE|SANDBOX|OCSB_DUAL_LAYER)
          continue
          ;;
      esac
      _INNER_ARGS+=(--setenv "$_inner_env_name" "$_inner_env_value")
    done < <(${pkgs.coreutils}/bin/env -0)

    _INNER_ARGS+=(
      --setenv HOME /home/sandbox
      --setenv PATH ${sandboxPath}
      --setenv TERM xterm-256color
      --setenv SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      --setenv SANDBOX 1
      --setenv OCSB_DUAL_LAYER inner
      --chdir ${lib.escapeShellArg cfg.workspace.sandboxDir}
    )

    # Route by invocation form — all go through inner bwrap
    case "''${1:-}" in
      -c)
        shift
        exec ${pkgs.bubblewrap}/bin/bwrap "''${_INNER_ARGS[@]}" -- ${sandboxBin}/bin/bash -c "$@"
        ;;
      "")
        # Interactive shell (no args)
        exec ${pkgs.bubblewrap}/bin/bwrap "''${_INNER_ARGS[@]}" -- ${sandboxBin}/bin/bash
        ;;
      *)
        # All other forms: flags (-l, --login, -lc), scripts, etc.
        exec ${pkgs.bubblewrap}/bin/bwrap "''${_INNER_ARGS[@]}" -- ${sandboxBin}/bin/bash "$@"
        ;;
    esac
  '';

  # --- Launcher script ---
  launcher = pkgs.writeShellScript "${cfg.app.name}-launcher" ''
    set -euo pipefail

    ${runtimeProcess.shellHelpers}

    proc_comm() {
      local _pid="$1"
      [[ "$_pid" =~ ^[0-9]+$ ]] || return 0
      [[ -r "/proc/$_pid/comm" ]] || return 0
      local _comm
      IFS= read -r _comm < "/proc/$_pid/comm" || return 0
      printf '%s\n' "$_comm"
    }

    resolve_attach_init_pid() {
      _ATTACH_STALE=0
      _ATTACH_ERROR=""
      _RESOLVED_INIT_PID=""
      local _candidate_pid="$1"
      local _expected_start="''${2:-}"
      [[ "$_candidate_pid" =~ ^[0-9]+$ ]] || {
        _ATTACH_ERROR="ocsb: invalid attach PID: $_candidate_pid"
        _ATTACH_STALE=1
        return 1
      }
      if ! kill -0 "$_candidate_pid" 2>/dev/null; then
        _ATTACH_ERROR="ocsb: no live process at PID $_candidate_pid (stale pidfile?)"
        _ATTACH_STALE=1
        return 1
      fi

      local _candidate_comm
      _candidate_comm="$(proc_comm "$_candidate_pid")"
      if [[ "$_candidate_comm" != "bwrap" ]]; then
        _ATTACH_ERROR="ocsb: attach PID $_candidate_pid is not a bwrap process yet (comm=''${_candidate_comm:-unknown})"
        return 1
      fi

      if [[ -n "$_expected_start" ]]; then
        local _actual_start
        _actual_start="$(ocsb_proc_start_time "$_candidate_pid")"
        if [[ -z "$_actual_start" || "$_actual_start" != "$_expected_start" ]]; then
          _ATTACH_ERROR="ocsb: attach PID $_candidate_pid start time changed (stale pidfile?)"
          _ATTACH_STALE=1
          return 1
        fi
      fi

      local _child_pid _child_comm
      local -a _child_candidates=()
      local -a _init_candidates=()
      mapfile -t _child_candidates < <(${pkgs.procps}/bin/pgrep -P "$_candidate_pid" -x bwrap || true)
      for _child_pid in "''${_child_candidates[@]}"; do
        _child_comm="$(proc_comm "$_child_pid")"
        [[ "$_child_comm" == "bwrap" ]] && _init_candidates+=("$_child_pid")
      done

      if [[ ''${#_init_candidates[@]} -eq 1 ]]; then
        _RESOLVED_INIT_PID="''${_init_candidates[0]}"
        return 0
      fi
      if [[ ''${#_init_candidates[@]} -eq 0 ]]; then
        _ATTACH_ERROR="ocsb: bwrap PID $_candidate_pid has no sandbox-init child to attach to"
      else
        _ATTACH_ERROR="ocsb: bwrap PID $_candidate_pid has multiple sandbox-init children: ''${_init_candidates[*]}"
      fi
      return 1
    }

    maybe_attach() {
    # =========================================================
    # --attach: enter namespaces of the currently-running sandbox
    # of this same app. Bypasses every other launcher behavior (no
    # preExecHook, no service start, no fresh bwrap). Use this when
    # you need a shell inside the
    # SAME instance (e.g. to query a postgres that's already up).
    # =========================================================
    if [[ -n "$ATTACH_TARGET" ]]; then
      if ! ocsb_validate_process_record "$OCSB_PROCESS_RECORD" "$OCSB_INSTANCE"; then
        if [[ -n "''${OCSB_RECORD_LINE:-}" && "''${OCSB_RECORD_INSTANCE:-}" == "$OCSB_INSTANCE" ]]; then
          ocsb_remove_matching_process_record "$OCSB_PROCESS_RECORD" "$OCSB_RECORD_LINE" 2>/dev/null || true
        fi
        echo "ocsb: no valid running ${cfg.app.name} instance record at $OCSB_PROCESS_RECORD" >&2
        exit 1
      fi
      _BWRAP_PID="$OCSB_RECORD_PID"
      _BWRAP_START="$OCSB_RECORD_START"
      # bwrap forks the sandbox-init child (also named "bwrap"), which
      # holds the user/mount/pid/etc namespaces we want to enter.
      # In filtered-network mode, slirp4netns is ALSO a child of bwrap
      # (reparented when launcher exec'd into bwrap), but it lives in
      # host namespaces — entering its namespaces would EINVAL.
      _INIT_PID=""
      _ATTACH_TRIES=0
      while [[ $_ATTACH_TRIES -lt 20 ]]; do
        if resolve_attach_init_pid "$_BWRAP_PID" "$_BWRAP_START"; then
          _INIT_PID="$_RESOLVED_INIT_PID"
          break
        fi
        [[ "''${_ATTACH_STALE:-0}" -eq 1 ]] && break
        _ATTACH_TRIES=$((_ATTACH_TRIES + 1))
        ${pkgs.coreutils}/bin/sleep 0.1
      done
      if [[ -z "$_INIT_PID" ]]; then
        echo "''${_ATTACH_ERROR:-ocsb: unable to resolve sandbox-init bwrap process}" >&2
        if [[ "''${_ATTACH_STALE:-0}" -eq 1 ]]; then
          ocsb_remove_matching_process_record "$OCSB_PROCESS_RECORD" "$OCSB_RECORD_LINE" 2>/dev/null || true
        fi
        exit 1
      fi
      if [[ "$ATTACH_TARGET" != "auto" && "$ATTACH_TARGET" != "$_BWRAP_PID" && "$ATTACH_TARGET" != "$_INIT_PID" ]]; then
        echo "ocsb: attach PID $ATTACH_TARGET does not match the recorded bwrap or its unique sandbox-init child" >&2
        exit 1
      fi
      # Inner shell: prefer the payload environment captured inside the sandbox
      # (after bwrap --setenv and preExecHook). Fall back to PID 1 env only for
      # older running instances that predate /tmp/ocsb-attach.env.
      _INNER_SCRIPT='if [[ -r ${attachEnvPath} ]]; then
  source ${attachEnvPath} 2>/dev/null || true
else
  while IFS= read -r -d "" _line; do
  _k="''${_line%%=*}"
  _v="''${_line#*=}"
  [[ -n "$_k" && "$_k" != "_" ]] && export "$_k=$_v" 2>/dev/null || true
  done < /proc/1/environ
fi
cd /workspace 2>/dev/null || cd /home/sandbox 2>/dev/null || cd /
exec ${pkgs.bashInteractive}/bin/bash -i'
      _NSENTER_ARGS=(
        -t "$_INIT_PID"
        -U --preserve-credentials
        -m -p -i -u
        -r --wdns=/
        ${lib.optionalString (networkMode != "host" && !dualLayerEnabled) ''-n''}
      )
      exec ${pkgs.util-linux}/bin/nsenter \
        "''${_NSENTER_ARGS[@]}" \
        -- ${pkgs.coreutils}/bin/env -i \
          HOME=/home/sandbox \
          PATH=/usr/bin \
          TERM="''${TERM:-xterm-256color}" \
          ${pkgs.bashInteractive}/bin/bash -c "$_INNER_SCRIPT"
    fi
    }

    record_attach_process() {
      ocsb_write_process_record "$OCSB_PROCESS_RECORD" "$$" "$OCSB_INSTANCE"
    }

    BACKEND_TYPE=${lib.escapeShellArg defaultBackend}
    HOST_UID="$(${pkgs.coreutils}/bin/id -u)"
    HOST_GID="$(${pkgs.coreutils}/bin/id -g)"

    # =========================================================
    # Helper: resolve ~ in paths at runtime
    # =========================================================

    # For backend source (host side): ~ expands to real $HOME
    resolve_host_path() {
      local p="$1"
      if [[ "$p" == "~/"* ]]; then
        p="$HOME/''${p:2}"
      elif [[ "$p" == "~" ]]; then
        p="$HOME"
      fi
      echo "$p"
    }

    # For bwrap destination (sandbox side): ~ expands to /home/sandbox
    resolve_sandbox_path() {
      local p="$1"
      if [[ "$p" == "~/"* ]]; then
        p="/home/sandbox/''${p:2}"
      elif [[ "$p" == "~" ]]; then
        p="/home/sandbox"
      fi
      echo "$p"
    }

    # Built-in compatibility mounts are selected by ocsb rather than by the
    # caller.  NixOS commonly exposes them as root-owned symlinks (notably
    # /etc/resolv.conf and /etc/ssl).  Resolve those trusted aliases before
    # manifest capture; the helper still opens the resulting canonical path
    # with openat2 RESOLVE_NO_SYMLINKS and verifies its captured identity.
    resolve_builtin_host_path() {
      local _path="$1"
      local _resolved
      if [[ -e "$_path" ]]; then
        _resolved="$(${pkgs.coreutils}/bin/readlink -e -- "$_path")" || {
          echo "ocsb: unsafe host path: cannot resolve built-in source: $_path" >&2
          exit 1
        }
        [[ "$_resolved" == /* && ! -L "$_resolved" ]] || {
          echo "ocsb: unsafe host path: invalid built-in source target: $_path" >&2
          exit 1
        }
        printf '%s\n' "$_resolved"
      elif [[ -L "$_path" ]]; then
        echo "ocsb: unsafe host path: dangling built-in source: $_path" >&2
        exit 1
      else
        printf '%s\n' "$_path"
      fi
    }

    parse_inherited_fd_root_spec() {
      local _spec="$1" _canonical _fd_path _stat _dev _ino _kind _index
      local -a _fields=()

      if [[ "$_spec" == *$'\n'* || "$_spec" == *$'\r'* ]]; then
        echo "ocsb: invalid --ocsb-internal-fd-root: expected one TAB-separated line" >&2
        exit 1
      fi
      IFS=$'\t' read -r -a _fields <<< "$_spec"
      if [[ ''${#_fields[@]} -ne 7 || "''${_fields[0]}" != v1 ]]; then
        echo "ocsb: invalid --ocsb-internal-fd-root: expected seven TAB-separated fields" >&2
        exit 1
      fi
      case "''${_fields[1]}" in
        project|state-base|mount) ;;
        *) echo "ocsb: invalid --ocsb-internal-fd-root role: ''${_fields[1]}" >&2; exit 1 ;;
      esac
      if [[ "''${_fields[2]}" != /* || "''${_fields[2]}" == *$'\t'* ||
            "''${_fields[2]}" == *$'\n'* || "''${_fields[2]}" == *$'\r'* ]]; then
        echo "ocsb: invalid --ocsb-internal-fd-root display path" >&2
        exit 1
      fi
      _canonical="$(${pkgs.coreutils}/bin/realpath -e -- "''${_fields[2]}")" || {
        echo "ocsb: invalid --ocsb-internal-fd-root display path: ''${_fields[2]}" >&2
        exit 1
      }
      if [[ "$_canonical" != "''${_fields[2]}" ]]; then
        echo "ocsb: invalid --ocsb-internal-fd-root non-canonical display path: ''${_fields[2]}" >&2
        exit 1
      fi
      if [[ ! "''${_fields[3]}" =~ ^[0-9]+$ ||
            ! "''${_fields[3]}" =~ ^0*([3-9]|[1-9][0-9]+)$ ||
            ! "''${_fields[4]}" =~ ^[0-9]+$ || ! "''${_fields[5]}" =~ ^[0-9]+$ ]]; then
        echo "ocsb: invalid --ocsb-internal-fd-root descriptor identity" >&2
        exit 1
      fi
      case "''${_fields[6]}" in
        directory|regular) ;;
        *) echo "ocsb: invalid --ocsb-internal-fd-root type: ''${_fields[6]}" >&2; exit 1 ;;
      esac
      if [[ ( "''${_fields[1]}" == project || "''${_fields[1]}" == state-base ) &&
            "''${_fields[6]}" != directory ]]; then
        echo "ocsb: invalid --ocsb-internal-fd-root: project and state-base must be directories" >&2
        exit 1
      fi
      for ((_index = 0; _index < ''${#INHERITED_FD_DISPLAYS[@]}; _index++)); do
        if [[ "''${INHERITED_FD_DISPLAYS[$_index]}" == "''${_fields[2]}" ]]; then
          if [[ "''${INHERITED_FD_TYPES[$_index]}" != "''${_fields[6]}" ]]; then
            echo "ocsb: conflicting inherited descriptor types for display path: ''${_fields[2]}" >&2
          else
            echo "ocsb: duplicate inherited descriptor display path: ''${_fields[2]}" >&2
          fi
          exit 1
        fi
      done
      case "''${_fields[1]}" in
        project)
          [[ -z "$INHERITED_PROJECT_FD" ]] || { echo "ocsb: duplicate inherited project descriptor" >&2; exit 1; }
          ;;
        state-base)
          [[ -z "$INHERITED_STATE_BASE_FD" ]] || { echo "ocsb: duplicate inherited state-base descriptor" >&2; exit 1; }
          ;;
      esac

      _fd_path="/proc/self/fd/''${_fields[3]}"
      [[ -e "$_fd_path" ]] || {
        echo "ocsb: invalid --ocsb-internal-fd-root descriptor: ''${_fields[2]}" >&2
        exit 1
      }
      _stat="$(LC_ALL=C ${pkgs.coreutils}/bin/stat -L -c $'%d\t%i\t%F' -- "$_fd_path" 2>/dev/null)" || {
        echo "ocsb: invalid --ocsb-internal-fd-root descriptor: ''${_fields[2]}" >&2
        exit 1
      }
      IFS=$'\t' read -r _dev _ino _kind <<< "$_stat"
      if [[ "$_dev" != "''${_fields[4]}" || "$_ino" != "''${_fields[5]}" ||
            ( "''${_fields[6]}" == directory && "$_kind" != directory ) ||
            ( "''${_fields[6]}" == regular && "$_kind" != "regular file" && "$_kind" != "regular empty file" ) ]]; then
        echo "ocsb: invalid --ocsb-internal-fd-root descriptor identity: ''${_fields[2]}" >&2
        exit 1
      fi

      INHERITED_FD_ARGS+=(--inherited-fd-spec "$_spec")
      INHERITED_FD_ROLES+=("''${_fields[1]}")
      INHERITED_FD_DISPLAYS+=("''${_fields[2]}")
      INHERITED_FD_NUMBERS+=("''${_fields[3]}")
      INHERITED_FD_DEVS+=("''${_fields[4]}")
      INHERITED_FD_INOS+=("''${_fields[5]}")
      INHERITED_FD_TYPES+=("''${_fields[6]}")
      case "''${_fields[1]}" in
        project)
          INHERITED_PROJECT_FD="''${_fields[3]}"
          INHERITED_PROJECT_DISPLAY="''${_fields[2]}"
          INHERITED_PROJECT_DEV="''${_fields[4]}"
          INHERITED_PROJECT_INO="''${_fields[5]}"
          ;;
        state-base)
          INHERITED_STATE_BASE_FD="''${_fields[3]}"
          INHERITED_STATE_BASE_DISPLAY="''${_fields[2]}"
          ;;
      esac
    }

    select_inherited_source_access() {
      local _path="$1" _index _root _relative _candidate=-1 _candidate_length=0

      INHERITED_SOURCE_MATCHED=0
      INHERITED_SOURCE_ACCESS_PATH=""
      INHERITED_SOURCE_DEV=""
      INHERITED_SOURCE_INO=""
      INHERITED_SOURCE_TYPE=""
      INHERITED_SOURCE_ERROR=0
      for ((_index = 0; _index < ''${#INHERITED_FD_DISPLAYS[@]}; _index++)); do
        _root="''${INHERITED_FD_DISPLAYS[$_index]}"
        if [[ "$_root" == / ]]; then
          [[ "$_path" == /* ]] || continue
          _relative="''${_path#/}"
        elif [[ "$_path" == "$_root" ]]; then
          _relative=""
        elif [[ "$_path" == "$_root/"* ]]; then
          _relative="''${_path#"$_root/"}"
        else
          continue
        fi
        if [[ "''${INHERITED_FD_TYPES[$_index]}" == regular ]]; then
          if [[ -n "$_relative" ]]; then
            echo "ocsb: inherited regular root cannot contain descendants: $_root" >&2
            INHERITED_SOURCE_ERROR=1
            return
          fi
          _candidate=$_index
          _candidate_length=''${#_root}
        elif [[ $_candidate -lt 0 || "''${INHERITED_FD_TYPES[$_candidate]}" != regular && ''${#_root} -gt $_candidate_length ]]; then
          _candidate=$_index
          _candidate_length=''${#_root}
        fi
      done
      [[ $_candidate -ge 0 ]] || return 0

      _root="''${INHERITED_FD_DISPLAYS[$_candidate]}"
      if [[ "$_root" == / ]]; then
        _relative="''${_path#/}"
      elif [[ "$_path" == "$_root" ]]; then
        _relative=""
      else
        _relative="''${_path#"$_root/"}"
      fi
      INHERITED_SOURCE_MATCHED=1
      INHERITED_SOURCE_ACCESS_PATH="/proc/self/fd/''${INHERITED_FD_NUMBERS[$_candidate]}"
      if [[ -z "$_relative" ]]; then
        INHERITED_SOURCE_DEV="''${INHERITED_FD_DEVS[$_candidate]}"
        INHERITED_SOURCE_INO="''${INHERITED_FD_INOS[$_candidate]}"
        INHERITED_SOURCE_TYPE="''${INHERITED_FD_TYPES[$_candidate]}"
        return
      fi
      INHERITED_SOURCE_ACCESS_PATH+="/$_relative"
      local _stat _kind
      _stat="$(LC_ALL=C ${pkgs.coreutils}/bin/stat -L -c $'%d\t%i\t%F' -- "$INHERITED_SOURCE_ACCESS_PATH" 2>/dev/null)" || {
        echo "ocsb: unsafe host path: cannot derive inherited source: $_path" >&2
        INHERITED_SOURCE_ERROR=1
        return
      }
      IFS=$'\t' read -r INHERITED_SOURCE_DEV INHERITED_SOURCE_INO _kind <<< "$_stat"
      case "$_kind" in
        directory) INHERITED_SOURCE_TYPE=directory ;;
        "regular file"|"regular empty file") INHERITED_SOURCE_TYPE=regular ;;
        *)
          echo "ocsb: unsafe host path: unsupported inherited source type: $_path ($_kind)" >&2
          INHERITED_SOURCE_ERROR=1
          ;;
      esac
    }

    reset_mount_anchor_sources() {
      MOUNT_ANCHOR_TOKENS=()
      MOUNT_ANCHOR_PATHS=()
      MOUNT_ANCHOR_CONTAINMENT_ROOTS=()
      MOUNT_ANCHOR_DEVS=()
      MOUNT_ANCHOR_INOS=()
      MOUNT_ANCHOR_TYPES=()
      MOUNT_ANCHOR_REQUIREDNESS=()
    }

    register_mount_anchor_source() {
      local _path="$1"
      local _requiredness="$2"
      local _index="''${#MOUNT_ANCHOR_TOKENS[@]}"
      local _token="@OCSB_SOURCE_''${_index}@"
      local _dev=0 _ino=0 _type=directory _kind _stat

      if [[ "$_path" != /* || "$_path" == *$'\t'* || "$_path" == *$'\n'* || "$_path" == *$'\r'* ]]; then
        echo "ocsb: unsafe host path: source must be an absolute path without TAB or newline: $_path" >&2
        exit 1
      fi
      select_inherited_source_access "$_path"
      if [[ "$INHERITED_SOURCE_ERROR" -eq 1 ]]; then
        exit 1
      elif [[ "$INHERITED_SOURCE_MATCHED" -eq 1 ]]; then
        _dev="$INHERITED_SOURCE_DEV"
        _ino="$INHERITED_SOURCE_INO"
        _type="$INHERITED_SOURCE_TYPE"
      elif [[ -L "$_path" ]]; then
        echo "ocsb: unsafe host path: symlink source refused: $_path" >&2
        exit 1
      fi
      if [[ "$INHERITED_SOURCE_MATCHED" -eq 1 ]]; then
        :
      elif [[ -n "''${WORKSPACE_RECEIPT_SOURCE_PATH:-}" &&
            "$_path" == "$WORKSPACE_RECEIPT_SOURCE_PATH" ]]; then
        _dev="$WORKSPACE_RECEIPT_SOURCE_DEV"
        _ino="$WORKSPACE_RECEIPT_SOURCE_INO"
        _type=directory
      elif _stat="$(LC_ALL=C ${pkgs.coreutils}/bin/stat -L -c $'%d\t%i\t%F' -- "$_path" 2>/dev/null)"; then
        IFS=$'\t' read -r _dev _ino _kind <<< "$_stat"
        case "$_kind" in
          directory) _type=directory ;;
          "regular file"|"regular empty file") _type=regular ;;
          *)
            echo "ocsb: unsafe host path: unsupported source type: $_path ($_kind)" >&2
            exit 1
            ;;
        esac
      fi

      MOUNT_ANCHOR_TOKENS+=("$_token")
      MOUNT_ANCHOR_PATHS+=("$_path")
      MOUNT_ANCHOR_CONTAINMENT_ROOTS+=(/)
      MOUNT_ANCHOR_DEVS+=("$_dev")
      MOUNT_ANCHOR_INOS+=("$_ino")
      MOUNT_ANCHOR_TYPES+=("$_type")
      MOUNT_ANCHOR_REQUIREDNESS+=("$_requiredness")
      MOUNT_ANCHOR_REGISTERED_TOKEN="$_token"
    }

    tokenize_bwrap_mount_sources() {
      reset_mount_anchor_sources
      local _i=0 _flag _requiredness
      while [[ $_i -lt ''${#BWRAP_ARGS[@]} ]]; do
        _flag="''${BWRAP_ARGS[$_i]}"
        case "$_flag" in
          --bind|--ro-bind|--bind-try|--ro-bind-try)
            _requiredness=required
            [[ "$_flag" == --bind-try || "$_flag" == --ro-bind-try ]] && _requiredness=optional
            register_mount_anchor_source "''${BWRAP_ARGS[$((_i + 1))]}" "$_requiredness"
            BWRAP_ARGS[$((_i + 1))]="$MOUNT_ANCHOR_REGISTERED_TOKEN"
            _i=$((_i + 3))
            ;;
          --overlay-src)
            register_mount_anchor_source "''${BWRAP_ARGS[$((_i + 1))]}" required
            BWRAP_ARGS[$((_i + 1))]="$MOUNT_ANCHOR_REGISTERED_TOKEN"
            _i=$((_i + 2))
            ;;
          --overlay)
            register_mount_anchor_source "''${BWRAP_ARGS[$((_i + 1))]}" required
            BWRAP_ARGS[$((_i + 1))]="$MOUNT_ANCHOR_REGISTERED_TOKEN"
            register_mount_anchor_source "''${BWRAP_ARGS[$((_i + 2))]}" required
            BWRAP_ARGS[$((_i + 2))]="$MOUNT_ANCHOR_REGISTERED_TOKEN"
            _i=$((_i + 4))
            ;;
          --setenv|--symlink) _i=$((_i + 3)) ;;
          --uid|--gid|--dev|--proc|--tmpfs|--dir|--chdir) _i=$((_i + 2)) ;;
          *) _i=$((_i + 1)) ;;
        esac
      done
    }

    build_mount_anchor_helper_args() {
      local _backend="$1"
      local _namespace="$2"
      local _argv_name="$3"
      local -n _backend_argv="$_argv_name"
      local _source_index _argv_index _occurrences _replacement_index
      local _drop_start _drop_count _spec _value _token

      MOUNT_ANCHOR_ARGS=(
        --backend "$_backend"
        --namespace "$_namespace"
        --host-uid "$HOST_UID"
        --host-gid "$HOST_GID"
        --anchor-root "$OCSB_RUNTIME_DIR"
        "''${INHERITED_FD_ARGS[@]}"
      )
      ${lib.optionalString (mountAnchorFinalTestHookArgs != [ ]) ''
      MOUNT_ANCHOR_ARGS+=(${lib.escapeShellArgs mountAnchorFinalTestHookArgs})
      ''}
      MOUNT_ANCHOR_ARGS+=(
        --workspace-receipt "$WORKSPACE_RECEIPT"
        --workspace-nonce "$WORKSPACE_NONCE"
        --workspace-project "$PROJECT_DIR"
        --workspace-base "$OCSB_BASE_DIR"
        --workspace-name "$WORKSPACE_NAME"
      )

      for ((_source_index = 0; _source_index < ''${#MOUNT_ANCHOR_TOKENS[@]}; _source_index++)); do
        _token="''${MOUNT_ANCHOR_TOKENS[$_source_index]}"
        _occurrences=0
        _replacement_index=-1
        for ((_argv_index = 0; _argv_index < ''${#_backend_argv[@]}; _argv_index++)); do
          _value="''${_backend_argv[$_argv_index]}"
          if [[ "$_value" == *"$_token"* ]]; then
            _occurrences=$((_occurrences + 1))
            _replacement_index=$_argv_index
          fi
        done
        if [[ $_occurrences -ne 1 ]]; then
          echo "ocsb: internal error: anchor token $_token occurs $_occurrences times in backend argv" >&2
          exit 1
        fi

        _drop_start=0
        _drop_count=0
        if [[ "''${MOUNT_ANCHOR_REQUIREDNESS[$_source_index]}" == optional ]]; then
          case "$_backend" in
            bubblewrap)
              _drop_start=$((_replacement_index - 1))
              _drop_count=3
              ;;
            podman)
              _drop_start=$((_replacement_index - 1))
              _drop_count=2
              ;;
            systemd-nspawn)
              _drop_start=$_replacement_index
              _drop_count=1
              ;;
          esac
        fi
        printf -v _spec '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
          "$_token" \
          "''${MOUNT_ANCHOR_PATHS[$_source_index]}" \
          "''${MOUNT_ANCHOR_CONTAINMENT_ROOTS[$_source_index]}" \
          "''${MOUNT_ANCHOR_DEVS[$_source_index]}" \
          "''${MOUNT_ANCHOR_INOS[$_source_index]}" \
          "''${MOUNT_ANCHOR_TYPES[$_source_index]}" \
          "''${MOUNT_ANCHOR_REQUIREDNESS[$_source_index]}" \
          "$_drop_start" \
          "$_drop_count"
        MOUNT_ANCHOR_ARGS+=(--source-spec "$_spec" --replace "$_replacement_index:$_token")
      done
    }

    chmod_tree_dirs_writable() {
      local p="$1"
      [[ -d "$p" ]] || return 0
      ${pkgs.findutils}/bin/find "$p" -type d -exec ${pkgs.coreutils}/bin/chmod u+w {} + 2>/dev/null || true
    }

    append_container_mount_from_bwrap_flag() {
      local _flag="$1"
      local _src="$2"
      local _dst="$3"
      local _mode="rw"
      [[ "$_flag" == "--ro-bind" || "$_flag" == "--ro-bind-try" ]] && _mode="ro"
      CONTAINER_MOUNT_SRCS+=("$_src")
      CONTAINER_MOUNT_DSTS+=("$_dst")
      CONTAINER_MOUNT_MODES+=("$_mode")
    }

    append_container_env_from_bwrap_flag() {
      CONTAINER_ENV_NAMES+=("$1")
      CONTAINER_ENV_VALUES+=("$2")
    }

    prepare_container_rootfs() {
      local _state_real _state_owner _state_mode _rootfs_owner

      CONTAINER_ROOTFS="$OVERLAY_STATE_DIR/rootfs"
      CONTAINER_ROOTFS_ACCESS="$OVERLAY_STATE_ACCESS_DIR/rootfs"

      # This rebuild intentionally happens while the per-workspace lock (FD 9)
      # is held.  The state directory and its canonical child must be safe
      # before making a recursive, non-following deletion.
      if ! { : >&9; }; then
        echo "ocsb: container rootfs preparation requires the workspace lock on FD 9" >&2
        exit 1
      fi
      _state_real="$(${pkgs.coreutils}/bin/realpath -e -- "$OVERLAY_STATE_ACCESS_DIR")" || {
        echo "ocsb: unsafe container rootfs state directory: $OVERLAY_STATE_DIR" >&2
        exit 1
      }
      if [[ "$_state_real" != "$OVERLAY_STATE_ACCESS_DIR" || -L "$OVERLAY_STATE_ACCESS_DIR" ||
            ! -d "$OVERLAY_STATE_ACCESS_DIR" || "$CONTAINER_ROOTFS_ACCESS" != "$_state_real/rootfs" ]]; then
        echo "ocsb: unsafe container rootfs state path: $OVERLAY_STATE_DIR" >&2
        exit 1
      fi
      read -r _state_owner _state_mode < <(${pkgs.coreutils}/bin/stat -c '%u %a' -- "$OVERLAY_STATE_ACCESS_DIR") || {
        echo "ocsb: cannot stat container rootfs state directory: $OVERLAY_STATE_DIR" >&2
        exit 1
      }
      if [[ "$_state_owner" != "$HOST_UID" || "$_state_mode" != 700 ]]; then
        echo "ocsb: unsafe container rootfs state directory: $OVERLAY_STATE_DIR must be a current-UID mode 0700 directory" >&2
        exit 1
      fi

      if [[ -e "$CONTAINER_ROOTFS_ACCESS" || -L "$CONTAINER_ROOTFS_ACCESS" ]]; then
        if [[ -L "$CONTAINER_ROOTFS_ACCESS" || ! -d "$CONTAINER_ROOTFS_ACCESS" ]]; then
          echo "ocsb: unsafe container rootfs path: $CONTAINER_ROOTFS is not a non-symlink directory" >&2
          exit 1
        fi
        _rootfs_owner="$(${pkgs.coreutils}/bin/stat -c %u -- "$CONTAINER_ROOTFS_ACCESS")" || {
          echo "ocsb: cannot stat container rootfs path: $CONTAINER_ROOTFS" >&2
          exit 1
        }
        if [[ "$_rootfs_owner" != "$HOST_UID" ]]; then
          echo "ocsb: unsafe container rootfs path: $CONTAINER_ROOTFS is not owned by the current UID" >&2
          exit 1
        fi
        if ! ${pkgs.findutils}/bin/find "$CONTAINER_ROOTFS_ACCESS" -xdev -type d ! -perm -u+w -exec ${pkgs.coreutils}/bin/chmod u+w -- {} +; then
          echo "ocsb: cannot make container rootfs directories writable: $CONTAINER_ROOTFS" >&2
          exit 1
        fi
        if ! ${pkgs.coreutils}/bin/rm -rf --one-file-system -- "$CONTAINER_ROOTFS_ACCESS"; then
          echo "ocsb: cannot remove container rootfs: $CONTAINER_ROOTFS" >&2
          exit 1
        fi
        if [[ -e "$CONTAINER_ROOTFS_ACCESS" || -L "$CONTAINER_ROOTFS_ACCESS" ]]; then
          echo "ocsb: container rootfs remains after removal: $CONTAINER_ROOTFS" >&2
          exit 1
        fi
      fi

      (umask 077; ${pkgs.coreutils}/bin/install -d -m 0700 -- "$CONTAINER_ROOTFS_ACCESS")
      ${pkgs.coreutils}/bin/mkdir -p \
        "$CONTAINER_ROOTFS_ACCESS/usr/bin" \
        "$CONTAINER_ROOTFS_ACCESS/usr/lib" \
        "$CONTAINER_ROOTFS_ACCESS/usr/lib64" \
        "$CONTAINER_ROOTFS_ACCESS/nix/store" \
        "$CONTAINER_ROOTFS_ACCESS/nix/var/nix" \
        "$CONTAINER_ROOTFS_ACCESS/workspace" \
        "$CONTAINER_ROOTFS_ACCESS/home/sandbox/.config" \
        "$CONTAINER_ROOTFS_ACCESS/home/sandbox/.local" \
        "$CONTAINER_ROOTFS_ACCESS/tmp" \
        "$CONTAINER_ROOTFS_ACCESS/run" \
        "$CONTAINER_ROOTFS_ACCESS/var/lib/postgresql" \
        "$CONTAINER_ROOTFS_ACCESS/etc"
      ${pkgs.coreutils}/bin/chmod 1777 -- "$CONTAINER_ROOTFS_ACCESS/tmp"
      ${pkgs.coreutils}/bin/ln -s usr/bin "$CONTAINER_ROOTFS_ACCESS/bin"
      ${pkgs.coreutils}/bin/ln -s usr/lib "$CONTAINER_ROOTFS_ACCESS/lib"
      ${pkgs.coreutils}/bin/ln -s usr/lib64 "$CONTAINER_ROOTFS_ACCESS/lib64"
    }

    build_container_plan_from_bwrap_args() {
      CONTAINER_MOUNT_SRCS=()
      CONTAINER_MOUNT_DSTS=()
      CONTAINER_MOUNT_MODES=()
      CONTAINER_ENV_NAMES=()
      CONTAINER_ENV_VALUES=()
      CONTAINER_WORKDIR="/workspace"

      local _i=0
      while [[ $_i -lt ''${#BWRAP_ARGS[@]} ]]; do
        case "''${BWRAP_ARGS[$_i]}" in
          --bind|--ro-bind|--bind-try|--ro-bind-try)
            append_container_mount_from_bwrap_flag "''${BWRAP_ARGS[$_i]}" "''${BWRAP_ARGS[$((_i + 1))]}" "''${BWRAP_ARGS[$((_i + 2))]}"
            _i=$((_i + 3))
            ;;
          --setenv)
            append_container_env_from_bwrap_flag "''${BWRAP_ARGS[$((_i + 1))]}" "''${BWRAP_ARGS[$((_i + 2))]}"
            _i=$((_i + 3))
            ;;
          --chdir)
            CONTAINER_WORKDIR="''${BWRAP_ARGS[$((_i + 1))]}"
            _i=$((_i + 2))
            ;;
          --overlay-src|--overlay)
            echo "ocsb: backend '$BACKEND_TYPE' does not support overlayfs mounts; use bubblewrap for workspace.strategy=overlayfs or --overlay-mount" >&2
            exit 1
            ;;
          --uid|--gid)
            _i=$((_i + 2))
            ;;
          --unshare-all|--share-net|--die-with-parent|--new-session|--clearenv|--dev|--proc|--tmpfs|--dir|--symlink)
            case "''${BWRAP_ARGS[$_i]}" in
              --tmpfs|--dir) _i=$((_i + 2)) ;;
              --dev|--proc) _i=$((_i + 2)) ;;
              --symlink) _i=$((_i + 3)) ;;
              *) _i=$((_i + 1)) ;;
            esac
            ;;
          *)
            _i=$((_i + 1))
            ;;
        esac
      done
    }

    append_podman_mount_args() {
      local _idx=0
      while [[ $_idx -lt ''${#CONTAINER_MOUNT_SRCS[@]} ]]; do
        PODMAN_ARGS+=(--volume "''${CONTAINER_MOUNT_SRCS[$_idx]}:''${CONTAINER_MOUNT_DSTS[$_idx]}:''${CONTAINER_MOUNT_MODES[$_idx]}")
        _idx=$((_idx + 1))
      done
    }

    append_podman_env_args() {
      local _idx=0
      while [[ $_idx -lt ''${#CONTAINER_ENV_NAMES[@]} ]]; do
        PODMAN_ARGS+=(--env "''${CONTAINER_ENV_NAMES[$_idx]}=''${CONTAINER_ENV_VALUES[$_idx]}")
        _idx=$((_idx + 1))
      done
    }

    append_nspawn_mount_args() {
      local _idx=0
      while [[ $_idx -lt ''${#CONTAINER_MOUNT_SRCS[@]} ]]; do
        if [[ "''${CONTAINER_MOUNT_MODES[$_idx]}" == "ro" ]]; then
          NSPAWN_ARGS+=(--bind-ro="''${CONTAINER_MOUNT_SRCS[$_idx]}:''${CONTAINER_MOUNT_DSTS[$_idx]}")
        else
          NSPAWN_ARGS+=(--bind="''${CONTAINER_MOUNT_SRCS[$_idx]}:''${CONTAINER_MOUNT_DSTS[$_idx]}")
        fi
        _idx=$((_idx + 1))
      done
    }

    append_nspawn_env_args() {
      local _idx=0
      while [[ $_idx -lt ''${#CONTAINER_ENV_NAMES[@]} ]]; do
        NSPAWN_ARGS+=(--setenv="''${CONTAINER_ENV_NAMES[$_idx]}=''${CONTAINER_ENV_VALUES[$_idx]}")
        _idx=$((_idx + 1))
      done
    }

    build_git_metadata_flags() {
      # =========================================================
      # Git metadata: safe discovery via git rev-parse
      # =========================================================
      # Use git rev-parse instead of manual .git file parsing to avoid
      # mounting arbitrary host paths from crafted .git files.
      # Unset GIT_* env vars to prevent host environment contamination.
      GIT_METADATA_FLAGS=()

      case "$WORKSPACE_STRATEGY" in
        overlayfs|direct) _GIT_CHECK_SRC="$PROJECT_ACCESS_DIR" ;;
        btrfs) _GIT_CHECK_SRC="''${BTRFS_SNAP_ACCESS:-}" ;;
        git-worktree) _GIT_CHECK_SRC="''${GWT_DIR_ACCESS:-}" ;;
        *) _GIT_CHECK_SRC="" ;;
      esac

      if [[ -n "$_GIT_CHECK_SRC" ]]; then
        _GITDIR_PATH="$(${pkgs.coreutils}/bin/env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
          ${pkgs.git}/bin/git -C "$_GIT_CHECK_SRC" rev-parse --absolute-git-dir 2>/dev/null)" || _GITDIR_PATH=""

        if [[ -n "$_GITDIR_PATH" ]] && [[ -d "$_GITDIR_PATH" ]]; then
          if [[ -n "$INHERITED_PROJECT_FD" ]]; then
            case "$_GITDIR_PATH" in
              "$PROJECT_ACCESS_DIR") _GITDIR_REAL="$PROJECT_DIR" ;;
              "$PROJECT_ACCESS_DIR"/*) _GITDIR_REAL="$PROJECT_DIR''${_GITDIR_PATH#"$PROJECT_ACCESS_DIR"}" ;;
              *)
                echo "ocsb: warning: git metadata path escapes project root, skipping: $_GITDIR_PATH" >&2
                return
                ;;
            esac
          else
            _GITDIR_REAL="$(${pkgs.coreutils}/bin/realpath -m "$_GITDIR_PATH")"
          fi
          # Security: constrain git metadata to project root boundary
          if [[ "$_GITDIR_REAL" != "$PROJECT_DIR"/* ]] && [[ "$_GITDIR_REAL" != "$PROJECT_DIR" ]]; then
            echo "ocsb: warning: git metadata path escapes project root, skipping: $_GITDIR_PATH" >&2
          else
            _GIT_BIND="--ro-bind"
            [[ "$WORKSPACE_STRATEGY" == "git-worktree" ]] && _GIT_BIND="--bind"

            # Use canonical path as bind source to prevent TOCTOU symlink-swap attacks
            GIT_METADATA_FLAGS+=("$_GIT_BIND" "$_GITDIR_REAL" "$_GITDIR_REAL")

            # Mount common dir if different from git dir (linked worktrees)
            _COMMONDIR_PATH="$(${pkgs.coreutils}/bin/env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
              ${pkgs.git}/bin/git -C "$_GIT_CHECK_SRC" rev-parse --git-common-dir 2>/dev/null)" || _COMMONDIR_PATH=""
            if [[ -n "$_COMMONDIR_PATH" ]] && [[ "$_COMMONDIR_PATH" != /* ]]; then
              _COMMONDIR_PATH="$(${pkgs.coreutils}/bin/realpath -m "$_GITDIR_PATH/$_COMMONDIR_PATH")"
            fi
            if [[ -n "$_COMMONDIR_PATH" ]] && [[ -d "$_COMMONDIR_PATH" ]] && [[ "$_COMMONDIR_PATH" != "$_GITDIR_PATH" ]]; then
              if [[ -n "$INHERITED_PROJECT_FD" ]]; then
                case "$_COMMONDIR_PATH" in
                  "$PROJECT_ACCESS_DIR") _COMMONDIR_REAL="$PROJECT_DIR" ;;
                  "$PROJECT_ACCESS_DIR"/*) _COMMONDIR_REAL="$PROJECT_DIR''${_COMMONDIR_PATH#"$PROJECT_ACCESS_DIR"}" ;;
                  *)
                    echo "ocsb: warning: git common-dir escapes project root, skipping: $_COMMONDIR_PATH" >&2
                    _COMMONDIR_REAL=""
                    ;;
                esac
              else
                _COMMONDIR_REAL="$(${pkgs.coreutils}/bin/realpath -m "$_COMMONDIR_PATH")"
              fi
              if [[ -n "$_COMMONDIR_REAL" ]] && [[ "$_COMMONDIR_REAL" != "$PROJECT_DIR"/* ]] && [[ "$_COMMONDIR_REAL" != "$PROJECT_DIR" ]]; then
                echo "ocsb: warning: git common-dir escapes project root, skipping: $_COMMONDIR_PATH" >&2
              elif [[ -n "$_COMMONDIR_REAL" ]]; then
                # Use canonical path as bind source to prevent TOCTOU symlink-swap attacks
                GIT_METADATA_FLAGS+=("$_GIT_BIND" "$_COMMONDIR_REAL" "$_COMMONDIR_REAL")
              fi
            fi
          fi
        fi
      fi
    }

    # Verify that every store path in the closure exists inside the chroot.
    # Returns 0 if all paths present, 1 if any are missing.
    # Prints missing paths to stderr for diagnostics.
    verify_chroot_store() {
      local _chroot_root="$1"
      local _store_paths_file="$2"
      local _missing=0
      local _path

      while IFS= read -r _path; do
        if [[ ! -e "$_chroot_root$_path" ]]; then
          echo "ocsb: warning: chroot store path missing: $_path" >&2
          _missing=1
        fi
      done < "$_store_paths_file"

      return $_missing
    }

    append_nix_store_args() {
      # /nix/store layout — see modules/experimental.nix nixStoreMode for tradeoffs.
      ${if cfg.experimental.nixStoreMode == "chroot" then ''
      # Chroot store: relocated, writable nix store populated by hard-link
      # preseed when possible, with `nix copy` as the correctness fallback.
      # Sandbox sees a real /nix/store with cache-compatible prefix; can
      # `nix profile add nixpkgs#foo` and persist pkgs per-workspace.
      _CHROOT_STATE_DIR="$OVERLAY_STATE_ACCESS_DIR/chroot"
      _CHROOT_STATE_DISPLAY_DIR="$OVERLAY_STATE_DIR/chroot"
      _CHROOT_ROOT="$_CHROOT_STATE_DIR/merged"
      _CHROOT_MARKER="$_CHROOT_STATE_DIR/.source"
      _CHROOT_SRC="${closureInfoDrv}"
      ${pkgs.coreutils}/bin/mkdir -p "$_CHROOT_STATE_DIR"
      if [[ -d "$_CHROOT_STATE_DIR/nix" && ! -d "$_CHROOT_ROOT/nix" ]]; then
        echo "ocsb: migrating legacy chroot layout at $_CHROOT_STATE_DIR" >&2
        chmod_tree_dirs_writable "$_CHROOT_STATE_DIR"
        ${pkgs.coreutils}/bin/rm -rf "$_CHROOT_STATE_DIR/nix" "$_CHROOT_STATE_DIR/.chroot-source"
      fi
      ${pkgs.coreutils}/bin/mkdir -p "$_CHROOT_ROOT/nix/store" "$_CHROOT_ROOT/nix/var/nix"
      if [[ ! -f "$_CHROOT_MARKER" ]] || [[ "$(${pkgs.coreutils}/bin/cat "$_CHROOT_MARKER" 2>/dev/null)" != "$_CHROOT_SRC" ]]; then
        echo "ocsb: populating chroot nix store at $_CHROOT_ROOT (first run / closure changed; may take a while)..." >&2
        mapfile -t _CHROOT_PATHS < "$_CHROOT_SRC/store-paths"

        _CHROOT_PRESEEDED=0
        _CHROOT_DB_DUMP="$_CHROOT_STATE_DIR/.valid-paths.dump"
        ${pkgs.coreutils}/bin/rm -f "$_CHROOT_DB_DUMP"
        if ${pkgs.coreutils}/bin/cp -al "''${_CHROOT_PATHS[@]}" "$_CHROOT_ROOT/nix/store/" 2>/dev/null && \
           ${pkgs.nix}/bin/nix-store --dump-db "''${_CHROOT_PATHS[@]}" > "$_CHROOT_DB_DUMP" && \
           ${pkgs.nix}/bin/nix-store --store "local?root=$_CHROOT_ROOT" --load-db < "$_CHROOT_DB_DUMP"; then
          _CHROOT_PRESEEDED=1
          echo "ocsb: chroot nix store preseeded with hard links" >&2
        else
          echo "ocsb: hard-link preseed unavailable; falling back to nix copy" >&2
          chmod_tree_dirs_writable "$_CHROOT_ROOT/nix/store"
          chmod_tree_dirs_writable "$_CHROOT_ROOT/nix/var/nix"
          while IFS= read -r _CHROOT_PATH; do
            ${pkgs.coreutils}/bin/rm -rf "$_CHROOT_ROOT$_CHROOT_PATH"
          done < "$_CHROOT_SRC/store-paths"
          ${pkgs.coreutils}/bin/rm -rf "$_CHROOT_ROOT/nix/var/nix/db"
          ${pkgs.coreutils}/bin/mkdir -p "$_CHROOT_ROOT/nix/store" "$_CHROOT_ROOT/nix/var/nix"
        fi
        ${pkgs.coreutils}/bin/rm -f "$_CHROOT_DB_DUMP"

        if [[ "$_CHROOT_PRESEEDED" -ne 1 ]] && ! ${pkgs.nix}/bin/nix --extra-experimental-features "nix-command" copy \
            --no-check-sigs --offline \
            --to "local?root=$_CHROOT_ROOT" \
            "''${_CHROOT_PATHS[@]}" >&2; then
          echo "ocsb: error: nix copy into chroot store failed" >&2
          exit 1
        fi

        # Verify every store path from the closure actually exists in the chroot.
        # Catches partial cp -al or nix copy failures that would otherwise leave
        # the chroot incomplete but marked as ready.
        if ! verify_chroot_store "$_CHROOT_ROOT" "$_CHROOT_SRC/store-paths"; then
          echo "ocsb: error: chroot store is incomplete after population; refusing to continue" >&2
          echo "ocsb:   try --overwrite to rebuild the workspace, or remove $OVERLAY_STATE_DIR/chroot manually" >&2
          exit 1
        fi

        echo "$_CHROOT_SRC" > "$_CHROOT_MARKER"
        echo "ocsb: chroot nix store ready" >&2
      else
        # Marker matches — but verify the chroot is actually intact.
        # Handles the edge case where the chroot was populated but later
        # corrupted (e.g. manual deletion, filesystem issues) or the
        # initial population partially failed without being caught.
        if ! verify_chroot_store "$_CHROOT_ROOT" "$_CHROOT_SRC/store-paths"; then
          echo "ocsb: chroot store has missing paths; repairing from host..." >&2
          local _mpath
          while IFS= read -r _mpath; do
            if [[ ! -e "$_CHROOT_ROOT$_mpath" ]] && [[ -e "$_mpath" ]]; then
              ${pkgs.coreutils}/bin/cp -a "$_mpath" "$_CHROOT_ROOT/nix/store/" 2>/dev/null || \
                ${pkgs.coreutils}/bin/cp -r "$_mpath" "$_CHROOT_ROOT/nix/store/" 2>/dev/null || {
                echo "ocsb: error: failed to copy missing store path $_mpath into chroot" >&2
                exit 1
              }
            fi
          done < "$_CHROOT_SRC/store-paths"
          if ! verify_chroot_store "$_CHROOT_ROOT" "$_CHROOT_SRC/store-paths"; then
            echo "ocsb: error: chroot store still incomplete after repair; host store paths may be missing (nix gc?)" >&2
            exit 1
          fi
          echo "ocsb: chroot store repaired" >&2
        fi
      fi

      # Rebuild gcroots for the current closure so that `nix gc` inside the
      # sandbox cannot collect ocsb's base dependencies (supervisor, bash,
      # bwrap, etc.).  All closure gcroots live under a single directory that
      # is wiped and rebuilt on every launch — this ensures stale closure
      # paths from previous builds become reclaimable by `nix gc`.
      _GCROOTS_DIR="$_CHROOT_ROOT/nix/var/nix/gcroots/ocsb-closure"
      ${pkgs.coreutils}/bin/rm -rf "$_GCROOTS_DIR"
      ${pkgs.coreutils}/bin/mkdir -p "$_GCROOTS_DIR"
      while IFS= read -r _gcpath; do
        ${pkgs.coreutils}/bin/ln -s "$_gcpath" "$_GCROOTS_DIR/"
      done < "$_CHROOT_SRC/store-paths"
      BWRAP_ARGS+=(
        --bind "$_CHROOT_STATE_DISPLAY_DIR/merged/nix/store" /nix/store
        --bind "$_CHROOT_STATE_DISPLAY_DIR/merged/nix/var/nix" /nix/var/nix
      )
      '' else if cfg.experimental.nixStoreMode == "host-daemon" then ''
      # Host daemon store: expose host /nix/store read-only and delegate all
      # mutations to the host nix-daemon socket. This is intentionally opt-in:
      # it has the best performance but the weakest store isolation.
      if [[ ! -S /nix/var/nix/daemon-socket/socket ]]; then
        echo "ocsb: error: nixStoreMode=host-daemon requires /nix/var/nix/daemon-socket/socket" >&2
        exit 1
      fi
      BWRAP_ARGS+=(
        --ro-bind /nix/store /nix/store
        --ro-bind /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket
      )
      echo "ocsb: host nix-daemon mode enabled (/nix/store read-only, writes via daemon)" >&2
      '' else ''
      # Closure-only /nix/store mounts: mount each store path individually,
      # read-only. Smallest attack surface; cannot install pkgs in-sandbox.
      while IFS= read -r storePath; do
        BWRAP_ARGS+=(--ro-bind "$storePath" "$storePath")
      done < ${closureInfoDrv}/store-paths
      ''}
    }

    trim_ascii_whitespace() {
      local _v="$1"
      _v="''${_v#"''${_v%%[![:space:]]*}"}"
      _v="''${_v%"''${_v##*[![:space:]]}"}"
      printf '%s' "$_v"
    }

    append_forwarded_host_env_args() {
      local _forward_raw="''${OCSB_FORWARD_ENV:-}"
      [[ -n "$_forward_raw" ]] || return 0

      local _entry _name
      local -A _forward_seen=()
      IFS=',' read -r -a _forward_entries <<< "$_forward_raw"
      for _entry in "''${_forward_entries[@]}"; do
        _name="$(trim_ascii_whitespace "$_entry")"
        [[ -n "$_name" ]] || continue

        if [[ ! "$_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          echo "ocsb: warning: skipping invalid OCSB_FORWARD_ENV entry: $_name" >&2
          continue
        fi

        if [[ -n "''${_forward_seen[$_name]:-}" ]]; then
          continue
        fi
        _forward_seen[$_name]=1

        if [[ -n "''${!_name+x}" ]]; then
          BWRAP_ARGS+=(--setenv "$_name" "''${!_name}")
        fi
      done
    }

    append_runtime_env_args() {
      local _idx=0
      while [[ $_idx -lt ''${#RUNTIME_ENV_NAMES[@]} ]]; do
        BWRAP_ARGS+=(--setenv "''${RUNTIME_ENV_NAMES[$_idx]}" "''${RUNTIME_ENV_VALUES[$_idx]}")
        _idx=$((_idx + 1))
      done
    }

    append_environment_args() {
      BWRAP_ARGS+=(
        --setenv HOME /home/sandbox
        --setenv PATH ${sandboxPath}
        --setenv TERM "''${TERM:-xterm-256color}"
        --setenv SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        --setenv SANDBOX 1
        --setenv OCSB_WORKSPACE "$WORKSPACE_NAME"
        --setenv OCSB_STRATEGY "$WORKSPACE_STRATEGY"
        --setenv OCSB_NETWORK "${if dualLayerEnabled then "dual-layer" else networkMode}"
        --setenv OCSB_STATE_DIR "$OVERLAY_STATE_DIR"
        --setenv OCSB_HOST_UID "$HOST_UID"
        --setenv OCSB_HOST_GID "$HOST_GID"
        ${lib.optionalString dualLayerEnabled ''--setenv SHELL "${sandboxShell}"''}
        ${lib.optionalString dualLayerEnabled ''--setenv OCSB_DUAL_LAYER outer''}
      )
      ${envSetenvEntries}
      append_forwarded_host_env_args
      append_runtime_env_args
      ${lib.optionalString (cfg.experimental.nixStoreMode == "host-daemon") ''
      # Force clients to use the host daemon even if a template/user env tried
      # to select local/single-user Nix state.
      BWRAP_ARGS+=(
        --setenv NIX_REMOTE daemon
        --setenv NIX_CONF_DIR /etc/nix
        --setenv NIX_SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      )
      ''}
    }

    build_sandbox_cmd() {
      SANDBOX_CMD=()
      if [[ -n "''${OCSB_EXEC_OVERRIDE:-}" && $# -gt 0 ]]; then
        SANDBOX_CMD=("$@")
      else
      ${if cfg.app.package != null then ''
      SANDBOX_CMD=(${lib.escapeShellArg appExec} ${appArgs} "$@")
      '' else ''
      if [[ $# -gt 0 ]]; then
        if [[ "$1" == -* ]]; then
          SANDBOX_CMD=(${lib.escapeShellArg appExec} ${appArgs} "$@")
        else
          SANDBOX_CMD=("$@")
        fi
      else
        SANDBOX_CMD=(${lib.escapeShellArg appExec})
      fi
      ''}
      fi

      ${if preExecScript != null then ''
      SANDBOX_CMD=(${preExecScript} "''${SANDBOX_CMD[@]}")
      '' else ''
      SANDBOX_CMD=(${envCaptureScript} "''${SANDBOX_CMD[@]}")
      ''}
      ${if daemonSupervisor != null then ''
      SANDBOX_CMD=(${daemonSupervisor} "''${SANDBOX_CMD[@]}")
      '' else ""}
    }

    build_workspace_strategy_flags() {
      STRATEGY_FLAGS=()

      case "$WORKSPACE_STRATEGY" in
        overlayfs)
          _WORKSPACE_OVERLAY_STATE="$OVERLAY_STATE_DIR/overlay/workspace"
          _WORKSPACE_OVERLAY_STATE_ACCESS="$OVERLAY_STATE_ACCESS_DIR/overlay/workspace"
          ${pkgs.coreutils}/bin/mkdir -p "$_WORKSPACE_OVERLAY_STATE_ACCESS/upper" "$_WORKSPACE_OVERLAY_STATE_ACCESS/work"
          STRATEGY_FLAGS=(
            --overlay-src "$PROJECT_DIR"
            --overlay "$_WORKSPACE_OVERLAY_STATE/upper" "$_WORKSPACE_OVERLAY_STATE/work" "$WORKSPACE_SANDBOX_DIR"
          )
          echo "ocsb: overlay workspace at $_WORKSPACE_OVERLAY_STATE" >&2
          ;;
        direct)
          STRATEGY_FLAGS=(
            --bind "$PROJECT_DIR" "$WORKSPACE_SANDBOX_DIR"
          )
          echo "ocsb: direct mount (read-write, no isolation)" >&2
          ;;
        btrfs)
          BTRFS_SNAP="$WS_DIR/snapshot"
          BTRFS_SNAP_ACCESS="$PROJECT_ACCESS_DIR/$OCSB_BASE_DIR/$WORKSPACE_NAME/snapshot"
          if [[ "$WORKSPACE_ACTION" == continue ]]; then
            echo "ocsb: reusing btrfs snapshot at $BTRFS_SNAP" >&2
          else
            echo "ocsb: created btrfs snapshot at $BTRFS_SNAP" >&2
          fi
          STRATEGY_FLAGS=(
            --bind "$BTRFS_SNAP" "$WORKSPACE_SANDBOX_DIR"
          )
          ;;
        git-worktree)
          GWT_DIR="$WS_DIR/worktree"
          GWT_DIR_ACCESS="$PROJECT_ACCESS_DIR/$OCSB_BASE_DIR/$WORKSPACE_NAME/worktree"
          if [[ "$WORKSPACE_ACTION" == continue ]]; then
            echo "ocsb: reusing git worktree at $GWT_DIR" >&2
          else
            echo "ocsb: created git worktree at $GWT_DIR" >&2
          fi
          STRATEGY_FLAGS=(
            --bind "$GWT_DIR" "$WORKSPACE_SANDBOX_DIR"
          )
          ;;
        *)
          echo "ocsb: unknown strategy: $WORKSPACE_STRATEGY" >&2
          exit 1
          ;;
      esac
    }

    append_workspace_mount_args() {
      # User-configured read-only mounts (resolved at runtime for ~ expansion)
      ${mkMountArrayEntries "--ro-bind-try" cfg.mounts.ro}

      # User-configured read-write mounts
      ${mkMountArrayEntries "--bind-try" cfg.mounts.rw}

      # Workspace strategy mounts (must come before runtime mounts so workspace dir exists)
      BWRAP_ARGS+=("''${STRATEGY_FLAGS[@]}")

      # Runtime CLI mounts (--ro / --rw flags) — after strategy so /workspace is available
      if [[ ''${#RUNTIME_MOUNTS[@]} -gt 0 ]]; then
        BWRAP_ARGS+=("''${RUNTIME_MOUNTS[@]}")
      fi

      # Per-directory overlay mounts (--overlay-mount HOST:SANDBOX)
      _OVL_IDX=0
      while [[ $_OVL_IDX -lt ''${#OVERLAY_MOUNTS[@]} ]]; do
        _OVL_HOST="''${OVERLAY_MOUNTS[$_OVL_IDX]}"
        _OVL_SANDBOX="''${OVERLAY_MOUNTS[$_OVL_IDX+1]}"
        _OVL_HASH="$(echo -n "$_OVL_HOST" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-12)"
        _OVL_STATE="$OVERLAY_STATE_DIR/overlay/mounts/ovl-$_OVL_HASH"
        _OVL_STATE_ACCESS="$OVERLAY_STATE_ACCESS_DIR/overlay/mounts/ovl-$_OVL_HASH"
        ${pkgs.coreutils}/bin/mkdir -p "$_OVL_STATE_ACCESS/upper" "$_OVL_STATE_ACCESS/work"
        BWRAP_ARGS+=(--overlay-src "$_OVL_HOST" --overlay "$_OVL_STATE/upper" "$_OVL_STATE/work" "$_OVL_SANDBOX")
        echo "ocsb: overlay mount $_OVL_HOST -> $_OVL_SANDBOX (state: $_OVL_STATE)" >&2
        _OVL_IDX=$((_OVL_IDX + 2))
      done

      # Per-directory snapshot mounts (--snap-mount HOST:SANDBOX)
      _SNAP_IDX=0
      while [[ $_SNAP_IDX -lt ''${#SNAP_MOUNTS[@]} ]]; do
        _SNAP_HOST="''${SNAP_MOUNTS[$_SNAP_IDX]}"
        _SNAP_SANDBOX="''${SNAP_MOUNTS[$_SNAP_IDX+1]}"
        _SNAP_HASH="$(echo -n "$_SNAP_HOST" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-12)"
        _SNAP_DIR="$OVERLAY_STATE_DIR/snapshots/snap-$_SNAP_HASH"
        _SNAP_DIR_ACCESS="$OVERLAY_STATE_ACCESS_DIR/snapshots/snap-$_SNAP_HASH"
        if [[ "$CONTINUE" -eq 1 ]] && [[ -d "$_SNAP_DIR_ACCESS" ]]; then
          echo "ocsb: reusing snapshot $_SNAP_HOST -> $_SNAP_SANDBOX" >&2
        else
          # Detect btrfs subvolume by inode (subvol roots have inode 256)
          _SNAP_INO="$(${pkgs.coreutils}/bin/stat -c %i "$_SNAP_HOST" 2>/dev/null || echo 0)"
          if [[ "$_SNAP_INO" != "256" ]]; then
            echo "ocsb: error: --snap-mount source must be a btrfs subvolume root: $_SNAP_HOST" >&2
            exit 1
          fi
          if [[ -d "$_SNAP_DIR_ACCESS" ]]; then
            ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$_SNAP_DIR_ACCESS" 2>/dev/null || ${pkgs.coreutils}/bin/rm -rf "$_SNAP_DIR_ACCESS"
          fi
          ${pkgs.coreutils}/bin/mkdir -p "$OVERLAY_STATE_ACCESS_DIR/snapshots"
          ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot "$_SNAP_HOST" "$_SNAP_DIR_ACCESS"
          echo "ocsb: snapshot mount $_SNAP_HOST -> $_SNAP_SANDBOX" >&2
        fi
        BWRAP_ARGS+=(--bind "$_SNAP_DIR" "$_SNAP_SANDBOX")
        _SNAP_IDX=$((_SNAP_IDX + 2))
      done

      # Git metadata mounts (for gitfile-backed repos)
      if [[ ''${#GIT_METADATA_FLAGS[@]} -gt 0 ]]; then
        BWRAP_ARGS+=("''${GIT_METADATA_FLAGS[@]}")
      fi
    }

    init_bwrap_args() {
      BWRAP_ARGS=(
        --unshare-all
        ${lib.optionalString (networkMode == "host" || dualLayerEnabled) "--share-net"}
        --die-with-parent
        ${lib.optionalString (!cfg.app.preserveCtty) "--new-session"}
        --clearenv

        ${if networkMode == "filtered" && !dualLayerEnabled && cfg.app.runAsRoot then ''
        # Filtered mode + runAsRoot: uid 0 for CAP_NET_ADMIN (iptables best-effort).
        # uid 0 inside a user namespace has NO host privileges.
        --uid 0
        --gid 0
        '' else ''
        --uid "$HOST_UID"
        --gid "$HOST_GID"
        ''}
        --dev /dev
        --proc /proc
        --tmpfs /tmp
        --tmpfs /run
        --dir /var
        --dir /var/lib
        --dir /var/lib/postgresql

        ${if networkMode == "filtered" && !dualLayerEnabled then
          ''--ro-bind "${customResolvConf}" /etc/resolv.conf''
        else
          ''--ro-bind-try "$(resolve_builtin_host_path /etc/resolv.conf)" /etc/resolv.conf''
        }
        --ro-bind-try "$(resolve_builtin_host_path /etc/ssl)" /etc/ssl
        --ro-bind-try "$(resolve_builtin_host_path /etc/static/ssl)" /etc/static/ssl
        --ro-bind-try "$(resolve_builtin_host_path /etc/nix)" /etc/nix
        --ro-bind-try "$(resolve_builtin_host_path /etc/passwd)" /etc/passwd
        --ro-bind-try "$(resolve_builtin_host_path /etc/group)" /etc/group
        --ro-bind-try "$(resolve_builtin_host_path /etc/nsswitch.conf)" /etc/nsswitch.conf

        --symlink usr/lib /lib
        --symlink usr/lib64 /lib64

        --tmpfs /home
        --dir /home/sandbox
        --dir /home/sandbox/.config
        --dir /home/sandbox/.local

        --ro-bind "${sandboxBin}/bin" /usr/bin
        --symlink /usr/bin /bin
      )
    }

    exec_sandbox() {
      # Freeze every host-side bwrap source into the immutable helper manifest
      # before translating the plan to any backend-specific argv.
      tokenize_bwrap_mount_sources

      if [[ "$BACKEND_TYPE" == "podman" ]]; then
        if [[ "${if dualLayerEnabled then "1" else "0"}" == "1" ]]; then
          echo "ocsb: experimental.dualLayer is bubblewrap-only" >&2
          exit 1
        fi
        if [[ "$WORKSPACE_STRATEGY" == "overlayfs" || ''${#OVERLAY_MOUNTS[@]} -gt 0 ]]; then
          echo "ocsb: backend 'podman' does not support overlayfs workspace or --overlay-mount in v1" >&2
          exit 1
        fi
        if [[ -n "''${CONTAINER_HOST:-}" || -n "''${CONTAINER_CONNECTION:-}" ]]; then
          echo "ocsb: backend 'podman' refuses remote connections when private mount anchors are required" >&2
          exit 1
        fi
        _PODMAN_BIN="$(type -P podman)" || {
          echo "ocsb: backend 'podman' requires podman on the host PATH" >&2
          exit 1
        }
        _PODMAN_BIN="$(${pkgs.coreutils}/bin/readlink -e -- "$_PODMAN_BIN")" || {
          echo "ocsb: backend 'podman' executable cannot be resolved safely" >&2
          exit 1
        }
        prepare_container_rootfs
        build_container_plan_from_bwrap_args
        _CONTAINER_NAME="ocsb-${cfg.app.name}-$(${pkgs.coreutils}/bin/printf '%s' "$OVERLAY_STATE_DIR" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-12)"
        PODMAN_ARGS=(run --rm --name "$_CONTAINER_NAME" --userns=keep-id --user "$HOST_UID:$HOST_GID" --workdir "$CONTAINER_WORKDIR")
        case "${networkMode}" in
          host) PODMAN_ARGS+=(--network host) ;;
          blocked) PODMAN_ARGS+=(--network none) ;;
          filtered) PODMAN_ARGS+=(--network slirp4netns:allow_host_loopback=false) ;;
        esac
        append_podman_mount_args
        append_podman_env_args
        if [[ -n "${podmanExtraArgs}" ]]; then
          # shellcheck disable=SC2206
          _PODMAN_EXTRA_ARGS=(${podmanExtraArgs})
          for _PODMAN_ARG in "''${_PODMAN_EXTRA_ARGS[@]}"; do
            case "$_PODMAN_ARG" in
              --annotation=*|--cap-add=*|--cap-drop=*|--cpus=*|--cpu-period=*|--cpu-quota=*|--cpu-shares=*|--cpuset-cpus=*|--cpuset-mems=*|--memory=*|--memory-reservation=*|--memory-swap=*|--memory-swappiness=*|--pids-limit=*|--ulimit=*|--restart=*|--stop-signal=*|--stop-timeout=*|--timeout=*|--hostname=*|--add-host=*|--dns=*|--dns-option=*|--dns-search=*|--shm-size=*|--systemd=*|--log-driver=*|--read-only|--replace)
                ;;
              *)
                echo "ocsb: backend.podman.extraArgs cannot add host path sources; use ocsb mounts" >&2
                exit 1
                ;;
            esac
          done
          PODMAN_ARGS+=("''${_PODMAN_EXTRA_ARGS[@]}")
        fi
        for _PODMAN_ARG in "''${PODMAN_ARGS[@]}"; do
          case "$_PODMAN_ARG" in
            --remote|-r|--remote=*|-r=*|--url|--url=*|--connection|--connection=*)
              echo "ocsb: backend 'podman' refuses remote connections when private mount anchors are required" >&2
              exit 1
              ;;
          esac
        done
        register_mount_anchor_source "$CONTAINER_ROOTFS" required
        _CONTAINER_ROOTFS_TOKEN="$MOUNT_ANCHOR_REGISTERED_TOKEN"
        PODMAN_BACKEND_ARGV=("$_PODMAN_BIN" --remote=false "''${PODMAN_ARGS[@]}" --rootfs "$_CONTAINER_ROOTFS_TOKEN" "''${SANDBOX_CMD[@]}")
        build_mount_anchor_helper_args podman current PODMAN_BACKEND_ARGV
        echo "$_CONTAINER_NAME" > "$OVERLAY_STATE_ACCESS_DIR/.backend-instance"
        if [[ "$HOST_UID" == 0 ]]; then
          exec ${mountAnchor}/bin/ocsb-mount-anchor \
            "''${MOUNT_ANCHOR_ARGS[@]}" -- "''${PODMAN_BACKEND_ARGV[@]}"
        fi
        exec "$_PODMAN_BIN" --remote=false unshare ${mountAnchor}/bin/ocsb-mount-anchor \
          "''${MOUNT_ANCHOR_ARGS[@]}" -- "''${PODMAN_BACKEND_ARGV[@]}"
      fi

      if [[ "$BACKEND_TYPE" == "systemd-nspawn" ]]; then
        if [[ "${if dualLayerEnabled then "1" else "0"}" == "1" ]]; then
          echo "ocsb: experimental.dualLayer is bubblewrap-only" >&2
          exit 1
        fi
        if [[ "$WORKSPACE_STRATEGY" == "overlayfs" || ''${#OVERLAY_MOUNTS[@]} -gt 0 ]]; then
          echo "ocsb: backend 'systemd-nspawn' does not support overlayfs workspace or --overlay-mount in v1" >&2
          exit 1
        fi
        if [[ "${networkMode}" == "filtered" ]]; then
          echo "ocsb: backend 'systemd-nspawn' supports only host or blocked networking in v1" >&2
          exit 1
        fi
        _NSPAWN_BIN="$(type -P systemd-nspawn)" || {
          echo "ocsb: backend 'systemd-nspawn' requires systemd-nspawn on the host PATH" >&2
          exit 1
        }
        _NSPAWN_BIN="$(${pkgs.coreutils}/bin/readlink -e -- "$_NSPAWN_BIN")" || {
          echo "ocsb: backend 'systemd-nspawn' executable cannot be resolved safely" >&2
          exit 1
        }
        prepare_container_rootfs
        build_container_plan_from_bwrap_args
        _MACHINE_NAME="ocsb-${cfg.app.name}-$(${pkgs.coreutils}/bin/printf '%s' "$OVERLAY_STATE_DIR" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-12)"
        register_mount_anchor_source "$CONTAINER_ROOTFS" required
        _CONTAINER_ROOTFS_TOKEN="$MOUNT_ANCHOR_REGISTERED_TOKEN"
        NSPAWN_ARGS=(--quiet --directory="$_CONTAINER_ROOTFS_TOKEN" --machine="$_MACHINE_NAME" --user="$HOST_UID" --chdir="$CONTAINER_WORKDIR")
        [[ "${networkMode}" == "blocked" ]] && NSPAWN_ARGS+=(--private-network)
        append_nspawn_mount_args
        append_nspawn_env_args
        if [[ -n "${nspawnExtraArgs}" ]]; then
          # shellcheck disable=SC2206
          _NSPAWN_EXTRA_ARGS=(${nspawnExtraArgs})
          for _NSPAWN_ARG in "''${_NSPAWN_EXTRA_ARGS[@]}"; do
            case "$_NSPAWN_ARG" in
              --slice=*|--register=*|--console=*|--kill-signal=*|--notify-ready=*|--suppress-sync=*|--capability=*|--drop-capability=*|--ambient-capability=*|--hostname=*|--port=*|--read-only|--volatile=*|--keep-unit|--collect|--as-pid2|--boot|--quiet)
                ;;
              *)
                echo "ocsb: backend.systemdNspawn.extraArgs cannot add host path sources; use ocsb mounts" >&2
                exit 1
                ;;
            esac
          done
          NSPAWN_ARGS+=("''${_NSPAWN_EXTRA_ARGS[@]}")
        fi
        NSPAWN_BACKEND_ARGV=("$_NSPAWN_BIN" "''${NSPAWN_ARGS[@]}" -- "''${SANDBOX_CMD[@]}")
        build_mount_anchor_helper_args systemd-nspawn current NSPAWN_BACKEND_ARGV
        echo "$_MACHINE_NAME" > "$OVERLAY_STATE_ACCESS_DIR/.backend-instance"
        exec ${mountAnchor}/bin/ocsb-mount-anchor \
          "''${MOUNT_ANCHOR_ARGS[@]}" -- "''${NSPAWN_BACKEND_ARGV[@]}"
      fi

      ${if networkMode == "filtered" && !dualLayerEnabled then ''
      _filtered_proc_group() {
        local _pid="$1" _stat _rest _field _index=1
        [[ "$_pid" =~ ^[1-9][0-9]*$ && -r "/proc/$_pid/stat" ]] || return 1
        IFS= read -r _stat < "/proc/$_pid/stat" || return 1
        _rest="''${_stat##*) }"
        for _field in $_rest; do
          if [[ $_index -eq 3 ]]; then
            [[ "$_field" =~ ^[1-9][0-9]*$ ]] || return 1
            printf '%s\n' "$_field"
            return 0
          fi
          _index=$((_index + 1))
        done
        return 1
      }

      _filtered_exact_live() {
        local _pid="$1" _start="$2" _actual _state
        _actual="$(ocsb_proc_start_time "$_pid" 2>/dev/null)" || return 1
        [[ "$_actual" == "$_start" ]] || return 1
        _state="$(ocsb__proc_state "$_pid" 2>/dev/null)" || return 1
        [[ "$_state" != Z && "$_state" != X && "$_state" != x ]]
      }

      _filtered_terminate_exact_child() {
        local _pid="$1" _start="$2" _attempt _state
        [[ "$_pid" =~ ^[1-9][0-9]*$ ]] || return 0
        if [[ ! "$_start" =~ ^[1-9][0-9]*$ ]]; then
          # Every caller passes an unreaped direct child from $!. Such a PID
          # cannot be reused before wait, even if procfs start capture failed.
          kill -TERM "$_pid" 2>/dev/null || true
          for ((_attempt = 0; _attempt < 50; _attempt++)); do
            kill -0 "$_pid" 2>/dev/null || break
            _state="$(ocsb__proc_state "$_pid" 2>/dev/null)" || break
            [[ "$_state" == Z || "$_state" == X || "$_state" == x ]] && break
            ${pkgs.coreutils}/bin/sleep 0.02
          done
          kill -0 "$_pid" 2>/dev/null && kill -KILL "$_pid" 2>/dev/null || true
          wait "$_pid" 2>/dev/null || true
          return 0
        fi
        if _filtered_exact_live "$_pid" "$_start"; then
          kill -TERM "$_pid" 2>/dev/null || true
          for ((_attempt = 0; _attempt < 50; _attempt++)); do
            _filtered_exact_live "$_pid" "$_start" || break
            ${pkgs.coreutils}/bin/sleep 0.02
          done
          if _filtered_exact_live "$_pid" "$_start"; then
            kill -KILL "$_pid" 2>/dev/null || true
          fi
        fi
        wait "$_pid" 2>/dev/null || true
      }

      _filtered_remove_paths() {
        ${pkgs.coreutils}/bin/rm -f -- \
          "$_NET_INFO" "$_NET_READY" "$_NET_READY.tmp" \
          "$_NET_CHILD_JSON" "$_NET_MONITOR_LOG"
        ${pkgs.coreutils}/bin/rmdir -- "$_NET_TMP" 2>/dev/null || true
      }

      _filtered_monitor() {
        local _MONITOR_PID="$BASHPID" _MONITOR_START=""
        local _READER_PID="" _READER_START="" _SLIRP_PID="" _SLIRP_START=""
        local _MONITOR_CLEANING=0 _CHILD_PID="" _attempt _actual _state _fd_path _fd

        # Drop the workspace lock and every unrelated inherited descriptor
        # before publishing readiness. slirp is forked only after this point.
        for _fd_path in /proc/self/fd/*; do
          _fd="''${_fd_path##*/}"
          [[ "$_fd" =~ ^[0-9]+$ ]] || continue
          case "$_fd" in
            0|1|2) ;;
            *) eval "exec $_fd>&-" 2>/dev/null || true ;;
          esac
        done
        # The monitor never reads from or writes to the controlling terminal.
        # Keep stderr attached so slirp capability failures remain diagnosable.
        exec </dev/null >/dev/null

        _filtered_monitor_cleanup() {
          [[ $_MONITOR_CLEANING -eq 0 ]] || return 0
          _MONITOR_CLEANING=1
          if [[ -n "$_READER_PID" ]]; then
            _filtered_terminate_exact_child "$_READER_PID" "$_READER_START"
            _READER_PID=""
          fi
          if [[ -n "$_SLIRP_PID" ]]; then
            _filtered_terminate_exact_child "$_SLIRP_PID" "$_SLIRP_START"
            _SLIRP_PID=""
          fi
          _filtered_remove_paths
        }
        trap '_filtered_monitor_cleanup' EXIT
        trap '_filtered_monitor_cleanup; exit 0' HUP INT TERM

        _MONITOR_START="$(ocsb_proc_start_time "$_MONITOR_PID")" || exit 1
        ${pkgs.util-linux}/bin/setpriv --pdeathsig=TERM -- \
          ${pkgs.coreutils}/bin/timeout 10 \
          ${pkgs.coreutils}/bin/cat -- "$_NET_INFO" > "$_NET_CHILD_JSON" &
        _READER_PID=$!
        for ((_attempt = 0; _attempt < 50; _attempt++)); do
          _READER_START="$(ocsb_proc_start_time "$_READER_PID" 2>/dev/null)" && break
          ${pkgs.coreutils}/bin/sleep 0.01
        done
        [[ -n "$_READER_START" ]] || exit 1
        _filtered_exact_live "$_READER_PID" "$_READER_START" || exit 1

        printf 'v1\t%s\t%s\t%s\t%s\t%s\n' \
          "$_MONITOR_PID" "$_MONITOR_START" \
          "$_NET_LAUNCHER_PID" "$_NET_LAUNCHER_START" "$_NET_LAUNCHER_PGID" \
          > "$_NET_READY.tmp"
        ${pkgs.coreutils}/bin/mv -f -T -- "$_NET_READY.tmp" "$_NET_READY"

        if ! wait "$_READER_PID"; then
          _READER_PID=""
          exit 1
        fi
        _READER_PID=""

        # The one-shot handoff is complete; remove both rendezvous paths before
        # parsing or starting slirp so neither can leak into its descriptor set.
        ${pkgs.coreutils}/bin/rm -f -- "$_NET_INFO" "$_NET_READY"
        _CHILD_PID="$(${pkgs.jq}/bin/jq -er \
          '.["child-pid"] | select(type == "number" and . > 0 and . == floor) | tostring' \
          "$_NET_CHILD_JSON")" || exit 1
        ${pkgs.coreutils}/bin/rm -f -- "$_NET_CHILD_JSON"
        [[ "$_CHILD_PID" =~ ^[1-9][0-9]*$ ]] || exit 1

        ${pkgs.util-linux}/bin/setpriv --pdeathsig=TERM -- \
          ${pkgs.slirp4netns}/bin/slirp4netns \
          --configure --disable-host-loopback "$_CHILD_PID" tap0 &
        _SLIRP_PID=$!
        for ((_attempt = 0; _attempt < 50; _attempt++)); do
          _SLIRP_START="$(ocsb_proc_start_time "$_SLIRP_PID" 2>/dev/null)" && break
          ${pkgs.coreutils}/bin/sleep 0.01
        done
        [[ -n "$_SLIRP_START" ]] || exit 1

        while :; do
          _actual="$(ocsb_proc_start_time "$_NET_LAUNCHER_PID" 2>/dev/null)" || break
          [[ "$_actual" == "$_NET_LAUNCHER_START" ]] || break
          _state="$(ocsb__proc_state "$_NET_LAUNCHER_PID" 2>/dev/null)" || break
          [[ "$_state" == Z || "$_state" == X || "$_state" == x ]] && break
          ${pkgs.coreutils}/bin/sleep 0.02
        done

        _filtered_monitor_cleanup
        trap - EXIT HUP INT TERM
      }

      _NET_LAUNCHER_PID=$$
      _NET_LAUNCHER_START="$(ocsb_proc_start_time "$_NET_LAUNCHER_PID")" || {
        echo "ocsb: cannot capture filtered-network launcher start time" >&2
        exit 1
      }
      _NET_LAUNCHER_PGID="$(_filtered_proc_group "$_NET_LAUNCHER_PID")" || {
        echo "ocsb: cannot capture filtered-network launcher process group" >&2
        exit 1
      }
      _NET_TMP_PARENT="$OCSB_RUNTIME_DIR/filtered-network"
      ${pkgs.coreutils}/bin/install -d -m 0700 -- "$_NET_TMP_PARENT"
      read -r _NET_PARENT_OWNER _NET_PARENT_MODE < <(${pkgs.coreutils}/bin/stat -c '%u %a' -- "$_NET_TMP_PARENT") || exit 1
      if [[ -L "$_NET_TMP_PARENT" || ! -d "$_NET_TMP_PARENT" || \
            "$_NET_PARENT_OWNER" != "$HOST_UID" || "$_NET_PARENT_MODE" != 700 ]]; then
        echo "ocsb: unsafe filtered-network temp parent: $_NET_TMP_PARENT" >&2
        exit 1
      fi
      _NET_TMP="$(umask 077; ${pkgs.coreutils}/bin/mktemp -d "$_NET_TMP_PARENT/net.XXXXXX")"
      _NET_INFO="$_NET_TMP/info"
      _NET_READY="$_NET_TMP/MONITOR_READY"
      _NET_CHILD_JSON="$_NET_TMP/child-pid.json"
      _NET_MONITOR_LOG="$_NET_TMP/monitor.log"
      if ! ${pkgs.coreutils}/bin/mkfifo -m 0600 -- "$_NET_INFO"; then
        _filtered_remove_paths
        echo "ocsb: cannot create filtered-network info FIFO" >&2
        exit 1
      fi

      _filtered_monitor &
      _NET_MONITOR_PID=$!
      _NET_MONITOR_START=""
      for ((_NET_WAIT = 0; _NET_WAIT < 40; _NET_WAIT++)); do
        _NET_MONITOR_START="$(ocsb_proc_start_time "$_NET_MONITOR_PID" 2>/dev/null)" && break
        ${pkgs.coreutils}/bin/sleep 0.01
      done
      if [[ -z "$_NET_MONITOR_START" ]]; then
        # An unreaped direct child cannot be replaced by PID reuse, so $! is
        # still an exact identity even when procfs failed before start capture.
        kill -TERM "$_NET_MONITOR_PID" 2>/dev/null || true
        for ((_NET_WAIT = 0; _NET_WAIT < 40; _NET_WAIT++)); do
          kill -0 "$_NET_MONITOR_PID" 2>/dev/null || break
          ${pkgs.coreutils}/bin/sleep 0.01
        done
        kill -KILL "$_NET_MONITOR_PID" 2>/dev/null || true
        wait "$_NET_MONITOR_PID" 2>/dev/null || true
        _filtered_remove_paths
        echo "ocsb: cannot capture filtered-network monitor start time" >&2
        exit 1
      fi

      _NET_LAUNCHER_ABORTED=0
      _filtered_launcher_abort() {
        [[ $_NET_LAUNCHER_ABORTED -eq 0 ]] || return 0
        _NET_LAUNCHER_ABORTED=1
        _filtered_terminate_exact_child "$_NET_MONITOR_PID" "$_NET_MONITOR_START"
        _filtered_remove_paths
      }
      trap '_filtered_launcher_abort' EXIT
      trap '_filtered_launcher_abort; exit 1' HUP INT TERM

      _NET_READY_OK=0
      for ((_NET_WAIT = 0; _NET_WAIT < 40; _NET_WAIT++)); do
        if [[ -r "$_NET_READY" ]]; then
          IFS=$'\t' read -r _NET_READY_VERSION _NET_READY_PID _NET_READY_START \
            _NET_READY_LAUNCHER_PID _NET_READY_LAUNCHER_START _NET_READY_LAUNCHER_PGID \
            < "$_NET_READY" || true
          if [[ "$_NET_READY_VERSION" == v1 && \
                "$_NET_READY_PID" == "$_NET_MONITOR_PID" && \
                "$_NET_READY_START" == "$_NET_MONITOR_START" && \
                "$_NET_READY_LAUNCHER_PID" == "$_NET_LAUNCHER_PID" && \
                "$_NET_READY_LAUNCHER_START" == "$_NET_LAUNCHER_START" && \
                "$_NET_READY_LAUNCHER_PGID" == "$_NET_LAUNCHER_PGID" && \
                ! -e "/proc/$_NET_MONITOR_PID/fd/9" ]] && \
             _filtered_exact_live "$_NET_MONITOR_PID" "$_NET_MONITOR_START"; then
            _NET_READY_OK=1
            break
          fi
        fi
        _filtered_exact_live "$_NET_MONITOR_PID" "$_NET_MONITOR_START" || break
        ${pkgs.coreutils}/bin/sleep 0.01
      done
      if [[ $_NET_READY_OK -ne 1 ]]; then
        echo "ocsb: filtered-network monitor did not become ready" >&2
        exit 1
      fi

      record_attach_process
      BUBBLEWRAP_BACKEND_ARGV=(
        ${pkgs.bubblewrap}/bin/bwrap
        "''${BWRAP_ARGS[@]}"
        --info-fd 3
        -- ${networkSetupScript} "''${SANDBOX_CMD[@]}"
      )
      build_mount_anchor_helper_args bubblewrap bubblewrap-user BUBBLEWRAP_BACKEND_ARGV
      exec ${mountAnchor}/bin/ocsb-mount-anchor \
        "''${MOUNT_ANCHOR_ARGS[@]}" -- "''${BUBBLEWRAP_BACKEND_ARGV[@]}" \
        3>"$_NET_TMP/info"
      '' else ''
      # Simple exec: host network or no network
      record_attach_process
      BUBBLEWRAP_BACKEND_ARGV=(
        ${pkgs.bubblewrap}/bin/bwrap
        "''${BWRAP_ARGS[@]}"
        -- "''${SANDBOX_CMD[@]}"
      )
      build_mount_anchor_helper_args bubblewrap bubblewrap-user BUBBLEWRAP_BACKEND_ARGV
      exec ${mountAnchor}/bin/ocsb-mount-anchor \
        "''${MOUNT_ANCHOR_ARGS[@]}" -- "''${BUBBLEWRAP_BACKEND_ARGV[@]}"
      ''}
    }

    # =========================================================
    # Runtime argument parsing
    # =========================================================
    WORKSPACE_NAME=${lib.escapeShellArg cfg.workspace.name}
    WORKSPACE_STRATEGY=${lib.escapeShellArg cfg.workspace.strategy}
    WORKSPACE_SANDBOX_DIR=${lib.escapeShellArg cfg.workspace.sandboxDir}
    PROJECT_DIR=""
    PROJECT_ACCESS_DIR=""
    STATE_BASE_DIR=""
    STATE_BASE_ACCESS_DIR=""
    OVERLAY_STATE_DIR=""
    OVERLAY_STATE_ACCESS_DIR=""
    INHERITED_FD_ARGS=()
    INHERITED_FD_ROLES=()
    INHERITED_FD_DISPLAYS=()
    INHERITED_FD_NUMBERS=()
    INHERITED_FD_DEVS=()
    INHERITED_FD_INOS=()
    INHERITED_FD_TYPES=()
    INHERITED_PROJECT_FD=""
    INHERITED_PROJECT_DISPLAY=""
    INHERITED_PROJECT_DEV=""
    INHERITED_PROJECT_INO=""
    INHERITED_STATE_BASE_FD=""
    INHERITED_STATE_BASE_DISPLAY=""
    CONTINUE=0
    OVERWRITE=0
    RUNTIME_MOUNTS=()
    RUNTIME_ENV_NAMES=()
    RUNTIME_ENV_VALUES=()
    OVERLAY_MOUNTS=()
    SNAP_MOUNTS=()
    ATTACH_TARGET=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        -w|--workspace)
          [[ $# -ge 2 ]] || { echo "ocsb: $1 requires a value" >&2; exit 1; }
          WORKSPACE_NAME="$2"; shift 2 ;;
        --strategy)
          [[ $# -ge 2 ]] || { echo "ocsb: $1 requires a value" >&2; exit 1; }
          WORKSPACE_STRATEGY="$2"; shift 2 ;;
        --continue)
          CONTINUE=1; shift ;;
        --overwrite)
          OVERWRITE=1; shift ;;
        --backend)
          [[ $# -ge 2 ]] || { echo "ocsb: $1 requires a value" >&2; exit 1; }
          case "$2" in
            bubblewrap|podman|systemd-nspawn) BACKEND_TYPE="$2" ;;
            *) echo "ocsb: unknown backend: $2" >&2; exit 1 ;;
          esac
          shift 2 ;;
        --attach)
          ATTACH_TARGET="auto"; shift ;;
        --attach=*)
          ATTACH_TARGET="''${1#--attach=}"
          [[ -n "$ATTACH_TARGET" ]] || { echo "ocsb: --attach requires a PID when using '='" >&2; exit 1; }
          shift ;;
        --ocsb-internal-fd-root)
          [[ $# -ge 2 ]] || { echo "ocsb: $1 requires a descriptor specification" >&2; exit 1; }
          parse_inherited_fd_root_spec "$2"
          shift 2 ;;
        --env)
          [[ $# -ge 2 ]] || { echo "ocsb: $1 requires NAME or NAME=VALUE" >&2; exit 1; }
          _ENV_SPEC="$2"
          if [[ "$_ENV_SPEC" == *=* ]]; then
            _ENV_NAME="''${_ENV_SPEC%%=*}"
            _ENV_VALUE="''${_ENV_SPEC#*=}"
          else
            _ENV_NAME="$_ENV_SPEC"
            if [[ ! "$_ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
              echo "ocsb: invalid --env name: $_ENV_NAME" >&2
              exit 1
            fi
            if [[ -z "''${!_ENV_NAME+x}" ]]; then
              echo "ocsb: --env $_ENV_NAME requested but host environment variable is unset" >&2
              exit 1
            fi
            _ENV_VALUE="''${!_ENV_NAME}"
          fi
          if [[ ! "$_ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "ocsb: invalid --env name: $_ENV_NAME" >&2
            exit 1
          fi
          RUNTIME_ENV_NAMES+=("$_ENV_NAME")
          RUNTIME_ENV_VALUES+=("$_ENV_VALUE")
          shift 2 ;;
        --ro|--rw)
          [[ $# -ge 2 ]] || { echo "ocsb: $1 requires HOST_PATH:SANDBOX_PATH" >&2; exit 1; }
          _MOUNT_FLAG="$1"
          _MOUNT_SPEC="$2"
          # Parse HOST:SANDBOX — split on first colon only
          _MOUNT_HOST="''${_MOUNT_SPEC%%:*}"
          _MOUNT_SANDBOX="''${_MOUNT_SPEC#*:}"
          if [[ "$_MOUNT_SPEC" != *":"* ]]; then
            echo "ocsb: $1 format must be HOST_PATH:SANDBOX_PATH" >&2
            exit 1
          fi
          # Validate host path: must be absolute
          if [[ "$_MOUNT_HOST" != /* ]]; then
            echo "ocsb: host path must be absolute: $_MOUNT_HOST" >&2
            exit 1
          fi
          # Validate host path: must exist
          if [[ ! -e "$_MOUNT_HOST" ]]; then
            echo "ocsb: host path does not exist: $_MOUNT_HOST" >&2
            exit 1
          fi
          # Validate sandbox path: reject '..' components
          if [[ "$_MOUNT_SANDBOX" == *".."* ]]; then
            echo "ocsb: sandbox path cannot contain '..': $_MOUNT_SANDBOX" >&2
            exit 1
          fi
          # Resolve sandbox path: relative → workspace sandbox dir
          if [[ "$_MOUNT_SANDBOX" == "./"* ]]; then
            _MOUNT_SANDBOX="$WORKSPACE_SANDBOX_DIR/''${_MOUNT_SANDBOX:2}"
          elif [[ "$_MOUNT_SANDBOX" != /* ]]; then
            _MOUNT_SANDBOX="$WORKSPACE_SANDBOX_DIR/$_MOUNT_SANDBOX"
          fi
          # Add to runtime mounts
          if [[ "$_MOUNT_FLAG" == "--ro" ]]; then
            RUNTIME_MOUNTS+=(--ro-bind "$_MOUNT_HOST" "$_MOUNT_SANDBOX")
          else
            RUNTIME_MOUNTS+=(--bind "$_MOUNT_HOST" "$_MOUNT_SANDBOX")
          fi
          shift 2 ;;
        --overlay-mount|--snap-mount)
          [[ $# -ge 2 ]] || { echo "ocsb: $1 requires HOST_PATH:SANDBOX_PATH" >&2; exit 1; }
          _DM_FLAG="$1"
          _DM_SPEC="$2"
          _DM_HOST="''${_DM_SPEC%%:*}"
          _DM_SANDBOX="''${_DM_SPEC#*:}"
          if [[ "$_DM_SPEC" != *":"* ]]; then
            echo "ocsb: $1 format must be HOST_PATH:SANDBOX_PATH" >&2
            exit 1
          fi
          if [[ "$_DM_HOST" != /* ]]; then
            echo "ocsb: host path must be absolute: $_DM_HOST" >&2
            exit 1
          fi
          if [[ ! -d "$_DM_HOST" ]]; then
            echo "ocsb: host path must be an existing directory: $_DM_HOST" >&2
            exit 1
          fi
          if [[ "$_DM_SANDBOX" == *".."* ]]; then
            echo "ocsb: sandbox path cannot contain '..': $_DM_SANDBOX" >&2
            exit 1
          fi
          if [[ "$_DM_SANDBOX" == "./"* ]]; then
            _DM_SANDBOX="$WORKSPACE_SANDBOX_DIR/''${_DM_SANDBOX:2}"
          elif [[ "$_DM_SANDBOX" != /* ]]; then
            _DM_SANDBOX="$WORKSPACE_SANDBOX_DIR/$_DM_SANDBOX"
          fi
          if [[ "$_DM_FLAG" == "--overlay-mount" ]]; then
            OVERLAY_MOUNTS+=("$_DM_HOST" "$_DM_SANDBOX")
          else
            SNAP_MOUNTS+=("$_DM_HOST" "$_DM_SANDBOX")
          fi
          shift 2 ;;
        --)
          shift; break ;;
        -*)
          echo "ocsb: unknown option: $1" >&2; exit 1 ;;
        *)
          break ;;
      esac
    done

    if [[ ''${#INHERITED_FD_ARGS[@]} -gt 0 ]]; then
      if [[ -z "$INHERITED_PROJECT_FD" || -z "$INHERITED_STATE_BASE_FD" ]]; then
        echo "ocsb: inherited descriptor set requires exactly one project and one state-base root" >&2
        exit 1
      fi
    fi
    if [[ -n "$INHERITED_PROJECT_FD" ]]; then
      PROJECT_DIR="$INHERITED_PROJECT_DISPLAY"
      PROJECT_ACCESS_DIR="/proc/self/fd/$INHERITED_PROJECT_FD"
    else
      PROJECT_DIR="$(${pkgs.coreutils}/bin/realpath "$(pwd)")"
      PROJECT_ACCESS_DIR="$PROJECT_DIR"
    fi

    # =========================================================
    # Workspace name validation (prevent path traversal)
    # =========================================================
    validate_workspace_name() {
      local name="$1"

      if [[ -z "$name" ]]; then
        echo "ocsb: workspace name cannot be empty" >&2
        return 1
      fi

      if [[ "$name" == -* ]]; then
        echo "ocsb: workspace name cannot start with '-'" >&2
        return 1
      fi

      if [[ "$name" == */* ]]; then
        echo "ocsb: workspace name cannot contain '/'" >&2
        return 1
      fi

      if [[ "$name" == ".." || "$name" == "." ]]; then
        echo "ocsb: workspace name cannot be '.' or '..'" >&2
        return 1
      fi

      if [[ "''${#name}" -gt 255 ]]; then
        echo "ocsb: workspace name too long (max 255 chars)" >&2
        return 1
      fi

      # Reject names containing path traversal sequences
      if [[ "$name" == *".."* ]]; then
        echo "ocsb: workspace name cannot contain '..'" >&2
        return 1
      fi

      return 0
    }

    validate_workspace_name "$WORKSPACE_NAME" || exit 1

    # =========================================================
    # Non-mutating workspace state and process identity
    # =========================================================
    OCSB_BASE_DIR=${lib.escapeShellArg cfg.workspace.baseDir}
    OCSB_DIR="$PROJECT_DIR/$OCSB_BASE_DIR"
    WS_DIR="$OCSB_DIR/$WORKSPACE_NAME"

    PROJECT_HASH="$(echo -n "$PROJECT_DIR" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-16)"
    if [[ -n "''${OCSB_STATE_BASE_DIR:-}" ]]; then
      if [[ "$OCSB_STATE_BASE_DIR" != /* ]]; then
        echo "ocsb: OCSB_STATE_BASE_DIR must be absolute: $OCSB_STATE_BASE_DIR" >&2
        exit 1
      fi
      STATE_BASE_DIR="$(${pkgs.coreutils}/bin/realpath -m "$OCSB_STATE_BASE_DIR")"
    else
      STATE_BASE_DIR="$HOME/.cache/ocsb/$PROJECT_HASH"
    fi
    if [[ -n "$INHERITED_STATE_BASE_FD" ]]; then
      if [[ "$STATE_BASE_DIR" != "$INHERITED_STATE_BASE_DISPLAY" ]]; then
        echo "ocsb: inherited state-base display does not match OCSB_STATE_BASE_DIR: $INHERITED_STATE_BASE_DISPLAY" >&2
        exit 1
      fi
      STATE_BASE_ACCESS_DIR="/proc/self/fd/$INHERITED_STATE_BASE_FD"
    else
      STATE_BASE_ACCESS_DIR="$STATE_BASE_DIR"
    fi
    OVERLAY_STATE_DIR="$STATE_BASE_DIR/$WORKSPACE_NAME"
    OVERLAY_STATE_ACCESS_DIR="$STATE_BASE_ACCESS_DIR/$WORKSPACE_NAME"
    OCSB_PROCESS_ROLE=${lib.escapeShellArg "sandbox:${cfg.app.name}"}
    OCSB_INSTANCE="$(ocsb_instance_digest "$OCSB_PROCESS_ROLE" "$OVERLAY_STATE_DIR")"
    OCSB_PROCESS_RECORD="$(ocsb_process_record_path "$OCSB_PROCESS_ROLE" "$OVERLAY_STATE_DIR")"
    OCSB_RUNTIME_DIR="''${OCSB_PROCESS_RECORD%/*}"

    maybe_attach

    # Validate strategy before creating any state
    case "$WORKSPACE_STRATEGY" in
      auto|overlayfs|btrfs|git-worktree|direct) ;;
      *)
        echo "ocsb: unknown strategy: $WORKSPACE_STRATEGY" >&2
        exit 1
        ;;
    esac

    if [[ "$BACKEND_TYPE" != "bubblewrap" && "$WORKSPACE_STRATEGY" == "overlayfs" ]]; then
      echo "ocsb: backend '$BACKEND_TYPE' does not support workspace.strategy=overlayfs in v1; use direct, btrfs, git-worktree, or bubblewrap" >&2
      exit 1
    fi
    if [[ "$BACKEND_TYPE" != "bubblewrap" && "${if dualLayerEnabled then "1" else "0"}" == "1" ]]; then
      echo "ocsb: experimental.dualLayer is bubblewrap-only" >&2
      exit 1
    fi
    if [[ "$BACKEND_TYPE" != "bubblewrap" && ''${#OVERLAY_MOUNTS[@]} -gt 0 ]]; then
      echo "ocsb: backend '$BACKEND_TYPE' does not support --overlay-mount in v1" >&2
      exit 1
    fi
    if [[ "$BACKEND_TYPE" == "systemd-nspawn" && "${networkMode}" == "filtered" ]]; then
      echo "ocsb: backend 'systemd-nspawn' supports only host or blocked networking in v1" >&2
      exit 1
    fi

    # =========================================================
    # Per-workspace lock and state (outside project tree — symlink-safe)
    # =========================================================
    ${pkgs.coreutils}/bin/install -d -m 0700 "$OVERLAY_STATE_ACCESS_DIR"
    if [[ ! -d "$OVERLAY_STATE_ACCESS_DIR" || -L "$OVERLAY_STATE_ACCESS_DIR" ||
          "$(${pkgs.coreutils}/bin/stat -c %u -- "$OVERLAY_STATE_ACCESS_DIR")" != "$HOST_UID" ||
          "$(${pkgs.coreutils}/bin/stat -c %a -- "$OVERLAY_STATE_ACCESS_DIR")" != 700 ]]; then
      echo "ocsb: unsafe workspace state directory: $OVERLAY_STATE_DIR must be a current-UID mode 0700 directory" >&2
      exit 1
    fi

    LOCK_FILE_ACCESS="$OVERLAY_STATE_ACCESS_DIR/.lock"
    if [[ -L "$LOCK_FILE_ACCESS" ]]; then
      echo "ocsb: unsafe workspace lock file: $OVERLAY_STATE_DIR/.lock" >&2
      exit 1
    fi
    exec 9>"$LOCK_FILE_ACCESS"
    if ! ${pkgs.util-linux}/bin/flock -n 9; then
      echo "ocsb: workspace '$WORKSPACE_NAME' is locked by another process" >&2
      exit 1
    fi

    read_workspace_state_marker() {
      local _path="$1"
      local _kind="$2"
      local _display_path="''${3:-$1}"
      local -a _lines=()

      [[ -e "$_path" ]] || return 1
      if [[ -L "$_path" || ! -f "$_path" ]]; then
        echo "ocsb: unsafe workspace $_kind marker: $_display_path" >&2
        exit 1
      fi
      mapfile -t _lines < "$_path"
      if [[ ''${#_lines[@]} -ne 1 ]]; then
        echo "ocsb: malformed workspace $_kind marker: $_display_path" >&2
        exit 1
      fi
      case "$_kind:''${_lines[0]}" in
        strategy:overlayfs|strategy:btrfs|strategy:git-worktree|strategy:direct|backend:bubblewrap|backend:podman|backend:systemd-nspawn) ;;
        *)
          echo "ocsb: malformed workspace $_kind marker: $_display_path" >&2
          exit 1
          ;;
      esac
      printf '%s\n' "''${_lines[0]}"
    }

    EXISTING_STRATEGY=""
    EXISTING_BACKEND=""
    if [[ -e "$OVERLAY_STATE_ACCESS_DIR/.strategy" ]]; then
      EXISTING_STRATEGY="$(read_workspace_state_marker "$OVERLAY_STATE_ACCESS_DIR/.strategy" strategy "$OVERLAY_STATE_DIR/.strategy")"
    fi
    if [[ -e "$OVERLAY_STATE_ACCESS_DIR/.backend" ]]; then
      EXISTING_BACKEND="$(read_workspace_state_marker "$OVERLAY_STATE_ACCESS_DIR/.backend" backend "$OVERLAY_STATE_DIR/.backend")"
    fi
    REQUESTED_STRATEGY="$WORKSPACE_STRATEGY"
    CLEANUP_STRATEGY=none

    if [[ "$OVERWRITE" -eq 1 ]]; then
      WORKSPACE_ACTION=overwrite
      [[ -n "$EXISTING_STRATEGY" ]] && CLEANUP_STRATEGY="$EXISTING_STRATEGY"
      echo "ocsb: overwriting workspace '$WORKSPACE_NAME'..." >&2
    elif [[ "$CONTINUE" -eq 1 ]]; then
      WORKSPACE_ACTION=continue
      if [[ -z "$EXISTING_STRATEGY" || -z "$EXISTING_BACKEND" ]]; then
        echo "ocsb: workspace '$WORKSPACE_NAME' has no complete strategy/backend state to continue" >&2
        echo "  Use --overwrite to recreate it." >&2
        exit 1
      fi
      CLEANUP_STRATEGY="$EXISTING_STRATEGY"
      if [[ "$REQUESTED_STRATEGY" == auto ]]; then
        if [[ "$EXISTING_STRATEGY" != btrfs && "$EXISTING_STRATEGY" != overlayfs ]]; then
          echo "ocsb: workspace '$WORKSPACE_NAME' was created with strategy '$EXISTING_STRATEGY', cannot continue with 'auto'" >&2
          echo "  Use --overwrite to recreate with a different strategy." >&2
          exit 1
        fi
      elif [[ "$EXISTING_STRATEGY" != "$REQUESTED_STRATEGY" ]]; then
        echo "ocsb: workspace '$WORKSPACE_NAME' was created with strategy '$EXISTING_STRATEGY', cannot continue with '$REQUESTED_STRATEGY'" >&2
        echo "  Use --overwrite to recreate with a different strategy." >&2
        exit 1
      fi
      if [[ "$EXISTING_BACKEND" != "$BACKEND_TYPE" ]]; then
        echo "ocsb: workspace '$WORKSPACE_NAME' was created with backend '$EXISTING_BACKEND', cannot continue with '$BACKEND_TYPE'" >&2
        echo "  Use --overwrite to recreate with a different backend." >&2
        exit 1
      fi
      echo "ocsb: continuing workspace '$WORKSPACE_NAME'..." >&2
    else
      WORKSPACE_ACTION=create
      if [[ -n "$EXISTING_STRATEGY" || -n "$EXISTING_BACKEND" ]]; then
        echo "ocsb: workspace '$WORKSPACE_NAME' already exists." >&2
        echo "  Use --continue to resume, or --overwrite to start fresh." >&2
        exit 1
      fi
    fi

    if [[ -n "$INHERITED_PROJECT_FD" ]]; then
      PROJECT_DEV="$INHERITED_PROJECT_DEV"
      PROJECT_INO="$INHERITED_PROJECT_INO"
    else
      PROJECT_IDENTITY="$(LC_ALL=C ${pkgs.coreutils}/bin/stat -c $'%d\t%i' -- "$PROJECT_DIR")"
      IFS=$'\t' read -r PROJECT_DEV PROJECT_INO <<< "$PROJECT_IDENTITY"
    fi
    if [[ ! "$PROJECT_DEV" =~ ^[0-9]+$ || ! "$PROJECT_INO" =~ ^[0-9]+$ ||
          "$PROJECT_DEV" == 0 || "$PROJECT_INO" == 0 ]]; then
      echo "ocsb: cannot capture project identity: $PROJECT_DIR" >&2
      exit 1
    fi
    WORKSPACE_NONCE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f 1)"
    [[ "$WORKSPACE_NONCE" =~ ^[0-9a-f]{64}$ ]] || {
      echo "ocsb: cannot generate workspace mutation nonce" >&2
      exit 1
    }
    WORKSPACE_RECEIPT="$OVERLAY_STATE_DIR/.workspace-receipt-$WORKSPACE_NONCE"
    WORKSPACE_RECEIPT_ACCESS="$OVERLAY_STATE_ACCESS_DIR/.workspace-receipt-$WORKSPACE_NONCE"
    printf -v WORKSPACE_MUTATION_SPEC '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      v1 "$WORKSPACE_NONCE" "$PROJECT_DIR" "$PROJECT_DEV" "$PROJECT_INO" \
      "$OCSB_BASE_DIR" "$WORKSPACE_NAME" "$WORKSPACE_ACTION" "$REQUESTED_STRATEGY" \
      "$CLEANUP_STRATEGY" "$BACKEND_TYPE" "$OVERLAY_STATE_DIR"
    WORKSPACE_MUTATION_ARGS=(
      --mutation-only
      "''${INHERITED_FD_ARGS[@]}"
      --mutation-spec "$WORKSPACE_MUTATION_SPEC"
      --workspace-receipt "$WORKSPACE_RECEIPT"
      --git-bin ${pkgs.git}/bin/git
    )
    ${lib.optionalString (mountAnchorMutationTestHookArgs != [ ]) ''
    WORKSPACE_MUTATION_ARGS+=(${lib.escapeShellArgs mountAnchorMutationTestHookArgs})
    ''}
    ${mountAnchor}/bin/ocsb-mount-anchor "''${WORKSPACE_MUTATION_ARGS[@]}"

    WORKSPACE_RECEIPT_LINES=()
    mapfile -t WORKSPACE_RECEIPT_LINES < "$WORKSPACE_RECEIPT_ACCESS"
    if [[ ''${#WORKSPACE_RECEIPT_LINES[@]} -ne 1 ]]; then
      echo "ocsb: workspace mutation helper produced a malformed receipt" >&2
      exit 1
    fi
    IFS=$'\t' read -r -a WORKSPACE_RECEIPT_FIELDS <<< "''${WORKSPACE_RECEIPT_LINES[0]}"
    if [[ ''${#WORKSPACE_RECEIPT_FIELDS[@]} -ne 17 ||
          "''${WORKSPACE_RECEIPT_FIELDS[0]}" != v1 ||
          "''${WORKSPACE_RECEIPT_FIELDS[1]}" != "$WORKSPACE_NONCE" ||
          "''${WORKSPACE_RECEIPT_FIELDS[2]}" != "$PROJECT_DIR" ||
          "''${WORKSPACE_RECEIPT_FIELDS[3]}" != "$OCSB_BASE_DIR" ||
          "''${WORKSPACE_RECEIPT_FIELDS[4]}" != "$WORKSPACE_NAME" ||
          "''${WORKSPACE_RECEIPT_FIELDS[12]}" != "$BACKEND_TYPE" ]]; then
      echo "ocsb: workspace mutation receipt does not match the request" >&2
      exit 1
    fi
    for _identity_index in 5 6 7 8 9 10 14 15; do
      [[ "''${WORKSPACE_RECEIPT_FIELDS[$_identity_index]}" =~ ^[0-9]+$ ]] || {
        echo "ocsb: workspace mutation receipt has an invalid identity" >&2
        exit 1
      }
    done
    WORKSPACE_STRATEGY="''${WORKSPACE_RECEIPT_FIELDS[11]}"
    case "$WORKSPACE_STRATEGY" in
      direct|overlayfs)
        [[ "''${WORKSPACE_RECEIPT_FIELDS[13]}" == none &&
          "''${WORKSPACE_RECEIPT_FIELDS[14]}" == 0 &&
          "''${WORKSPACE_RECEIPT_FIELDS[15]}" == 0 &&
          "''${WORKSPACE_RECEIPT_FIELDS[16]}" == none ]] || {
          echo "ocsb: workspace mutation receipt has an invalid direct/overlay identity" >&2
          exit 1
        }
        WORKSPACE_RECEIPT_SOURCE_PATH="$PROJECT_DIR"
        WORKSPACE_RECEIPT_SOURCE_DEV="''${WORKSPACE_RECEIPT_FIELDS[5]}"
        WORKSPACE_RECEIPT_SOURCE_INO="''${WORKSPACE_RECEIPT_FIELDS[6]}"
        ;;
      btrfs)
        [[ "''${WORKSPACE_RECEIPT_FIELDS[13]}" == snapshot &&
          "''${WORKSPACE_RECEIPT_FIELDS[14]}" != 0 &&
          "''${WORKSPACE_RECEIPT_FIELDS[15]}" != 0 &&
          "''${WORKSPACE_RECEIPT_FIELDS[16]}" == btrfs-subvolume ]] || {
          echo "ocsb: workspace mutation receipt has an invalid btrfs identity" >&2
          exit 1
        }
        WORKSPACE_RECEIPT_SOURCE_PATH="$WS_DIR/snapshot"
        WORKSPACE_RECEIPT_SOURCE_DEV="''${WORKSPACE_RECEIPT_FIELDS[14]}"
        WORKSPACE_RECEIPT_SOURCE_INO="''${WORKSPACE_RECEIPT_FIELDS[15]}"
        ;;
      git-worktree)
        [[ "''${WORKSPACE_RECEIPT_FIELDS[13]}" == worktree &&
          "''${WORKSPACE_RECEIPT_FIELDS[14]}" != 0 &&
          "''${WORKSPACE_RECEIPT_FIELDS[15]}" != 0 &&
          "''${WORKSPACE_RECEIPT_FIELDS[16]}" == git-worktree ]] || {
          echo "ocsb: workspace mutation receipt has an invalid git worktree identity" >&2
          exit 1
        }
        WORKSPACE_RECEIPT_SOURCE_PATH="$WS_DIR/worktree"
        WORKSPACE_RECEIPT_SOURCE_DEV="''${WORKSPACE_RECEIPT_FIELDS[14]}"
        WORKSPACE_RECEIPT_SOURCE_INO="''${WORKSPACE_RECEIPT_FIELDS[15]}"
        ;;
      *)
        echo "ocsb: workspace mutation receipt has an invalid resolved strategy" >&2
        exit 1
        ;;
    esac

    if [[ "$BACKEND_TYPE" != "bubblewrap" && "$WORKSPACE_STRATEGY" == "overlayfs" ]]; then
      echo "ocsb: backend '$BACKEND_TYPE' does not support workspace.strategy=overlayfs in v1; use direct, btrfs, git-worktree, or bubblewrap" >&2
      exit 1
    fi

    # External state is cleaned only after the project mutation succeeds and
    # while FD 9 still holds the per-workspace lock.
    if [[ "$WORKSPACE_ACTION" == overwrite ]]; then
        if [[ -d "$OVERLAY_STATE_ACCESS_DIR/chroot" ]]; then
          chmod_tree_dirs_writable "$OVERLAY_STATE_ACCESS_DIR/chroot"
        fi
        ${pkgs.coreutils}/bin/rm -rf "$OVERLAY_STATE_ACCESS_DIR/chroot" "$OVERLAY_STATE_ACCESS_DIR/.chroot-source"
        ${pkgs.coreutils}/bin/rm -rf "$OVERLAY_STATE_ACCESS_DIR/overlay" "$OVERLAY_STATE_ACCESS_DIR/upper" "$OVERLAY_STATE_ACCESS_DIR/work"
        # Clean per-directory overlay and snapshot state. Keep the root-level
        # ovl-*/snap-* loops as legacy cleanup for workspaces created before
        # overlay/mounts and snapshots became separate state directories.
        for _d in "$OVERLAY_STATE_ACCESS_DIR"/ovl-*; do
          [[ -d "$_d" ]] && ${pkgs.coreutils}/bin/rm -rf "$_d"
        done
        for _d in "$OVERLAY_STATE_ACCESS_DIR"/snap-*; do
          if [[ -d "$_d" ]]; then
            ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$_d" 2>/dev/null || ${pkgs.coreutils}/bin/rm -rf "$_d"
          fi
        done
        for _d in "$OVERLAY_STATE_ACCESS_DIR"/snapshots/snap-*; do
          if [[ -d "$_d" ]]; then
            ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$_d" 2>/dev/null || ${pkgs.coreutils}/bin/rm -rf "$_d"
          fi
        done
        ${pkgs.coreutils}/bin/rm -rf "$OVERLAY_STATE_ACCESS_DIR/snapshots"
    fi

    printf '%s\n' "$WORKSPACE_STRATEGY" > "$OVERLAY_STATE_ACCESS_DIR/.strategy.tmp.$$"
    ${pkgs.coreutils}/bin/mv -f -T -- "$OVERLAY_STATE_ACCESS_DIR/.strategy.tmp.$$" "$OVERLAY_STATE_ACCESS_DIR/.strategy"
    printf '%s\n' "$BACKEND_TYPE" > "$OVERLAY_STATE_ACCESS_DIR/.backend.tmp.$$"
    ${pkgs.coreutils}/bin/mv -f -T -- "$OVERLAY_STATE_ACCESS_DIR/.backend.tmp.$$" "$OVERLAY_STATE_ACCESS_DIR/.backend"

    # =========================================================
    # Strategy-specific flags
    # =========================================================
    build_workspace_strategy_flags

    build_git_metadata_flags

    # =========================================================
    # Build bwrap argument array
    # =========================================================
    init_bwrap_args

    append_nix_store_args

    append_workspace_mount_args

    # Environment
    append_environment_args

    # Working directory and command
    BWRAP_ARGS+=(
      --chdir "$WORKSPACE_SANDBOX_DIR"
    )

    # =========================================================
    # Determine sandbox command
    # =========================================================
    build_sandbox_cmd "$@"

    # =========================================================
    # Exec bwrap
    # =========================================================
    exec_sandbox
  '';

in
pkgs.writeShellScriptBin cfg.app.name ''
  exec ${launcher} "$@"
''
