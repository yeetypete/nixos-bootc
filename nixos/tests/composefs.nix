# Boot a disk with the system's sealed image deployed to a composefs
# repository.
{ lib, hostPkgs, ... }:
{
  name = "composefs";

  nodes.machine = ./common/composefs-machine.nix;

  testScript =
    { nodes, ... }:
    ''
      ${import ./common/composefs-disk.nix {
        inherit lib hostPkgs;
        machine = nodes.machine;
      }}

      machine.wait_for_unit("multi-user.target")

      ${import ./common/composefs-subtests.nix {
        inherit lib;
        machine = nodes.machine;
      }}
    '';
}
