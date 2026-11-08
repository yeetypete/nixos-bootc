{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.boot.bootc;

  settingsFormat = pkgs.formats.toml { };

  inherit (config.system.boot.loader) ukiFile;
  systemdBootFile = "systemd-boot${pkgs.stdenv.hostPlatform.efiArch}.efi";

  # The binaries to sign, by the names in secureBoot.signatures.
  bootFiles = {
    uki = "${config.system.build.uki}/${ukiFile}";
    systemd-boot = "${config.systemd.package}/lib/systemd/boot/efi/${systemdBootFile}";
  };

  imageSuffix = "${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";

  setupRootConf = settingsFormat.generate "setup-root-conf.toml" cfg.setupRoot.settings;
  installConf = settingsFormat.generate "bootc-install.toml" cfg.install.settings;

  sbsign = "${pkgs.buildPackages.systemd}/lib/systemd/systemd-sbsign";

  # The data to sign offline for a binary, e.g. with:
  #   openssl dgst -sha256 -sign secure-boot-private-key.pem -out uki.sig uki
  signedData =
    name: file:
    pkgs.runCommand "nixos-bootc-signed-data-${name}" { } ''
      ${sbsign} sign --certificate=${cfg.secureBoot.certificate} --prepare-offline-signing \
        --output=$out ${file}
    '';

  signed =
    name:
    let
      inherit (cfg.secureBoot) certificate;
      file = bootFiles.${name};
      data = signedData name file;
      signature = cfg.secureBoot.signatures.${name};
    in
    pkgs.runCommand "nixos-bootc-signed-${name}" { nativeBuildInputs = [ pkgs.buildPackages.openssl ]; }
      ''
        openssl dgst -sha256 -signature ${signature} \
          -verify <(openssl x509 -pubkey -noout -in ${certificate}) ${data}
        ${sbsign} sign --certificate=${certificate} \
          --signed-data=${data} --signed-data-signature=${signature} \
          --output=$out ${file}
      '';

  # fromImage only inherits Env.
  imageConfig = {
    Cmd = [ "${config.system.build.toplevel}/init" ];
    Labels = {
      "containers.bootc" = "1";
    }
    // lib.optionalAttrs (config.system.image.version != null) {
      "org.opencontainers.image.version" = config.system.image.version;
    };
  };

  unsealedLayers = 100;

  # The image without the UKI.
  unsealedImage = pkgs.dockerTools.buildLayeredImage {
    name = "nixos";
    tag = "unsealed";
    compressor = "none";
    maxLayers = unsealedLayers;
    config = imageConfig;
    # Directories and files bootc, bootctl expect in the image at fixed paths.
    extraCommands = ''
      mkdir -p usr/lib/composefs usr/lib/bootc/install boot sysroot etc var tmp
      chmod 1777 tmp
      # bootctl --root and bootc read these from the image.
      cp ${config.environment.etc."os-release".source} usr/lib/os-release
      cp ${setupRootConf} usr/lib/composefs/setup-root-conf.toml
      cp ${installConf} usr/lib/bootc/install/00-nixos.toml
    ''
    # bootctl install --root prefers systemd-boot*.efi.signed if placed next to the
    # unsigned binary.
    + lib.optionalString cfg.secureBoot.enable ''
      dir=.${dirOf bootFiles.systemd-boot}
      mkdir -p $dir
      cp ${signed "systemd-boot"} $dir/${systemdBootFile}.signed
      chmod -R a-w .${config.systemd.package}
    ''
    + lib.optionalString (cfg.secureBoot.enable && cfg.secureBoot.enrollKeys != null) ''
      mkdir -p usr/lib/bootc/install/secureboot-keys
      cp -r ${cfg.secureBoot.enrollKeys} usr/lib/bootc/install/secureboot-keys/auto
    '';
  };

  # Excluding store paths the UKI references keeps the digest unchanged.
  sealedImage = pkgs.dockerTools.streamLayeredImage {
    name = "nixos";
    tag = "latest";
    fromImage = unsealedImage;
    includeStorePaths = false;
    # The base image's layers count towards the limit.
    maxLayers = unsealedLayers + 2;
    config = imageConfig;
    extraCommands = ''
      cp -r --no-preserve=mode ${bootDir} boot
    '';
  };

  # TERM=dumb hides progress bars.
  # compute-composefs-digest needs /var/tmp which does not exist in the sandbox.
  # --insecure is required as the build directory's filesystem may lack fs-verity.
  cfs = ''
    export TERM=dumb
    cfs() { bootc internals cfs -- --repo $PWD/repo "$@"; }
    bootc internals cfs -- init --insecure $PWD/repo
  '';

  bootDir = pkgs.runCommand "nixos-bootc-boot" { } ''
    install -D -m 0644 ${
      if cfg.secureBoot.enable then signed "uki" else bootFiles.uki
    } $out/EFI/Linux/${ukiFile}
  '';
in
{
  options.boot.bootc = {
    enable = lib.mkEnableOption "booting from a sealed bootc image";

    package = lib.mkOption {
      type = lib.types.package;
      # Use the image's systemd, so that bootctl finds the signed systemd-boot.
      default = pkgs.callPackage ../../pkgs/bootc/package.nix {
        systemd = config.systemd.package;
        withPre615 = lib.versionOlder config.boot.kernelPackages.kernel.version "6.15";
      };
      defaultText = lib.literalMD "bootc, built with `config.systemd.package`";
      description = "The bootc package used at runtime, in the system and its initrd.";
    };

    buildPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.buildPackages.callPackage ../../pkgs/bootc/package.nix { };
      defaultText = lib.literalMD "bootc for the build platform";
      description = "The bootc package used at build time to compute the image's composefs digest.";
    };

    secureBoot = {
      enable = lib.mkEnableOption "Secure Boot signing of the UKI and systemd-boot";

      certificate = lib.mkOption {
        type = lib.types.path;
        description = "The db certificate the signatures are verified against.";
      };

      enrollKeys = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "A directory of PK, KEK and db .auth files for systemd-boot to enroll.";
      };

      signatures = {
        uki = lib.mkOption {
          type = lib.types.path;
          description = ''
            Offline signature of `config.system.build.bootcSignedData.uki`,
            e.g. from `openssl dgst -sha256 -sign <key>`.
            See {manpage}`systemd-sbsign(8)`.
          '';
        };

        systemd-boot = lib.mkOption {
          type = lib.types.path;
          description = ''
            Offline signature of `config.system.build.bootcSignedData.systemd-boot`.
            It is part of the image's composefs digest, so sign this before the UKI.
          '';
        };
      };
    };

    install.settings = lib.mkOption {
      inherit (settingsFormat) type;
      default = { };
      description = ''
        Configuration for `bootc install`, shipped in the image. Only read when
        bootc runs from the image. See {manpage}`bootc-install-config.toml(5)`.
      '';
    };

    setupRoot.settings = lib.mkOption {
      inherit (settingsFormat) type;
      default = { };
      description = ''
        Configuration for `bootc-root-setup.service`.
        See {manpage}`bootc-setup-root-conf.toml(5)`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.loader.grub.enable = lib.mkDefault false;

    # An immutable system.etc.overlay sets this placeholder itself.
    environment.etc.machine-id =
      lib.mkIf (!config.system.etc.overlay.enable || config.system.etc.overlay.mutable)
        (
          lib.mkDefault {
            text = "";
            mode = "0444";
          }
        );

    boot.bootc.install.settings.install = {
      filesystem.root.type = lib.mkDefault "ext4";
      bootloader = lib.mkDefault "systemd";
    };

    boot.bootc.setupRoot.settings = {
      # NixOS writes to the root while booting, so it must be writable.
      root.transient = lib.mkDefault true;
      # NixOS sets up /etc itself, in the transient root.
      etc.mount = lib.mkDefault "none";
    };

    boot.initrd.availableKernelModules = [
      "erofs"
      "overlay"
    ];

    system.requiredKernelConfig = [ (config.lib.kernelConfig.isEnabled "EROFS_FS") ];

    # `bootc install` uses the Discoverable Partitions Specification.
    boot.initrd.supportedFilesystems.${cfg.install.settings.install.filesystem.root.type} =
      lib.mkDefault true;

    boot.initrd.systemd = {
      root = lib.mkDefault "gpt-auto";
      packages = [ cfg.package.initramfs ];
      storePaths = [ cfg.package.initramfs ];
      contents."/usr/lib/composefs/setup-root-conf.toml".source = setupRootConf;

      # bootc's unit replaces the physical root at /sysroot with the image.
      # NixOS then looks for its closure, /etc and /run in the image.
      services.bootc-root-setup = {
        before = [
          "initrd-find-nixos-closure.service"
          "initrd-find-etc.service"
          "sysroot-etc.mount"
          "sysroot-run.mount"
        ];
        wantedBy = [ "initrd-root-fs.target" ];
      };
    };

    environment.systemPackages = [ cfg.package ];
    systemd.packages = [ cfg.package ];
    # Pulling from a registry or containers-storage needs /etc/containers.
    virtualisation.containers.enable = true;

    system.build.composefsDigest =
      pkgs.runCommand "nixos-bootc-digest-${imageSuffix}"
        {
          nativeBuildInputs = [
            pkgs.buildPackages.skopeo
            cfg.buildPackage
          ];
        }
        ''
          skopeo --insecure-policy copy --quiet docker-archive:${unsealedImage} oci:$PWD/image:latest
          ${cfs}
          cfs oci pull oci:$PWD/image:latest nixos
          cfs --erofs-version 1 oci compute-id --bootable nixos > $out
        '';

    boot.uki.settings.UKI.Cmdline = "@${
      pkgs.runCommand "nixos-bootc-cmdline" { } ''
        printf '%s%s' ${lib.escapeShellArg "init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams} composefs.digest=v1-sha512-12:"} "$(< ${config.system.build.composefsDigest})" > $out
      ''
    }";

    system.build.bootcSignedData = lib.mkIf cfg.secureBoot.enable (lib.mapAttrs signedData bootFiles);

    system.build.bootcImage =
      pkgs.runCommand "nixos-bootc-image-${imageSuffix}"
        {
          nativeBuildInputs = [
            pkgs.buildPackages.skopeo
            cfg.buildPackage
          ];
        }
        ''
          ${sealedImage} > image.tar
          skopeo --insecure-policy copy --quiet docker-archive:image.tar oci:$out:latest

          # Adding the UKI must not change the image's digest.
          ${cfs}
          cfs oci pull oci:$out:latest nixos
          [ "$(cfs --erofs-version 1 oci compute-id --bootable nixos)" = "$(< ${config.system.build.composefsDigest})" ]
        '';
  };
}
