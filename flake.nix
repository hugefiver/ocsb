{
  description = "ocsb - Nix sandbox for OpenCode with isolated filesystem and workspace branching";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v2026.5.29";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Track ironclaw releases. The "latest" alias (`ironclaw-src`) points at the
    # newest tag we ship; retained older releases are pinned independently and
    # remain buildable as `ironclaw_v0_28_1`, etc. Retention policy:
    #   - keep two 0.<minor> series;
    #   - keep two releases for the newest 0.<minor> series;
    #   - keep only the latest release for older retained series, unless that
    #     series gets post-newer-series updates, then append and retain those two
    #     follow-up releases.
    ironclaw-src = {
      url = "github:nearai/ironclaw/ironclaw-v0.29.0";
      flake = false;
    };
    ironclaw-src-v0_28_2 = {
      url = "github:nearai/ironclaw/faf2ed446534a4bb403b375da05061ed636427fb";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, hermes-agent, ironclaw-src, ironclaw-src-v0_28_2, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      lib = nixpkgs.lib;

      mkPkgs = system: nixpkgs.legacyPackages.${system};

      # Latest first. The first entry's package becomes the unversioned
      # `ironclaw` / `ironclaw-sandbox` aliases.
      ironclawVersionSeries = [
        {
          series = "0.29";
          releases = [
            { slug = "v0_29_0"; version = "0.29.0"; src = ironclaw-src; }
          ];
        }
        {
          series = "0.28";
          releases = [
            { slug = "v0_28_2"; version = "0.28.2"; src = ironclaw-src-v0_28_2; }
          ];
        }
      ];

      ironclawVersions = lib.concatMap (series: series.releases) ironclawVersionSeries;

      # Micro-architecture variants. The first entry is the unsuffixed default
      # (psABI x86-64-v1, baseline). Additional entries produce parallel
      # packages with `_<archSlug>` appended to every name.
      ironclawArchs = [
        { archSlug = ""; microArch = "x86-64"; }
        { archSlug = "x86_64_v3"; microArch = "x86-64-v3"; }
      ];
    in
    {
      lib.mkSandbox = { system ? "x86_64-linux" }:
        let
          pkgs = mkPkgs system;
        in
        import ./lib/mkSandbox.nix { inherit pkgs; lib = nixpkgs.lib; };

      packages = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          mkSandbox = import ./lib/mkSandbox.nix { inherit pkgs; lib = nixpkgs.lib; };

          hermesAgentPackage = hermes-agent.packages.${system}.default;
          mkHermesAgentSandboxBase = mkSandbox (import ./templates/hermes-agent.nix {
            inherit pkgs hermesAgentPackage;
          });

          mkHermesAgentSandboxBin = pkgs.callPackage ./scripts/hermes-wrapper.nix {
            inherit mkHermesAgentSandboxBase;
          };

          mkHermesAgentNixConfigSandboxBase = mkSandbox (import ./templates/hermes-agent-nix-config.nix {
            inherit pkgs hermesAgentPackage;
          });
          mkHermesAgentNixConfigSandboxBin = pkgs.callPackage ./scripts/hermes-wrapper.nix {
            mkHermesAgentSandboxBase = mkHermesAgentNixConfigSandboxBase;
          };

          mkIronclawPackage = { src, version, microArch, ... }: pkgs.callPackage ./pkgs/ironclaw.nix {
            ironclaw-src = src;
            inherit version microArch;
          };

          mkIronclawSandboxBase = ironclawPackage: mkSandbox (import ./templates/ironclaw.nix {
            inherit pkgs ironclawPackage;
          });

          # `slug` controls wrapper/package names. `persistSlug` controls the
          # default state directory and intentionally omits arch suffixes so
          # optimized wrappers reuse the same Ironclaw data for a version.
          mkSandboxBin = { slug, persistSlug ? slug, ironclawSandboxBase }: pkgs.callPackage ./scripts/ironclaw-wrapper.nix {
            inherit slug persistSlug ironclawSandboxBase;
          };

          # Build per-version × per-arch package + sandbox wrapper.
          # First entry of ironclawVersions × first entry of ironclawArchs is
          # the "latest baseline" → `ironclaw` / `ironclaw-sandbox` aliases.
          # Per-arch suffix appended after version slug; empty archSlug means
          # the unsuffixed (baseline x86-64-v1) variant.
          versionEntries = lib.concatMap (v:
            lib.concatMap (a:
              let
                pkg = mkIronclawPackage (v // { inherit (a) microArch; });
                base = mkIronclawSandboxBase pkg;
                archSuffix = if a.archSlug == "" then "" else "_${a.archSlug}";
                fullSlug = "${v.slug}${archSuffix}";
              in
              [
                { name = "ironclaw_${fullSlug}"; value = pkg; }
                { name = "ironclaw-sandbox_${fullSlug}"; value = mkSandboxBin { slug = "_${fullSlug}"; persistSlug = "_${v.slug}"; ironclawSandboxBase = base; }; }
              ]
            ) ironclawArchs
          ) ironclawVersions;

          versionAttrs = lib.listToAttrs versionEntries;

          latestVersion = builtins.head ironclawVersions;
          baselineArch = builtins.head ironclawArchs;
          latestPkg = mkIronclawPackage (latestVersion // { inherit (baselineArch) microArch; });
          latestBase = mkIronclawSandboxBase latestPkg;

          # Per-arch latest aliases (e.g. `ironclaw_x86_64_v3` = latest version
          # at arch v3). The baseline arch is the unsuffixed `ironclaw`.
          latestArchEntries = lib.concatMap (a:
            if a.archSlug == "" then [] else
            let
              pkg = mkIronclawPackage (latestVersion // { inherit (a) microArch; });
              base = mkIronclawSandboxBase pkg;
            in
            [
              { name = "ironclaw_${a.archSlug}"; value = pkg; }
              { name = "ironclaw-sandbox_${a.archSlug}"; value = mkSandboxBin { slug = "_${a.archSlug}"; persistSlug = ""; ironclawSandboxBase = base; }; }
            ]
          ) ironclawArchs;
          latestArchAttrs = lib.listToAttrs latestArchEntries;
        in
        {
          default = mkSandbox (import ./templates/opencode.nix { inherit pkgs; });

          hermes-agent = hermesAgentPackage;
          hermes-agent-sandbox = mkHermesAgentSandboxBin;
          hermes-agent-sandbox-nix-config = mkHermesAgentNixConfigSandboxBin;

          # Aliases pointing at the latest tracked release (baseline arch).
          ironclaw = latestPkg;
          ironclaw-sandbox = mkSandboxBin { slug = ""; ironclawSandboxBase = latestBase; };
        } // versionAttrs // latestArchAttrs
      );

      # CI checks — build sandbox variants to verify they evaluate and build.
      # Versioned ironclaw builds are NOT in checks (heavy Rust compile);
      # they remain buildable on demand via `nix build .#ironclaw_v0_XX_X`.
      checks = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          mkSandbox = import ./lib/mkSandbox.nix { inherit pkgs; lib = nixpkgs.lib; };
        in
        {
          default = self.packages.${system}.default;

          ironclaw-retention-policy =
            let
              actualRetention = map (series: {
                inherit (series) series;
                releases = map (release: {
                  inherit (release) slug version;
                }) series.releases;
              }) ironclawVersionSeries;
              expectedRetention = [
                {
                  series = "0.29";
                  releases = [
                    { slug = "v0_29_0"; version = "0.29.0"; }
                  ];
                }
                {
                  series = "0.28";
                  releases = [
                    { slug = "v0_28_2"; version = "0.28.2"; }
                  ];
                }
              ];
            in
            assert actualRetention == expectedRetention;
            pkgs.runCommand "ironclaw-retention-policy" { } ''
              printf '%s\n' '${builtins.toJSON actualRetention}' > $out
            '';

          net-test = mkSandbox ({ pkgs, ... }: {
            app.name = "ocsb-net-test";
            packages = with pkgs; [ coreutils curl jq iptables iproute2 ];
            workspace = { strategy = "direct"; baseDir = ".ocsb"; name = "_"; };
            network.enable = true;
            env = {};
            mounts.ro = [];
            mounts.rw = [];
          });

          dual-layer-test = mkSandbox ({ pkgs, ... }: {
            app.name = "ocsb-dual-test";
            packages = with pkgs; [ coreutils curl jq iproute2 gnugrep ];
            workspace = { strategy = "direct"; baseDir = ".ocsb"; name = "_"; };
            experimental.dualLayer = true;
            env = {};
            mounts.ro = [];
            mounts.rw = [];
          });

          host-daemon-test = mkSandbox ({ pkgs, ... }: {
            app.name = "ocsb-host-daemon-test";
            packages = with pkgs; [ coreutils nix ];
            workspace = { strategy = "direct"; baseDir = ".ocsb"; name = "_"; };
            experimental.nixStoreMode = "host-daemon";
            env = {};
            mounts.ro = [];
            mounts.rw = [];
          });
        }
      );

      devShells = forAllSystems (system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              self.packages.${system}.default
            ];
          };
        }
      );
    };
}
