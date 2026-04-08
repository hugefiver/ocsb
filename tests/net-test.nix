let
  pkgs = import <nixpkgs> {};
  lib = pkgs.lib;
  mkSandbox = import ../lib/mkSandbox.nix { inherit pkgs lib; };
in mkSandbox ({ pkgs, ... }: {
  app.name = "ocsb-net-test";
  packages = with pkgs; [ coreutils curl jq iptables iproute2 ];
  workspace = { strategy = "direct"; baseDir = ".ocsb"; name = "_"; };
  network.enable = true;
  env = {};
  mounts.ro = [];
  mounts.rw = [];
})
