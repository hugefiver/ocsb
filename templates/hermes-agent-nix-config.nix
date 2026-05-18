{ pkgs, hermesAgentPackage, hermesInit ? pkgs.callPackage ../lib/hermes-config.nix { } }:

{ ... }:

{
  app = {
    name = "hermes-agent";
    package = hermesAgentPackage;
    binPath = "bin/hermes";
    runAsRoot = false;
    preExecHook = ''
      set -euo pipefail

      # --- ocsb sandbox env ---
      export HERMES_HOME="$HOME/.hermes"
      export MESSAGING_CWD="/home/sandbox"

      # --- hermes init (dirs + config.yaml) ---
      ${hermesInit}

      # --- nix config ---
      mkdir -p "$HOME/.config/nix"
      cat > "$HOME/.config/nix/nix.conf" <<EOF
      experimental-features = nix-command flakes
      build-users-group =
      sandbox = false
      substituters = https://cache.nixos.org
      trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      max-jobs = auto
      cores = 0
      warn-dirty = false
      accept-flake-config = true
      EOF

      # --- api keys ---
      _API_KEYS_FILE="''${OCSB_HERMES_AGENT_API_KEYS_ENV_FILE:-}"
      if [[ -n "$_API_KEYS_FILE" ]]; then
        if [[ ! -r "$_API_KEYS_FILE" ]]; then
          echo "[hermes-agent] OCSB_HERMES_AGENT_API_KEYS_ENV_FILE is not readable: $_API_KEYS_FILE" >&2
          exit 1
        fi
        source "$_API_KEYS_FILE"
      fi
    '';
  };

  packages = with pkgs; [
    coreutils
    gnused
    gawk
    gnugrep
    findutils
    which
    bash
    less
    file
    git
    curl
    ripgrep
    nodejs
    python3
    nix
    cacert
  ];

  mounts.rw = [];
  mounts.ro = [];

  workspace = {
    strategy = "direct";
    sandboxDir = "/home/sandbox";
    baseDir = ".ocsb";
    name = "hermes-agent";
  };

  network = {
    enable = null;
  };

  env = {
    LANG = "C.UTF-8";
    EDITOR = "cat";
  };
}