# Boot the machine from the Secure Boot test and open a root shell in it.
{ lib, hostPkgs, ... }:
let
  # The same keys as in the Secure Boot test.
  keys = hostPkgs.callPackage ./secure-boot-keys.nix { };
in
{
  imports = [ ./composefs-secure-boot.nix ];

  name = lib.mkForce "composefs-shell";

  sshBackdoor.enable = true;

  testScript = lib.mkForce (
    { nodes, ... }:
    ''
      ${import ./common/composefs-disk.nix {
        inherit lib hostPkgs;
        machine = nodes.machine;
        espFiles = [ "${keys}/auto:/loader/keys/auto" ];
      }}

      # systemd-boot enrolls the keys and reboots.
      machine.start(allow_reboot=True)
      machine.wait_for_unit("multi-user.target")
      serial_stdout_off()

      subprocess.run(["${lib.getExe hostPkgs.openssh_gssapi}", f"vsock-mux/{machine.vsock_host}"])
    ''
  );
}
