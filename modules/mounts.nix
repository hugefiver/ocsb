# Mount configuration — read-only and read-write bind mounts
{ lib, ... }:
{
  options.mounts = {
    ro = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Host paths to bind-mount read-only inside the sandbox.
        Paths are mounted at the same location inside the sandbox.
        Uses --ro-bind-try so missing paths are silently skipped.
      '';
      example = [
        "~/.local/opencode"
        "~/.config/opencode"
      ];
    };

    rw = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Host paths to bind-mount read-write inside the sandbox.
        Paths are mounted at the same location inside the sandbox.
        Uses --bind-try so missing paths are silently skipped.
      '';
      example = [
        "~/.local/share/opencode"
      ];
    };
  };
}
