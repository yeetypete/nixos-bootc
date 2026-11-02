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
  systemdBootFile = "systemd-boot${pkgs.stdenv.hostPlatform.efiArch}.efi";

  # The binaries in /boot in the image, named as in secureBoot.signatures.
  bootFiles = {
    uki = {
      source = "${config.system.build.uki}/${ukiFile}";
      target = "EFI/Linux/${ukiFile}";
    };
    systemd-boot = {
      source = "${config.systemd.package}/lib/systemd/boot/efi/${systemdBootFile}";
      target = "EFI/systemd/${systemdBootFile}";
    };
  };

  sbsign = "${pkgs.buildPackages.systemd}/lib/systemd/systemd-sbsign";

  # Referencing the toplevel in a label puts its closure in the image.
  image = pkgs.dockerTools.streamLayeredImage {
    name = "nixos";
    # cfsctl requires these directories to exist when computing a composefs digest.
    extraCommands = "mkdir usr boot sysroot";
    config.Labels = {
      "org.nixos.toplevel" = "${config.system.build.toplevel}";
    }
    // lib.optionalAttrs (config.system.image.version != null) {
      "org.opencontainers.image.version" = config.system.image.version;
    };
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

    algorithm = lib.mkOption {
      type = lib.types.enum [
        "fsverity-sha256-12"
        "fsverity-sha512-12"
      ];
      default = "fsverity-sha512-12";
      description = ''
        The fs-verity algorithm the image's composefs digest is computed with.
        It must match the algorithm of the composefs repository the image is
        deployed to (set when creating it with `cfsctl init --algorithm`).
      '';
    };

    secureBoot = {
      enable = lib.mkEnableOption "Secure Boot signatures for the UKI and systemd-boot in the image";

      certificate = lib.mkOption {
        type = lib.types.path;
        description = "The db certificate the signatures are verified against.";
      };

      signatures = {
        uki = lib.mkOption {
          type = lib.types.path;
          description = ''
            Offline signature of the `uki` file in
            `config.system.build.composefsSignedData`, e.g. from
            `openssl dgst -sha256 -sign <key>`. See {manpage}`systemd-sbsign(8)`.
          '';
        };

        systemd-boot = lib.mkOption {
          type = lib.types.path;
          description = ''
            Offline signature of the `systemd-boot` file in
            `config.system.build.composefsSignedData`.
          '';
        };
      };
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
    warnings = lib.optional (config.system.image.version == null) ''
      `system.image.version` must be set to a unique, increasing version for
      each image. It determines the image's UKI name and which image
      systemd-boot boots by default.
    '';

    # The image's UKI is the boot entry.
    boot.loader.grub.enable = lib.mkDefault false;

    # An immutable system.etc.overlay sets this placeholder itself.
    #
    # If possible, prefer setting `boot.kernelParams = [ "systemd.machine_id=firmware" ]`
    # for a stable machine ID. Note that this depends on the firmware reporting
    # a unique product UUID.
    environment.etc.machine-id =
      lib.mkIf (!(config.system.etc.overlay.enable && !config.system.etc.overlay.mutable))
        (
          lib.mkDefault {
            text = "";
            mode = "0444";
          }
        );

    boot.composefs.setupRoot.settings = {
      # A tmpfs over the image, as NixOS writes to the root while booting.
      root.transient = lib.mkDefault true;
      # NixOS sets up /etc itself, in the transient root.
      etc.mount = lib.mkDefault "none";
      # NixOS mounts /var itself, below.
      var.mount = lib.mkDefault "none";
    };

    # Shared by all deployments, on the physical root that composefs-setup-root
    # mounts at /sysroot.
    fileSystems."/var" = lib.mkDefault {
      device = "/sysroot/state/os/default/var";
      fsType = "none";
      options = [ "bind" ];
    };

    # The root partition is at /sysroot, not /.
    systemd.services.systemd-growfs-root.serviceConfig.ExecStart = [
      ""
      "${config.systemd.package}/lib/systemd/systemd-growfs /sysroot"
    ];

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
          cfsctl --repo repo init --insecure --algorithm ${cfg.algorithm} --erofs-version 1
          # TERM=dumb hides cfsctl progress bars.
          TERM=dumb cfsctl --repo repo oci pull oci:${intermediateImage}:latest nixos
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
            --cmdline="${cmdline} composefs.digest=v1-${lib.removePrefix "fsverity-" cfg.algorithm}:$(< ${config.system.build.composefsDigest})" \
            --output="$out/${ukiFile}"
        ''
      );

    # The data to sign offline for each binary in the image's /boot, e.g. with:
    #   openssl dgst -sha256 -sign secure-boot-private-key.pem -out uki.sig uki
    system.build.composefsSignedData = lib.mkIf cfg.secureBoot.enable (
      pkgs.runCommand "nixos-composefs-signed-data" { } ''
        mkdir $out
        ${lib.concatMapAttrsStringSep "\n" (name: file: ''
          ${sbsign} sign --certificate=${cfg.secureBoot.certificate} --prepare-offline-signing \
            --output=$out/${name} ${file.source}
        '') bootFiles}
      ''
    );

    # Assemble the image's /boot from the UKI and systemd-boot, optionally signing them with secureBoot.
    system.build.composefsBoot =
      pkgs.runCommand "nixos-composefs-boot"
        { nativeBuildInputs = lib.optional cfg.secureBoot.enable pkgs.openssl; }
        (
          lib.concatMapAttrsStringSep "\n" (
            name: file:
            if cfg.secureBoot.enable then
              let
                inherit (cfg.secureBoot) certificate;
                signedData = "${config.system.build.composefsSignedData}/${name}";
                signature = cfg.secureBoot.signatures.${name};
              in
              ''
                openssl dgst -sha256 -signature ${signature} \
                  -verify <(openssl x509 -pubkey -noout -in ${certificate}) ${signedData}
                mkdir -p $(dirname $out/${file.target})
                ${sbsign} sign --certificate=${certificate} \
                  --signed-data=${signedData} --signed-data-signature=${signature} \
                  --output=$out/${file.target} ${file.source}
              ''
            else
              ''
                install -D -m 0644 ${file.source} $out/${file.target}
              ''
          ) bootFiles
        );

    # final system image is created from the intermediate image by injecting the UKI from above
    # and systemd-boot, as an OCI image layout addressed as oci:<path>:latest
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
          cp -r --no-preserve=mode ${config.system.build.composefsBoot} boot
          tar --create --file layer.tar \
            --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner boot
          umoci raw add-layer --image $out:latest --no-history --compress none layer.tar
          umoci gc --layout $out

          # Adding the UKI must not change the image's digest.
          cfsctl --repo repo init --insecure --algorithm ${cfg.algorithm} --erofs-version 1
          TERM=dumb cfsctl --repo repo oci pull oci:$out:latest nixos
          [ "$(cfsctl --repo repo oci compute-id --bootable nixos)" = "$(< ${config.system.build.composefsDigest})" ]
        '';
  };
}
