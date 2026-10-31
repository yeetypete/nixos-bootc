{
  description = "Boot NixOS from sealed composefs images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];

      treefmt =
        pkgs:
        pkgs.nixfmt-tree.override {
          settings.formatter.nixf-diagnose = {
            command = lib.getExe pkgs.nixf-diagnose;
            options = [ "--auto-fix" ];
            includes = [ "*.nix" ];
            # Ensure nixfmt cleans up after nixf-diagnose.
            priority = -1;
          };
        };
    in
    {
      packages = forAllSystems (
        system:
        lib.packagesFromDirectoryRecursive {
          inherit (nixpkgs.legacyPackages.${system}) callPackage;
          directory = ./pkgs;
        }
      );

      formatter = forAllSystems (system: treefmt nixpkgs.legacyPackages.${system});

      checks = forAllSystems (
        system:
        lib.mapAttrs' (name: lib.nameValuePair "package-${name}") self.packages.${system}
        // {
          formatting = (treefmt nixpkgs.legacyPackages.${system}).check self;
        }
      );
    };
}
