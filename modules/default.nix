# Root module — imports all ocsb option definitions
{ ... }:
{
  imports = [
    ./app.nix
    ./packages.nix
    ./programs.nix
    ./mounts.nix
    ./workspace.nix
    ./env.nix
    ./network.nix
    ./backend.nix
    ./experimental.nix
  ];
}
