let
  pkgs = import <nixpkgs> {};
  lib = pkgs.lib;
  mkSandbox = import ../lib/mkSandbox.nix { inherit pkgs lib; };
in mkSandbox ({ pkgs, ... }: {
  app.name = "ocsb-dual-test";
  packages = with pkgs; [ coreutils curl jq iproute2 gnugrep ];
  workspace = { strategy = "direct"; baseDir = ".ocsb"; name = "_"; };
  experimental.dualLayer = true;
  env = {};
  mounts.ro = [];
  mounts.rw = [];
})
