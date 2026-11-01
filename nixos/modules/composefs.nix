{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.boot.composefs;

  # Referencing the toplevel in a label puts its closure in the image.
  image = pkgs.dockerTools.streamLayeredImage {
    name = "nixos";
    # cfsctl requires these directories to exist when computing a composefs digest.
    extraCommands = "mkdir usr boot sysroot";
    config.Labels."org.nixos.toplevel" = "${config.system.build.toplevel}";
  };
in
{
  options.boot.composefs = {
    enable = lib.mkEnableOption "booting from a sealed composefs image";

    package = lib.mkPackageOption pkgs "composefs-ctl" {
      # We use buildPackages so that the digest is computed with the build
      # platform's composefs-ctl, allowing for cross-compiled systems to work.
      default = [
        "buildPackages"
        "composefs-ctl"
      ];
    };
  };

  config = lib.mkIf cfg.enable {
    # An OCI image layout, addressed as oci:<path>:latest.
    system.build.composefsImage =
      pkgs.runCommand
        "nixos-composefs-image-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}"
        { nativeBuildInputs = [ pkgs.skopeo ]; }
        ''
          ${image} > image.tar
          skopeo --insecure-policy copy --quiet docker-archive:image.tar oci:$out:latest
        '';

    # The composefs digest of the image's root filesystem.
    system.build.composefsDigest =
      pkgs.runCommand
        "nixos-composefs-digest-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}"
        { nativeBuildInputs = [ cfg.package ]; }
        ''
          # The build's filesystem may lack fs-verity, which computing the digest doesn't need.
          cfsctl --repo repo init --insecure
          cfsctl --repo repo oci pull oci:${config.system.build.composefsImage}:latest nixos
          cfsctl --repo repo oci compute-id --bootable nixos > $out
        '';
  };
}
