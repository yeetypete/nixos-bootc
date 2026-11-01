{
  boot.composefs.enable = true;

  # The system is immutable and must be updated by deploying a new image.
  nix.enable = false;
  system.switch.enable = false;

  # The partition holding the composefs repository.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  system.stateVersion = "26.05";
}
