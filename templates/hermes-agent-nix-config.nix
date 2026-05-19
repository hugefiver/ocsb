{ pkgs, hermesAgentPackage, hermesInit ? (pkgs.callPackage ../lib/hermes-config.nix { }) { } }:

{ ... }:

{
  app = {
    name = "hermes-agent";
    package = hermesAgentPackage;
    binPath = "bin/hermes";
    runAsRoot = false;
    daemon = [
      {
        command = ''
          if [[ "''${OCSB_HERMES_NO_GATEWAY:-0}" != "1" ]]; then
            hermes gateway run --replace > "$HERMES_HOME/logs/gateway.log" 2>&1
          else
            exec ${pkgs.coreutils}/bin/sleep infinity
          fi
        '';
        restart = true;
      }
    ];
    preExecHook = ''
      set -euo pipefail

      # --- ocsb sandbox env ---
      export HERMES_HOME="$HOME/.hermes"
      export MESSAGING_CWD="/home/sandbox"

      # --- hermes init (dirs + config.yaml) ---
      ${hermesInit}

      # --- persistent venv for Python packages ---
      _HERMES_VENV="$HOME/.hermes-venv"
      if [[ ! -d "$_HERMES_VENV" ]]; then
        python3 -m venv "$_HERMES_VENV"
        "$_HERMES_VENV/bin/pip" install --quiet --upgrade pip
      fi
      _VENV_SITE=$("$_HERMES_VENV/bin/python" -c 'import site; print(site.getsitepackages()[0])')
      export PYTHONPATH="$_VENV_SITE''${PYTHONPATH:+:$PYTHONPATH}"
      export PATH="$_HERMES_VENV/bin:$PATH"

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
    procps
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
    OCSB_HERMES_NO_GATEWAY = "0";
  };
}