# Default OpenCode sandbox configuration
#
# Usage in flake.nix:
#   mkSandbox (import ./templates/opencode.nix { inherit pkgs; })

{ pkgs }:

{ ... }:

{
  app.name = "ocsb";
  # app.package = null → drops into interactive bash shell
  # Set app.package to an actual package to sandbox it, e.g.:
  # app.package = pkgs.opencode;
  # app.binPath = "bin/opencode";

  packages = with pkgs; [
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    diffutils
    patch
    git
    ripgrep
    fd
    tree
    jq
    curl
    less
  ];

  mounts.ro = [
    # Common config paths — silently skipped if absent (--ro-bind-try)
    "~/.config/opencode"
    "~/.local/share/opencode"
  ];

  mounts.rw = [
    # Add paths that need write access here
  ];

  workspace = {
    strategy = "overlayfs";
    baseDir = ".ocsb";
    name = "_";
  };

  env = {
    EDITOR = "cat";  # safe default — override as needed
    LANG = "C.UTF-8";
  };
}
