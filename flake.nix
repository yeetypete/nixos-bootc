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
      nixosModules = {
        composefs =
          { pkgs, ... }:
          {
            imports = [ ./nixos/modules/composefs.nix ];
            boot.composefs = {
              package = lib.mkDefault (pkgs.buildPackages.callPackage ./pkgs/composefs-ctl/package.nix { });
              setupRoot.package = lib.mkDefault (pkgs.callPackage ./pkgs/composefs-setup-root/package.nix { });
            };
          };
        default = self.nixosModules.composefs;
      };

      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        modules = [
          self.nixosModules.default
          ./examples/sealed-root.nix
          { nixpkgs.hostPlatform = "x86_64-linux"; }
        ];
      };

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
