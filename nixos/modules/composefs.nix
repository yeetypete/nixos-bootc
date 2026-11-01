{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.boot.composefs;

  settingsFormat = pkgs.formats.toml { };

  inherit (config.system.boot.loader) ukiFile;

  # Referencing the toplevel in a label puts its closure in the image.
  image = pkgs.dockerTools.streamLayeredImage {
    name = "nixos";
    # cfsctl requires these directories to exist when computing a composefs digest.
    extraCommands = "mkdir usr boot sysroot";
    config.Labels."org.nixos.toplevel" = "${config.system.build.toplevel}";
  };

  # intermediate system image without the UKI
  intermediateImage =
    pkgs.runCommand
      "nixos-composefs-image-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}-intermediate"
      { nativeBuildInputs = [ pkgs.skopeo ]; }
      ''
        ${image} > image.tar
        skopeo --insecure-policy copy --quiet docker-archive:image.tar oci:$out:latest
      '';
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

    setupRoot = {
      package = lib.mkPackageOption pkgs "composefs-setup-root" { };

      settings = lib.mkOption {
        type = lib.types.submodule { freeformType = settingsFormat.type; };
        default = { };
        description = ''
          Configuration for composefs-setup-root,
          see <https://github.com/containers/composefs-rs> for documentation.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    boot.composefs.setupRoot.settings = {
      # A tmpfs over the image, as NixOS writes to the root while booting.
      root.transient = lib.mkDefault true;
      # NixOS sets up /etc itself, in the transient root.
      etc.mount = lib.mkDefault "none";
    };

    boot.initrd.availableKernelModules = [
      "loop"
      "erofs"
      "overlay"
    ];

    system.requiredKernelConfig = with config.lib.kernelConfig; [
      (isEnabled "EROFS_FS")
    ];

    boot.initrd.systemd = {
      storePaths = [ (lib.getExe cfg.setupRoot.package) ];
      contents."/usr/lib/composefs/setup-root-conf.toml".source =
        settingsFormat.generate "setup-root-conf.toml" cfg.setupRoot.settings;

      services.composefs-setup-root = {
        description = "Mount the composefs image as the root filesystem";
        unitConfig = {
          DefaultDependencies = false;
          ConditionKernelCommandLine = [
            "|composefs"
            "|composefs.digest"
          ];
          OnFailure = "emergency.target";
          OnFailureJobMode = "isolate";
        };
        # composefs-setup-root replaces the physical root at /sysroot with the
        # image, which NixOS then looks for its closure, /etc and /run in.
        requires = [ "sysroot.mount" ];
        after = [ "sysroot.mount" ];
        before = [
          "initrd-root-fs.target"
          "initrd-find-nixos-closure.service"
          "initrd-find-etc.service"
          "sysroot-etc.mount"
          "sysroot-run.mount"
        ];
        wantedBy = [ "initrd-root-fs.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe cfg.setupRoot.package;
        };
      };
    };

    # The composefs digest of the image's root filesystem.
    system.build.composefsDigest =
      pkgs.runCommand
        "nixos-composefs-digest-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}"
        { nativeBuildInputs = [ cfg.package ]; }
        ''
          # The build's filesystem may lack fs-verity, which computing the digest doesn't need.
          cfsctl --repo repo init --insecure
          cfsctl --repo repo oci pull oci:${intermediateImage}:latest nixos
          cfsctl --repo repo oci compute-id --bootable nixos > $out
        '';

    # UKI with embedded composefs digest from intermediateImage
    system.build.uki =
      let
        cmdline = "init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}";
      in
      # override the default UKI
      lib.mkOverride 99 (
        pkgs.runCommand ukiFile { nativeBuildInputs = [ pkgs.buildPackages.systemdUkify ]; } ''
          mkdir -p $out
          ukify build \
            --config=${config.boot.uki.configFile} \
            --cmdline="${cmdline} composefs.digest=v1-sha512-12:$(< ${config.system.build.composefsDigest})" \
            --output="$out/${ukiFile}"
        ''
      );

    # final system image is created from the intermediate image by injecting the UKI from above,
    # as an OCI image layout addressed as oci:<path>:latest
    system.build.composefsImage =
      pkgs.runCommand
        "nixos-composefs-image-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}"
        {
          nativeBuildInputs = [
            pkgs.umoci
            cfg.package
          ];
        }
        ''
          cp -r --no-preserve=mode ${intermediateImage} $out
          install -D -m 0644 ${config.system.build.uki}/${ukiFile} layer/boot/EFI/Linux/${ukiFile}
          tar --create --file layer.tar --directory layer \
            --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner boot
          umoci raw add-layer --image $out:latest --no-history --compress none layer.tar
          umoci gc --layout $out

          # Adding the UKI must not change the image's digest.
          cfsctl --repo repo init --insecure
          cfsctl --repo repo oci pull oci:$out:latest nixos
          [ "$(cfsctl --repo repo oci compute-id --bootable nixos)" = "$(< ${config.system.build.composefsDigest})" ]
        '';
  };
}
