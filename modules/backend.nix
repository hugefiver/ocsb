# Runtime backend configuration
{ lib, ... }:
{
  options.backend = {
    type = lib.mkOption {
      type = lib.types.enum [ "bubblewrap" "podman" "systemd-nspawn" ];
      default = "bubblewrap";
      description = ''
        Runtime backend used by the generated launcher.

        - bubblewrap: default, full ocsb feature set.
        - podman: daemon/container-runtime backend using the same prepared
          workspace and /nix state, with a narrower v1 capability matrix.
        - systemd-nspawn: systemd-managed backend using the same prepared
          workspace and /nix state, with conservative v1 networking support.
      '';
    };

    podman.extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Extra arguments appended to `podman run` before the rootfs/command.
        Use this for site-specific daemon/runtime integration; ocsb still owns
        workspace, mount, environment, and /nix preparation.
      '';
    };

    systemdNspawn.extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Extra arguments appended to `systemd-nspawn` before the command.
        Use this for site-specific machine/scope integration; ocsb still owns
        workspace, mount, environment, and /nix preparation.
      '';
    };
  };
}
