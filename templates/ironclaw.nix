{ pkgs, ironclawPackage }:

{ ... }:

let
  pgWithExt = pkgs.postgresql_18.withPackages (p: [ p.pgvector ]);
in
{
  # nixStoreMode defaults to "chroot" — sandbox gets a real, writable
  # /nix/store preseeded with hard links when possible, falling back to
  # `nix copy` on first launch. Override to
  # "host-daemon" or "closure" via experimental.nixStoreMode if desired.

  app = {
    name = "ironclaw";
    package = ironclawPackage;
    binPath = "bin/ironclaw";
    runAsRoot = false;
    preExecHook = ''
      set -euo pipefail

      DB_MODE="''${OCSB_IRONCLAW_DB_MODE:-embedded}"
      case "$DB_MODE" in
        embedded|external|sidecar) ;;
        *)
          echo "[ironclaw] invalid OCSB_IRONCLAW_DB_MODE: $DB_MODE (expected embedded|external|sidecar)" >&2
          exit 1
          ;;
      esac

      mkdir -p "$HOME/.config/nix"
      mkdir -p "$HOME/.ironclaw" "$HOME/.claude"
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

      if [[ "$DB_MODE" == "embedded" ]]; then
        PGDATA=/var/lib/postgresql/data
        PGRUN=/run/postgresql
        export PGDATA
        export PGHOST="$PGRUN"
        export DATABASE_URL="postgres:///ironclaw?host=/run/postgresql&sslmode=disable"
        export DATABASE_BACKEND="postgres"
        export DATABASE_SSLMODE="disable"
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
      else
        DB_ENV_FILE="''${OCSB_IRONCLAW_DB_ENV_FILE:-/tmp/ocsb-ironclaw-db.env}"
        if [[ ! -r "$DB_ENV_FILE" ]]; then
          echo "[ironclaw] db mode '$DB_MODE' requires readable db env file: $DB_ENV_FILE" >&2
          exit 1
        fi
        # Host wrapper writes shell-safe `export KEY=%q` lines to this private
        # file (0600 host-side, mounted read-only) to avoid exposing DB secrets
        # through bwrap --setenv argv.
        source "$DB_ENV_FILE"
        if [[ -z "''${DATABASE_URL:-}" ]]; then
          echo "[ironclaw] db mode '$DB_MODE' requires DATABASE_URL" >&2
          exit 1
        fi
        export DATABASE_BACKEND="''${DATABASE_BACKEND:-postgres}"
      fi

      mkdir -p /var/lib/ironclaw
      export IRONCLAW_DATA_DIR=/var/lib/ironclaw
      export IRONCLAW_BASE_DIR="$HOME/.ironclaw"

      # Persist a SECRETS_MASTER_KEY so the onboard wizard skips the keychain
      # step (no D-Bus secret service inside the sandbox). 32 random bytes
      # hex-encoded = 64 chars; ironclaw treats env-var presence as authoritative
      # and returns early from step_security().
      _MK_FILE=/var/lib/ironclaw/master_key.hex
      if [ ! -s "$_MK_FILE" ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$_MK_FILE"
        chmod 0600 "$_MK_FILE"
      fi
      export SECRETS_MASTER_KEY="$(cat "$_MK_FILE")"
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
    gh
    pkg-config
    gcc
    gnumake
    nodejs
    python3
    cargo
    rustc
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
    # App persistence lives under wrapper-managed mounts.rw (data, pgdata,
    # etc). The wrapper launches ocsb from $PERSIST_DIR/home and mounts that
    # directory directly as /home/sandbox, so Ironclaw's workspace and HOME are
    # the same persisted tree.
    strategy = "direct";
    sandboxDir = "/home/sandbox";
    baseDir = ".ocsb";
    name = "ironclaw";
  };

  network = {
    # Ironclaw starts postgres in preExecHook, and postgres refuses to run as
    # uid 0. The filtered slirp4netns path currently requires uid 0 inside the
    # bwrap user namespace so slirp can enter the network namespace. Use host
    # networking for this template until the sandbox grows multi-uid mappings.
    enable = null;
  };

  env = {
    LANG = "C.UTF-8";
    EDITOR = "cat";
    RUST_LOG = "ironclaw=info";
    CLAUDE_CONFIG_DIR = "/home/sandbox/.claude";
    SANDBOX_ENABLED = "true";
    SANDBOX_POLICY = "readonly";
  };
}
