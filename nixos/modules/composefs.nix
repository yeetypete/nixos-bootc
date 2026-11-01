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
    config.Labels."org.nixos.toplevel" = "${config.system.build.toplevel}";
  };
in
{
  options.boot.composefs = {
    enable = lib.mkEnableOption "booting from a sealed composefs image";
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
  };
}
