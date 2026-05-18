{ pkgs, hermesAgentPackage }:

{ ... }:

{
  app = {
    name = "hermes-agent";
    package = hermesAgentPackage;
    binPath = "bin/hermes";
    # Run in gateway mode: long-lived messaging service (Telegram/Discord/Slack/...).
    # This matches upstream NixOS module's `hermes gateway run --replace`.
    args = ["gateway" "run" "--replace"];
    runAsRoot = false;
    preExecHook = ''
      set -euo pipefail

      export HERMES_HOME="$HOME/.hermes"
      export MESSAGING_CWD="/home/sandbox"

      mkdir -p "$HOME/.config/nix"
      mkdir -p "$HERMES_HOME" "$MESSAGING_CWD" "$HERMES_HOME/cron" "$HERMES_HOME/sessions" "$HERMES_HOME/logs" "$HERMES_HOME/memories" "$HERMES_HOME/plugins"

      if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then
        cat > "$HERMES_HOME/config.yaml" <<EOF
      messaging:
        cwd: /home/sandbox
      EOF
      fi

      _API_KEYS_FILE="''${OCSB_HERMES_AGENT_API_KEYS_ENV_FILE:-}"
      if [[ -n "$_API_KEYS_FILE" ]]; then
        if [[ ! -r "$_API_KEYS_FILE" ]]; then
          echo "[hermes-agent] OCSB_HERMES_AGENT_API_KEYS_ENV_FILE is not readable: $_API_KEYS_FILE" >&2
          exit 1
        fi
        source "$_API_KEYS_FILE"
      fi

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