{
  description = "Declarative /etc files for standalone Home Manager on SteamOS (Steam Deck, Steam Frame)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Only for checks/activation.nix.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
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
        activation = import ./checks/activation.nix { inherit pkgs home-manager; };
        services = import ./checks/services.nix { inherit pkgs home-manager; };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
