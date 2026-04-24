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
      default = false;
      description = ''
        If true, omit bwrap's --new-session flag so the sandboxed process
        inherits the controlling tty. Required for interactive TUI apps
        (e.g. ironclaw onboard wizard, plain --shell bash) — without ctty,
        readline/raw-mode input sees EOF and the app exits or auto-skips
        prompts.

        Security tradeoff: --new-session prevents TIOCSTI ioctl injection
        from inside the sandbox into the host tty. Modern kernels (>= 5.17)
        restrict TIOCSTI by default (dev.tty.legacy_tiocsti_restrict=1),
        making this mitigation largely redundant. Keep false (default) for
        non-interactive or non-TUI workloads.
      '';
    };

    runAsRoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        In filtered network mode, run sandbox as uid 0 to gain CAP_NET_ADMIN
        for iptables RFC1918 blocking. Set false for apps that refuse to
        run as root (e.g. postgres initdb). When false, sandbox runs as
        host uid and iptables filtering is skipped (netns + slirp4netns +
        --disable-host-loopback isolation still active).
      '';
    };
  };

}
