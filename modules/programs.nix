# Declarative command aliases — expose one checked executable per package.
{ lib, ... }:
{
  options.programs = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
      options = {
        package = lib.mkOption {
          type = lib.types.package;
          description = "Package containing the declared command.";
        };

        binPath = lib.mkOption {
          type = lib.types.addCheck lib.types.str (v:
            v != ""
            && !(lib.hasPrefix "/" v)
            && !(builtins.elem ".." (lib.splitString "/" v))
          );
          description = ''
            Path to the command within package, relative to its root. It must
            be non-empty, relative, and cannot contain a '..' path segment.
          '';
          example = "bin/my-command";
        };
      };
    }));
    default = { };
    description = ''
      Named commands exposed at /usr/bin/<name>. Each declaration exposes only
      its selected executable, rather than the package's complete bin directory.
    '';
  };
}
