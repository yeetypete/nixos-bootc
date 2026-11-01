{
  boot.composefs.enable = true;

  # The system is immutable and must be updated by deploying a new image.
  nix.enable = false;
  system.switch.enable = false;

  # Find the partition holding the composefs repository by its GPT type.
  boot.initrd.systemd.root = "gpt-auto";
  boot.initrd.supportedFilesystems.ext4 = true;

  system.stateVersion = "26.05";
}
