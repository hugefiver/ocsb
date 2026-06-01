{ pkgs, hermesAgentPackage, hermesServicePackage }:

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
            exec service gateway supervise
          else
            exec ${pkgs.coreutils}/bin/sleep infinity
          fi
        '';
        restart = true;
      }
    ];
    preExecHook = ''
      set -euo pipefail

      export HERMES_HOME="$HOME/.hermes"
      export MESSAGING_CWD="/home/sandbox"

      mkdir -p "$HOME/.config/nix"
      mkdir -p "$HERMES_HOME" "$MESSAGING_CWD" "$HERMES_HOME/cron" "$HERMES_HOME/sessions" "$HERMES_HOME/logs" "$HERMES_HOME/memories" "$HERMES_HOME/plugins"

      # --- persistent venv for Python packages ---
      # Persisted in $HOME so it survives workspace resets.
      # Hermes can `pip install` runtime dependencies into it;
      # PYTHONPATH ensures they're importable without modifying the Nix closure.
      _HERMES_VENV="$HOME/.hermes-venv"
      if [[ ! -d "$_HERMES_VENV" ]]; then
        python3 -m venv "$_HERMES_VENV"
        "$_HERMES_VENV/bin/pip" install --quiet --upgrade pip
      fi
      _VENV_SITE=$("$_HERMES_VENV/bin/python" -c 'import site; print(site.getsitepackages()[0])')
      export PYTHONPATH="$_VENV_SITE''${PYTHONPATH:+:$PYTHONPATH}"
      export PATH="$_HERMES_VENV/bin:$PATH"

      if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then
        cat > "$HERMES_HOME/config.yaml" <<EOF
      messaging:
        cwd: /home/sandbox
EOF
      fi

      # --- api keys ---
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

  packages = [ hermesServicePackage ] ++ (with pkgs; [
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
  ]);

  mounts.rw = [];

  mounts.ro = [];

  workspace = {
    # The host wrapper launches from $PERSIST_DIR/home, so direct strategy maps
    # that persistent home to /home/sandbox.
    strategy = "direct";
    sandboxDir = "/home/sandbox";
    baseDir = ".ocsb";
    name = "hermes-agent";
  };

  network = {
    # Hermes must run non-root. Filtered/slirp mode currently requires uid 0 in
    # ocsb, so use host networking until multi-uid mappings are supported.
    enable = null;
  };

  env = {
    LANG = "C.UTF-8";
    EDITOR = "cat";
    OCSB_HERMES_NO_GATEWAY = "0";
  };
}
