# A disk with the machine's sealed image deployed to a composefs repository.
# Returns Python to boot the machine from a copy of it.
{
  lib,
  hostPkgs,
  machine,
  # Additional repart CopyFiles for the ESP.
  espFiles ? [ ],
}:
let
  inherit (machine) boot system;
  inherit (machine.nixpkgs.hostPlatform) efiArch;

  # This disk layout matches what an installer would create.
  repartDefinitions = hostPkgs.linkFarm "repart.d" (
    lib.mapAttrs (name: (hostPkgs.formats.ini { listsAsDuplicateKeys = true; }).generate name) {
      "10-esp.conf".Partition = {
        Type = "esp";
        Format = "vfat";
        SizeMinBytes = "256M";
        SizeMaxBytes = "256M";
        CopyFiles = [
          "${system.build.composefsBoot}/EFI/systemd/systemd-boot${efiArch}.efi:/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI"
          "${system.build.composefsBoot}/EFI/Linux:/EFI/Linux"
        ]
        ++ espFiles;
      };
      "20-root.conf".Partition = {
        Type = "root";
        Format = "ext4";
        MakeDirectories = "/state/os/default/var";
      };
    }
  );

  disk = hostPkgs.vmTools.runInLinuxVM (
    hostPkgs.runCommand "composefs-disk"
      {
        nativeBuildInputs = [
          hostPkgs.systemd
          hostPkgs.dosfstools
          hostPkgs.e2fsprogs
          hostPkgs.util-linux
          boot.composefs.package
        ];
        preVM = hostPkgs.vmTools.createEmptyImage {
          size = 4096;
          fullName = "composefs-disk";
        };
      }
      ''
        # composefs requires fs-verity on the root's files.
        SYSTEMD_REPART_MKFS_OPTIONS_EXT4="-O verity" \
          systemd-repart --empty=require --dry-run=no --definitions=${repartDefinitions} /dev/vda

        mount --mkdir /dev/vda2 /mnt
        cfsctl --repo /mnt/composefs init --algorithm ${boot.composefs.algorithm} --erofs-version 1
        TERM=dumb cfsctl --repo /mnt/composefs oci pull --bootable oci:${system.build.composefsImage}:latest nixos
        # composefs-setup-root requires the deployment's state directory.
        mkdir -p /mnt/state/deploy/$(< ${system.build.composefsDigest})
        umount /mnt
      ''
  );
in
''
  import os
  import subprocess
  import tempfile

  tmp_disk_image = tempfile.NamedTemporaryFile()
  subprocess.run([
    "${machine.virtualisation.qemu.package}/bin/qemu-img",
    "create", "--format", "qcow2",
    "--backing", "${disk}/disk-image.qcow2", "--backing-format", "qcow2",
    tmp_disk_image.name,
  ], check=True)
  os.environ["NIX_DISK_IMAGE"] = tmp_disk_image.name
''
