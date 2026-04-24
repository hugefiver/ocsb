# mkSandbox — Core sandbox builder
#
# Evaluates user config through the Nix module system, then generates
# a wrapped script that launches bubblewrap with proper isolation.
#
# Usage:
#   mkSandbox { packages = [ pkgs.coreutils ]; workspace.strategy = "overlayfs"; }
#   mkSandbox ({ pkgs, ... }: { packages = [ pkgs.coreutils ]; })

{ pkgs, lib }:

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
      [ sandboxBin pkgs.bubblewrap pkgs.cacert ]
      ++ lib.optional (cfg.app.package != null) cfg.app.package
      ++ lib.optional (preExecScript != null) preExecScript
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

  preExecScript =
    if cfg.app.preExecHook != ""
    then pkgs.writeShellScript "${cfg.app.name}-pre-exec" ''
      set -euo pipefail
      ${cfg.app.preExecHook}
      exec "$@"
    ''
    else null;

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
      --bind /workspace /workspace
      --ro-bind-try /etc/passwd /etc/passwd
      --ro-bind-try /etc/group /etc/group
      --clearenv
      --setenv HOME /home/sandbox
      --setenv PATH /usr/bin
      --setenv TERM "''${TERM:-xterm-256color}"
      --setenv SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      --setenv SANDBOX 1
      --setenv OCSB_DUAL_LAYER inner
      --chdir "$(pwd)"
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

    # =========================================================
    # Helper: resolve ~ in paths at runtime
    # =========================================================

    # For bwrap source (host side): ~ expands to real $HOME
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

    # =========================================================
    # Runtime argument parsing
    # =========================================================
    WORKSPACE_NAME=${lib.escapeShellArg cfg.workspace.name}
    WORKSPACE_STRATEGY=${lib.escapeShellArg cfg.workspace.strategy}
    PROJECT_DIR="$(${pkgs.coreutils}/bin/realpath "$(pwd)")"
    CONTINUE=0
    OVERWRITE=0
    RUNTIME_MOUNTS=()
    OVERLAY_MOUNTS=()
    SNAP_MOUNTS=()

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
          # Resolve sandbox path: relative → /workspace/...
          if [[ "$_MOUNT_SANDBOX" == "./"* ]]; then
            _MOUNT_SANDBOX="/workspace/''${_MOUNT_SANDBOX:2}"
          elif [[ "$_MOUNT_SANDBOX" != /* ]]; then
            _MOUNT_SANDBOX="/workspace/$_MOUNT_SANDBOX"
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
            _DM_SANDBOX="/workspace/''${_DM_SANDBOX:2}"
          elif [[ "$_DM_SANDBOX" != /* ]]; then
            _DM_SANDBOX="/workspace/$_DM_SANDBOX"
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
    # btrfs probe: returns 0 if dir is on btrfs AND current user can
    # create AND delete subvolumes there (needs user_subvol_rm_allowed
    # mount option for unprivileged delete). Sets _btrfs_probe_reason.
    # rc=1 not btrfs / rc=2 btrfs but no perm.
    # =========================================================
    _btrfs_probe_reason=""
    _btrfs_probe() {
      local _dir="$1"
      local _fstype
      _fstype="$(${pkgs.coreutils}/bin/stat -f -c %T "$_dir" 2>/dev/null)"
      if [[ "$_fstype" != "btrfs" ]]; then
        _btrfs_probe_reason="not a btrfs filesystem (fstype=$_fstype)"
        return 1
      fi
      local _probe="$_dir/.ocsb-btrfs-probe.$$"
      if ! ${pkgs.btrfs-progs}/bin/btrfs subvolume create "$_probe" &>/dev/null; then
        _btrfs_probe_reason="cannot create subvolume in $_dir (permission denied)"
        return 1
      fi
      if ! ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$_probe" &>/dev/null; then
        ${pkgs.coreutils}/bin/rm -rf "$_probe" 2>/dev/null || true
        _btrfs_probe_reason="cannot delete subvolume (mount with 'user_subvol_rm_allowed' or run as root)"
        return 2
      fi
      _btrfs_probe_reason=""
      return 0
    }

    # Validate strategy before creating any state
    case "$WORKSPACE_STRATEGY" in
      auto|overlayfs|btrfs|git-worktree|direct) ;;
      *)
        echo "ocsb: unknown strategy: $WORKSPACE_STRATEGY" >&2
        exit 1
        ;;
    esac

    # =========================================================
    # Auto-detect: resolve 'auto' to btrfs or overlayfs
    # =========================================================
    if [[ "$WORKSPACE_STRATEGY" == "auto" ]]; then
      if _btrfs_probe "$PROJECT_DIR"; then
        WORKSPACE_STRATEGY="btrfs"
        echo "ocsb: auto-detected btrfs filesystem with subvolume perms, using btrfs snapshot strategy" >&2
      else
        WORKSPACE_STRATEGY="overlayfs"
        echo "ocsb: btrfs unavailable ($_btrfs_probe_reason), using overlayfs strategy" >&2
      fi
    fi

    # =========================================================
    # Workspace directory setup
    # =========================================================
    OCSB_BASE_DIR=${lib.escapeShellArg cfg.workspace.baseDir}
    OCSB_DIR="$PROJECT_DIR/$OCSB_BASE_DIR"
    WS_DIR="$OCSB_DIR/$WORKSPACE_NAME"

    # =========================================================
    # Symlink escape protection
    # =========================================================
    OCSB_DIR_REAL="$(${pkgs.coreutils}/bin/realpath -m "$OCSB_DIR")"
    WS_DIR_REAL="$(${pkgs.coreutils}/bin/realpath -m "$WS_DIR")"

    if [[ "$OCSB_DIR_REAL" != "$PROJECT_DIR"/* ]] && [[ "$OCSB_DIR_REAL" != "$PROJECT_DIR" ]]; then
      echo "ocsb: workspace base directory escapes project root (symlink?)" >&2
      exit 1
    fi
    if [[ "$WS_DIR_REAL" != "$PROJECT_DIR"/* ]]; then
      echo "ocsb: workspace directory escapes project root" >&2
      exit 1
    fi
    OCSB_DIR="$OCSB_DIR_REAL"
    WS_DIR="$WS_DIR_REAL"

    # =========================================================
    # Per-workspace lock and state (outside project tree — symlink-safe)
    # =========================================================
    PROJECT_HASH="$(echo -n "$PROJECT_DIR" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-16)"
    OVERLAY_STATE_DIR="$HOME/.cache/ocsb/$PROJECT_HASH/$WORKSPACE_NAME"
    ${pkgs.coreutils}/bin/mkdir -p "$OVERLAY_STATE_DIR"

    LOCK_FILE="$OVERLAY_STATE_DIR/.lock"
    exec 9>"$LOCK_FILE"
    if ! ${pkgs.util-linux}/bin/flock -n 9; then
      echo "ocsb: workspace '$WORKSPACE_NAME' is locked by another process" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$OCSB_DIR"

    if [[ -d "$WS_DIR" ]] || [[ -f "$OVERLAY_STATE_DIR/.strategy" ]]; then
      if [[ "$OVERWRITE" -eq 1 ]]; then
        echo "ocsb: overwriting workspace '$WORKSPACE_NAME'..." >&2
        # Use EXISTING strategy for cleanup (not the requested one)
        CLEANUP_STRATEGY="$WORKSPACE_STRATEGY"
        if [[ -f "$OVERLAY_STATE_DIR/.strategy" ]]; then
          CLEANUP_STRATEGY="$(< "$OVERLAY_STATE_DIR/.strategy")"
        fi
        # Strategy-specific cleanup before removing directories
        case "$CLEANUP_STRATEGY" in
          git-worktree)
            GWT_CLEANUP="$WS_DIR/worktree"
            if [[ -d "$GWT_CLEANUP" ]]; then
              ${pkgs.git}/bin/git -C "$PROJECT_DIR" worktree remove --force "$GWT_CLEANUP" 2>/dev/null || true
            fi
            ;;
          btrfs)
            BTRFS_CLEANUP="$WS_DIR/snapshot"
            if [[ -d "$BTRFS_CLEANUP" ]]; then
              ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$BTRFS_CLEANUP" 2>/dev/null || true
            fi
            ;;
        esac
        ${pkgs.coreutils}/bin/rm -rf "$WS_DIR"
        ${pkgs.coreutils}/bin/rm -rf "$OVERLAY_STATE_DIR/upper" "$OVERLAY_STATE_DIR/work"
        # Clean per-directory overlay and snapshot state
        for _d in "$OVERLAY_STATE_DIR"/ovl-*; do
          [[ -d "$_d" ]] && ${pkgs.coreutils}/bin/rm -rf "$_d"
        done
        for _d in "$OVERLAY_STATE_DIR"/snap-*; do
          if [[ -d "$_d" ]]; then
            ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$_d" 2>/dev/null || ${pkgs.coreutils}/bin/rm -rf "$_d"
          fi
        done
      elif [[ "$CONTINUE" -eq 1 ]]; then
        # Verify strategy matches what workspace was created with
        if [[ -f "$OVERLAY_STATE_DIR/.strategy" ]]; then
          EXISTING_STRATEGY="$(< "$OVERLAY_STATE_DIR/.strategy")"
          if [[ "$EXISTING_STRATEGY" != "$WORKSPACE_STRATEGY" ]]; then
            echo "ocsb: workspace '$WORKSPACE_NAME' was created with strategy '$EXISTING_STRATEGY', cannot continue with '$WORKSPACE_STRATEGY'" >&2
            echo "  Use --overwrite to recreate with a different strategy." >&2
            exit 1
          fi
        fi
        echo "ocsb: continuing workspace '$WORKSPACE_NAME'..." >&2
      else
        echo "ocsb: workspace '$WORKSPACE_NAME' already exists." >&2
        echo "  Use --continue to resume, or --overwrite to start fresh." >&2
        exit 1
      fi
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$WS_DIR"
    echo "$WORKSPACE_STRATEGY" > "$OVERLAY_STATE_DIR/.strategy"

    # =========================================================
    # Strategy-specific flags
    # =========================================================
    STRATEGY_FLAGS=()

    case "$WORKSPACE_STRATEGY" in
      overlayfs)
        ${pkgs.coreutils}/bin/mkdir -p "$OVERLAY_STATE_DIR/upper" "$OVERLAY_STATE_DIR/work"
        STRATEGY_FLAGS=(
          --overlay-src "$PROJECT_DIR"
          --overlay "$OVERLAY_STATE_DIR/upper" "$OVERLAY_STATE_DIR/work" /workspace
        )
        echo "ocsb: overlay workspace at $OVERLAY_STATE_DIR" >&2
        ;;
      direct)
        STRATEGY_FLAGS=(
          --bind "$PROJECT_DIR" /workspace
        )
        echo "ocsb: direct mount (read-write, no isolation)" >&2
        ;;
      btrfs)
        # btrfs strategy: create a snapshot of the project directory as workspace
        BTRFS_SNAP="$WS_DIR/snapshot"
        if [[ "$CONTINUE" -eq 1 ]] && [[ -d "$BTRFS_SNAP" ]]; then
          echo "ocsb: reusing btrfs snapshot at $BTRFS_SNAP" >&2
        else
          # Check if project dir is on btrfs and we can manage subvolumes
          if ! _btrfs_probe "$PROJECT_DIR"; then
            echo "ocsb: btrfs strategy unavailable: $_btrfs_probe_reason" >&2
            echo "  Hint: ensure project dir is on btrfs and the filesystem is mounted with 'user_subvol_rm_allowed'." >&2
            exit 1
          fi
          # Create a read-write snapshot of the project directory
          if [[ -d "$BTRFS_SNAP" ]]; then
            ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$BTRFS_SNAP" 2>/dev/null || ${pkgs.coreutils}/bin/rm -rf "$BTRFS_SNAP"
          fi
          ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot "$PROJECT_DIR" "$BTRFS_SNAP"
          echo "ocsb: created btrfs snapshot at $BTRFS_SNAP" >&2
        fi
        STRATEGY_FLAGS=(
          --bind "$BTRFS_SNAP" /workspace
        )
        ;;
      git-worktree)
        # git-worktree strategy: create a worktree for the workspace
        GWT_DIR="$WS_DIR/worktree"
        if [[ "$CONTINUE" -eq 1 ]] && [[ -d "$GWT_DIR" ]]; then
          echo "ocsb: reusing git worktree at $GWT_DIR" >&2
        else
          # Verify we're in a git repo
          if ! ${pkgs.git}/bin/git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
            echo "ocsb: git-worktree strategy requires project directory to be a git repository" >&2
            exit 1
          fi
          # Remove existing worktree if present
          if [[ -d "$GWT_DIR" ]]; then
            ${pkgs.git}/bin/git -C "$PROJECT_DIR" worktree remove --force "$GWT_DIR" 2>/dev/null || ${pkgs.coreutils}/bin/rm -rf "$GWT_DIR"
          fi
          # Create a detached worktree from HEAD
          ${pkgs.git}/bin/git -C "$PROJECT_DIR" worktree add --detach "$GWT_DIR" HEAD
          echo "ocsb: created git worktree at $GWT_DIR" >&2
        fi
        STRATEGY_FLAGS=(
          --bind "$GWT_DIR" /workspace
        )
        ;;
      *)
        echo "ocsb: unknown strategy: $WORKSPACE_STRATEGY" >&2
        exit 1
        ;;
    esac

    # =========================================================
    # Git metadata: safe discovery via git rev-parse
    # =========================================================
    # Use git rev-parse instead of manual .git file parsing to avoid
    # mounting arbitrary host paths from crafted .git files.
    # Unset GIT_* env vars to prevent host environment contamination.
    GIT_METADATA_FLAGS=()

    case "$WORKSPACE_STRATEGY" in
      overlayfs|direct) _GIT_CHECK_SRC="$PROJECT_DIR" ;;
      btrfs) _GIT_CHECK_SRC="''${BTRFS_SNAP:-}" ;;
      git-worktree) _GIT_CHECK_SRC="''${GWT_DIR:-}" ;;
      *) _GIT_CHECK_SRC="" ;;
    esac

    if [[ -n "$_GIT_CHECK_SRC" ]]; then
      _GITDIR_PATH="$(${pkgs.coreutils}/bin/env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        ${pkgs.git}/bin/git -C "$_GIT_CHECK_SRC" rev-parse --absolute-git-dir 2>/dev/null)" || _GITDIR_PATH=""

      if [[ -n "$_GITDIR_PATH" ]] && [[ -d "$_GITDIR_PATH" ]]; then
        # Security: constrain git metadata to project root boundary
        _GITDIR_REAL="$(${pkgs.coreutils}/bin/realpath -m "$_GITDIR_PATH")"
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
            _COMMONDIR_REAL="$(${pkgs.coreutils}/bin/realpath -m "$_COMMONDIR_PATH")"
            if [[ "$_COMMONDIR_REAL" != "$PROJECT_DIR"/* ]] && [[ "$_COMMONDIR_REAL" != "$PROJECT_DIR" ]]; then
              echo "ocsb: warning: git common-dir escapes project root, skipping: $_COMMONDIR_PATH" >&2
            else
              # Use canonical path as bind source to prevent TOCTOU symlink-swap attacks
              GIT_METADATA_FLAGS+=("$_GIT_BIND" "$_COMMONDIR_REAL" "$_COMMONDIR_REAL")
            fi
          fi
        fi
      fi
    fi

    # =========================================================
    # Build bwrap argument array
    # =========================================================
    BWRAP_ARGS=(
      --unshare-all
      ${lib.optionalString (networkMode == "host" || dualLayerEnabled) "--share-net"}
      --die-with-parent
      --new-session
      --clearenv

      ${if networkMode == "filtered" && !dualLayerEnabled && cfg.app.runAsRoot then ''
      # Filtered mode + runAsRoot: uid 0 for CAP_NET_ADMIN (iptables best-effort).
      # uid 0 inside a user namespace has NO host privileges.
      --uid 0
      --gid 0
      '' else ''
      --uid "$(${pkgs.coreutils}/bin/id -u)"
      --gid "$(${pkgs.coreutils}/bin/id -g)"
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
        "--ro-bind-try /etc/resolv.conf /etc/resolv.conf"
      }
      --ro-bind-try /etc/ssl /etc/ssl
      --ro-bind-try /etc/static/ssl /etc/static/ssl
      --ro-bind-try /etc/nix /etc/nix
      --ro-bind-try /etc/passwd /etc/passwd
      --ro-bind-try /etc/group /etc/group
      --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf

      --symlink usr/lib /lib
      --symlink usr/lib64 /lib64

      --tmpfs /home
      --dir /home/sandbox
      --dir /home/sandbox/.config
      --dir /home/sandbox/.local

      --ro-bind "${sandboxBin}/bin" /usr/bin
      --symlink /usr/bin /bin
    )

    # Closure-only /nix/store mounts: mount each store path individually
    while IFS= read -r storePath; do
      BWRAP_ARGS+=(--ro-bind "$storePath" "$storePath")
    done < ${closureInfoDrv}/store-paths

    # User-configured read-only mounts (resolved at runtime for ~ expansion)
    ${mkMountArrayEntries "--ro-bind-try" cfg.mounts.ro}

    # User-configured read-write mounts
    ${mkMountArrayEntries "--bind-try" cfg.mounts.rw}

    # Workspace strategy mounts (must come before runtime mounts so /workspace exists)
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
      _OVL_STATE="$OVERLAY_STATE_DIR/ovl-$_OVL_HASH"
      ${pkgs.coreutils}/bin/mkdir -p "$_OVL_STATE/upper" "$_OVL_STATE/work"
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
      _SNAP_DIR="$OVERLAY_STATE_DIR/snap-$_SNAP_HASH"
      if [[ "$CONTINUE" -eq 1 ]] && [[ -d "$_SNAP_DIR" ]]; then
        echo "ocsb: reusing snapshot $_SNAP_HOST -> $_SNAP_SANDBOX" >&2
      else
        # Detect btrfs subvolume by inode (subvol roots have inode 256)
        _SNAP_INO="$(${pkgs.coreutils}/bin/stat -c %i "$_SNAP_HOST" 2>/dev/null || echo 0)"
        if [[ "$_SNAP_INO" != "256" ]]; then
          echo "ocsb: error: --snap-mount source must be a btrfs subvolume root: $_SNAP_HOST" >&2
          exit 1
        fi
        if [[ -d "$_SNAP_DIR" ]]; then
          ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$_SNAP_DIR" 2>/dev/null || ${pkgs.coreutils}/bin/rm -rf "$_SNAP_DIR"
        fi
        ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot "$_SNAP_HOST" "$_SNAP_DIR"
        echo "ocsb: snapshot mount $_SNAP_HOST -> $_SNAP_SANDBOX" >&2
      fi
      BWRAP_ARGS+=(--bind "$_SNAP_DIR" "$_SNAP_SANDBOX")
      _SNAP_IDX=$((_SNAP_IDX + 2))
    done

    # Git metadata mounts (for gitfile-backed repos)
    if [[ ''${#GIT_METADATA_FLAGS[@]} -gt 0 ]]; then
      BWRAP_ARGS+=("''${GIT_METADATA_FLAGS[@]}")
    fi

    # Environment
    BWRAP_ARGS+=(
  --setenv HOME /home/sandbox
  --setenv PATH /usr/bin
  --setenv TERM "''${TERM:-xterm-256color}"
  --setenv SSL_CERT_FILE "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
  --setenv SANDBOX 1
      --setenv OCSB_WORKSPACE "$WORKSPACE_NAME"
      --setenv OCSB_STRATEGY "$WORKSPACE_STRATEGY"
      --setenv OCSB_NETWORK "${if dualLayerEnabled then "dual-layer" else networkMode}"
      --setenv OCSB_HOST_UID "$(${pkgs.coreutils}/bin/id -u)"
      --setenv OCSB_HOST_GID "$(${pkgs.coreutils}/bin/id -g)"
      ${lib.optionalString dualLayerEnabled ''--setenv SHELL "${sandboxShell}"''}
      ${lib.optionalString dualLayerEnabled ''--setenv OCSB_DUAL_LAYER outer''}
    )
    ${envSetenvEntries}

    # Working directory and command
    BWRAP_ARGS+=(
      --chdir /workspace
    )

    # =========================================================
    # Determine sandbox command
    # =========================================================
    SANDBOX_CMD=()
    ${if cfg.app.package != null then ''
    SANDBOX_CMD=(${lib.escapeShellArg appExec} "$@")
    '' else ''
    if [[ $# -gt 0 ]]; then
      if [[ "$1" == -* ]]; then
        SANDBOX_CMD=(${lib.escapeShellArg appExec} "$@")
      else
        SANDBOX_CMD=("$@")
      fi
    else
      SANDBOX_CMD=(${lib.escapeShellArg appExec})
    fi
    ''}

    ${lib.optionalString (preExecScript != null) ''
    SANDBOX_CMD=(${preExecScript} "''${SANDBOX_CMD[@]}")
    ''}

    # =========================================================
    # Exec bwrap
    # =========================================================
    ${if networkMode == "filtered" && !dualLayerEnabled then ''
    _NET_TMP="$(${pkgs.coreutils}/bin/mktemp -d)"
    _BWRAP_PID=""
    _SLIRP_PID=""

    _cleanup_net() {
      [[ -n "$_BWRAP_PID" ]] && kill "$_BWRAP_PID" 2>/dev/null || true
      [[ -n "$_SLIRP_PID" ]] && kill "$_SLIRP_PID" 2>/dev/null || true
      ${pkgs.coreutils}/bin/rm -rf "$_NET_TMP"
    }
    trap _cleanup_net EXIT

    ${pkgs.coreutils}/bin/mkfifo "$_NET_TMP/info"

    (
      exec ${pkgs.bubblewrap}/bin/bwrap \
        "''${BWRAP_ARGS[@]}" \
        --info-fd 3 \
        -- ${networkSetupScript} "''${SANDBOX_CMD[@]}" \
        3>"$_NET_TMP/info"
    ) &
    _BWRAP_PID=$!

    _CHILD_PID=$(${pkgs.coreutils}/bin/timeout 10 ${pkgs.jq}/bin/jq -r '.["child-pid"]' < "$_NET_TMP/info") || {
      >&2 echo "ocsb: failed to start sandbox with network filtering"
      exit 1
    }

    ${pkgs.slirp4netns}/bin/slirp4netns --configure --disable-host-loopback "$_CHILD_PID" tap0 &
    _SLIRP_PID=$!

    set +e
    wait "$_BWRAP_PID"
    _BWRAP_RC=$?
    _BWRAP_PID=""
    exit $_BWRAP_RC
    '' else ''
    # Simple exec: host network or no network
    exec ${pkgs.bubblewrap}/bin/bwrap "''${BWRAP_ARGS[@]}" -- "''${SANDBOX_CMD[@]}"
    ''}
  '';

in
pkgs.writeShellScriptBin cfg.app.name ''
  exec ${launcher} "$@"
''
