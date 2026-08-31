{ pkgs
, mkSandbox
, dssbModule ? import ./module.nix
, dshPackage ? pkgs.callPackage ./package.nix { }
}:

rec {
  package = dshPackage;
  sandboxBase = mkSandbox {
    imports = [ dssbModule ];
    dssb.package = package;
  };
  wrapper = pkgs.callPackage ./wrapper.nix {
    dssbSandboxBase = sandboxBase;
  };
}
