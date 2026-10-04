{
  description = "Declarative /etc files for standalone Home Manager on SteamOS (Steam Deck, Steam Frame)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      homeManagerModules.default = ./hm-module.nix;

      checks = forAllSystems (pkgs: {
        sync = import ./checks/sync.nix { inherit pkgs; };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
