# A machine booting from a disk produced by composefs-disk.nix.
{ config, lib, ... }:
{
  boot.composefs.enable = true;
  environment.systemPackages = [ config.boot.composefs.package ];

  virtualisation = {
    directBoot.enable = false;
    mountHostNixStore = false;
    useEFIBoot = true;
    # Override the qemu-vm module's filesystems with the configured fileSystems.
    fileSystems = lib.mkForce { };
  };

  boot.initrd.systemd.root = "gpt-auto";
  boot.initrd.supportedFilesystems.ext4 = true;
}
