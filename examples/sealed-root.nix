{
  boot.composefs.enable = true;

  # Until the module provides them.
  boot.loader.grub.enable = false;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  system.stateVersion = "26.05";
}
