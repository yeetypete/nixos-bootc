{
  boot.bootc.enable = true;

  system.image.version = "1";

  # The system is immutable and must be updated by deploying a new image.
  nix.enable = false;
  system.switch.enable = false;

  system.stateVersion = "26.05";
}
