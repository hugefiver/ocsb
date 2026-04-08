{
  description = "ocsb - Nix sandbox for OpenCode with isolated filesystem and workspace branching";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      mkPkgs = system: nixpkgs.legacyPackages.${system};
    in
    {
      # Core library: mkSandbox function
      lib.mkSandbox = { system ? "x86_64-linux" }:
        let
          pkgs = mkPkgs system;
        in
        import ./lib/mkSandbox.nix { inherit pkgs; lib = nixpkgs.lib; };

      # Pre-built sandbox packages (one per system)
      packages = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          mkSandbox = import ./lib/mkSandbox.nix { inherit pkgs; lib = nixpkgs.lib; };
        in
        {
          default = mkSandbox (import ./templates/opencode.nix { inherit pkgs; });
        }
      );

      # Dev shells for working on ocsb itself
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
