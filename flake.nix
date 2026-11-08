{
  description = "Boot NixOS from sealed bootc images";

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
        bootc = ./nixos/modules/bootc.nix;
        default = self.nixosModules.bootc;
      };

      nixosConfigurations.example = lib.nixosSystem {
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

      apps = forAllSystems (system: {
        vm = {
          type = "app";
          program =
            lib.getExe
              (nixpkgs.legacyPackages.${system}.testers.runNixOSTest ./nixos/tests/bootc/shell.nix).driver;
          meta.description = "Boot the example system with Secure Boot and open a root shell";
        };
        dive =
          let
            pkgs = nixpkgs.legacyPackages.${system};
            image = self.checks.${system}.image;
            # dive cannot read an OCI image layout, only a Docker archive.
            archive =
              pkgs.runCommand "${image.name}-docker-archive.tar"
                {
                  nativeBuildInputs = [ pkgs.skopeo ];
                }
                ''
                  HOME=$TMPDIR skopeo --insecure-policy --tmpdir $TMPDIR copy \
                    oci:${image}:latest docker-archive:$out:nixos:latest
                '';
          in
          {
            type = "app";
            program = lib.getExe (
              pkgs.writeShellApplication {
                name = "dive-image";
                runtimeInputs = [ pkgs.dive ];
                text = ''exec dive --source docker-archive ${archive} "$@"'';
              }
            );
            meta.description = "Inspect the example composefs image with dive";
          };
      });

      formatter = forAllSystems (system: treefmt nixpkgs.legacyPackages.${system});

      checks = forAllSystems (
        system:
        let
          inherit (nixpkgs.legacyPackages.${system}.testers) runNixOSTest;
        in
        lib.mapAttrs' (name: lib.nameValuePair "package-${name}") self.packages.${system}
        // {
          formatting = (treefmt nixpkgs.legacyPackages.${system}).check self;
          vm-test = runNixOSTest ./nixos/tests/bootc/basic.nix;
          vm-test-secure-boot = runNixOSTest ./nixos/tests/bootc/secure-boot.nix;
          image = self.checks.${system}.vm-test.nodes.machine.system.build.bootcImage;
        }
      );
    };
}
