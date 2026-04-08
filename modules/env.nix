# Extra environment variables inside the sandbox
{ lib, ... }:
{
  options.env = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = ''
      Additional environment variables to set inside the sandbox.
      HOME, PATH, and TERM are set automatically.
    '';
    example = {
      EDITOR = "vim";
      OPENCODE_HOME = "/home/sandbox/.local/opencode";
    };
  };
}
