{ pkgs, ironclawPackage }:

{ ... }:

let
  pgWithExt = pkgs.postgresql_18.withPackages (p: [ p.pgvector ]);
in
{
  app = {
    name = "ironclaw";
    package = ironclawPackage;
    binPath = "bin/ironclaw";
    runAsRoot = false;
    preExecHook = ''
      set -euo pipefail

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

      NIX_MODE="''${OCSB_IRONCLAW_NIX_MODE:-single-user}"
      case "$NIX_MODE" in
        portable)
          # TODO: nix-portable is not packaged in nixpkgs. To enable this mode,
          # add DavHau/nix-portable as a flake input and inject its binary into
          # PATH here, or fetchurl the static release binary.
          echo "[ironclaw] portable mode not yet supported (no nix-portable available)" >&2
          exit 1
          ;;
        single-user)
          export NIX_STORE_DIR="$HOME/.local/nix/store"
          export NIX_STATE_DIR="$HOME/.local/nix/var"
          export NIX_LOG_DIR="$HOME/.local/nix/var/log/nix"
          mkdir -p "$NIX_STORE_DIR" "$NIX_STATE_DIR" "$NIX_LOG_DIR"
          cat >> "$HOME/.config/nix/nix.conf" <<EOF
      store = $NIX_STORE_DIR
      state-dir = $NIX_STATE_DIR
      EOF
          ;;
        isolated-store)
          # Known limitation: /nix/store overlay for isolated upper layer is not
          # automatically configured by ocsb yet.
          :
          ;;
        *)
          echo "Unknown OCSB_IRONCLAW_NIX_MODE: $NIX_MODE" >&2
          exit 1
          ;;
      esac

      PGDATA=/var/lib/postgresql/data
      PGRUN=/run/postgresql
      export PGDATA
      mkdir -p "$PGRUN"
      chmod 0700 "$PGDATA" 2>/dev/null || true

      # Use postgresql.withPackages buildEnv: pgvector is installed under
      # PG's default share/postgresql/extension and lib paths, found via
      # compile-time prefix. No extension_control_path needed.
      _PG_BIN="${pgWithExt}/bin"

      if [ ! -f "$PGDATA/PG_VERSION" ]; then
        echo "[ironclaw] initializing postgres cluster..."
        "$_PG_BIN/initdb" -D "$PGDATA" --auth=trust --no-locale --encoding=UTF8 -U "$(whoami)"
      fi

      "$_PG_BIN/pg_ctl" -D "$PGDATA" -l "$HOME/postgres.log" -w \
        -o "-k $PGRUN -h ''' -c listen_addresses='''" \
        start

      trap '"$_PG_BIN/pg_ctl" -D "$PGDATA" -m fast stop || true' EXIT

      if ! "$_PG_BIN/psql" -h "$PGRUN" -lqt | cut -d \| -f 1 | grep -qw ironclaw; then
        "$_PG_BIN/createdb" -h "$PGRUN" ironclaw
      fi
      "$_PG_BIN/psql" -h "$PGRUN" -d ironclaw -c "CREATE EXTENSION IF NOT EXISTS vector;"

      mkdir -p /var/lib/ironclaw
      export IRONCLAW_DATA_DIR=/var/lib/ironclaw
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
    # If pgvector is unavailable for postgresql_18 in your pinned nixpkgs,
    # fall back to postgresql_17.withPackages (p: [ p.pgvector ]).
    pgWithExt
    nix
    cacert
    openssl
  ];

  mounts.rw = [
    # Persistence is mounted by the host-side wrapper (packages.*.ironclaw-sandbox)
    # because the path depends on runtime workspace and env/CLI overrides.
  ];

  mounts.ro = [];

  workspace = {
    # All persistent state lives under mounts.rw bind-mounts (home, data, pgdata, etc).
    # cwd is irrelevant to ironclaw, so skip CoW snapshot overhead and bind cwd directly.
    strategy = "direct";
    baseDir = ".ocsb";
    name = "ironclaw";
  };

  network = {
    enable = true;
    tunDevice = "Mihomo";
  };

  env = {
    LANG = "C.UTF-8";
    EDITOR = "cat";
    PGHOST = "/run/postgresql";
    DATABASE_URL = "postgres:///ironclaw?host=/run/postgresql";
  };
}
