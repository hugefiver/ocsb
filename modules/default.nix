# Root module — imports all ocsb option definitions
{ ... }:
{
  imports = [
    ./app.nix
    ./packages.nix
    ./mounts.nix
    ./workspace.nix
    ./env.nix
    ./network.nix
  ];
}
