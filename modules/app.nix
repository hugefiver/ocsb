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
  };

}
