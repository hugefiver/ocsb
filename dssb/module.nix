{ config, lib, pkgs, ... }:

let
  validCommand = name:
    builtins.match "^[A-Za-z0-9][A-Za-z0-9._+-]*$" name != null
    && !(lib.hasInfix ".." name);

  programType = lib.types.attrsOf (lib.types.submodule ({ ... }: {
    options = {
      package = lib.mkOption {
        type = lib.types.package;
        description = "Package containing the declared DSH command.";
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

in
{
  options.dssb = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      description = "DSH package used by the DSSB sandbox.";
    };

    extraPrograms = lib.mkOption {
      type = programType;
      default = { };
      apply = programs:
        assert lib.assertMsg
          (lib.all validCommand (builtins.attrNames programs))
          "dssb.extraPrograms command names must match ^[A-Za-z0-9][A-Za-z0-9._+-]*$ and cannot contain '..'";
        programs;
      description = ''
        Named commands made available to DSH at /usr/bin/<name>. Command names
        use the same validation as the generic programs option.
      '';
    };
  };

  config = lib.mkMerge [
    {
      app = {
        name = "dssb";
        package = config.dssb.package;
        binPath = "bin/dsh";
      };

      workspace = {
        strategy = "auto";
        baseDir = ".ocsb";
        name = "dssb";
        sandboxDir = "/workspace";
      };

      network.enable = true;

      env = {
        DSH_HOME = "/home/sandbox/.dsh";
        DSH_PERMISSION_MODE = "danger-full-access";
        DSH_TELEMETRY_DISABLED = "1";
      };

      packages = with pkgs; [
        coreutils
        findutils
        gnugrep
        gnused
        gawk
        git
        curl
        ripgrep
        fd
        jq
        which
      ];

      programs.pnpm = {
        package = pkgs.pnpm;
        binPath = "bin/pnpm";
      };
    }

    {
      programs = config.dssb.extraPrograms;
    }
  ];
}
