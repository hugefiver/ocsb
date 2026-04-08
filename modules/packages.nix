# Package whitelist — only these are available inside the sandbox
{ lib, pkgs, ... }:
{
  options.packages = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [];
    description = ''
      Packages available inside the sandbox.
      bash is always included implicitly.
      Only binaries from these packages will be on PATH.
    '';
    example = lib.literalExpression "[ pkgs.coreutils pkgs.git pkgs.ripgrep ]";
  };
}
