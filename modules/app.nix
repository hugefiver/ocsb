# App configuration — what to sandbox
{ lib, ... }:
{
  options.app = {
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        The main package to run inside the sandbox.
        If null, drops into an interactive bash shell.
      '';
    };

    binPath = lib.mkOption {
      type = lib.types.addCheck lib.types.str (v:
        v == "" || (!(lib.hasPrefix "/" v) && !(lib.hasInfix ".." v))
      );
      default = "";
      defaultText = lib.literalExpression ''"bin/<package-name>"'';
      description = ''
        Path to the binary within the package, relative to the package root.
        Only used when app.package is set. Must be specified if app.package is non-null.
        Must be a relative path and cannot contain '..' components.
      '';
      example = "bin/opencode";
    };

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Arguments passed to the app binary at startup.
        Example: ["gateway" "run" "--replace"] for Hermes Agent gateway mode.
      '';
      example = ["gateway" "run" "--replace"];
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "ocsb";
      description = "Name for the generated wrapper script derivation.";
      example = "ocsb-opencode";
    };

    preExecHook = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Bash code executed inside sandbox right before app.package binary, runs as sandbox user with full env.";
    };

    preserveCtty = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        If true (default), omit bwrap's --new-session flag so the sandboxed
        process inherits the controlling tty. Required for interactive TUI
        apps (ironclaw onboard wizard, --shell bash) — without ctty,
        readline/raw-mode input sees EOF and the app exits or auto-skips
        prompts.

        Set false to enable bwrap's --new-session, which calls setsid() to
        prevent TIOCSTI ioctl injection from inside the sandbox into the
        host tty. Modern kernels (>= 5.17) restrict TIOCSTI by default
        (dev.tty.legacy_tiocsti_restrict=1), making this mitigation largely
        redundant. Only set false for non-interactive batch workloads on
        older kernels where you explicitly want this hardening.
      '';
    };

    runAsRoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        In filtered network mode, run sandbox as uid 0 so the host-side
        slirp4netns helper can enter the sandbox network namespace and so
        best-effort iptables RFC1918 blocking can run. Set false only for apps
        that must not run as root (e.g. postgres initdb); such apps should use
        host networking (network.enable = null) until multi-uid mappings are
        supported.
      '';
    };

    daemon = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule ({ ... }: {
        options = {
          command = lib.mkOption {
            type = lib.types.str;
            description = "Shell command to run as a background daemon inside the sandbox.";
            example = "hermes gateway run --replace > $HERMES_HOME/logs/gateway.log 2>&1";
          };
          restart = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Automatically restart the daemon if it exits (non-zero or zero).";
          };
        };
      }));
      default = [];
      description = ''
        Background services managed by the sandbox supervisor (PID 1).
        Each daemon is spawned before the foreground app and monitored
        while the sandbox is alive. Use `restart = true` for crash-resistant
        long-lived services like messaging gateways.
      '';
    };
  };
}
